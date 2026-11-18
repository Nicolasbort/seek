import Foundation

/// User settings, stored as JSON in ~/.config/seek/config.json (created with defaults on first launch).
struct Config: Codable {
    /// Global shortcut, e.g. "option+space", "cmd+shift+space", "ctrl+option+k".
    var hotkey = "cmd+shift+space"
    /// Folders (or single bundles) to index. "~" is your home folder.
    var roots = ["~", "/Applications", "/System/Applications", "/System/Library/CoreServices/Finder.app"]
    /// Folder names skipped anywhere in the tree.
    var excludeNames = ["node_modules", "__pycache__", "Pods", "DerivedData", ".build", "venv", ".venv",
                        "bower_components"]
    /// Full paths skipped (with everything under them).
    var excludePaths = ["~/Library", "~/.Trash"]
    /// Regular expressions matched against a folder's full path; a match skips the folder and
    /// everything under it. A leading "~" (or "^~") means your home folder.
    /// Example: "~/Developer/.*/deps$", "/build/(intermediates|tmp)$".
    var excludePatterns: [String] = []
    /// Index files and folders whose names start with ".".
    var includeHidden = false
    /// Result rows shown before the list scrolls.
    var visibleRows = 8
    /// Keyword that switches to Passwords mode ("pw github").
    var passwordsKeyword = "pw"
    /// Path to the apw CLI. Empty = look in /opt/homebrew/bin and /usr/local/bin.
    var apwPath = ""

    init() {}

    init(from decoder: Decoder) throws {
        let d = Config()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? d.roots
        excludeNames = try c.decodeIfPresent([String].self, forKey: .excludeNames) ?? d.excludeNames
        excludePaths = try c.decodeIfPresent([String].self, forKey: .excludePaths) ?? d.excludePaths
        excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? d.excludePatterns
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? d.includeHidden
        visibleRows = max(1, try c.decodeIfPresent(Int.self, forKey: .visibleRows) ?? d.visibleRows)
        passwordsKeyword = try c.decodeIfPresent(String.self, forKey: .passwordsKeyword) ?? d.passwordsKeyword
        apwPath = try c.decodeIfPresent(String.self, forKey: .apwPath) ?? d.apwPath
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/seek")
    static let url = directory.appendingPathComponent("config.json")

    static func load() -> Config {
        if let data = try? Data(contentsOf: url) {
            do { return try JSONDecoder().decode(Config.self, from: data) }
            catch { NSLog("Seek: could not read config (\(error)); using defaults") }
            return Config()
        }
        let config = Config()
        try? config.save()
        return config
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Config.url, options: .atomic)
    }
}

/// Everything Seek learns from use: open counts, which result you picked for which query,
/// and recently opened / recently changed files. Main thread only.
final class Knowledge {
    struct Recent: Codable { var path: String; var date: Date }
    private struct Stored: Codable {
        var counts: [String: Int] = [:]
        var learned: [String: [String: Int]] = [:]  // folded query -> path -> picks
        var opened: [Recent] = []
        var touched: [Recent] = []
    }

    private var data = Stored()
    private let url: URL
    private var saveScheduled = false

    var counts: [String: Int] { data.counts }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Seek")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("knowledge.json")
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: d) { data = s }
    }

    static func boost(_ count: Int) -> Int32 { Int32(min(count, 20) * 12) }

    static func queryKey(_ text: String) -> String {
        String(decoding: foldKey(text.trimmingCharacters(in: .whitespaces)), as: UTF8.self)
    }

    /// Records an open. Returns the new global count for the path.
    @discardableResult
    func recordOpen(_ path: String, query: String) -> Int {
        let c = (data.counts[path] ?? 0) + 1
        data.counts[path] = c
        let q = Knowledge.queryKey(query)
        if !q.isEmpty && !q.hasPrefix("/") && !q.hasPrefix("~") {
            data.learned[q, default: [:]][path, default: 0] += 1
            if data.learned.count > 2000 { data.learned.removeValue(forKey: data.learned.keys.first!) }
        }
        data.opened.removeAll { $0.path == path }
        data.opened.insert(Recent(path: path, date: Date()), at: 0)
        if data.opened.count > 40 { data.opened.removeLast(data.opened.count - 40) }
        scheduleSave()
        return c
    }

    /// Paths picked before for this query (exact match first), or for longer queries that start with it.
    func learned(for text: String) -> [LearnedHit] {
        let q = Knowledge.queryKey(text)
        guard !q.isEmpty else { return [] }
        var best: [String: LearnedHit] = [:]
        if let exact = data.learned[q] {
            for (p, n) in exact { best[p] = LearnedHit(path: p, count: n, exact: true) }
        }
        for (key, picks) in data.learned where key.count > q.count && key.hasPrefix(q) {
            for (p, n) in picks where best[p] == nil { best[p] = LearnedHit(path: p, count: n, exact: false) }
        }
        return best.values.sorted { ($0.exact ? 1 : 0, $0.count) > ($1.exact ? 1 : 0, $1.count) }
            .prefix(3).map { $0 }
    }

    func noteTouched(_ path: String) {
        data.touched.removeAll { $0.path == path }
        data.touched.insert(Recent(path: path, date: Date()), at: 0)
        if data.touched.count > 60 { data.touched.removeLast(data.touched.count - 60) }
        scheduleSave()
    }

    /// Recently opened (via Seek) and recently changed files, newest first.
    func recents(limit: Int) -> [String] {
        let merged = (data.opened + data.touched).sorted { $0.date > $1.date }
        var seen = Set<String>(), out: [String] = []
        for r in merged where !seen.contains(r.path) {
            seen.insert(r.path)
            if FileManager.default.fileExists(atPath: r.path) { out.append(r.path) }
            if out.count == limit { break }
        }
        return out
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.saveNow() }
    }

    func saveNow() {
        saveScheduled = false
        if let d = try? JSONEncoder().encode(data) { try? d.write(to: url, options: .atomic) }
    }
}

struct LearnedHit { let path: String; let count: Int; let exact: Bool }
