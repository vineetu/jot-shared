import Foundation

/// Final whitespace / punctuation pass applied to a transcript after the
/// rest of the cleanup chain (segment → filler-clean → number-normalize).
///
/// Moved verbatim from the macOS app (`Sources/Transcription/PostProcessing.swift`)
/// so the app and the `jot` CLI run one implementation — the same extraction
/// that produced this package in the first place. Rules:
///   • trim leading/trailing whitespace,
///   • collapse runs of interior whitespace (tabs / stray single newlines the
///     decoder occasionally emits around punctuation) into single spaces,
///   • preserve `\n\n` paragraph boundaries (inserted upstream by
///     `ParagraphSegmenter`) — cleanup runs per paragraph,
///   • drop stray spaces before sentence punctuation (" ." → ".").
///
/// The rules are Latin-script-safe, not English-specific — the macOS app runs
/// them on every Parakeet v3 language. Callers gate per script: CJK / spaceless
/// scripts (Japanese, the Nemotron multilingual non-Latin ships) should not be
/// passed through this — route them around it, as the app's per-model switch
/// does.
public enum PostProcessing {
    public static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return "" }

        let working = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ParagraphSegmenter inserts "\n\n" boundaries before this final pass.
        // Preserve those boundaries while still applying the whitespace and
        // punctuation cleanup inside each paragraph.
        let paragraphs = working.components(separatedBy: "\n\n")
        return paragraphs
            .map(cleanParagraph)
            .joined(separator: "\n\n")
    }

    private static func collapseInternalWhitespace(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)

        var lastWasWhitespace = false
        for scalar in input.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasWhitespace {
                    output.append(" ")
                    lastWasWhitespace = true
                }
            } else {
                output.unicodeScalars.append(scalar)
                lastWasWhitespace = false
            }
        }
        return output
    }

    private static func cleanParagraph(_ paragraph: String) -> String {
        var working = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)

        // Collapse runs of internal whitespace (including tabs / single
        // newlines the decoder occasionally emits around punctuation) into
        // single spaces.
        working = collapseInternalWhitespace(working)

        // Remove stray spaces that precede sentence punctuation — Parakeet
        // sometimes emits " ." or " ,".
        for punctuation in [",", ".", ";", ":", "!", "?"] {
            working = working.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }

        return working
    }
}
