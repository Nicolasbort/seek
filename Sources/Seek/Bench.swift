import Foundation

/// `Seek --bench [queries…]`: builds the index from scratch, times queries, and compares with `mdfind -name`.
enum Bench {
    static func run(_ queries: [String]) {
        let qs = queries.isEmpty ? ["s", "saf", "safari", "doc", "read me", "vsc", ".pdf invoice"] : queries
        let index = FileIndex(config: Config.load(), usage: [:])
        let engine = SearchEngine()
        let done = DispatchSemaphore(value: 0)
        var last: Snapshot?
        index.onPublish = { last = $0 }
        let t0 = Date()
        index.rebuild(watch: false, useCache: false) { done.signal() }
        done.wait()
        guard let snap = last else { print("Index failed"); return }
        print(String(format: "Indexed %@ items in %.2f s (full walk, no cache)\n",
                     NumberFormatter.localizedString(from: NSNumber(value: snap.liveCount), number: .decimal),
                     Date().timeIntervalSince(t0)))
        engine.updateSync(snap)

        print("query".padding(toLength: 16, withPad: " ", startingAt: 0) + "matches    Seek      mdfind -name   top result")
        for q in qs {
            var times: [Double] = []
            var out = SearchOutcome()
            for _ in 0..<15 {
                engine.resetCache()
                out = engine.searchSync(SearchRequest(text: q, limit: 10))
                times.append(out.ms)
            }
            times.sort()
            let md = mdfind(q)
            let top = out.items.first?.name ?? "—"
            print(q.padding(toLength: 16, withPad: " ", startingAt: 0)
                  + String(out.total).padding(toLength: 11, withPad: " ", startingAt: 0)
                  + String(format: "%6.2f ms", times[times.count / 2]).padding(toLength: 10, withPad: " ", startingAt: 0)
                  + String(format: "%8.1f ms", md).padding(toLength: 15, withPad: " ", startingAt: 0)
                  + top)
        }
        print("\nSeek times are the median of 15 cold (non-incremental) searches over the whole index.")
    }

    private static func mdfind(_ q: String) -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-name", q]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let t = Date()
        do { try p.run() } catch { return .nan }
        p.waitUntilExit()
        return Date().timeIntervalSince(t) * 1000
    }
}
