import Foundation

/// **The keyboard correction-ask decision core.** Extracted from iOS's
/// `CorrectionAsksPublisher` (design §1): the pure *decision* logic —
/// `worthAsking` / `prior` / rank / `maxAsks` cap / merge-teach one-shot /
/// mixed-payload drop — with none of the IPC. The app-side plumbing keeps the
/// pieces that touch a process boundary: slicing context snippets out of the
/// published text, serializing into `CorrectionBridge.Ask`, and — critically —
/// *spending* the merge-teach one-shot.
///
/// **Decide in core, spend in plumbing (package invariant).** `select` READS the
/// `mergeAsked` set and MARKS the chosen merge-teach asks (`Selection.isMergeTeach`),
/// but never writes. The `CorrectionStore.noteMergeAsked(...)` spend happens
/// after publish, app-side, exactly as iOS does it. The one-shot flag is computed
/// ONCE here and carried on the `Selection` so the plumbing only reads it (the
/// iOS publisher evaluated the same predicate twice — folded to one).
public enum AskPolicy {
    public static let maxAsks = 3

    /// A selected ask: which record, whether it is the one-shot merge-teach
    /// card (so the plumbing knows to spend its shot), and the chosen alternate
    /// (surfaced so Mac's 3-option pill can read it without re-deriving, §2a).
    public struct Selection: Sendable, Equatable {
        public let record: CorrectionProvenance.Record
        public let isMergeTeach: Bool
        public let altTerm: String?
        public let altFind: String?

        public init(record: CorrectionProvenance.Record, isMergeTeach: Bool,
                    altTerm: String?, altFind: String?) {
            self.record = record
            self.isMergeTeach = isMergeTeach
            self.altTerm = altTerm
            self.altFind = altFind
        }
    }

    /// Select the ≤`maxAsks` records worth a keyboard confirm, closest-to-automatic
    /// first. Pure — no persistence, no IPC. Inputs:
    ///   - `unresolved`: records the owner has not adjudicated (verdict == nil).
    ///   - `overrides`: the store snapshot (drives `prior` and the always-replace
    ///     `granted` exclusion — both derived here, not passed separately).
    ///   - `keyboardSuppressed`: `CorrectionStore.keyboardSuppressedPairs()`.
    ///   - `mergeAsked`: `CorrectionStore.mergeAskedPairs()`.
    public static func select(
        unresolved: [CorrectionProvenance.Record],
        overrides: [CorrectionStore.OverrideEntry],
        keyboardSuppressed: Set<String>,
        mergeAsked: Set<String>
    ) -> [Selection] {
        func pairKey(_ r: CorrectionProvenance.Record) -> String {
            CorrectionKey.pairKey(originalWord: r.originalWord, term: r.term)
        }
        func prior(_ r: CorrectionProvenance.Record) -> Int {
            // Match the store's normalization exactly (lowercase + trim the same
            // punctuation set) so `prior` doesn't silently read 0 on a punctuated
            // original — which would drop its prior-desc ranking.
            let ow = CorrectionKey.normalize(r.originalWord)
            let tm = r.term.lowercased()
            return overrides.first { $0.originalWord == ow && $0.term.lowercased() == tm }?.net ?? 0
        }
        // V2-3 one-shot teach lane: a merge-shaped BLOCKED proposal ("sri ram" →
        // Sriram) gets exactly ONE teach ask per phrase EVER. Memoized by the
        // per-occurrence `record.key` so the eligibility is computed ONCE and read
        // by both `worthAsking` (selection) and the final `Selection.isMergeTeach`
        // (the plumbing's spend flag) — folding the former double evaluation.
        var mergeEligibleMemo: [String: Bool] = [:]
        func mergeTeachEligible(_ r: CorrectionProvenance.Record) -> Bool {
            if let cached = mergeEligibleMemo[r.key] { return cached }
            let v = r.shape == "merge" && r.outcome == "kept" && !mergeAsked.contains(pairKey(r))
            mergeEligibleMemo[r.key] = v
            return v
        }
        // V2-4: a pair the owner explicitly granted "Always replace" stops
        // consuming ask budget — it auto-applies (revocable in transcript review).
        func granted(_ r: CorrectionProvenance.Record) -> Bool {
            overrides.first {
                $0.originalWord == CorrectionKey.normalize(r.originalWord)
                    && $0.term.lowercased() == r.term.lowercased()
            }?.alwaysReplace == true
        }
        // Worth asking on the keyboard: an APPLIED correction (the gate changed
        // the text — most worth a quick confirm) or a mapping part-way to
        // automatic (prior > 0). ALL other KEPT blocks — including low-confidence
        // (`unsure`) ones — stay on the transcript only. EXCLUDE suppressed pairs
        // and always-replace grants. A merge-shaped BLOCKED record is eligible
        // ONLY through the one-shot teach lane — never via prior>0 (which would
        // resurrect a spent phrase and defeat both once-ever and post-paste-only).
        func worthAsking(_ r: CorrectionProvenance.Record) -> Bool {
            if keyboardSuppressed.contains(pairKey(r)) { return false }
            if granted(r) { return false }
            if r.shape == "merge", r.outcome == "kept" {
                return mergeTeachEligible(r)
            }
            return r.outcome == "applied" || prior(r) > 0
        }

        let candidates = unresolved.filter(worthAsking)
        let ranked = candidates.sorted { prior($0) > prior($1) }
        var selected = Array(ranked.prefix(maxAsks))
        // Mixed-payload rules:
        // (a) pair-dedupe merge teach asks — two occurrences of "sri ram" in one
        //     dictation must produce ONE card, not two;
        // (b) if any normal (paste-holding) ask is selected, DROP the merge teach
        //     asks from this publish WITHOUT spending their one shot — a teach
        //     card must never ride a paste-holding deck.
        var seenMergePairs: Set<String> = []
        let hasNormalAsk = selected.contains { !($0.shape == "merge" && $0.outcome == "kept") }
        selected = selected.filter { r in
            guard r.shape == "merge", r.outcome == "kept" else { return true }
            if hasNormalAsk { return false }
            return seenMergePairs.insert(pairKey(r)).inserted
        }

        return selected.map { r in
            Selection(
                record: r,
                isMergeTeach: mergeTeachEligible(r),
                altTerm: r.alternates?.first?.term,
                altFind: r.alternates?.first?.find)
        }
    }
}
