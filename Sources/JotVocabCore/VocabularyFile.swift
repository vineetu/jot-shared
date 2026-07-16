import Foundation

/// The vocabulary "simple format" parser/serializer — one term per line,
/// optional aliases after a colon separator:
///
/// ```
/// UJET: you jet, ew jet
/// Osiris
/// D'Andre: dandre, dahndray
/// Parakeet
/// ```
///
/// Extracted verbatim from `VocabularyStore.parse` / `.serialize` (iOS) — pure,
/// byte-identical across apps and to FluidAudio's `loadFromSimpleFormat`. The
/// `@MainActor @Observable` store shell stays per-app; only this parse/serialize
/// pair moves into the package. Colon (not pipe) because that's what FluidAudio's
/// `CustomVocabularyContext.loadFromSimpleFormat(from:)` consumes directly.
/// Format rules: `#` for line comments, comma-separated aliases, all
/// whitespace/newlines trimmed.
public enum VocabularyFile {

    /// Parse the plain-text format. Lines starting with `#` are treated
    /// as comments. Empty lines are skipped. Terms with duplicate text
    /// are preserved.
    public static func parse(_ body: String) -> [VocabTerm] {
        var result: [VocabTerm] = []
        let lines = body.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let text = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            let aliases: [String] = parts.count > 1
                ? parts[1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                : []

            result.append(VocabTerm(text: text, aliases: aliases))
        }
        return result
    }

    public static func serialize(_ terms: [VocabTerm]) -> String {
        var lines: [String] = []
        for t in terms where !t.isBlank {
            let trimmedText = t.text.trimmingCharacters(in: .whitespaces)
            if t.aliases.isEmpty {
                lines.append(trimmedText)
            } else {
                lines.append("\(trimmedText): \(t.aliases.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}
