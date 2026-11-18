import Foundation

/// A file, folder or app shown as a result.
struct Item: Hashable {
    let path: String
    let kind: Kind

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { Store.displayName((path as NSString).lastPathComponent, kind: kind) }
    var location: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
    var isContainer: Bool { kind == .folder }

    /// Builds an item for a path that didn't come from the index (browsing, Spotlight, history).
    static func make(_ path: String) -> Item? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let name = (path as NSString).lastPathComponent
        if isDir.boolValue {
            if PathFilter.isPackage(name) { return Item(path: path, kind: PathFilter.ext(name) == "app" ? .app : .file) }
            return Item(path: path, kind: .folder)
        }
        return Item(path: path, kind: .file)
    }
}

struct SearchRequest {
    var text: String
    var foldersOnly = false
    var limit = 60
    var learned: [LearnedHit] = []
}

struct SearchOutcome {
    var items: [Item] = []
    var total = 0
    var ms: Double = 0
    var indexed = 0
    var indexing = false
    var browsingDirectory: String?
    var contentSearch = false
}

final class SearchEngine {
    private let queue = DispatchQueue(label: "seek.search", qos: .userInteractive)
    private var snap: Snapshot?
    private var cacheKey = ""
    private var cacheTerms: [UInt8] = []
    private var cacheMatches: [Int32] = []
    private var cacheGen = -1
    private let lock = NSLock()
    private var latest = 0
    var includeHidden = false

    func update(_ s: Snapshot) { queue.async { self.snap = s } }
    func updateSync(_ s: Snapshot) { snap = s }
    func resetCache() { cacheGen = -1 }

    /// Runs on a background queue; skips requests superseded by newer keystrokes.
    func search(_ req: SearchRequest, done: @escaping (SearchOutcome) -> Void) {
        lock.lock(); latest += 1; let id = latest; lock.unlock()
        queue.async {
            self.lock.lock(); let stale = id != self.latest; self.lock.unlock()
            if stale { return }
            let out = self.searchSync(req)
            DispatchQueue.main.async { done(out) }
        }
    }

    func searchSync(_ req: SearchRequest) -> SearchOutcome {
        let t0 = DispatchTime.now().uptimeNanoseconds
        func finish(_ o: SearchOutcome) -> SearchOutcome {
            var o = o
            o.ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            o.indexed = snap?.liveCount ?? 0
            o.indexing = snap?.indexing ?? true
            return o
        }

        let text = req.text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") || text.hasPrefix("~") { return finish(browse(text, foldersOnly: req.foldersOnly)) }

        var q = ParsedQuery.parse(text)
        if req.foldersOnly { q.kindMask = ParsedQuery.bit(.folder) }
        if let content = q.content { return finish(contentSearch(content, q: q, limit: req.limit)) }
        guard let s = snap, !(q.terms.isEmpty && !q.hasFilters) else { return finish(SearchOutcome()) }

        // Each keystroke that extends the previous query only rescans the previous matches.
        let terms = q.termBytes
        let key = q.filterSignature
        let narrow = cacheGen == s.generation && key == cacheKey && !cacheTerms.isEmpty && terms.starts(with: cacheTerms)
        let wantsDates = q.modifiedSince != nil
        let (matches, top) = Matcher.run(q, snap: s, candidates: narrow ? cacheMatches : nil,
                                         limit: wantsDates ? 3000 : req.limit)
        if q.modifiedSince == nil { cacheGen = s.generation; cacheKey = key; cacheTerms = terms; cacheMatches = matches }
        else { cacheGen = -1 }

        var items: [Item] = []
        var seen = Set<String>()

        // Results you picked before for this query go first.
        for l in req.learned {
            guard let item = Item.make(l.path), q.kindMask & ParsedQuery.bit(item.kind) != 0,
                  Matcher.scoreAll(q.terms, key: foldKey(item.name)) >= 0 else { continue }
            if wantsDates, !modified(item.path, since: q.modifiedSince!) { continue }
            items.append(item); seen.insert(item.path)
        }

        var total = matches.count
        if let since = q.modifiedSince {
            total = 0
            for h in top {
                let p = s.paths[Int(h.idx)]
                guard modified(p, since: since) else { continue }
                total += 1
                if items.count < req.limit, !seen.contains(p) { items.append(Item(path: p, kind: Kind(rawValue: s.kinds[Int(h.idx)]) ?? .file)) }
            }
        } else {
            for h in top where items.count < req.limit {
                let p = s.paths[Int(h.idx)]
                if seen.contains(p) { continue }
                items.append(Item(path: p, kind: Kind(rawValue: s.kinds[Int(h.idx)]) ?? .file))
            }
        }
        return finish(SearchOutcome(items: items, total: total))
    }

    private func modified(_ path: String, since: Date) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return TimeInterval(st.st_mtimespec.tv_sec) >= since.timeIntervalSince1970
    }

    /// "~/Doc" lists ~/ filtered by "doc"; "~/Documents/" lists that folder.
    private func browse(_ text: String, foldersOnly: Bool) -> SearchOutcome {
        let expanded = (text as NSString).expandingTildeInPath
        let dir: String, partial: String
        if text.hasSuffix("/") { dir = expanded; partial = "" }
        else { dir = (expanded as NSString).deletingLastPathComponent; partial = (expanded as NSString).lastPathComponent }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return SearchOutcome(browsingDirectory: dir)
        }
        let showHidden = includeHidden || partial.hasPrefix(".")
        let term = foldKey(partial)
        var scored: [(Item, Int32)] = []
        for name in names {
            if !showHidden && name.hasPrefix(".") { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            guard let item = Item.make(path) else { continue }
            if foldersOnly && item.kind != .folder { continue }
            let sc = term.isEmpty ? 0 : Matcher.scoreAll([term], key: foldKey(item.name))
            if sc < 0 { continue }
            scored.append((item, sc))
        }
        scored.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if (a.0.kind == .folder) != (b.0.kind == .folder) { return a.0.kind == .folder }
            return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }
        return SearchOutcome(items: scored.prefix(200).map { $0.0 }, total: scored.count, browsingDirectory: dir)
    }

    /// "in:words" hands the query to Spotlight, which indexes file contents.
    private func contentSearch(_ text: String, q: ParsedQuery, limit: Int) -> SearchOutcome {
        guard text.count >= 2 else { return SearchOutcome(contentSearch: true) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), text]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return SearchOutcome(contentSearch: true) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let library = NSHomeDirectory() + "/Library/"
        var items: [Item] = []
        var total = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let path = String(line)
            if path.hasPrefix(library) { continue }
            total += 1
            if items.count < limit, let it = Item.make(path), q.kindMask & ParsedQuery.bit(it.kind) != 0 { items.append(it) }
        }
        return SearchOutcome(items: items, total: total, contentSearch: true)
    }
}
