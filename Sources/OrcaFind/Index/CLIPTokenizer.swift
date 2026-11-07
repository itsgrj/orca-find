import Foundation

/// The byte-pair tokenizer CLIP models were trained with (OpenAI's `bpe_simple_vocab_16e6`, shipped
/// as `clip-vocab.json` + `clip-merges.txt`). Turns "a slide with a bar chart" into the 77 token ids
/// MobileCLIP's text encoder expects: <start> … <end>, padded with 0.
final class CLIPTokenizer: @unchecked Sendable {
    static let contextLength = 77

    private let encoder: [String: Int32]
    private let ranks: [Pair: Int]
    private let byteToChar: [Character]
    private let sot: Int32
    private let eot: Int32
    private var cache: [String: [Int32]] = [:]
    private let lock = NSLock()

    private struct Pair: Hashable { let a: String; let b: String }

    init(vocabURL: URL, mergesURL: URL) throws {
        let data = try Data(contentsOf: vocabURL)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        encoder = raw.mapValues { Int32($0) }
        var r: [Pair: Int] = [:]
        let lines = try String(contentsOf: mergesURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        var rank = 0
        for line in lines where !line.hasPrefix("#version") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            r[Pair(a: String(parts[0]), b: String(parts[1]))] = rank
            rank += 1
        }
        ranks = r
        byteToChar = CLIPTokenizer.bytesToUnicode()
        sot = encoder["<|startoftext|>"] ?? 49406
        eot = encoder["<|endoftext|>"] ?? 49407
    }

    /// GPT-2's reversible byte → printable character table.
    private static func bytesToUnicode() -> [Character] {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b); cs.append(256 + n); n += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bs, cs) { table[b] = Character(UnicodeScalar(c)!) }
        return table
    }

    private static let pattern = try! NSRegularExpression(
        pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+",
        options: [.caseInsensitive])

    /// Token ids for one sentence, always exactly `contextLength` long.
    func encode(_ text: String) -> [Int32] {
        let clean = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var ids: [Int32] = [sot]
        let ns = clean as NSString
        for m in CLIPTokenizer.pattern.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            let mapped = String(token.utf8.map { byteToChar[Int($0)] })
            ids += bpe(mapped)
            if ids.count >= CLIPTokenizer.contextLength - 1 { break }
        }
        ids = Array(ids.prefix(CLIPTokenizer.contextLength - 1))
        ids.append(eot)
        while ids.count < CLIPTokenizer.contextLength { ids.append(0) }
        return ids
    }

    private func bpe(_ token: String) -> [Int32] {
        lock.lock()
        if let hit = cache[token] { lock.unlock(); return hit }
        lock.unlock()
        var word = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks[Pair(a: word[i], b: word[i + 1])], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let best else { break }
            let a = word[best.index], b = word[best.index + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == a && word[i + 1] == b {
                    merged.append(a + b); i += 2
                } else {
                    merged.append(word[i]); i += 1
                }
            }
            word = merged
        }
        let out = word.compactMap { encoder[$0] }
        lock.lock(); cache[token] = out; lock.unlock()
        return out
    }
}
