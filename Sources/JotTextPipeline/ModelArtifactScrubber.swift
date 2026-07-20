import Foundation

/// Removes tokenizer-artifact `<unk>` tokens from Nemotron output. The
/// multilingual tokenizer has no %/€/$ vocabulary at all, so its inline ITN
/// emits `25<unk>` for "veinticinco por ciento". A `<unk>` directly following
/// a digit is that percent sign (measured: currency stays as words, percent is
/// the only symbolized unit — docs/multilingual-itn-options.md Addendum 3);
/// anywhere else it is unrepresentable-symbol noise and is dropped.
///
/// Case-exact `<unk>` only (that is the literal the tokenizer emits).
/// Idempotent, and a guaranteed no-op on text without `<unk>`.
public enum ModelArtifactScrubber {
    public static func scrub(_ text: String) -> String {
        guard text.contains("<unk>") else { return text }

        // A `<unk>` directly after an ASCII digit (same line, optionally
        // space/tab-separated) is the percent sign the tokenizer could not
        // emit: "25<unk>" / "25 <unk>" → "25%". `[ \t]*` — NOT `\s*` — so the
        // inference never crosses a newline and eats a paragraph break, and
        // `[0-9]` — NOT ICU `\d` — so non-ASCII digits (e.g. Arabic-Indic
        // "٢٥") fall through to the plain drop below: the %-evidence was only
        // measured on the latin ship, and Arabic typography uses ٪ anyway.
        var working = text.replacingOccurrences(
            of: #"([0-9])[ \t]*<unk>"#,
            with: "$1%",
            options: .regularExpression
        )

        // Any remaining `<unk>` is unrepresentable-symbol noise. Replace it
        // (with its surrounding same-line spacing) by a single space — an
        // empty string would glue neighbors: "hola<unk>mundo" → "holamundo".
        working = working.replacingOccurrences(
            of: #"[ \t]*<unk>[ \t]*"#,
            with: " ",
            options: .regularExpression
        )

        // Clean the boundary artifacts the space-replacement can leave:
        // spaces butting a newline (a `<unk>` at a line edge), doubled spaces
        // (adjacent `<unk>`s), and edge whitespace.
        working = working.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        working = working.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        working = working.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return working.trimmingCharacters(in: .whitespaces)
    }
}
