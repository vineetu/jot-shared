import Foundation

/// Post-transcription filler-word stripper. Pure enum with no I/O —
/// safe to call from any batch-transcription path (in-app hero,
/// keyboard, wizard mic test, Shortcuts intent, etc.) on ANY model.
///
/// This runs AFTER `ParagraphSegmenter.segment(...)` so the removed
/// tokens never affect pause-measurement decisions — paragraph
/// breaks are already baked in by the time we get here, and the
/// filler strip preserves any `\n\n` boundary the segmenter inserted.
///
/// Lightweight sweep that always runs on every transcript. Only removes
/// the most obvious NON-LEXICAL hesitation tokens — English `um`, `uh`,
/// `er`, `uhm`, `erm` and their elongated variants, plus small per-language
/// equivalents for es/de/fr/it/pt via `clean(_:language:)` — no toggle,
/// no model. Lexical discourse fillers (es "este", de "halt", fr "ben")
/// are never stripped; see `fillerWordsByLanguage`.
///
/// **Recapitalization is blanket but abbreviation-aware.** The first word
/// of the transcript, and the first word after any sentence-ending `.`,
/// `!`, or `?`, are capitalized — so under-cased models (Parakeet v2,
/// which emits lowercase) get proper per-sentence capitalization. The one
/// exception is a period that belongs to a known abbreviation ("e.g.",
/// "i.e.", "Dr.", "Mr.", "vs.", "etc.", "approx.", dotted acronyms like
/// "U.S.") — those never trigger a following-word capital, so already-cased
/// models (v3 / Nemotron) are not corrupted ("See e.g. the example." keeps
/// "the" lowercase). Decimals are immune for free: the character after the
/// dot in "3.14" is a digit, and only *letters* are ever capitalized.
/// Filler removal additionally exposes a sentence-initial word to the same
/// capitalization ("Um, hello" → "Hello"). Safe to run on every model.
public enum FillerWordCleaner {

    /// Regex fragments matched case-insensitively at word boundaries.
    static let fillerWords: [String] = [
        "um(m+)?", "uh(h+)?", "er(r+)?", "uhm", "erm"
    ]

    /// Per-language NON-LEXICAL hesitation sounds (see
    /// docs/multilingual-itn-options.md §5.2). Each language strips ONLY its
    /// own list — the lists REPLACE the English one rather than extend it,
    /// because English tokens are homographs of real words elsewhere
    /// ("um" = German "at/around", "er" = German "he"). Deliberately
    /// exhaustive: lexical discourse fillers (es "este/pues", de "halt/genau",
    /// fr "ben/eh bien", it "cioè", pt "tipo/né") are homographs of content
    /// words and are NEVER stripped — that would need POS/position rules and
    /// a native-speaker validator Jot doesn't have.
    ///
    /// Elongation variants mirror the English `um(m+)?` idiom. Italian "mmm+"
    /// requires at least three m's so "mm" (millimetres) survives; German
    /// "hm(m+)?" covers hm/hmm/hmmm.
    static let fillerWordsByLanguage: [String: [String]] = [
        "en": fillerWords,
        "es": ["eh(h+)?", "em(m+)?"],
        "de": ["äh(h+)?", "ähm(m+)?", "öh(h+)?", "hm(m+)?"],
        "fr": ["euh(h+)?"],
        "it": ["ehm(m+)?", "mmm+"],
        "pt": ["hum(m+)?"],
    ]

    /// Full-match filler test regex per language, compiled once. Anchored
    /// `^(?:…)$` against the punctuation-trimmed token core — this is the
    /// word-boundary guard (no `\b`, so no ICU ASCII-vs-Unicode boundary
    /// ambiguity around umlauts: "ähnlich" simply fails the full match).
    /// `.caseInsensitive` uses ICU Unicode case folding, so "Äh"/"ÄHM"
    /// match "äh"/"ähm".
    private static let fillerCoreRegexByLanguage: [String: NSRegularExpression] = {
        var map: [String: NSRegularExpression] = [:]
        for (lang, patterns) in fillerWordsByLanguage {
            let alternation = patterns.joined(separator: "|")
            map[lang] = try? NSRegularExpression(
                pattern: "^(?:\(alternation))$",
                options: [.caseInsensitive]
            )
        }
        return map
    }()

    /// Punctuation trimmed off a token to expose its "core" for filler /
    /// abbreviation matching.
    /// Includes Spanish inverted marks (¡ ¿) so "¡eh!" / "¿eh?" trim to a
    /// matchable filler core instead of being blocked by the leading mark.
    private static let corePunct = CharacterSet(charactersIn: ".,!?;:\"')]}»’”“‘([{«¡¿")
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    private static let sentenceEnderTrim = CharacterSet(charactersIn: "\"')]}»’”")

    /// Abbreviations whose trailing period does NOT end a sentence, so the
    /// following word must not be capitalized. Deliberately small and
    /// principled: honorifics/titles that are always written capitalized,
    /// the common scholarly Latin abbreviations, and a few measurement
    /// words. Matched case-insensitively on the period-stripped core.
    ///
    /// Intentionally EXCLUDED: bare "a", "no", "al" — each collides with a
    /// common word that frequently ends a real sentence ("I said no.",
    /// "…and that was that."), and failing to capitalize the next sentence
    /// is a worse, more visible error than occasionally capitalizing after
    /// "No. 5". Dotted acronyms ("e.g.", "i.e.", "U.S.", "a.m.") are handled
    /// separately by `isDottedAcronym` and need no entry here.
    private static let knownAbbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "mx", "prof", "sr", "jr", "st", "rev",
        "vs", "etc", "cf", "approx", "dept", "fig", "vol", "pp", "est"
    ]

    /// Strip filler tokens (plus a directly-adjacent comma so
    /// "I, uh, mean" → "I mean"), normalize interior whitespace while
    /// preserving `\n\n` paragraph breaks, and recapitalize the first word
    /// plus every post-sentence word except after a known abbreviation.
    /// Appends a single trailing space (non-empty only) so back-to-back
    /// dictations don't butt together at the cursor.
    ///
    /// English behavior, unchanged — equivalent to `clean(text, language: "en")`.
    public static func clean(_ text: String) -> String {
        clean(text, language: "en")
    }

    /// Language-aware variant. `language` is a lowercase ISO-ish code
    /// ("en", "es", "de", "fr", "it", "pt"); region subtags are tolerated and
    /// ignored ("de-DE" / "pt_BR" ⇒ "de" / "pt"). `nil` ⇒ English.
    ///
    /// **Non-English casing policy: the model's own casing is authoritative.**
    /// The v3 European models emit correctly-cased text, and the blanket
    /// after-period recapitalization is tuned to ENGLISH abbreviations — on
    /// German/French it corrupts correct output ("ca. um drei" → "ca. Um
    /// drei", "M. le président" → "M. Le président"). So for non-English
    /// languages the ONLY capitalization applied is repairing what the strip
    /// itself broke: a word exposed to sentence-initial position (string
    /// start, or after a sentence ender) by a stripped filler gets a capital
    /// ("Äh! Wo?" → "Wo?", "Ähm, hallo" → "Hallo"). Everything else passes
    /// through with the model's casing. English keeps the full blanket recap
    /// unchanged (Parakeet v2 emits lowercase and needs it).
    ///
    /// **Non-English trailing punctuation of a stripped filler is preserved**
    /// so sentence punctuation survives: "¿Verdad, eh?" → "¿Verdad?" (the
    /// filler's `?` re-attaches to the previous word; the comma is eaten as
    /// usual). A filler wrapped in its own leading punctuation ("¡eh!",
    /// "¿eh?", "(ehm)") is a self-contained interjection and is dropped
    /// wholesale. A sentence-initial filler's trailing punctuation has no
    /// previous word to attach to and is dropped ("Äh! Wo?" → "Wo?").
    ///
    /// **Unknown/unsupported codes are a strict IDENTITY no-op** — the input
    /// is returned byte-for-byte (no filler strip, no recapitalization, no
    /// trailing space). Rationale: (a) we have no validated hesitation list
    /// for that language, and cross-applying another language's tokens
    /// deletes real words ("um"/"er" are content words in German); (b) the
    /// recapitalization machinery's abbreviation list is English — running it
    /// blind on an unvalidated language risks miscapitalizing after
    /// abbreviations like Polish "np."; (c) identity exactly preserves the
    /// status quo, where non-English transcripts get no filler cleaning at
    /// all. Callers must gate on the return value if they rely on the
    /// trailing-space convention.
    public static func clean(_ text: String, language: String?) -> String {
        let base = baseCode(of: language)
        guard let regex = fillerCoreRegexByLanguage[base] else { return text }
        return clean(text, fillerRegex: regex, english: base == "en")
    }

    /// Normalize a language code to its base subtag. `nil` ⇒ "en";
    /// "de-DE" / "pt_BR" ⇒ "de" / "pt"; unknown codes pass through (and
    /// fail the regex-map lookup ⇒ identity no-op).
    private static func baseCode(of language: String?) -> String {
        guard let language else { return "en" }
        let lowered = language.lowercased()
        return lowered.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init) ?? lowered
    }

    private static func clean(
        _ text: String, fillerRegex: NSRegularExpression, english: Bool
    ) -> String {
        guard !text.isEmpty else { return text }

        let pieces = tokenize(text)

        // Kept words with the separator that precedes each (empty for the
        // first). Building an array lets a later filler strip reach back and
        // drop a trailing comma off the previous kept word.
        var kept: [(sep: String, word: String)] = []
        var pendingSep = ""   // whitespace accumulated since the last kept word
        var capNext = true    // next kept word sits at a sentence-initial position (start / post-sentence)
        var fillerExposed = false // a filler was stripped since the last kept word
                                  // (non-English: capitalization only fires when
                                  // capNext AND fillerExposed — the strip broke
                                  // the casing, so the strip repairs it; the
                                  // model's casing is otherwise authoritative)

        func mergeSep(_ a: String, _ b: String) -> String {
            if a.contains("\n") || b.contains("\n") { return "\n\n" }
            return (a.isEmpty && b.isEmpty) ? "" : " "
        }

        for piece in pieces {
            switch piece {
            case .space(let s):
                // Drop whitespace before the first kept word; otherwise fold it
                // into the pending separator (collapsing runs, keeping breaks).
                pendingSep = kept.isEmpty ? "" : mergeSep(pendingSep, s)

            case .word(let w):
                if isFiller(w, regex: fillerRegex) {
                    // Mimic the old regex's leading `,?`: eat one trailing comma
                    // off the previous kept word ("I, uh, mean" → "I mean").
                    if let last = kept.last, last.word.hasSuffix(",") {
                        kept[kept.count - 1].word = String(last.word.dropLast())
                    }
                    // `capNext` is deliberately left untouched: a sentence-initial
                    // filler leaves it `true` (from string start or the prior
                    // sentence-ender) so the exposed word is capitalized, and a
                    // mid-sentence filler leaves it `false`. English keeps the
                    // legacy semantics exactly: the filler's own attached
                    // punctuation goes away with it.
                    if !english {
                        fillerExposed = true
                        reattachTrailingEnders(of: w, to: &kept, capNext: &capNext)
                    }
                } else {
                    let word = (capNext && (english || fillerExposed))
                        ? capitalizeFirstLetter(w) : w
                    let sep = kept.isEmpty ? "" : (pendingSep.isEmpty ? " " : pendingSep)
                    kept.append((sep: sep, word: word))
                    pendingSep = ""
                    fillerExposed = false
                    capNext = capitalizesFollowingWord(word)
                }
            }
        }

        var result = ""
        result.reserveCapacity(text.count + 1)
        for k in kept {
            result += k.sep
            result += k.word
        }
        guard !result.isEmpty else { return "" }
        result += " "
        return result
    }

    // MARK: - Tokenizer

    private enum Piece {
        case word(String)
        case space(String)
    }

    /// Split into alternating word / whitespace pieces, preserving the exact
    /// whitespace runs (so `\n\n` survives).
    private static func tokenize(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace || c.isNewline {
                let start = i
                while i < text.endIndex, text[i].isWhitespace || text[i].isNewline {
                    i = text.index(after: i)
                }
                pieces.append(.space(String(text[start..<i])))
            } else {
                let start = i
                while i < text.endIndex, !(text[i].isWhitespace || text[i].isNewline) {
                    i = text.index(after: i)
                }
                pieces.append(.word(String(text[start..<i])))
            }
        }
        return pieces
    }

    // MARK: - Helpers

    /// True if `token`, once surrounding punctuation is trimmed, is exactly a
    /// filler word for the active language (e.g. `um`/`uh`/`er` + elongations
    /// for English, `äh`/`ähm` for German). Word-boundary safe by full-match
    /// anchoring: "umbrella" and "ähnlich" trim to themselves and fail the
    /// anchored match.
    private static func isFiller(_ token: String, regex: NSRegularExpression) -> Bool {
        let core = token.trimmingCharacters(in: corePunct)
        guard !core.isEmpty else { return false }
        let range = NSRange(core.startIndex..<core.endIndex, in: core)
        return regex.firstMatch(in: core, options: [], range: range) != nil
    }

    /// Non-English only: preserve sentence punctuation carried by a stripped
    /// filler token. "¿Verdad, eh?" — the `?` on "eh?" closes the clause the
    /// KEPT words began, so it re-attaches to the previous kept word
    /// ("¿Verdad" → "¿Verdad?"), and `capNext` is recomputed so a following
    /// word counts as sentence-initial ("¿verdad, eh? sí" → "¿verdad? Sí").
    /// Chosen edge semantics:
    ///   - Token with LEADING punctuation ("¡eh!", "¿eh?", "(ehm)") is a
    ///     self-contained interjection — dropped wholesale, nothing re-attached.
    ///   - No previous kept word (sentence-initial "Äh!") — punctuation is
    ///     dropped; there is no clause to close.
    ///   - Previous word already sentence-ended ("¿sí? eh?") — dropped; never
    ///     double-terminate.
    ///   - Only sentence enders (. ! ?) re-attach, in order; commas/closers in
    ///     the trailing run are discarded ("eh?," re-attaches just "?").
    private static func reattachTrailingEnders(
        of token: String,
        to kept: inout [(sep: String, word: String)],
        capNext: inout Bool
    ) {
        guard !kept.isEmpty else { return }
        if let first = token.unicodeScalars.first, corePunct.contains(first) { return }
        var run: [Character] = []
        for ch in token.reversed() {
            guard ch.unicodeScalars.count == 1,
                  let scalar = ch.unicodeScalars.first,
                  corePunct.contains(scalar) else { break }
            run.append(ch)
        }
        let enders = String(run.reversed().filter { sentenceEnders.contains($0) })
        guard !enders.isEmpty else { return }
        let prev = kept[kept.count - 1].word
        let prevTrimmed = prev.trimmingCharacters(in: sentenceEnderTrim)
        if let last = prevTrimmed.last, sentenceEnders.contains(last) { return }
        kept[kept.count - 1].word = prev + enders
        capNext = capitalizesFollowingWord(kept[kept.count - 1].word)
    }

    /// True if `word` ends a sentence AND is not a known abbreviation — i.e.
    /// the word immediately after it should be capitalized. Returns false for
    /// non-sentence-ending words, abbreviations ("Dr.", "etc."), and dotted
    /// acronyms ("e.g.", "U.S."). Decimals never reach the abbreviation check
    /// because a numeric token like "3.14" does not end in `.!?` (it ends in a
    /// digit); even "3.14." only means the NEXT word gets a capital, and the
    /// dot inside is irrelevant since capitalization only touches letters.
    private static func capitalizesFollowingWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: sentenceEnderTrim)
        guard let last = trimmed.last, sentenceEnders.contains(last) else { return false }
        let core = word.trimmingCharacters(in: corePunct)
        if knownAbbreviations.contains(core.lowercased()) { return false }
        if isDottedAcronym(core) { return false }
        return true
    }

    /// True if `core` is a dotted acronym / abbreviation such as "e.g", "i.e",
    /// "U.S", "a.m" — it contains a period, has at least one letter, and every
    /// character is a letter or a period (no digits, so decimals are excluded).
    private static func isDottedAcronym(_ core: String) -> Bool {
        guard core.contains(".") else { return false }
        var sawLetter = false
        for c in core {
            if c.isLetter { sawLetter = true }
            else if c != "." { return false }
        }
        return sawLetter
    }

    /// Uppercase the first cased character of `word`, skipping any leading
    /// punctuation/quotes. No-op on caseless scripts (CJK) and on words with
    /// no letter (digits, bare punctuation).
    private static func capitalizeFirstLetter(_ word: String) -> String {
        var chars = Array(word)
        for idx in chars.indices where chars[idx].isLetter {
            let upper = chars[idx].uppercased()
            if let first = upper.first, first != chars[idx] {
                // A single scalar may uppercase to multiple chars (ß→SS); splice.
                chars.replaceSubrange(idx...idx, with: Array(upper))
            }
            break
        }
        return String(chars)
    }
}
