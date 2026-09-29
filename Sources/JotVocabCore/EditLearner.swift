import Foundation

/// **Learn from transcript edits** (design `docs/vocabulary-learn-from-edits/
/// design.md`, "Selected design"). A pure word-level diff of the transcript as
/// it was when the user pressed Edit (`before`) against what they saved
/// (`after`), turned into lessons the stores act on:
///   - `.substitute` — the user replaced 1–3 words with 1–4 words: the new
///     text is what they meant (a vocabulary term), the old text is what Jot
///     wrote for it.
///   - `.reverse` — the user changed a vocabulary term the decoder wrote to
///     something else ("Claude" → "cloud"): lowers the learned strength.
///     Checked FIRST, so correcting a term can never add the replacement as a
///     term.
///   - `.recase` — a case-only edit of a vocabulary term ("claude" → "Claude")
///     fixes the term's casing; it is not a mishearing (D10).
///
/// Foundation-only and stateless; the app decides what each lesson does to the
/// vocabulary and the correction store.
public enum EditLearner {

    public enum Lesson: Sendable, Equatable {
        /// `original` is store-normalized (`CorrectionKey.normalize`); `term`
        /// keeps the user's casing. `heardByModel` is false when the original
        /// is not in the model's raw output (AI cleanup wrote it — D11), so the
        /// model did not mishear and bias must not rise.
        case substitute(original: String, term: String, heardByModel: Bool)
        /// `term` is the vocabulary term's canonical text; `original` is
        /// store-normalized.
        case reverse(original: String, term: String)
        /// The term as the user now cases it.
        case recase(term: String)
    }

    /// Largest replaced side (words) that still reads as a mishearing (D2).
    public static let maxOriginalWords = 3
    /// Largest replacement side (words) — the vocabulary term cap (D2).
    public static let maxTermWords = 4
    /// Past this many changed words (after trimming the shared prefix and
    /// suffix) the session is a rewrite, not corrections — learn nothing.
    public static let maxChangedWords = 2000

    /// - Parameters:
    ///   - before: the transcript when Edit was pressed.
    ///   - after: the transcript the user saved.
    ///   - raw: what the model produced (`rawTranscript`), for D11. Empty ⇒
    ///     every original counts as heard (no cleanup layer to blame).
    ///   - vocabulary: the user's terms (canonical text + aliases).
    ///   - isCommonWord: the active language's everyday-word test for ONE
    ///     lowercased word (D8). A language with no everyday-word list must not
    ///     call this at all (the caller skips learning, as the model-free
    ///     corrector does) — without the brake every edit would teach.
    public static func learn(
        before: String,
        after: String,
        raw: String,
        vocabulary: [VocabTerm],
        isCommonWord: (String) -> Bool
    ) -> [Lesson] {
        let b = tokens(before)
        let a = tokens(after)
        guard b.map(\.key) != a.map(\.key) || b.map(\.text) != a.map(\.text) else { return [] }

        // Vocabulary lookup by normalized text, and each term's word run for
        // the "edited a term" check.
        var termsByKey: [String: VocabTerm] = [:]
        for term in vocabulary where !term.isBlank {
            let key = CorrectionKey.normalize(term.text)
            termsByKey[key] = termsByKey[key] ?? term
        }
        let termRuns = termsByKey.values.map { tokens($0.text).map(\.key) }.filter { !$0.isEmpty }

        let rawKeys = tokens(raw).map(\.key)
        guard let alignment = align(b, a) else { return [] }
        var lessons: [Lesson] = []
        var seen: Set<String> = []   // D9: one lesson per (kind, original, term)

        func emit(_ lesson: Lesson, key: String) {
            if seen.insert(key).inserted { lessons.append(lesson) }
        }

        for hunk in alignment.hunks {
            let old = Array(b[hunk.before])
            let new = Array(a[hunk.after])
            // D2: pure inserts / deletes teach nothing; sizes outside 1–3 → 1–4
            // are rewrites, not mishearings.
            guard !old.isEmpty, !new.isEmpty,
                  old.count <= maxOriginalWords, new.count <= maxTermWords else { continue }
            let (oldText, newText) = stripSharedPossessive(
                old.map(\.text).joined(separator: " "), new.map(\.text).joined(separator: " "))
            // D2: punctuation / spacing only ("e-mail" → "email"). Case-sensitive,
            // so a re-cased join ("tensor flow" → "TensorFlow") still teaches.
            let oldLetters = oldText.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            let newLetters = newText.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            guard !oldLetters.isEmpty, !newLetters.isEmpty,
                  String(String.UnicodeScalarView(oldLetters)) != String(String.UnicodeScalarView(newLetters))
            else { continue }
            // A number edit ("2" → "3") is not a vocabulary mishearing.
            guard oldText.contains(where: \.isLetter), newText.contains(where: \.isLetter) else { continue }

            let original = CorrectionKey.normalize(oldText)
            let newKey = CorrectionKey.normalize(newText)

            // Reverse FIRST (review #5): the user changed a vocabulary term the
            // decoder wrote ("Anthropic" → "and the topic"). That lowers the
            // term's strength and NEVER adds the replacement as a term. A hunk
            // that merely contains a term alongside other words teaches nothing.
            if let term = termsByKey[original] {
                emit(.reverse(original: newKey, term: term.text),
                     key: "r|\(newKey)|\(original)")
                continue
            }
            let oldKeys = old.map(\.key)
            if termRuns.contains(where: { containsRun(oldKeys, $0) }) { continue }

            // D8: both sides everyday words ("their" → "there") — biasing either
            // would hurt every dictation. Grammar swaps are lowercase, so a
            // capitalized replacement ("cloud" → "Claude") is a proper-noun
            // correction and IS learned: the everyday-word list is 24k entries
            // and holds most names. A new vocabulary term is learned too.
            // Single letters ("a", "I") are function words the lists omit.
            // Contractions are looked up without the apostrophe ("you're" →
            // "youre") and by their stem ("who's" → "who"), so "your" →
            // "you're" is a grammar swap.
            let allCommon = (old + new).allSatisfy { t in
                t.key.count <= 1 || isCommonWord(t.key) || isCommonWord(stripApostrophes(t.key))
                    || contractionStem(t.key).map(isCommonWord) == true
            }
            let newTerm = termsByKey[newKey]
            if allCommon, newTerm == nil, !capitalizesName(old: old, new: new) { continue }

            // Sound-alike only (the gate's own plausibility test): a mishearing
            // sounds like what was written; a rewording ("tomorrow" → "on
            // Monday") does not. A vocabulary term's aliases count, exactly as
            // the gate reads them ("we need" → "Vineet").
            guard VocabularyGate.plausible(
                original: oldText, term: newText, aliases: newTerm?.aliases ?? [])
            else { continue }

            let heard = rawKeys.isEmpty || containsRun(rawKeys, old.map(\.key))
            emit(.substitute(original: original, term: newText, heardByModel: heard),
                 key: "s|\(original)|\(newKey)")
        }

        // D10: case-only edits of a vocabulary term. The alignment compares
        // case-folded keys, so these surface as matched runs whose display text
        // changed case.
        for lesson in recases(alignment.matches, before: b, after: a, termsByKey: termsByKey) {
            if case .recase(let text) = lesson { emit(lesson, key: "c|\(text.lowercased())") }
        }
        return lessons
    }

    // MARK: - Tokens

    struct Token: Equatable {
        /// The word with edge punctuation trimmed, user casing ("Claude's").
        let text: String
        /// Case-folded `text` — the alignment key.
        let key: String
        /// First word of the text or of a sentence (after . ! ?).
        var sentenceStart = false
    }

    private static let edgePunctuation = CharacterSet.punctuationCharacters
        .union(.symbols).union(.whitespacesAndNewlines)

    /// Whitespace-split words; pure-punctuation tokens ("—", "…") are dropped so
    /// the diff is punctuation-insensitive.
    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var atSentenceStart = true
        for piece in s.split(whereSeparator: { $0.isWhitespace }) {
            let text = String(piece).trimmingCharacters(in: edgePunctuation)
            if !text.isEmpty {
                out.append(Token(text: text, key: text.precomposedStringWithCanonicalMapping.lowercased(),
                                 sentenceStart: atSentenceStart))
                atSentenceStart = false
            }
            let closing = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201D}\u{2019})]"))
            if let last = closing.last, ".!?\u{2026}".contains(last) { atSentenceStart = true }
        }
        return out
    }

    /// "who's" → "who"; nil when `s` has no apostrophe.
    static func contractionStem(_ s: String) -> String? {
        guard let i = s.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }), i > s.startIndex
        else { return nil }
        return String(s[..<i])
    }

    static func stripApostrophes(_ s: String) -> String {
        s.filter { $0 != "'" && $0 != "\u{2019}" }
    }

    // MARK: - Alignment

    struct Hunk: Equatable {
        let before: Range<Int>
        let after: Range<Int>
    }

    struct Alignment {
        var hunks: [Hunk] = []
        /// Matched (before index, after index) pairs, in order.
        var matches: [(Int, Int)] = []
    }

    /// Word alignment on case-folded keys. The shared prefix and suffix are
    /// matched directly; only the changed middle goes through the standard
    /// library's Myers diff. nil when the middle exceeds `maxChangedWords`.
    static func align(_ b: [Token], _ a: [Token]) -> Alignment? {
        var prefix = 0
        while prefix < b.count, prefix < a.count, b[prefix].key == a[prefix].key { prefix += 1 }
        var suffix = 0
        while suffix < b.count - prefix, suffix < a.count - prefix,
              b[b.count - 1 - suffix].key == a[a.count - 1 - suffix].key { suffix += 1 }
        let midB = Array(b[prefix..<(b.count - suffix)])
        let midA = Array(a[prefix..<(a.count - suffix)])
        guard max(midB.count, midA.count) <= maxChangedWords else { return nil }

        var out = alignMiddle(midB, midA)
        out.hunks = out.hunks.map {
            Hunk(before: ($0.before.lowerBound + prefix)..<($0.before.upperBound + prefix),
                 after: ($0.after.lowerBound + prefix)..<($0.after.upperBound + prefix))
        }
        out.matches = (0..<prefix).map { ($0, $0) }
            + out.matches.map { ($0.0 + prefix, $0.1 + prefix) }
            + (0..<suffix).reversed().map { (b.count - 1 - $0, a.count - 1 - $0) }
        return out
    }

    private static func alignMiddle(_ b: [Token], _ a: [Token]) -> Alignment {
        let diff = a.map(\.key).difference(from: b.map(\.key))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out = Alignment()
        var i = 0, j = 0
        while i < b.count || j < a.count {
            let hunkStartI = i, hunkStartJ = j
            while i < b.count, removed.contains(i) { i += 1 }
            while j < a.count, inserted.contains(j) { j += 1 }
            if i > hunkStartI || j > hunkStartJ {
                out.hunks.append(Hunk(before: hunkStartI..<i, after: hunkStartJ..<j))
                continue
            }
            // Both sides now sit on a kept element — a match.
            guard i < b.count, j < a.count else { break }
            out.matches.append((i, j))
            i += 1
            j += 1
        }
        return out
    }

    // MARK: - Rules

    /// True when the replacement contains a capitalized word (2+ letters) —
    /// a name. Excluded: the only capital is the replacement's first word and
    /// the replaced first word was capitalized too — a sentence-start swap
    /// ("The" → "A"), not a name.
    static func capitalizesName(old: [Token], new: [Token]) -> Bool {
        func capitalized(_ t: Token) -> Bool {
            t.text.filter(\.isLetter).count >= 2 && (t.text.first?.isUppercase ?? false)
        }
        let caps = new.indices.filter { capitalized(new[$0]) }
        guard !caps.isEmpty else { return false }
        if caps == [0], old.first?.text.first?.isUppercase == true { return false }
        return true
    }

    /// "cloud's" → "Claude's" teaches cloud → Claude, not the possessive forms.
    static func stripSharedPossessive(_ old: String, _ new: String) -> (String, String) {
        for suffix in ["'s", "\u{2019}s"] {
            let o = old.lowercased(), n = new.lowercased()
            if o.hasSuffix(suffix), n.hasSuffix(suffix), o.count > suffix.count, n.count > suffix.count {
                return (String(old.dropLast(suffix.count)), String(new.dropLast(suffix.count)))
            }
        }
        return (old, new)
    }

    /// Whether `needle` occurs as a contiguous word run in `haystack`.
    static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where haystack[start] == needle[0] && Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    /// Case-only edits of vocabulary terms. Windows of up to `maxTermWords`
    /// matched words (contiguous on both sides) that spell a term, contain at
    /// least one case change, and now differ from the term's stored casing.
    private static func recases(
        _ matches: [(Int, Int)], before b: [Token], after a: [Token], termsByKey: [String: VocabTerm]
    ) -> [Lesson] {
        guard !termsByKey.isEmpty else { return [] }
        var out: [Lesson] = []
        // A first-letter-only change at a sentence start is capitalization
        // grammar, not a term's casing (D10).
        let changed = matches.indices.filter { i in
            let old = b[matches[i].0], new = a[matches[i].1]
            guard old.text != new.text else { return false }
            let firstLetterOnly = old.text.dropFirst() == new.text.dropFirst()
            return !(firstLetterOnly && new.sentenceStart)
        }
        var tried = Set<Range<Int>>()
        for c in changed {
            for length in 1...maxTermWords {
                for start in max(0, c - length + 1)...c {
                    let window = start..<(start + length)
                    guard window.upperBound <= matches.count, tried.insert(window).inserted else { continue }
                    // Contiguous on both sides (no hunk inside the window).
                    let pairs = matches[window]
                    guard zip(pairs, pairs.dropFirst()).allSatisfy({ $1.0 == $0.0 + 1 && $1.1 == $0.1 + 1 })
                    else { continue }
                    let text = pairs.map { a[$0.1].text }.joined(separator: " ")
                    guard let term = termsByKey[CorrectionKey.normalize(text)], term.text != text else { continue }
                    out.append(.recase(term: text))
                }
            }
        }
        return out
    }
}
