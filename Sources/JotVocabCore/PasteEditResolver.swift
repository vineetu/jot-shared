import Foundation

/// **Exact paste-edit span resolution (F3).** Pure, Foundation-only, no
/// SwiftData / SwiftUI / App-Group concept — so the *producer* (the app's
/// `CorrectionAsksPublisher`, which knows the immutable published text) and the
/// *consumer* (the keyboard extension, which must splice into that same
/// baseline) can resolve the identical span with one implementation.
///
/// Why this exists: the keyboard's hold deck asks about a word, the owner picks
/// a different one, and the splice has to find that word in the staged text. The
/// resolution was previously duplicated inside the keyboard controller, so an
/// ask could be *shown* whose edit could never be honored — the transcript then
/// flipped to the pick while the pasted text kept the gate's word (the
/// paste/transcript divergence). Resolving on the producer side, against the
/// exact text that will be pasted, lets an unhonorable ask be dropped BEFORE it
/// is ever offered.
///
/// Semantics are a faithful port of the keyboard's `spliceRange` /
/// `contextCorroborates` (see `JotKeyboardViewController`, which keeps its own
/// copy until the consumer half of F3 lands) and of the transcript pane's
/// `CorrectionReviewModel.resolveSpan`: anchor-first, then a bounded-window
/// unique + context-corroborated fallback. Offsets are CHARACTER offsets
/// (`Array(text)` indices), matching both call sites.
public enum PasteEditResolver {

    /// A resolved, verifiable edit target: the half-open character range
    /// `[start, end)` in the baseline plus the EXACT substring standing there.
    /// The substring is what the consumer re-verifies before editing — it is not
    /// necessarily equal to the needle it was resolved from (matching is
    /// case-insensitive, and Unicode case folds vary in length).
    public struct Span: Sendable, Equatable, Codable {
        public let start: Int
        /// Exclusive. Always `> start` — see `isWellFormed`.
        public let end: Int
        /// `baseline[start..<end]`, verbatim.
        public let text: String

        public init(start: Int, end: Int, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }

        /// Half-open interval form, for overlap arithmetic.
        public var range: Range<Int> { start..<end }

        /// A span that replaces NO characters is not a paste edit — it is an
        /// insertion, and an empty range can never conflict with anything
        /// (`overlaps` is false for it), so a degenerate span would slip through
        /// the whole non-overlap validation and then rewrite text nobody
        /// validated. `resolve` can never return one; this is the invariant the
        /// producers assert before they ship a descriptor over a process
        /// boundary and the consumers check before they apply one.
        public var isWellFormed: Bool {
            start >= 0 && end > start && end - start == text.count
        }
    }

    /// One validated replacement in a consumer's baseline: swap the characters
    /// in `[start, end)` for `text`. Built from a verified `Span` (or from the
    /// bridge's own descriptor), never from a raw offset.
    public struct Replacement: Sendable, Equatable {
        public let start: Int
        /// Exclusive.
        public let end: Int
        /// What replaces `[start, end)`.
        public let text: String

        public init(start: Int, end: Int, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }

        public var range: Range<Int> { start..<end }
    }

    /// Trim the surrounding punctuation the gate/provenance may carry on a word
    /// (e.g. "Rama." → "Rama"). Same character set as the keyboard splice and
    /// `CorrectionReviewModel.resolveSpan` — the three MUST agree or one side
    /// resolves a span the others reject.
    public static func trimGatedWord(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'\u{2019}\u{201D})]}"))
    }

    /// Resolve the span `needle` occupies in `baseline` for an ask anchored at
    /// `anchor`. Returns nil when the edit cannot be honored — zero matches, an
    /// ambiguous neighbourhood, or a lone candidate the ask's spoken context does
    /// not corroborate. Resolution order:
    ///
    ///  1. STRICT anchor — a direct `.anchored` whole-word match at `anchor`
    ///     wins outright (parity with the transcript review's exact-at-offset
    ///     resolution). A direct anchored test is immune to the enumeration
    ///     order of overlapping matches.
    ///  2. Otherwise a UNIQUE whole-word match within a bounded window around
    ///     the anchor, corroborated by the ask's context. The window (not a
    ///     global scan) is load-bearing: post-gate cleanup shifts an anchor by
    ///     small LOCAL deltas, so the true occurrence sits near it; a global
    ///     search would splice a same-spelled word ELSEWHERE when cleanup
    ///     deleted the intended occurrence but an identical word survives.
    ///
    /// `primaryLengthInNeedle` is for the 3-option alternate, whose needle is the
    /// alternate's `find` phrase (winner word + following words) while the ask's
    /// `contextAfter` starts right after the PRIMARY word — i.e. INSIDE that
    /// tail. Pass the primary word's length so after-side corroboration searches
    /// from the right place; nil for a plain original/term span.
    public static func resolve(needle: String, anchoredAt anchor: Int, in baseline: String,
                               contextBefore: String, contextAfter: String,
                               primaryLengthInNeedle: Int? = nil) -> Span? {
        let text = baseline
        let n = text.count
        guard !needle.isEmpty else { return nil }
        // Out-of-range anchor (incl. one mapped to a removal point at/after the
        // text end) fails safe — an anchor with no character to sit on must not
        // resurrect a splice.
        guard anchor >= 0, anchor < n else { return nil }

        func charOffset(_ idx: String.Index) -> Int { text.distance(from: text.startIndex, to: idx) }
        func idx(_ off: Int) -> String.Index { text.index(text.startIndex, offsetBy: off) }
        // Boundary tests run against the FULL text by ABSOLUTE offset (never a
        // cropped window slice — a letter just outside the window still blocks
        // the match). Out-of-bounds is a text edge → not a letter → boundary OK.
        func isLetterAt(_ off: Int) -> Bool {
            guard off >= 0, off < n else { return false }
            return text[idx(off)].isLetter
        }
        func wholeWord(start: Int, end: Int) -> Bool {
            !isLetterAt(start - 1) && !isLetterAt(end)
        }
        // A resolved span must REPLACE something: `end > start`. Every caller
        // treats a returned span as "these characters go away", and an empty
        // range is invisible to `overlaps`/`hasOverlap`, so a degenerate span
        // would ship as an unvalidated insertion. Fail closed instead.
        func span(_ start: Int, _ end: Int) -> Span? {
            guard end > start else { return nil }
            return Span(start: start, end: end, text: String(text[idx(start)..<idx(end)]))
        }

        // 1. Strict anchor.
        let anchorIdx = idx(anchor)
        if let r = text.range(of: needle, options: [.caseInsensitive, .anchored],
                              range: anchorIdx..<text.endIndex) {
            let end = charOffset(r.upperBound)
            if wholeWord(start: anchor, end: end), let s = span(anchor, end) { return s }
        }

        // 2. Windowed unique + context-corroborated fallback. Radius = 2× the
        // ask context window (24 chars): generous for local cleanup drift, well
        // short of unrelated repeats. `+ 8` fold slack on `hi` so a
        // variable-length case fold near the far edge (Straße→STRASSE, +1 char)
        // still fits the window.
        let radius = 48
        let lo = max(0, anchor - radius)
        let hi = min(n, anchor + needle.count + radius + 8)
        guard lo < hi else { return nil }
        var matches: [(start: Int, end: Int)] = []   // GLOBAL char offsets
        var searchLo = idx(lo)
        let hiIdx = idx(hi)
        while let r = text.range(of: needle, options: [.caseInsensitive], range: searchLo..<hiIdx) {
            let start = charOffset(r.lowerBound)
            let end = charOffset(r.upperBound)
            if wholeWord(start: start, end: end) { matches.append((start, end)) }
            // Advance by ONE Character past the match START (not its end) so
            // OVERLAPPING candidates are still enumerated for the ambiguity count.
            searchLo = text.index(after: r.lowerBound)
            if searchLo >= hiIdx { break }
        }
        guard matches.count == 1 else { return nil }   // zero or ambiguous → fail safe
        let match = matches[0]
        let afterSearchStart = primaryLengthInNeedle.map { min(match.start + $0, match.end) } ?? match.end
        guard contextCorroborates(matchStart: match.start, matchEnd: match.end, in: text,
                                  contextBefore: contextBefore, contextAfter: contextAfter,
                                  afterSearchStart: afterSearchStart)
        else { return nil }
        return span(match.start, match.end)
    }

    /// Whether the two half-open ranges intersect. An EMPTY range replaces no
    /// characters, so it can never conflict with anything.
    public static func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    /// Defensive batch check: true when ANY two of these ranges intersect. The
    /// consumer runs this over its final edit set before touching text — a
    /// batch that overlaps would corrupt the paste no matter what order it is
    /// applied in.
    public static func hasOverlap(_ ranges: [Range<Int>]) -> Bool {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var maxUpper = Int.min
        for r in sorted {
            if r.lowerBound < maxUpper { return true }
            maxUpper = max(maxUpper, r.upperBound)
        }
        return false
    }

    /// Verify a PRODUCER-shipped descriptor against the consumer's own copy of
    /// the baseline: the characters standing at `[start, start + text.count)`
    /// must equal `text` VERBATIM (case-sensitive — the descriptor carries the
    /// baseline's own casing, so a casing-only difference means the two sides
    /// are looking at different strings). Returns the verified `Span`, or nil
    /// when the descriptor cannot be honored here — a descriptor resolved
    /// against a different string can then only fail closed.
    public static func verify(start: Int, text: String, in baseline: [Character]) -> Span? {
        let end = start + text.count
        guard start >= 0, end > start, end <= baseline.count else { return nil }
        guard String(baseline[start..<end]) == text else { return nil }
        return Span(start: start, end: end, text: text)
    }

    /// Apply a batch of validated replacements to `baseline`. Returns nil — the
    /// WHOLE batch, not a partial application — when any replacement is out of
    /// bounds, degenerate, or overlaps another: a batch that overlaps corrupts
    /// the text no matter which order it is applied in, and half-applying an
    /// owner's picks is the paste/transcript divergence in miniature.
    /// Applied in DESCENDING start order so an earlier edit never shifts a
    /// later one's offsets.
    public static func apply(_ edits: [Replacement], to baseline: [Character]) -> String? {
        guard !edits.isEmpty else { return String(baseline) }
        for e in edits {
            guard e.start >= 0, e.end > e.start, e.end <= baseline.count else { return nil }
        }
        guard !hasOverlap(edits.map(\.range)) else { return nil }
        var out = baseline
        for e in edits.sorted(by: { $0.start > $1.start }) {
            out.replaceSubrange(e.start..<e.end, with: Array(e.text))
        }
        return String(out)
    }

    /// Whether a FALLBACK candidate (a lone in-window match that did NOT sit
    /// exactly on the anchor) is corroborated by the ask's spoken context.
    /// Requires at least one context word (from `contextBefore` within the 24
    /// chars PRECEDING the match, OR from `contextAfter` within the 24 chars
    /// FOLLOWING it) to appear, case-insensitively and whole-word. Genuine
    /// cleanup drift preserves the neighbouring words; a same-spelled survivor
    /// in a different clause shares neither side. If both contexts are empty
    /// (span at a text edge) there is nothing to corroborate against → fall back
    /// to uniqueness-only. Words shorter than 2 chars are ignored so a stray
    /// "a"/"I" can't rubber-stamp any neighbourhood.
    private static func contextCorroborates(matchStart: Int, matchEnd: Int, in text: String,
                                            contextBefore: String, contextAfter: String,
                                            afterSearchStart: Int?) -> Bool {
        func words(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\u{2026}" })
                .map { trimGatedWord(String($0)) }
                .filter { $0.count >= 2 }
        }
        let before = words(contextBefore)
        let after = words(contextAfter)
        if before.isEmpty && after.isEmpty { return true }   // edge span — uniqueness-only
        let n = text.count
        func idx(_ off: Int) -> String.Index { text.index(text.startIndex, offsetBy: off) }
        func isLetterAt(_ off: Int) -> Bool {
            guard off >= 0, off < n else { return false }
            return text[idx(off)].isLetter
        }
        // WHOLE-WORD, case-insensitive presence of any context word inside
        // [lo,hi) — boundaries checked by ABSOLUTE offset on the full text so a
        // context word can't corroborate from inside a longer word ("he" must
        // not match inside "breathe").
        func anyWholeWord(_ list: [String], from lo: Int, to hi: Int) -> Bool {
            guard lo < hi, !list.isEmpty else { return false }
            let hiIdx = idx(hi)
            for w in list {
                var searchLo = idx(lo)
                while let r = text.range(of: w, options: [.caseInsensitive], range: searchLo..<hiIdx) {
                    let s = text.distance(from: text.startIndex, to: r.lowerBound)
                    let e = text.distance(from: text.startIndex, to: r.upperBound)
                    if !isLetterAt(s - 1) && !isLetterAt(e) { return true }
                    searchLo = text.index(after: r.lowerBound)
                    if searchLo >= hiIdx { break }
                }
            }
            return false
        }
        if anyWholeWord(before, from: max(0, matchStart - 24), to: matchStart) { return true }
        let aStart = afterSearchStart ?? matchEnd
        let aEnd = min(n, max(matchEnd, aStart) + 24)
        if anyWholeWord(after, from: aStart, to: aEnd) { return true }
        return false
    }
}
