import Foundation

/// A parsed search: name terms plus optional filters.
///   .pdf .key      only these extensions
///   app: folder: file:   only these kinds (can be combined with a term: "app:code")
///   mod:3d  mod:12h  mod:2w  mod:today   modified within
///   in:some words   search inside files (Spotlight content search)
struct ParsedQuery {
    var terms: [[UInt8]] = []
    var kindMask: UInt8 = 0b111
    var exts: [[UInt8]] = []
    var modifiedSince: Date?
    var content: String?

    var hasFilters: Bool { kindMask != 0b111 || !exts.isEmpty || modifiedSince != nil }
    /// Identifies everything except the terms, for the incremental-search cache.
    var filterSignature: String { "\(kindMask)|\(exts)|\(modifiedSince?.timeIntervalSince1970 ?? 0)" }
    var termBytes: [UInt8] { Array(terms.joined(separator: [32])) }

    static func bit(_ k: Kind) -> UInt8 { 1 << k.rawValue }

    static func parse(_ text: String) -> ParsedQuery {
        var q = ParsedQuery()
        var kinds: UInt8 = 0
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < tokens.count {
            var tok = tokens[i]
            let lower = tok.lowercased()
            i += 1
            if lower.hasPrefix("in:") {
                let rest = ([String(tok.dropFirst(3))] + tokens[i...]).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                q.content = rest
                break
            }
            if lower.hasPrefix("mod:") {
                q.modifiedSince = parseAge(String(lower.dropFirst(4)))
                continue
            }
            var matchedKind = false
            for (prefix, kind) in [("app:", Kind.app), ("apps:", .app), ("folder:", .folder), ("dir:", .folder), ("file:", .file)]
            where lower.hasPrefix(prefix) {
                kinds |= bit(kind)
                tok = String(tok.dropFirst(prefix.count))
                matchedKind = true
                break
            }
            if matchedKind && tok.isEmpty { continue }
            if tok.count >= 2, tok.first == ".", tok.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) {
                q.exts.append(foldKey(tok))
                continue
            }
            q.terms.append(foldKey(tok))
        }
        if kinds != 0 { q.kindMask = kinds }
        if !q.exts.isEmpty && kinds == 0 { q.kindMask = bit(.file) }
        return q
    }

    private static func parseAge(_ s: String) -> Date? {
        if s == "today" { return Calendar.current.startOfDay(for: Date()) }
        if s == "yesterday" { return Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())) }
        guard let unit = s.last, let n = Double(s.dropLast()) else { return nil }
        let seconds: Double
        switch unit {
        case "m": seconds = 60
        case "h": seconds = 3600
        case "d": seconds = 86400
        case "w": seconds = 7 * 86400
        case "y": seconds = 365 * 86400
        default: return nil
        }
        return Date().addingTimeInterval(-n * seconds)
    }
}

enum Matcher {
    struct Hit { var idx: Int32; var score: Int32 }

    struct TopK {
        let k: Int
        var items: [Hit] = []
        init(_ k: Int) { self.k = k; items.reserveCapacity(k + 1) }
        @inline(__always) mutating func insert(_ idx: Int32, _ score: Int32) {
            if items.count == k, score <= items[k - 1].score { return }
            var lo = 0, hi = items.count
            while lo < hi { let mid = (lo + hi) >> 1; if items[mid].score >= score { lo = mid + 1 } else { hi = mid } }
            items.insert(Hit(idx: idx, score: score), at: lo)
            if items.count > k { items.removeLast() }
        }
    }

    @inline(__always) static func isSep(_ b: UInt8) -> Bool {
        b == 32 || b == 45 || b == 95 || b == 46 || b == 40 || b == 91 || b == 44 || b == 47
    }

    @inline(__always) static func isSubsequence(_ q: UnsafeBufferPointer<UInt8>, from qi: Int,
                                                _ k: UnsafeBufferPointer<UInt8>, from ki: Int) -> Bool {
        var j = ki
        for i in qi..<q.count {
            while j < k.count && k[j] != q[i] { j += 1 }
            if j == k.count { return false }
            j += 1
        }
        return true
    }

    /// Scores one query term against one name key. -1 = no match.
    /// exact 1200 > prefix 1000 > word-start substring 800 > substring 600 > fuzzy 300–590.
    /// Non-ASCII terms (e.g. Korean) only match as substrings, so multibyte characters never split.
    static func score(_ q: UnsafeBufferPointer<UInt8>, _ k: UnsafeBufferPointer<UInt8>, fuzzy: Bool) -> Int32 {
        let qn = q.count, kn = k.count
        if qn == 0 { return 500 }
        if qn > kn { return -1 }
        let q0 = q[0]
        var best: Int32 = -1
        var i = 0
        let last = kn - qn
        while i <= last {
            if k[i] == q0 {
                var m = 1
                while m < qn && k[i + m] == q[m] { m += 1 }
                if m == qn {
                    if i == 0 { return qn == kn ? 1200 : 1000 }
                    if isSep(k[i - 1]) { return 800 }
                    if best < 0 { best = 600 }
                }
            }
            i += 1
        }
        if best >= 0 || !fuzzy { return best }

        // Fuzzy subsequence, preferring word starts ("vsc" → Visual Studio Code).
        var s: Int32 = 300
        var ki = 0
        var prev = -1
        for qi in 0..<qn {
            let c = q[qi]
            while ki < kn && k[ki] != c { ki += 1 }
            if ki == kn { return -1 }
            var pick = ki
            let atStart = ki == 0 || isSep(k[ki - 1])
            if !atStart && !(prev >= 0 && ki == prev + 1) {
                var b = ki + 1
                while b < kn && !(k[b] == c && isSep(k[b - 1])) { b += 1 }
                if b < kn && isSubsequence(q, from: qi + 1, k, from: b + 1) { pick = b }
            }
            if pick == 0 || isSep(k[pick - 1]) { s += 30 }
            else if prev >= 0 && pick == prev + 1 { s += 12 }
            else if prev >= 0 { s -= Int32(min(pick - prev - 1, 8)) }
            prev = pick
            ki = pick + 1
        }
        return min(s, 590)
    }

    static func scoreAll(_ terms: [[UInt8]], key: [UInt8]) -> Int32 {
        if terms.isEmpty { return 500 }
        var total: Int32 = 0
        for t in terms {
            let fuzzy = !t.contains { $0 >= 0x80 }
            let s = t.withUnsafeBufferPointer { qb in key.withUnsafeBufferPointer { kb in score(qb, kb, fuzzy: fuzzy) } }
            if s < 0 { return -1 }
            total += s
        }
        return total / Int32(terms.count)
    }

    @inline(__always) static func hasSuffix(_ k: UnsafeBufferPointer<UInt8>, _ s: UnsafeBufferPointer<UInt8>) -> Bool {
        if s.count > k.count { return false }
        let off = k.count - s.count
        for i in 0..<s.count where k[off + i] != s[i] { return false }
        return true
    }

    /// Scans the whole index (or a previous result set) in parallel.
    /// Returns every matching index (for narrowing the next keystroke) and the top `limit` by score.
    static func run(_ q: ParsedQuery, snap s: Snapshot, candidates: [Int32]?, limit: Int) -> ([Int32], [Hit]) {
        let n = candidates?.count ?? s.paths.count
        if n == 0 { return ([], []) }
        let chunks = n < 16_384 ? 1 : ProcessInfo.processInfo.activeProcessorCount * 3
        var matchParts = [[Int32]](repeating: [], count: chunks)
        var topParts = [[Hit]](repeating: [], count: chunks)

        // Flatten terms and extensions into one buffer so the hot loop touches raw pointers only.
        var flat: [UInt8] = []
        var termRanges: [Range<Int>] = [], extRanges: [Range<Int>] = []
        for t in q.terms { termRanges.append(flat.count..<(flat.count + t.count)); flat += t }
        for e in q.exts { extRanges.append(flat.count..<(flat.count + e.count)); flat += e }
        let fuzzy = q.terms.map { t in !t.contains { $0 >= 0x80 } }
        let termCount = Int32(max(1, q.terms.count))
        let mask = q.kindMask
        let useCand = candidates != nil
        let cand = candidates ?? []

        flat.withUnsafeBufferPointer { qb in
        s.keyBytes.withUnsafeBufferPointer { kb in
        s.keyStart.withUnsafeBufferPointer { ks in
        cand.withUnsafeBufferPointer { cb in
        matchParts.withUnsafeMutableBufferPointer { mp in
        topParts.withUnsafeMutableBufferPointer { tp in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = n * c / chunks, hi = n * (c + 1) / chunks
                var local: [Int32] = []
                var top = TopK(limit)
                for j in lo..<hi {
                    let i = useCand ? Int(cb[j]) : j
                    if !s.alive[i] { continue }
                    let kind = s.kinds[i]
                    if mask & (1 << kind) == 0 { continue }
                    let a = Int(ks[i]), b = Int(ks[i + 1])
                    let key = UnsafeBufferPointer(rebasing: kb[a..<b])
                    if !extRanges.isEmpty {
                        var any = false
                        for r in extRanges where hasSuffix(key, UnsafeBufferPointer(rebasing: qb[r])) { any = true; break }
                        if !any { continue }
                    }
                    var total: Int32 = termRanges.isEmpty ? 500 : 0
                    var ok = true
                    for t in 0..<termRanges.count {
                        let sc = score(UnsafeBufferPointer(rebasing: qb[termRanges[t]]), key, fuzzy: fuzzy[t])
                        if sc < 0 { ok = false; break }
                        total += sc
                    }
                    if !ok { continue }
                    local.append(Int32(i))
                    let kindBoost: Int32 = kind == Kind.app.rawValue ? 120 : (kind == Kind.folder.rawValue ? 25 : 0)
                    let final = total / termCount + kindBoost + s.boosts[i] - Int32(b - a) - Int32(s.depths[i]) * 3
                    top.insert(Int32(i), final)
                }
                mp[c] = local
                tp[c] = top.items
            }
        }}}}}}

        let matches = chunks == 1 ? matchParts[0] : Array(matchParts.joined())
        var all = topParts.flatMap { $0 }
        all.sort { $0.score > $1.score }
        if all.count > limit { all.removeLast(all.count - limit) }
        return (matches, all)
    }
}
