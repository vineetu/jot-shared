import Foundation

/// **§1 — the model-free vocabulary corrector.**
///
/// Instead of spotting terms acoustically, fuzzy-match transcript words against
/// the user's terms *after* decoding and feed the results through the same gate
/// as a detection source. No model, no download, no licence — it works anywhere
/// a common-word list already ships.
///
/// Measured value (E5, English, FLEURS, 1041 clips / 22,490 words): it recovers
/// **34.1 % of the terms the engine got wrong, at 0.27 false applies per 1000
/// words** on a realistic 25-term list. For languages with no acoustic
/// checkpoint that is **0 % → ~35 % for zero bytes**.
///
/// ## Division of labour
///
/// This type is a *candidate finder only*. It decides which terms are plausibly
/// present and roughly where, then emits `VocabularyGate.Detection`s;
/// `VocabularyGate.applyFromDetections` remains the single authority on
/// placement, widening, identity and the apply/block decision. Two consequences
/// worth keeping:
///
/// * It matches with `VocabularyGate`'s own `skeleton` + `levenshtein`, so it can
///   never propose a span the gate then silently refuses on a different metric.
/// * Its detections carry `.textual` evidence, so the §6 confidence-conditional
///   ceiling does **not** apply to them and they keep the flat 0.45. The
///   corrector's control is its per-language acceptance distance below plus its
///   edit budget, not the gate's ceiling. Each detection names its real word
///   window, so the gate never re-derives a position.
public enum VocabularyCorrector {

    // MARK: - The 19-language table (E6)

    /// Whether a language may run the corrector, and how tight its acceptance
    /// distance must be.
    ///
    /// The corrector's only safety net beyond its own edit budget is the
    /// common-word brake, and the brake's strength is simply how much of running
    /// text a 24,000-entry frequency list covers: **88.8 % of English types,
    /// 76.3 % of German, 60.1 % of Finnish, 56.9 % of Greek.** Shipping to 19
    /// languages on an English measurement would have been unsafe, so E6 measured
    /// all of them — 9,500 FLEURS clips through the real engine and the real gate.
    ///
    /// Budget: **1.0 false applies / 1000 words**, on a realistic 25-term list
    /// AND a mechanically adversarial one. At or above 0.9 (one measured event
    /// from the line) the language is tightened to the loosest distance that
    /// brings both arms ≤ 0.5; a language that cannot reach that without losing
    /// half its recall is not served at all.
    public struct Support: Sendable, Equatable {
        /// Max normalized edit distance the corrector will accept, or `nil` for
        /// "no cap" — the gate's flat 0.45 plausibility ceiling is the only bound.
        public let maxDistance: Double?
        /// Measured false applies per 1000 words, `(realistic, adversarial)`,
        /// AFTER any cap above. Documentation of record, not used at runtime.
        public let falseAppliesPer1k: (realistic: Double, adversarial: Double)

        public static func == (a: Support, b: Support) -> Bool {
            a.maxDistance == b.maxDistance
                && a.falseAppliesPer1k == b.falseAppliesPer1k
        }
    }

    /// Every language the corrector is cleared to run in, keyed by primary
    /// language subtag. **19 entries — 13 uncapped, 6 capped.**
    ///
    /// Absences are deliberate and load-bearing; see `unservedReason`.
    public static let supported: [String: Support] = [
        // ── Uncapped: both measurement arms comfortably inside budget. ──
        // Baseline. The ACOUSTIC path is preferred here when the checkpoint is
        // present; the corrector is the fallback.
        "en": Support(maxDistance: nil, falseAppliesPer1k: (0.27, 0.22)),
        "cs": Support(maxDistance: nil, falseAppliesPer1k: (0.55, 0.88)),   // closest pass
        "da": Support(maxDistance: nil, falseAppliesPer1k: (0.10, 0.79)),
        "es": Support(maxDistance: nil, falseAppliesPer1k: (0.00, 0.32)),
        // Predicted worst; is among the safest — agglutination starves the
        // frequency list and lengthens words past collision range.
        "fi": Support(maxDistance: nil, falseAppliesPer1k: (0.00, 0.41)),
        "fr": Support(maxDistance: nil, falseAppliesPer1k: (0.00, 0.08)),
        "hu": Support(maxDistance: nil, falseAppliesPer1k: (0.34, 0.57)),   // also predicted worst; also fine
        "it": Support(maxDistance: nil, falseAppliesPer1k: (0.09, 0.09)),
        "nl": Support(maxDistance: nil, falseAppliesPer1k: (0.00, 0.09)),
        "pt": Support(maxDistance: nil, falseAppliesPer1k: (0.00, 0.09)),
        "ro": Support(maxDistance: nil, falseAppliesPer1k: (0.09, 0.81)),
        "sk": Support(maxDistance: nil, falseAppliesPer1k: (0.32, 0.11)),
        "sv": Support(maxDistance: nil, falseAppliesPer1k: (0.29, 0.69)),

        // ── Capped: uncapped they breached the budget. Recall cost noted. ──
        "bg": Support(maxDistance: 0.25, falseAppliesPer1k: (0.10, 0.20)),  // 1.27 adv; recall 50.7 → 43.8
        // Long words absorb an edit, so German needs the tightest cap shipped.
        "de": Support(maxDistance: 0.15, falseAppliesPer1k: (0.00, 0.19)),  // 0.96 adv; recall 54.3 → 31.4
        "el": Support(maxDistance: 0.20, falseAppliesPer1k: (0.27, 0.09)),  // 1.42 real; recall 35.7 → 18.8
        "pl": Support(maxDistance: 0.20, falseAppliesPer1k: (0.11, 0.45)),  // 0.90 adv; recall 51.8 → 33.9
        "ru": Support(maxDistance: 0.20, falseAppliesPer1k: (0.32, 0.43)),  // 1.73 adv; recall 60.3 → 56.9
        "uk": Support(maxDistance: 0.20, falseAppliesPer1k: (0.33, 0.22)),  // 0.99 adv; recall 59.0 → 47.5
    ]

    /// **§1.2 — the default for an unmeasured language is the TIGHTEST shipped
    /// value, not the loosest.** It should be unreachable: `isServed` answers
    /// false for anything absent from the table, so the mode selector never turns
    /// the corrector on there. This exists so that if a future caller does reach
    /// it, it fails closed rather than open.
    public static let unmeasuredMaxDistance: Double = 0.15

    /// Why a language a caller might expect is deliberately absent. Returns nil
    /// for served languages. Exists so the reasons survive as code rather than
    /// as tribal knowledge — each one is a decision someone will otherwise
    /// "fix" later.
    public static func unservedReason(_ language: String) -> String? {
        switch primarySubtag(language) {
        case let code where supported[code] != nil:
            return nil
        case "sl":
            // 1.72 adversarial FP/1k, and the only setting that gets it under
            // 0.5 recovers 16 % of missed terms — 43 % of what it recovers
            // uncapped. The engine is also at 58.6 % WER there, so the premise
            // (a mostly-right transcript with a few mis-spelled terms) does not
            // hold. A feature that corrupts at the budget line and recovers one
            // term in six is not a feature.
            return "measured unsafe: 1.72 adversarial FP/1k, and 58.6% WER breaks the premise"
        case "sr":
            // Has a 24,000-entry list, but nothing can select it.
            return "no engine locale — the list exists but the language cannot be chosen"
        case "hr", "ar":
            // Running the corrector — or the spotter — here means running with
            // the brake absent. Do NOT enable on the basis that a model exists.
            return "no common-word list ships — the common-word brake would be ABSENT"
        default:
            return "not measured — fail closed (§1.2)"
        }
    }

    /// True when the corrector may run for this language. **Fail closed:**
    /// anything not in the measured table answers false.
    public static func isServed(_ language: String) -> Bool {
        supported[primarySubtag(language)] != nil
    }

    /// The acceptance distance for a language. Served-and-uncapped falls back to
    /// the gate's own plausibility ceiling; unserved languages get the tightest
    /// shipped value (they should never get this far).
    public static func acceptanceDistance(for language: String) -> Double {
        guard let support = supported[primarySubtag(language)] else {
            return unmeasuredMaxDistance
        }
        return min(support.maxDistance ?? VocabularyGate.plausibilityCeiling,
                   VocabularyGate.plausibilityCeiling)
    }

    /// Resource name for a language's frequency list, matching the files bundled
    /// in `Resources/`: English is the unsuffixed `common-words`, everything else
    /// is `common-words-<code>`.
    public static func commonWordsResource(for language: String) -> String? {
        let code = primarySubtag(language)
        guard supported[code] != nil else { return nil }
        return code == "en" ? "common-words" : "common-words-\(code)"
    }

    /// `"es-MX"` → `"es"`, `"pt_BR"` → `"pt"`. Case- and separator-tolerant so a
    /// caller's locale identifier doesn't silently fall off the table.
    static func primarySubtag(_ language: String) -> String {
        let lowered = language.lowercased()
        let cut = lowered.prefix { $0 != "-" && $0 != "_" }
        return String(cut)
    }

    // MARK: - Candidate finding (converged with jot-windows `VocabularyCorrector`)

    /// At or below this skeleton length an exact match is required. Three
    /// characters at one edit is a third of the word — every short term would
    /// collide with ordinary text.
    public static let exactMatchMaxLength = 3

    /// Widest window considered, so a long dictation can't turn into an O(n·W)
    /// surprise. Only spelled-out acronyms ("W A S A P I") ever need more than a
    /// term's word count + 1.
    public static let maxWindowWords = 8

    /// One edit per this many term characters. MEASURED on Windows (E5, 1041
    /// FLEURS clips), not chosen: loosening to 4 bought +8 recoveries for +14
    /// false applies, and to 3 bought +26 for +42. The band a looser threshold
    /// reaches is where near-neighbour NAMES live (Maria/Marie, Raku/Raju),
    /// exactly where a purely textual rule cannot tell a hit from a collision.
    public static let charactersPerEdit = 5

    /// Terms/forms shorter than this (after sanitizing) are never matched.
    public static let minFormLength = 2

    /// Edits allowed against a term form of `skeletonLength` characters:
    /// 0 up to `exactMatchMaxLength`, else ⌈length / 5⌉.
    public static func editBudget(skeletonLength: Int) -> Int {
        skeletonLength <= exactMatchMaxLength
            ? 0
            : (skeletonLength + charactersPerEdit - 1) / charactersPerEdit
    }

    /// Fuzzy-match `terms` against `transcript` and emit gate detections.
    ///
    /// Returns an empty array — doing nothing at all — for any language the
    /// table does not clear (§1.2, fail closed).
    ///
    /// Converged with jot-windows (design R8): each term contributes its text,
    /// its aliases and, for a multi-word term, its space-stripped merge; windows
    /// are word n-grams up to the form's word count + 1 (a spelled-out acronym:
    /// its letter count), capped at 8; the distance is restricted
    /// Damerau–Levenshtein (OSA) inside an edit budget of ⌈len/5⌉ (exact at
    /// ≤ 3 chars) AND the language's acceptance distance; a window two
    /// different terms reach equally well is dropped as ambiguous; a span
    /// already spelled as a term is claimed first so no wider window can steal
    /// it ("George W" → "George" deleted the initial); a window wider than its
    /// form must itself pass the gate's 0.45 plausibility gap.
    ///
    /// Each detection carries `.textual(distance:)` evidence and its REAL word
    /// window (`wordRange`), so the gate places it exactly there — no position
    /// encoded as a time fraction.
    public static func detections(
        in transcript: String,
        terms: [VocabTerm],
        language: String,
        diagnostics: DiagnosticsSink = NoopDiagnosticsSink()
    ) -> [VocabularyGate.Detection] {
        guard isServed(language) else {
            if let reason = unservedReason(language) {
                diagnostics.record(
                    category: .vocabularyGate,
                    message: "corrector off for '\(language)' — \(reason)",
                    metadata: ["language": language])
            }
            return []
        }
        guard !transcript.isEmpty, !terms.isEmpty else { return [] }
        return detections(in: transcript, terms: terms, maxDistance: acceptanceDistance(for: language))
    }

    /// The same search with the acceptance distance passed in explicitly, so a
    /// sweep measures the SHIPPING code path with only the number varying.
    static func detections(
        in transcript: String,
        terms: [VocabTerm],
        maxDistance: Double
    ) -> [VocabularyGate.Detection] {
        // Whole words in document order, with their character ranges. Split on
        // ALL whitespace, matching the gate's own tokenizer, so the word indices
        // the two derive agree.
        var spans: [Range<String.Index>] = []
        var idx = transcript.startIndex
        while idx < transcript.endIndex {
            while idx < transcript.endIndex, transcript[idx].isWhitespace {
                idx = transcript.index(after: idx)
            }
            guard idx < transcript.endIndex else { break }
            let start = idx
            while idx < transcript.endIndex, !transcript[idx].isWhitespace {
                idx = transcript.index(after: idx)
            }
            spans.append(start..<idx)
        }
        let n = spans.count
        guard n > 0 else { return [] }

        let forms = buildForms(terms)
        guard !forms.isEmpty else { return [] }
        let maxWidth = min(forms.map(\.windowWidthLimit).max() ?? 1, maxWindowWords, n)

        // windows[w - 1][i] = the w-word window starting at word i.
        var windows: [[Window]] = []
        for w in 1...maxWidth {
            var row: [Window] = []
            row.reserveCapacity(n - w + 1)
            for i in 0...(n - w) {
                let text = String(transcript[spans[i].lowerBound..<spans[i + w - 1].upperBound])
                let skeleton = VocabularyGate.skeleton(text)
                row.append(Window(text: text, skeleton: skeleton, letters: letterMask(skeleton)))
            }
            windows.append(row)
        }

        struct Key: Hashable { let index: Int; let width: Int }
        var best: [Key: Match] = [:]
        var ambiguous = Set<Key>()

        for form in forms {
            let budget = editBudget(skeletonLength: form.skeleton.count)
            for w in 1...min(form.windowWidthLimit, maxWidth) {
                for (i, window) in windows[w - 1].enumerated() {
                    guard couldMatch(window, form, budget: budget) else { continue }
                    let edits = restrictedEdits(window.skeleton, form.skeleton, budget: budget)
                    guard edits <= budget else { continue }
                    let normalized = Double(edits) / Double(max(window.skeleton.count, form.skeleton.count))
                    // The per-language brake (E6), applied HERE: the gate's 0.45
                    // never binds on this path — the budget is already tighter.
                    guard normalized <= maxDistance else { continue }
                    let key = Key(index: i, width: w)
                    let candidate = Match(index: i, width: w, form: form, normalized: normalized)
                    guard let current = best[key] else {
                        best[key] = candidate
                        continue
                    }
                    if normalized < current.normalized {
                        best[key] = candidate
                        ambiguous.remove(key)
                    } else if normalized == current.normalized, current.form.termIndex != form.termIndex {
                        ambiguous.insert(key)
                    }
                }
            }
        }
        guard !best.isEmpty else { return [] }

        var claimed = Set<Int>()
        // Identity first: a span the engine already spelled as a term is
        // settled, and claiming it FIRST keeps a wider window off it.
        for m in best.values.sorted(by: { ($0.index, $0.width) < ($1.index, $1.width) }) {
            let spanText = windows[m.width - 1][m.index].text
            guard isIdentity(spanText, m) else { continue }
            for k in 0..<m.width { claimed.insert(m.index + k) }
        }

        let ordered = best
            .filter { !ambiguous.contains($0.key) }
            .map(\.value)
            .sorted {
                if $0.normalized != $1.normalized { return $0.normalized < $1.normalized }
                if $0.width != $1.width { return $0.width > $1.width }
                return $0.index < $1.index
            }

        var accepted: [(match: Match, aliases: [String])] = []
        for m in ordered {
            guard !(0..<m.width).contains(where: { claimed.contains(m.index + $0) }) else { continue }
            let spanText = windows[m.width - 1][m.index].text
            guard let aliases = widthUnlockAliases(spanText, m) else { continue }
            for k in 0..<m.width { claimed.insert(m.index + k) }
            accepted.append((m, aliases))
        }

        return accepted
            .sorted { $0.match.index < $1.match.index }
            .map { entry in
                let m = entry.match
                // Also encode the window as the gate's legacy [0, 1] position so
                // a caller that ignores `wordRange` still lands on it.
                let centre = (Double(m.index) + Double(m.width) / 2) / Double(n)
                return VocabularyGate.Detection(
                    term: m.form.term.text,
                    aliases: entry.aliases,
                    evidence: .textual(distance: m.normalized),
                    startTime: centre,
                    endTime: centre,
                    wordRange: m.index..<(m.index + m.width))
            }
    }

    // MARK: - Forms and windows

    private struct Form {
        let term: VocabTerm
        let termIndex: Int
        let skeleton: [Character]
        let letters: UInt32
        let wordCount: Int
        /// Word n-grams up to the form's own word count + 1 cover merge and
        /// split. A term with no lowercase is a possible spelled-out acronym,
        /// where each letter arrives as its own "word".
        let windowWidthLimit: Int
    }

    private struct Window {
        let text: String
        let skeleton: [Character]
        let letters: UInt32
    }

    private struct Match {
        let index: Int
        let width: Int
        let form: Form
        let normalized: Double
    }

    private static func buildForms(_ terms: [VocabTerm]) -> [Form] {
        var forms: [Form] = []
        for (termIndex, term) in terms.enumerated() where !term.isBlank {
            let acronym = !term.text.contains(where: { $0.isLowercase })
            var seen = Set<String>()
            for raw in [term.text] + feedAliases(term) {
                let form = sanitize(raw)
                guard form.count >= minFormLength, seen.insert(form).inserted else { continue }
                let skeleton = VocabularyGate.skeleton(form)
                guard !skeleton.isEmpty else { continue }
                let wordCount = form.split(separator: " ").count
                forms.append(Form(
                    term: term, termIndex: termIndex, skeleton: skeleton,
                    letters: letterMask(skeleton), wordCount: wordCount,
                    windowWidthLimit: max(wordCount + 1, acronym ? skeleton.count : 0)))
            }
        }
        return forms
    }

    /// The user's aliases plus, for a multi-word term, its space-stripped form
    /// ("Ramaa Nathan" → "RamaaNathan") — the merged-word fix Mac, iOS and
    /// Windows each filed against the same bug. Feed-time only.
    static func feedAliases(_ term: VocabTerm) -> [String] {
        let merged = term.text.split(separator: " ").joined()
        guard !merged.isEmpty,
              merged.count != term.text.trimmingCharacters(in: .whitespaces).count else {
            return term.aliases
        }
        if term.aliases.contains(where: { CorrectionKey.normalize($0) == CorrectionKey.normalize(merged) }) {
            return term.aliases
        }
        return term.aliases + [merged]
    }

    /// The interchange-format sanitizer (Windows `VocabularyStore.SanitizeTerm`):
    /// NFC, drop `:` `,` `;` and control characters, collapse whitespace, strip
    /// a leading `#`. Never case-folds.
    static func sanitize(_ raw: String) -> String {
        let nfc = raw.precomposedStringWithCanonicalMapping
        let kept = String(nfc.unicodeScalars.filter {
            $0 != ":" && $0 != "," && $0 != ";" && !CharacterSet.controlCharacters.contains($0)
        }.map(Character.init))
        let collapsed = kept.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
    }

    /// Same letters as the term — claimed so a wider window cannot steal it.
    /// Single-word is case-insensitive (the gate's own identity test); a
    /// multi-word span only on an exact spelling, because there the casing is
    /// still the fix.
    private static func isIdentity(_ spanText: String, _ m: Match) -> Bool {
        m.width == 1
            ? CorrectionKey.normalize(spanText) == CorrectionKey.normalize(m.form.term.text)
            : spanText == m.form.term.text
    }

    /// The alias list to hand the gate, or nil when this match must be dropped.
    /// A window WIDER than its form ("nemo tron" → "Nemotron") is reachable in
    /// the gate only through a surface of that width, so the matched span is
    /// fed back as an alias — and ONLY when the span is already inside the
    /// gate's plausibility gap on its own. The brake is never loosened.
    private static func widthUnlockAliases(_ spanText: String, _ m: Match) -> [String]? {
        var aliases = m.form.term.aliases
        guard m.width > m.form.wordCount else { return aliases }
        let heard = VocabularyGate.skeleton(spanText)
        guard !heard.isEmpty else { return nil }
        let gap = ([m.form.term.text] + aliases).map { surface -> Double in
            let s = VocabularyGate.skeleton(surface)
            guard !s.isEmpty else { return .infinity }
            return Double(VocabularyGate.levenshtein(heard, s)) / Double(max(heard.count, s.count))
        }.min() ?? .infinity
        guard gap <= VocabularyGate.plausibilityCeiling else { return nil }
        let unlock = sanitize(spanText)
        guard !unlock.isEmpty else { return nil }
        if !aliases.contains(where: { CorrectionKey.normalize($0) == CorrectionKey.normalize(unlock) }) {
            aliases.append(unlock)
        }
        return aliases
    }

    /// Cheap pre-filter: every character present on one side and absent on the
    /// other needs at least one edit, so a symmetric-difference popcount over
    /// the budget cannot match.
    private static func couldMatch(_ window: Window, _ form: Form, budget: Int) -> Bool {
        guard !window.skeleton.isEmpty else { return false }
        guard abs(window.skeleton.count - form.skeleton.count) <= budget else { return false }
        return (window.letters & ~form.letters).nonzeroBitCount <= budget
            && (form.letters & ~window.letters).nonzeroBitCount <= budget
    }

    /// Presence bitmap over a–z; everything else folds into one shared bit,
    /// which only ever makes the filter more permissive.
    private static func letterMask(_ skeleton: [Character]) -> UInt32 {
        var mask: UInt32 = 0
        for c in skeleton {
            if let a = c.asciiValue, a >= 97, a <= 122 {
                mask |= 1 << UInt32(a - 97)
            } else {
                mask |= 1 << 26
            }
        }
        return mask
    }

    /// Restricted Damerau–Levenshtein (optimal string alignment), abandoned as
    /// soon as every cell in a row exceeds `budget` (returns `budget + 1`).
    /// Transpositions are the point: an ASR that swaps two letters of a name is
    /// one mistake, and charging it two would put half the near-misses out of
    /// reach.
    static func restrictedEdits(_ a: [Character], _ b: [Character], budget: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let overflow = budget + 1
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    v = Swift.min(v, prev2[j - 2] + 1)
                }
                cur[j] = v
                rowMin = Swift.min(rowMin, v)
            }
            if rowMin > budget { return overflow }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count]
    }

    // MARK: - One-call entry point

    /// Find and apply in one step: the corrector's candidates, run through the
    /// full gate. `totalAudioDuration` is 1.0 because the synthesized detection
    /// times are already positions on the gate's [0, 1] axis, not real seconds.
    public static func correct(
        transcript: String,
        terms: [VocabTerm],
        language: String,
        commonWords: CommonWordsProvider,
        overrides: [CorrectionStore.OverrideEntry] = [],
        diagnostics: DiagnosticsSink = NoopDiagnosticsSink()
    ) -> VocabularyGate.Result {
        let found = detections(
            in: transcript, terms: terms, language: language, diagnostics: diagnostics)
        guard !found.isEmpty else {
            return VocabularyGate.Result(
                text: transcript, applied: 0, blocked: [], proposals: [])
        }
        return VocabularyGate.applyFromDetections(
            originalTranscript: transcript,
            detections: found,
            totalAudioDuration: 1.0,
            commonWords: commonWords,
            commonWordsResource: commonWordsResource(for: language),
            overrides: overrides,
            diagnostics: diagnostics)
    }
}
