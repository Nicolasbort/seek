import Darwin
import Foundation

enum Kind: UInt8 { case file = 0, folder = 1, app = 2 }

/// Lowercased, accent-folded UTF-8 bytes used for matching. ASCII names take a fast path.
@inline(__always)
func foldKey(_ s: String) -> [UInt8] {
    var ascii = true
    for b in s.utf8 where b >= 0x80 { ascii = false; break }
    if ascii { return s.utf8.map { ($0 >= 65 && $0 <= 90) ? $0 | 0x20 : $0 } }
    // Fold case/accents/width, then recompose (file names may be stored decomposed, e.g. Hangul jamo).
    let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return Array(folded.precomposedStringWithCanonicalMapping.utf8)
}

/// An immutable view of the index handed to the search engine. Arrays are copy-on-write,
/// so publishing a snapshot costs nothing until the indexer next mutates.
struct Snapshot {
    let generation: Int
    let paths: [String]
    let keyBytes: [UInt8]   // all match keys, back to back
    let keyStart: [UInt32]  // key i is keyBytes[keyStart[i]..<keyStart[i+1]]
    let kinds: [UInt8]
    let depths: [UInt8]
    let alive: [Bool]
    let boosts: [Int32]
    let liveCount: Int
    let indexing: Bool
}

struct PathFilter {
    let roots: [String]
    let excludeNames: Set<String>
    let excludePaths: [String]
    let excludePatterns: [String]
    private let excludeRegexes: [NSRegularExpression]
    let includeHidden: Bool

    /// Directories that behave like files: shown as one result, never descended into.
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "prefpane", "appex", "xpc", "qlgenerator",
        "photoslibrary", "musiclibrary", "tvlibrary", "photoboothlibrary", "imovielibrary", "fcpbundle",
        "xcodeproj", "xcworkspace", "xcarchive", "playground", "pkg", "mpkg", "rtfd", "pages", "numbers",
        "key", "band", "logicx", "scriptd", "workflow", "sparsebundle", "dsym", "nib", "car",
    ]

    init(config: Config) {
        roots = config.roots.map(PathFilter.normalize)
        excludeNames = Set(config.excludeNames)
        excludePaths = config.excludePaths.map(PathFilter.normalize)
        excludePatterns = config.excludePatterns
        excludeRegexes = config.excludePatterns.compactMap(PathFilter.compile)
        includeHidden = config.includeHidden
    }

    /// Compiles an exclude pattern, expanding a leading "~" / "^~" to the home folder.
    static func compile(_ pattern: String) -> NSRegularExpression? {
        var p = pattern
        let home = NSRegularExpression.escapedPattern(for: NSHomeDirectory())
        if p.hasPrefix("^~") { p = "^" + home + p.dropFirst(2) }
        else if p.hasPrefix("~") { p = "^" + home + p.dropFirst(1) }
        do { return try NSRegularExpression(pattern: p) }
        catch { NSLog("Seek: ignoring invalid excludePatterns entry \"\(pattern)\": \(error)"); return nil }
    }

    /// Whether a folder path matches one of the `excludePatterns`.
    func matchesExcludePattern(_ path: String) -> Bool {
        guard !excludeRegexes.isEmpty else { return false }
        let range = NSRange(path.startIndex..., in: path)
        for r in excludeRegexes where r.firstMatch(in: path, range: range) != nil { return true }
        return false
    }

    /// Identifies the settings an on-disk cache was built with.
    var signature: String {
        "v2|\(roots.joined(separator: ":"))|\(excludeNames.sorted().joined(separator: ":"))|"
            + "\(excludePaths.joined(separator: ":"))|\(includeHidden)|"
            + excludePatterns.joined(separator: "\u{1F}")
    }

    static func normalize(_ p: String) -> String {
        var s = (p as NSString).expandingTildeInPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    static func isPackage(_ name: String) -> Bool { packageExtensions.contains(ext(name)) }

    func isExcludedPath(_ p: String) -> Bool {
        for e in excludePaths where p == e || p.hasPrefix(e + "/") { return true }
        return false
    }

    func skipName(_ name: String) -> Bool {
        (!includeHidden && name.hasPrefix(".")) || excludeNames.contains(name)
    }

    /// Whether a path reported by FSEvents belongs in the index.
    func shouldIndex(_ path: String) -> Bool {
        if isExcludedPath(path) { return false }
        var root: String?
        for r in roots where path.hasPrefix(r + "/") {
            if root == nil || r.count > root!.count { root = r }
        }
        guard let root, !PathFilter.isPackage((root as NSString).lastPathComponent) else { return false }
        let comps = path.dropFirst(root.count + 1).split(separator: "/")
        var dir = root
        for (i, c) in comps.enumerated() {
            let name = String(c)
            if skipName(name) { return false }
            let isLast = i == comps.count - 1
            if !isLast && PathFilter.isPackage(name) { return false } // inside a bundle
            dir += "/" + name
            if matchesExcludePattern(dir) {
                if !isLast { return false } // under an excluded folder
                var isDir: ObjCBool = false     // patterns apply to folders only
                if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue { return false }
            }
        }
        return true
    }
}

/// Column-oriented storage for index entries.
struct Store {
    var paths: [String] = []
    var keyBytes: [UInt8] = []
    var keyStart: [UInt32] = [0]
    var kinds: [UInt8] = []
    var depths: [UInt8] = []
    var alive: [Bool] = []
    var boosts: [Int32] = []
    var indexOf: [String: Int32] = [:]
    var dead = 0

    var live: Int { paths.count - dead }

    static func displayName(_ name: String, kind: Kind) -> String {
        (kind == .app && name.lowercased().hasSuffix(".app")) ? String(name.dropLast(4)) : name
    }

    mutating func add(path: String, name: String, kind: Kind, boost: Int32) {
        if indexOf[path] != nil { return }
        let idx = Int32(paths.count)
        paths.append(path)
        keyBytes.append(contentsOf: foldKey(Store.displayName(name, kind: kind)))
        keyStart.append(UInt32(keyBytes.count))
        kinds.append(kind.rawValue)
        var depth = 0
        for b in path.utf8 where b == 47 { depth += 1 }
        depths.append(UInt8(min(depth, 255)))
        alive.append(true)
        boosts.append(boost)
        indexOf[path] = idx
    }

    mutating func kill(_ i: Int) {
        guard alive[i] else { return }
        alive[i] = false
        indexOf.removeValue(forKey: paths[i])
        dead += 1
    }

    mutating func removeDescendants(of path: String) {
        let prefix = path + "/"
        var victims: [Int32] = []
        for (p, i) in indexOf where p.hasPrefix(prefix) { victims.append(i) }
        for i in victims { kill(Int(i)) }
    }

    mutating func compact() {
        guard dead > 0 else { return }
        var s = Store()
        let n = live
        s.paths.reserveCapacity(n); s.kinds.reserveCapacity(n); s.depths.reserveCapacity(n)
        s.alive.reserveCapacity(n); s.boosts.reserveCapacity(n); s.keyStart.reserveCapacity(n + 1)
        s.keyBytes.reserveCapacity(keyBytes.count); s.indexOf.reserveCapacity(n)
        for i in 0..<paths.count where alive[i] {
            s.indexOf[paths[i]] = Int32(s.paths.count)
            s.paths.append(paths[i])
            s.keyBytes.append(contentsOf: keyBytes[Int(keyStart[i])..<Int(keyStart[i + 1])])
            s.keyStart.append(UInt32(s.keyBytes.count))
            s.kinds.append(kinds[i]); s.depths.append(depths[i]); s.alive.append(true); s.boosts.append(boosts[i])
        }
        self = s
    }
}

/// The live, mutable index. All mutation happens on `queue`.
final class FileIndex {
    let queue = DispatchQueue(label: "seek.index", qos: .userInitiated)
    /// Called on `queue` whenever a new snapshot is ready.
    var onPublish: ((Snapshot) -> Void)?
    /// Called on `queue` when a file is created or modified (for "recent files").
    var onTouched: ((String) -> Void)?

    private var filter: PathFilter
    private var usage: [String: Int]
    private var store = Store()
    private var generation = 0
    private var indexing = false
    private var publishScheduled = false
    private var cacheSaveScheduled = false
    private var watcher: Watcher?

    init(config: Config, usage: [String: Int]) {
        filter = PathFilter(config: config)
        self.usage = usage
    }

    // MARK: Public

    /// Loads the on-disk cache (instant results), then re-walks everything in the background and swaps.
    func rebuild(config: Config? = nil, watch: Bool = true, useCache: Bool = true, completion: (() -> Void)? = nil) {
        queue.async {
            if let config { self.filter = PathFilter(config: config) }
            self.watcher?.stop()
            self.watcher = nil
            self.indexing = true

            var hadCache = false
            if useCache, let cached = IndexCache.load(signature: self.filter.signature) {
                self.store = cached
                for (p, c) in self.usage { if let i = self.store.indexOf[p] { self.store.boosts[Int(i)] = Knowledge.boost(c) } }
                hadCache = true
            } else {
                self.store = Store()
            }
            self.publish()

            let start = CFAbsoluteTimeGetCurrent()
            if watch {
                let watchable = self.filter.roots.filter {
                    FileManager.default.fileExists(atPath: $0) && !PathFilter.isPackage(($0 as NSString).lastPathComponent)
                }
                // Events that arrive during the scan queue up behind it on `queue`.
                self.watcher = Watcher(paths: watchable, queue: self.queue) { [weak self] in self?.apply($0) }
            }

            var fresh = Store()
            let progress: ((Store) -> Void)? = hadCache ? nil : { [weak self] partial in self?.publish(partial) }
            for root in self.filter.roots { self.scan(root, into: &fresh, includeRoot: false, progress: progress) }
            self.store = fresh
            self.indexing = false
            NSLog("Seek: indexed %d items in %.2fs", self.store.live, CFAbsoluteTimeGetCurrent() - start)
            self.publish()
            IndexCache.save(self.store, signature: self.filter.signature)
            completion?()
        }
    }

    func setUsage(_ path: String, count: Int) {
        queue.async {
            self.usage[path] = count
            if let i = self.store.indexOf[path] {
                self.store.boosts[Int(i)] = Knowledge.boost(count)
                self.schedulePublish()
            }
        }
    }

    func saveCacheNow() {
        queue.sync { if !indexing { IndexCache.save(store, signature: filter.signature) } }
    }

    // MARK: Publishing

    private func publish(_ s: Store? = nil) {
        if s == nil && store.dead > 20_000 && store.dead > store.paths.count / 4 { store.compact() }
        let st = s ?? store
        generation += 1
        onPublish?(Snapshot(generation: generation, paths: st.paths, keyBytes: st.keyBytes, keyStart: st.keyStart,
                            kinds: st.kinds, depths: st.depths, alive: st.alive, boosts: st.boosts,
                            liveCount: st.live, indexing: indexing))
    }

    private func schedulePublish() {
        if !publishScheduled {
            publishScheduled = true
            queue.asyncAfter(deadline: .now() + 0.2) {
                self.publishScheduled = false
                self.publish()
            }
        }
        if !cacheSaveScheduled {
            cacheSaveScheduled = true
            queue.asyncAfter(deadline: .now() + 120) {
                self.cacheSaveScheduled = false
                if !self.indexing { IndexCache.save(self.store, signature: self.filter.signature) }
            }
        }
    }

    private func boost(_ path: String) -> Int32 {
        usage.isEmpty ? 0 : Knowledge.boost(usage[path] ?? 0)
    }

    // MARK: Scanning

    /// Walks a tree with fts(3) without stat()ing files (d_type only), which is what makes it fast.
    private func scan(_ root: String, into store: inout Store, includeRoot: Bool, progress: ((Store) -> Void)?) {
        guard let cRoot = strdup(root) else { return }
        defer { free(cRoot) }
        let argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) else { return }
        defer { fts_close(fts) }

        var added = 0
        while let ent = fts_read(fts) {
            let e = ent.pointee
            let info = Int32(e.fts_info)
            let isDir = info == FTS_D
            guard isDir || info == FTS_F || info == FTS_NSOK || info == FTS_SL
                    || info == FTS_SLNONE || info == FTS_DEFAULT else { continue }
            guard let cPath = e.fts_path else { continue }

            let level = Int(e.fts_level)
            let pathLen = Int(e.fts_pathlen)
            let nameLen = Int(e.fts_namelen)
            let raw = UnsafeRawPointer(cPath)
            let path = String(decoding: UnsafeRawBufferPointer(start: raw, count: pathLen), as: UTF8.self)

            let name: String
            if level == 0 {
                name = (path as NSString).lastPathComponent
            } else {
                let nb = UnsafeRawBufferPointer(start: raw + (pathLen - nameLen), count: nameLen)
                if !filter.includeHidden && nameLen > 0 && nb[0] == 0x2E { // "."
                    if isDir { fts_set(fts, ent, FTS_SKIP) }
                    continue
                }
                name = String(decoding: nb, as: UTF8.self)
            }

            if isDir {
                if level > 0 && (filter.excludeNames.contains(name) || filter.isExcludedPath(path)
                                 || filter.matchesExcludePattern(path)) {
                    fts_set(fts, ent, FTS_SKIP)
                    continue
                }
                if PathFilter.isPackage(name) {
                    store.add(path: path, name: name, kind: PathFilter.ext(name) == "app" ? .app : .file, boost: boost(path))
                    fts_set(fts, ent, FTS_SKIP)
                } else if level > 0 || includeRoot {
                    store.add(path: path, name: name, kind: .folder, boost: boost(path))
                }
            } else {
                store.add(path: path, name: name, kind: .file, boost: boost(path))
            }

            added += 1
            if let progress, added % 50_000 == 0 { progress(store) }
        }
    }

    // MARK: Live updates

    private func apply(_ events: [(String, UInt32)]) {
        let mustRescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                | kFSEventStreamEventFlagItemRenamed)
        let touchedFlags = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemCreated)
        let isFileFlag = UInt32(kFSEventStreamEventFlagItemIsFile)
        var changed = false

        for (rawPath, flags) in events {
            var path = rawPath
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

            if flags & mustRescan != 0 {
                // FSEvents dropped detail for this subtree; re-walk it.
                let isRoot = filter.roots.contains(path)
                guard isRoot || filter.shouldIndex(path) else { continue }
                store.removeDescendants(of: path)
                scan(path, into: &store, includeRoot: !isRoot, progress: nil)
                changed = true
                continue
            }

            guard filter.shouldIndex(path) else { continue }
            if flags & touchedFlags != 0 && flags & isFileFlag != 0 && FileManager.default.fileExists(atPath: path) {
                onTouched?(path)
            }
            let existing = store.indexOf[path]
            if existing != nil && flags & structural == 0 { continue } // content/metadata change only

            if let i = existing {
                if store.kinds[Int(i)] == Kind.folder.rawValue { store.removeDescendants(of: path) }
                store.kill(Int(i))
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue {
                    scan(path, into: &store, includeRoot: true, progress: nil)
                } else {
                    store.add(path: path, name: (path as NSString).lastPathComponent, kind: .file, boost: boost(path))
                }
            }
            changed = true
        }
        if changed { schedulePublish() }
    }
}

/// Binary on-disk copy of the index so results are available the instant Seek launches.
enum IndexCache {
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seek/index.bin")
    }
    private static let magic = Array("SEEKIDX2".utf8)

    static func save(_ input: Store, signature: String) {
        var s = input
        s.compact()
        var d = Data()
        d.reserveCapacity(s.keyBytes.count * 6 + 64)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: magic)
        let sig = Array(signature.utf8)
        u32(sig.count); d.append(contentsOf: sig)
        u32(s.paths.count)
        u32(s.keyBytes.count); d.append(contentsOf: s.keyBytes)
        s.keyStart.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(contentsOf: s.kinds)
        d.append(contentsOf: s.depths)
        var blob: [UInt8] = []
        blob.reserveCapacity(s.paths.count * 60)
        for p in s.paths { blob.append(contentsOf: p.utf8); blob.append(0) }
        u32(blob.count); d.append(contentsOf: blob)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url, options: .atomic)
        } catch { NSLog("Seek: could not save index cache: \(error)") }
    }

    static func load(signature: String) -> Store? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Store? in
            var off = 0
            func take(_ n: Int) -> UnsafeRawBufferPointer? {
                guard n >= 0, off + n <= buf.count else { return nil }
                defer { off += n }
                return UnsafeRawBufferPointer(rebasing: buf[off..<(off + n)])
            }
            func u32() -> Int? {
                guard let b = take(4) else { return nil }
                return Int(UInt32(littleEndian: b.loadUnaligned(as: UInt32.self)))
            }
            guard let m = take(magic.count), Array(m) == magic,
                  let sigLen = u32(), let sig = take(sigLen), String(decoding: sig, as: UTF8.self) == signature,
                  let count = u32(), let keyLen = u32(), let keys = take(keyLen),
                  let starts = take((count + 1) * 4), let kinds = take(count), let depths = take(count),
                  let blobLen = u32(), let blob = take(blobLen) else { return nil }

            var s = Store()
            s.keyBytes = Array(keys)
            s.keyStart = (0...count).map { UInt32(littleEndian: starts.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
            s.kinds = Array(kinds)
            s.depths = Array(depths)
            s.alive = [Bool](repeating: true, count: count)
            s.boosts = [Int32](repeating: 0, count: count)
            s.paths.reserveCapacity(count)
            s.indexOf.reserveCapacity(count)
            var start = 0
            for i in 0..<blob.count where blob[i] == 0 {
                let p = String(decoding: UnsafeRawBufferPointer(rebasing: blob[start..<i]), as: UTF8.self)
                s.indexOf[p] = Int32(s.paths.count)
                s.paths.append(p)
                start = i + 1
            }
            guard s.paths.count == count, Int(s.keyStart.last ?? 0) == s.keyBytes.count else { return nil }
            return s
        }
    }
}
