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
/// * Its detections carry `acoustic: false`, so the §6 confidence-conditional
///   ceiling does **not** apply to them and they keep the flat 0.45. `score`
///   carries two incompatible scales; the corrector's control is its per-language
///   acceptance distance below, not the gate's ceiling.
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

    // MARK: - Candidate finding

    /// Fuzzy-match `terms` against `transcript` and emit gate detections.
    ///
    /// Returns an empty array — doing nothing at all — for any language the
    /// table does not clear (§1.2, fail closed).
    ///
    /// Windows are scanned at widths driven by each surface's word count, so a
    /// multi-word term can be found even when the engine wrote it as separate
    /// words. The gate re-derives the same window from the synthesized time
    /// fraction and re-applies every one of its own guards, so the worst a bad
    /// candidate here can do is be refused there.
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

        let ceiling = acceptanceDistance(for: language)

        // Whole words in document order. Split on ALL whitespace, matching the
        // gate's own tokenizer, so the word indices the two derive agree.
        let words = transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let n = words.count
        guard n > 0 else { return [] }

        struct Candidate {
            let range: Range<Int>       // window word indices
            let distance: Double
            let term: VocabTerm
        }
        var candidates: [Candidate] = []

        for term in terms where !term.isBlank {
            let surfaces = ([term.text] + term.aliases).filter { !$0.isEmpty }
            var widths: Set<Int> = []
            for surface in surfaces { widths.insert(max(1, surface.split(separator: " ").count)) }

            for width in widths.sorted() where width <= n {
                for lo in 0...(n - width) {
                    let hi = lo + width
                    let windowText = words[lo..<hi].joined(separator: " ")
                    let heard = VocabularyGate.skeleton(windowText)
                    guard !heard.isEmpty else { continue }

                    var best = Double.infinity
                    for surface in surfaces {
                        let s = VocabularyGate.skeleton(surface)
                        guard !s.isEmpty else { continue }
                        let d = Double(VocabularyGate.levenshtein(heard, s))
                            / Double(max(heard.count, s.count))
                        best = Swift.min(best, d)
                    }
                    // A distance of exactly 0 is the term already written
                    // correctly — the gate's identity no-op would drop it, so
                    // don't spend a detection on it.
                    guard best > 0, best <= ceiling else { continue }
                    candidates.append(Candidate(range: lo..<hi, distance: best, term: term))
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Best match first, then document order. The gate claims words
        // first-come by detection order, so emitting in this order is what makes
        // the strongest candidate win a contested span.
        candidates.sort {
            $0.distance != $1.distance
                ? $0.distance < $1.distance
                : $0.range.lowerBound < $1.range.lowerBound
        }

        var takenWords = Set<Int>()
        var out: [VocabularyGate.Detection] = []
        for candidate in candidates {
            guard !candidate.range.contains(where: { takenWords.contains($0) }) else { continue }
            candidate.range.forEach { takenWords.insert($0) }
            // Synthesize the position the gate reads. `applyFromDetections`
            // scores windows by proportional position over a [0, 1] axis, so
            // centring the detection on this window's midpoint makes the gate
            // re-derive exactly the window we matched.
            let centre = (Double(candidate.range.lowerBound) + Double(candidate.range.upperBound))
                / 2 / Double(n)
            out.append(
                VocabularyGate.Detection(
                    term: candidate.term.text,
                    aliases: candidate.term.aliases,
                    // NOT an acoustic score — the normalized string distance,
                    // negated so "closer" reads as "stronger" in the trace, the
                    // same direction the spotter's scores run. `acoustic: false`
                    // keeps anything from interpreting it on the CTC scale.
                    score: Float(-candidate.distance),
                    startTime: centre,
                    endTime: centre,
                    acoustic: false))
        }
        return out
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
