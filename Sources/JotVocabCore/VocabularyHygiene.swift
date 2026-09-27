import Foundation

/// **Vocabulary hygiene (A4)** — a short inline warning when a term is likely to
/// be confused with ordinary speech, shown where terms are added (Mac
/// vocabulary pane, iOS vocabulary settings). Advisory only: it never blocks the
/// add, and nothing else reads it.
public enum VocabularyHygiene {

    public enum Kind: Sendable, Equatable {
        /// The term's first word is itself an everyday word ("Claude", "codex").
        case commonFirstWord(String)
        /// The term opens with an everyday FUNCTION word ("And…" in "Andalamma"),
        /// which decode-time bias and fuzzy matching can mistake for the start of
        /// the term.
        case commonPrefix(String)
    }

    public struct Warning: Sendable, Equatable {
        public let kind: Kind
        public let message: String
    }

    /// Shortest prefix the prefix rule considers.
    public static let minPrefixLength = 3

    /// The prefix rule is limited to closed-class English words (conjunctions,
    /// pronouns, articles, auxiliaries). Measured on the owner's 25-term list,
    /// "any common word as a prefix" flagged 17 of 25 terms ("sri" in Sriram,
    /// "vin" in Vineet, "mar" in Maran — the everyday-word list is 24k entries
    /// and includes most short syllables), which is noise nobody would read.
    /// These are the words speech is actually full of.
    static let englishFunctionWords: Set<String> = [
        "and", "the", "for", "but", "nor", "yet", "not", "you", "are", "was",
        "were", "can", "all", "any", "our", "one", "how", "who", "why", "what",
        "when", "then", "than", "this", "that", "with", "from", "have", "has",
        "had", "his", "her", "him", "she", "its", "yes", "now", "may", "will",
        "just", "also", "into", "they", "them", "your", "yeah", "okay", "there",
        "here", "some", "does", "did", "get", "got", "let", "say", "see", "too",
    ]

    /// The warning for `term`, or nil. `commonWords` is the active language's
    /// everyday-word set (empty ⇒ no list ships ⇒ no warning); `language` is its
    /// primary subtag ("en", "es", …) — the prefix rule only runs for English,
    /// where its word set is defined.
    public static func warning(
        for term: String, commonWords: Set<String>, language: String?
    ) -> Warning? {
        guard !commonWords.isEmpty,
              let first = term.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let word = String(VocabularyGate.skeleton(String(first)))
        guard !word.isEmpty else { return nil }
        if commonWords.contains(word) {
            return Warning(
                kind: .commonFirstWord(word),
                message: "“\(first)” is also an everyday word, so Jot may mix it up with ordinary speech.")
        }
        let english = language.map { VocabularyCorrector.primarySubtag($0) == "en" } ?? false
        guard english, word.count > minPrefixLength else { return nil }
        for length in minPrefixLength..<word.count {
            let prefix = String(word.prefix(length))
            guard englishFunctionWords.contains(prefix), commonWords.contains(prefix) else { continue }
            return Warning(
                kind: .commonPrefix(prefix),
                message: "Starts with the everyday word “\(prefix)”, so Jot may hear ordinary speech as this term.")
        }
        return nil
    }
}
