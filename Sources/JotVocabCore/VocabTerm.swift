import Foundation

/// One user-curated vocabulary term — the word Jot should prefer, plus
/// optional "sounds like" aliases that drive an alias-substitution fallback
/// when the acoustic CTC rescorer doesn't catch the misfire on its own.
///
/// Ported from `jot/Sources/Vocabulary/VocabTerm.swift`. Identical shape
/// so the on-disk plain-text "simple format"
/// (`Term: alias1, alias2`) round-trips between desktop and mobile —
/// useful for future sync, and required so FluidAudio's
/// `CustomVocabularyContext.loadFromSimpleFormat(from:)` accepts the
/// same file.
public struct VocabTerm: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var aliases: [String]

    public init(id: UUID = UUID(), text: String, aliases: [String] = []) {
        self.id = id
        self.text = text
        self.aliases = aliases
    }

    /// True when the term is empty or whitespace only. Used to skip
    /// degenerate rows during persistence.
    public var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
