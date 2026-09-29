import Foundation

/// Which sounds-likes become decoder pairs. ONE isolated predicate on purpose,
/// so any eligibility rule lands here and nowhere else.
///
/// **Same first letter** (measured 2026-09-29, LibriSpeech test-clean, push 10
/// + near-completion). The pair push acts from the first letter the original
/// and the term share; with none shared it fires at every word start that
/// begins like the original. Everyday original → term with a different first
/// letter ("chart" → Jot shape): a genuinely spoken original converted in
/// 10 / 2497 utterances (0.4%), while 21 / 2620 utterances changed elsewhere
/// (dropped or garbled neighbouring words, U-WER 1.982 → 2.019). Natural
/// misrecognitions sharing a first letter ("cloud" → Claude shape): ~42%
/// conversion, 0/640 collateral. So a different-first-letter sounds-like stays
/// with the CTC gate (text level, after transcription), which still honours it.
public enum LearnedPairPolicy {
    /// Shortest sounds-like (in letters) the decoder pair push accepts.
    public static let minLetters = 3

    /// True when `original` → `term` goes to the decoder as a learned pair:
    /// a single word (multi-word sounds-likes stay CTC-gate-only — the pair
    /// push is single-word), at least `minLetters` letters, Latin script only,
    /// not the term itself, and not paused by the user's last explicit signal.
    public static func isDecoderPair(original: String, term: String, paused: Bool = false) -> Bool {
        guard !paused else { return false }
        let word = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !word.contains(where: \.isWhitespace),
              !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CorrectionKey.normalize(word) != CorrectionKey.normalize(term)
        else { return false }
        guard let first = word.lowercased().first(where: \.isLetter),
              first == term.lowercased().first(where: \.isLetter)
        else { return false }
        var letters = 0
        for scalar in word.unicodeScalars {
            if scalar.properties.isAlphabetic {
                guard isLatin(scalar) else { return false }
                letters += 1
            } else if !"'\u{2019}-".unicodeScalars.contains(scalar) {
                return false
            }
        }
        return letters >= minLetters
    }

    private static func isLatin(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x41...0x5A, 0x61...0x7A,   // Basic Latin
             0xC0...0x24F,               // Latin-1 Supplement letters, Extended-A/B
             0x1E00...0x1EFF,            // Latin Extended Additional
             0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F:
            return s.value != 0xD7 && s.value != 0xF7   // × ÷
        default:
            return false
        }
    }
}

/// What the decode-time-bias decoder (Nemotron Multilingual today) is given,
/// derived from the vocabulary list alone (Revision 2 review #1, #9) —
/// nothing is stored twice. Deleting a sounds-like anywhere (Settings or a
/// text editor) removes its pair, because nothing else feeds it.
public struct DecoderVocabulary: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        public let text: String
        public let weight: Float

        public init(text: String, weight: Float) {
            self.text = text
            self.weight = weight
        }
    }

    /// The decoder pushes toward `term` only where it is spelling `original`.
    public struct Pair: Sendable, Equatable, Hashable {
        /// Store-normalized (`CorrectionKey.normalize`).
        public let original: String
        public let term: String

        public init(original: String, term: String) {
            self.original = original
            self.term = term
        }
    }

    /// Bias weight of a term with no active pair (chosen on LibriSpeech).
    public static let baseWeight: Float = 3.5
    /// Whole-word weight of a term with an active pair. Measured on LibriSpeech
    /// test-clean with one such term: 5 is indistinguishable from control, 6
    /// already repeats the term. Several terms at 5 at once is not measured.
    public static let pairedWeight: Float = 5.0

    /// Canonical terms only, never sounds-likes (the decoder would boost a
    /// sounds-like as itself).
    public var terms: [Term]
    /// Sorted, for a stable comparison between sessions.
    public var pairs: [Pair]

    public init(terms: [Term] = [], pairs: [Pair] = []) {
        self.terms = terms
        self.pairs = pairs
    }

    /// - Parameters:
    ///   - list: the vocabulary list.
    ///   - pausedPairKeys: `CorrectionStore.pausedPairKeys()`.
    public static func derive(from list: [VocabTerm], pausedPairKeys: Set<String>) -> DecoderVocabulary {
        var out = DecoderVocabulary()
        var seenTerms: Set<String> = []
        var seenPairs: Set<Pair> = []
        for entry in list where !entry.isBlank {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenTerms.insert(text.lowercased()).inserted else { continue }
            var paired = false
            for alias in entry.aliases {
                let paused = pausedPairKeys.contains(CorrectionKey.pairKey(originalWord: alias, term: text))
                guard LearnedPairPolicy.isDecoderPair(original: alias, term: text, paused: paused) else { continue }
                paired = true
                let pair = Pair(original: CorrectionKey.normalize(alias), term: text)
                if seenPairs.insert(pair).inserted { out.pairs.append(pair) }
            }
            out.terms.append(Term(text: text, weight: paired ? pairedWeight : baseWeight))
        }
        out.pairs.sort { ($0.term.lowercased(), $0.original) < ($1.term.lowercased(), $1.original) }
        return out
    }
}
