import Foundation

/// The text side of SigLIP 2: Gemma's word pieces. Lowercase (as the model was trained), spaces become "▁",
/// pieces are merged by rank, unknown characters fall back to their bytes, then an end marker and padding to 64.
/// Checked token-for-token against Google's own tokenizer (NoteUnderstandingTests / SigLIPTokenizerTests).
final class SigLIPTokenizer: @unchecked Sendable {
    static let contextLength = 64
    static let eos: Int32 = 1
    static let pad: Int32 = 0

    private let ids: [String: Int32]
    private let ranks: [String: Int]
    private var cache: [String: [Int32]] = [:]
    private let lock = NSLock()

    /// `vocab`: a JSON array of pieces in id order. `merges`: one JSON string per line, "left right", best first.
    init(vocabURL: URL, mergesURL: URL) throws {
        guard let vocab = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabURL)) as? [String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var ids: [String: Int32] = [:]
        ids.reserveCapacity(vocab.count)
        for (i, t) in vocab.enumerated() where ids[t] == nil { ids[t] = Int32(i) }
        self.ids = ids
        var ranks: [String: Int] = [:]
        let text = try String(contentsOf: mergesURL, encoding: .utf8)
        var r = 0
        ranks.reserveCapacity(600_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Each line is a JSON string; almost none need unescaping, so skip the decoder for those (580k lines).
            if !line.contains("\\"), line.first == "\"", line.last == "\"" {
                ranks[String(line.dropFirst().dropLast())] = r
            } else if let s = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed) as? String {
                ranks[s] = r
            }
            r += 1
        }
        self.ranks = ranks
    }

    /// Ids padded to 64: pieces, then the end marker, then padding.
    func encode(_ text: String) -> [Int32] {
        var out = pieces(text)
        if out.count > Self.contextLength - 1 { out = Array(out.prefix(Self.contextLength - 1)) }
        out.append(Self.eos)
        out += Array(repeating: Self.pad, count: Self.contextLength - out.count)
        return out
    }

    /// The word-piece ids, no end marker.
    func pieces(_ text: String) -> [Int32] {
        let normalized = text.lowercased().replacingOccurrences(of: " ", with: "▁")
        lock.lock()
        if let hit = cache[normalized] { lock.unlock(); return hit }
        lock.unlock()
        var symbols = normalized.unicodeScalars.map { String($0) }
        // Merge the best-ranked neighbouring pair until none is in the table.
        while symbols.count > 1 {
            var best = Int.max, at = -1
            for i in 0..<(symbols.count - 1) {
                if let r = ranks[symbols[i] + " " + symbols[i + 1]], r < best { best = r; at = i }
            }
            guard at >= 0 else { break }
            symbols[at] += symbols[at + 1]
            symbols.remove(at: at + 1)
        }
        var out: [Int32] = []
        for s in symbols {
            if let id = ids[s] { out.append(id); continue }
            // Byte fallback: "<0xE2>"…
            for b in s.utf8 { if let id = ids[String(format: "<0x%02X>", b)] { out.append(id) } }
        }
        lock.lock(); if cache.count > 2000 { cache.removeAll() }; cache[normalized] = out; lock.unlock()
        return out
    }
}
