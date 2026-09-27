import Foundation

/// The audio span of one transcript word — what the gate places a time-stamped
/// detection against (`VocabularyGate.applyFromDetections(wordTimes:)`).
public struct WordTime: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// One decoder token with its audio time, engine-neutral (the apps map their
/// engine's token timings into this at the call site — the same seam pattern as
/// `TokenTiming`). `token` is the raw SentencePiece piece: a leading `▁` (or a
/// space) marks a word start.
public struct TimedPiece: Sendable, Equatable {
    public let token: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(token: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.token = token
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// **Real word positions from decoder token timings** (R10). The CTC spotter
/// says WHEN it heard a term; the decoder's token timings say when each word it
/// wrote was spoken. Joining the two places a detection on the word the decoder
/// wrote at that moment — instead of mapping a time fraction onto a word
/// fraction, which lands on the wrong word whenever speech rate varies.
public enum WordTimeline {

    /// Below this share of real words matched between the decoded pieces and
    /// the transcript, the timeline describes some other text and is refused.
    public static let minMatchedShare: Double = 0.8

    /// Per-word audio spans for `transcript`'s whitespace-split words (the gate's
    /// own tokenization), or nil when the pieces can't be aligned to it.
    ///
    /// Words are matched by letter skeleton, so casing and attached punctuation
    /// don't matter. A transcript word the pieces don't account for (e.g. a
    /// punctuation-only token) takes the gap between its matched neighbours.
    public static func wordTimes(for transcript: String, pieces: [TimedPiece]) -> [WordTime]? {
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, !pieces.isEmpty else { return nil }
        let decoded = decodedWords(pieces)
        guard !decoded.isEmpty else { return nil }

        let wordKeys = words.map { String(VocabularyGate.skeleton($0)) }
        let decodedKeys = decoded.map { String(VocabularyGate.skeleton($0.text)) }

        // Greedy walk with a short resync window. The transcript IS the decoded
        // pieces joined in the common case, so this is linear; the window only
        // matters when a later stage inserted or merged a word.
        var times = [WordTime?](repeating: nil, count: words.count)
        var i = 0, j = 0
        let lookahead = 8
        while i < words.count, j < decoded.count {
            if wordKeys[i].isEmpty { i += 1; continue }
            if decodedKeys[j].isEmpty { j += 1; continue }
            if wordKeys[i] == decodedKeys[j] {
                times[i] = WordTime(start: decoded[j].start, end: decoded[j].end)
                i += 1; j += 1
                continue
            }
            var resync: (di: Int, dj: Int)?
            search: for total in 1...(2 * lookahead) {
                for di in 0...min(total, lookahead) {
                    let dj = total - di
                    guard dj <= lookahead, i + di < words.count, j + dj < decoded.count else { continue }
                    if !wordKeys[i + di].isEmpty, wordKeys[i + di] == decodedKeys[j + dj] {
                        resync = (di, dj)
                        break search
                    }
                }
            }
            guard let r = resync else { i += 1; j += 1; continue }
            i += r.di
            j += r.dj
        }

        let real = wordKeys.filter { !$0.isEmpty }.count
        let matched = times.enumerated().filter { !wordKeys[$0.offset].isEmpty && $0.element != nil }.count
        guard real > 0, Double(matched) / Double(real) >= minMatchedShare else { return nil }

        // Fill each unmatched run from its matched neighbours' boundary.
        var out: [WordTime] = []
        out.reserveCapacity(words.count)
        for k in words.indices {
            if let t = times[k] { out.append(t); continue }
            let before = (0..<k).reversed().lazy.compactMap { times[$0] }.first
            let after = ((k + 1)..<words.count).lazy.compactMap { times[$0] }.first
            let start = before?.end ?? after?.start ?? 0
            let end = after?.start ?? before?.end ?? start
            out.append(WordTime(start: start, end: max(start, end)))
        }
        return out
    }

    /// Words as the decoder emitted them: a piece starting with `▁` (or a space)
    /// opens a word; control pieces (`<…>`) are skipped.
    static func decodedWords(_ pieces: [TimedPiece]) -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        var out: [(text: String, start: TimeInterval, end: TimeInterval)] = []
        // A bare "▁" piece opens the NEXT piece's word.
        var pendingOpen = false
        for piece in pieces {
            let raw = piece.token
            if raw.hasPrefix("<"), raw.hasSuffix(">") { continue }
            let startsWord = raw.hasPrefix("\u{2581}") || raw.hasPrefix(" ")
            let text = raw.replacingOccurrences(of: "\u{2581}", with: " ")
            // A piece can carry an internal word boundary too ("▁a▁b" is rare
            // but legal); split it so every word gets its own entry.
            let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if parts.allSatisfy(\.isEmpty) {
                if startsWord { pendingOpen = true }
                continue
            }
            for (n, part) in parts.enumerated() {
                let opens = n > 0 || startsWord || pendingOpen || out.isEmpty
                if part.isEmpty { continue }
                pendingOpen = false
                if opens {
                    out.append((part, piece.startTime, piece.endTime))
                } else {
                    out[out.count - 1].text += part
                    out[out.count - 1].end = piece.endTime
                }
            }
        }
        return out
    }
}
