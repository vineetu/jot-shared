import Foundation

/// **v1b — the correction store.** Per-term trust + user-confirmed wrong→right
/// mappings, learned from the owner's ✓/✗ verdicts in the transcript pane.
///
/// Each mapping carries `net = confirmations − reverts`. The gate consults a
/// snapshot of these (see `VocabularyGate`): a confirmed mapping with a high
/// enough net **overrides the gate's guards for that exact `(originalWord →
/// term)` pair only** — so once the owner has said "when I say Jamie I mean
/// Jamy", the gate applies it, even though "jamie" is a common word.
///
/// Safety (review §0j, corrected V2-4 2026-07-14 — the old "common arms at
/// net ≥ 2" note described behavior the gate never implemented):
///   - A mapping whose `originalWord` is a **common word** NEVER auto-applies
///     from net alone (§v2-B) — it auto-applies only via the explicit
///     "Always replace" grant (`alwaysReplace`), which the pane offers after
///     net ≥ 2 and which ONE revert revokes. A rare/OOV original arms at
///     net ≥ 1. Deactivation is always net ≤ 0 (easy to disarm, hard to arm
///     a dangerous one).
///   - "Confirm a block is correct" adds the pair to a per-term **suppressed**
///     set so the pane stops re-surfacing it (the gate keeps blocking silently).
///
/// Storage: a side-JSON `corrections.json` under `<containerRoot>/Vocabulary/`.
/// Path *policy* (which OS directory the root is) is the app's — the store takes
/// an injected `containerRoot` (nil ⇒ in-memory, no persistence, for tests).
/// Single writer (this actor); atomic writes.
public actor CorrectionStore {

    // MARK: - Model

    public struct Mapping: Codable, Sendable, Equatable {
        public var originalWord: String     // normalized, lowercased ("jamie")
        public var term: String             // the vocab term, original casing ("Jamy")
        public var confirmations: Int = 0
        public var reverts: Int = 0
        /// Count of times the owner said "keep original" on this pair while it was
        /// BLOCKED (gate outcome "kept"). The learning `net` deliberately ignores
        /// these — a kept-keep contributes 0 (demote needs an APPLIED revert,
        /// `CorrectionProvenance.desiredContribution`), so for a common-word
        /// proposal like "okay"→"Okta" `net` never moves no matter how many times
        /// the owner rejects it. `blockedKeeps` is the ONLY signal of that repeated
        /// rejection. Read ONLY by the keyboard ask filter (`keyboardSuppressedPairs`)
        /// — the gate and the transcript pane ignore it, so suppression is
        /// keyboard-only. Defaulted-decode for back-compat with corrections.json
        /// written before this field existed.
        public var blockedKeeps: Int = 0
        /// V2-4 explicit grant: the owner tapped "Always replace" for this
        /// exact pair — the gate auto-applies it even when the original is a
        /// common word (§v2-B's letter is kept: the user consented
        /// explicitly, on-screen). REVOKED automatically by any negative
        /// learning event (an applied-revert) — one revert demotes.
        public var alwaysReplace: Bool = false
        /// Learn-from-edits counters (design `vocabulary-learn-from-edits`),
        /// written ONLY by `recordEdit` — a hand edit in the transcript, or an
        /// explicit "keep original" tap. Separate from `confirmations`/`reverts`
        /// on purpose: `confirm` refuses common originals and a revert can lock a
        /// common pair at net −1, while an edit of "cloud" → "Claude" must count.
        /// Edits toward the term.
        public var editsToward: Int = 0
        /// Edits back to the original, and explicit "keep original" taps.
        public var editsAway: Int = 0
        /// Toward-edits in a row since the last away-edit (D6 arming).
        public var editStreak: Int = 0
        /// A toward-edit whose original the MODEL wrote (not AI cleanup, D11) —
        /// only such pairs raise decode-time strength.
        public var editHeard: Bool = false
        public var net: Int { confirmations - reverts }

        /// Edits say the user means the term here (toward outweighs away).
        public var editsFavorTerm: Bool { editsToward > editsAway }

        /// D6: the common-original text rule armed by edits alone — two toward
        /// edits in a row since the last away edit. `alwaysReplace` is the arm
        /// itself (cleared by any away edit); requiring the streak too keeps a
        /// legacy common grant from passing as edit-armed.
        public var isEditArmed: Bool {
            alwaysReplace && editStreak >= CorrectionStore.commonEditArmStreak
        }

        public init(originalWord: String, term: String,
                    confirmations: Int = 0, reverts: Int = 0, blockedKeeps: Int = 0,
                    alwaysReplace: Bool = false,
                    editsToward: Int = 0, editsAway: Int = 0, editStreak: Int = 0,
                    editHeard: Bool = false) {
            self.originalWord = originalWord
            self.term = term
            self.confirmations = confirmations
            self.reverts = reverts
            self.blockedKeeps = blockedKeeps
            self.alwaysReplace = alwaysReplace
            self.editsToward = editsToward
            self.editsAway = editsAway
            self.editStreak = editStreak
            self.editHeard = editHeard
        }

        enum CodingKeys: String, CodingKey {
            case originalWord, term, confirmations, reverts, blockedKeeps, alwaysReplace
            case editsToward, editsAway, editStreak, editHeard
        }

        // Custom decode so an existing corrections.json (no `blockedKeeps` /
        // `alwaysReplace` key) loads cleanly instead of throwing — a throw
        // here makes `loadIfNeeded` silently drop ALL learned corrections.
        // Encodable stays synthesized. (This is ALSO how the Mac subset file —
        // no `alwaysReplace`/`mergeAskedPhrases` — decodes losslessly through
        // the shared superset model: absent keys default, present keys survive.)
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            originalWord = try c.decode(String.self, forKey: .originalWord)
            term = try c.decode(String.self, forKey: .term)
            confirmations = try c.decodeIfPresent(Int.self, forKey: .confirmations) ?? 0
            reverts = try c.decodeIfPresent(Int.self, forKey: .reverts) ?? 0
            blockedKeeps = try c.decodeIfPresent(Int.self, forKey: .blockedKeeps) ?? 0
            alwaysReplace = try c.decodeIfPresent(Bool.self, forKey: .alwaysReplace) ?? false
            editsToward = try c.decodeIfPresent(Int.self, forKey: .editsToward) ?? 0
            editsAway = try c.decodeIfPresent(Int.self, forKey: .editsAway) ?? 0
            editStreak = try c.decodeIfPresent(Int.self, forKey: .editStreak) ?? 0
            editHeard = try c.decodeIfPresent(Bool.self, forKey: .editHeard) ?? false
        }
    }

    /// Direction of one learn-from-edits signal.
    public enum EditDirection: Sendable, Equatable {
        /// The user edited the original into the term.
        case toward
        /// The user edited the term back, or explicitly kept the original.
        case away
    }

    /// One learned `(original → term)` pair for pair-targeted decode bias: the
    /// decoder pushes toward `term` only where it is spelling `original`.
    public struct LearnedPair: Sendable, Equatable, Hashable {
        public let original: String
        public let term: String

        public init(original: String, term: String) {
            self.original = original
            self.term = term
        }
    }

    /// Decode-time bias weight for a vocabulary term nobody has corrected (the
    /// Nemotron Multilingual default, chosen on LibriSpeech).
    public static let baseBiasStrength: Float = 3.5
    /// Whole-word strength of a term the user has corrected toward (D5: one
    /// edit is enough). Measured on LibriSpeech test-clean: 5 is
    /// indistinguishable from control; 6 already repeats the term.
    public static let learnedBiasStrength: Float = 5.0
    /// Toward-edits in a row (since the last away edit) that arm a common
    /// original's text rule for decoders without bias (D6).
    public static let commonEditArmStreak = 2

    /// Threshold of repeated "keep original" rejections on a BLOCKED pair after
    /// which the keyboard stops re-asking it (transcript review still surfaces it).
    public static let keyboardKeepSuppressThreshold = 2

    public struct Term: Codable, Sendable {
        public var mappings: [Mapping] = []
        public var suppressedBlocks: [String] = []   // normalized originalWords the user said "don't ask"
        /// V2-3 one-shot teach lane: normalized heard phrases this term has
        /// already used its single merge-teach ask on ("sri ram"). A phrase
        /// appears here once EVER — asked and never re-asked, adjudicated or
        /// not (round-2: bounded fatigue). Optional for back-compat decode.
        public var mergeAskedPhrases: [String]?

        public init(mappings: [Mapping] = [], suppressedBlocks: [String] = [],
                    mergeAskedPhrases: [String]? = nil) {
            self.mappings = mappings
            self.suppressedBlocks = suppressedBlocks
            self.mergeAskedPhrases = mergeAskedPhrases
        }
    }

    /// Immutable, `Sendable` snapshot handed to the (synchronous) gate so the
    /// per-replacement hot loop never hops back to this actor.
    public struct OverrideEntry: Sendable, Equatable {
        public let originalWord: String
        public let term: String
        public let net: Int
        /// V2-4 explicit grant flag (see `Mapping.alwaysReplace`).
        public let alwaysReplace: Bool

        public init(originalWord: String, term: String, net: Int, alwaysReplace: Bool = false) {
            self.originalWord = originalWord
            self.term = term
            self.net = net
            self.alwaysReplace = alwaysReplace
        }
    }

    // MARK: - State

    private let containerRoot: URL?
    private let diagnostics: DiagnosticsSink
    /// **Learning guard (A3/R9).** True when an original is common by the
    /// gate's own rule (`VocabularyGate.isCommonOriginal`: ANY word in the
    /// active language's everyday-word set). A rule whose source is a common
    /// word is never learned: confirmations, positive adjustments and "Always
    /// replace" grants for it are refused (reverts are still recorded), and the
    /// snapshot never hands the gate a positive or granted rule for one. nil ⇒
    /// no guard (tests / legacy callers).
    private let isCommonOriginal: (@Sendable (String) -> Bool)?
    private var terms: [String: Term] = [:]   // keyed by lowercased term
    private var loaded = false
    /// Set when `loadIfNeeded` found a file that EXISTS but failed to decode.
    /// While true, `persist()` is a hard no-op — the store must never overwrite
    /// a curated ledger it could not read (Q-3, real data-loss guard). Distinct
    /// from file-absent/empty, which is safe to start empty and persist.
    private var loadFailed = false
    /// Set when `loadIfNeeded` found a file that exists but could not be READ.
    /// The store still starts empty (legacy), but the one-time migration must
    /// not count as done over a ledger it never saw.
    private var loadUnreadable = false

    /// - Parameters:
    ///   - containerRoot: directory the `Vocabulary/` subtree lives under. `nil`
    ///     ⇒ purely in-memory (no load, no persist) — the test / no-persist mode.
    ///   - diagnostics: sink for the decode-failure guard (design seam 3).
    ///   - isCommonOriginal: the learning guard (see the property). The app
    ///     passes the gate's own test over its active language's list.
    public init(containerRoot: URL?, diagnostics: DiagnosticsSink = NoopDiagnosticsSink(),
                isCommonOriginal: (@Sendable (String) -> Bool)? = nil) {
        self.containerRoot = containerRoot
        self.diagnostics = diagnostics
        self.isCommonOriginal = isCommonOriginal
    }

    /// True when the learning guard refuses positive learning for `originalWord`.
    public nonisolated func refusesLearning(originalWord: String) -> Bool {
        isCommonOriginal?(CorrectionKey.normalize(originalWord)) ?? false
    }

    private func refuse(_ what: String, originalWord: String, term: String) -> Bool {
        guard refusesLearning(originalWord: originalWord) else { return false }
        diagnostics.record(
            category: .vocabularyGate,
            message: "learning refused (\(what)): common original",
            metadata: ["original": CorrectionKey.normalize(originalWord), "term": term])
        return true
    }

    // MARK: - Reads (for the gate + pane)

    /// All confirmed mappings as override entries. Fetched once per dictation,
    /// before rescore, and passed into `VocabularyGate.apply`.
    public func snapshot() -> [OverrideEntry] {
        loadIfNeeded()
        return terms.values.flatMap { term in
            term.mappings.map {
                // Defense in depth for rules learned before the guard existed
                // (the migration below persists the same cleanup): a common
                // original keeps its demotions but never a positive or granted
                // rule.
                let guarded = refusesLearning(originalWord: $0.originalWord)
                // D6: the one common arm is the edit-earned one. It reports net
                // 0 so an older revert (net ≤ −1 blocks before the grant is
                // read) can't cancel two later deliberate edits.
                if guarded, $0.isEditArmed {
                    return OverrideEntry(originalWord: $0.originalWord, term: $0.term,
                                         net: 0, alwaysReplace: true)
                }
                return OverrideEntry(originalWord: $0.originalWord, term: $0.term,
                                     net: guarded ? min($0.net, 0) : $0.net,
                                     alwaysReplace: guarded ? false : $0.alwaysReplace)
            }
        }
    }

    /// V2-4: grant "always replace originalWord with term" — the explicit
    /// user consent that lets the gate auto-apply a common-word pair. Ends
    /// the forever-ask treadmill for a pair the owner has confirmed twice.
    /// Returns false (and records nothing) when the learning guard refuses a
    /// common original — a grant must never make an everyday word auto-apply.
    @discardableResult
    public func grantAlwaysReplace(originalWord: String, term: String) -> Bool {
        loadIfNeeded()
        if refuse("always-replace", originalWord: originalWord, term: term) { return false }
        mutate(originalWord: originalWord, term: term) { $0.alwaysReplace = true }
        persist()
        return true
    }

    /// True if the owner tapped "Stop asking" on a blocked `(originalWord → term)`
    /// pair. Read ONLY by `keyboardSuppressedPairs` (keyboard-only) — the gate and
    /// transcript pane do NOT consult this, so suppression never hides the pair
    /// from the transcript review.
    public func isBlockSuppressed(originalWord: String, term: String) -> Bool {
        loadIfNeeded()
        return terms[term.lowercased()]?.suppressedBlocks.contains(normalize(originalWord)) ?? false
    }

    /// Normalized `"<originalWord>|<term>"` keys the keyboard should STOP asking:
    /// the owner has either kept the original ≥ `keyboardKeepSuppressThreshold`
    /// times on a blocked pair (`blockedKeeps`) OR tapped "Stop asking"
    /// (`suppressedBlocks`). Keyboard-only — the transcript review reads neither,
    /// so it keeps surfacing these for deliberate correction. The key format
    /// matches `AskPolicy`'s pair key exactly (`CorrectionKey.normalize(originalWord)
    /// + "|" + term.lowercased()`).
    public func keyboardSuppressedPairs() -> Set<String> {
        loadIfNeeded()
        var out: Set<String> = []
        for (termKey, term) in terms {
            // `m.originalWord` / `ow` are already normalized on write and
            // `termKey` is already lowercased, so `pairKey` is idempotent here —
            // but routing through it keeps ONE key rule shared with `AskPolicy`.
            for m in term.mappings where m.blockedKeeps >= Self.keyboardKeepSuppressThreshold {
                out.insert(CorrectionKey.pairKey(originalWord: m.originalWord, term: termKey))
            }
            for ow in term.suppressedBlocks {
                out.insert(CorrectionKey.pairKey(originalWord: ow, term: termKey))
            }
        }
        return out
    }

    /// V2-3 one-shot teach lane reads: every "originalWord|term" pair whose
    /// merge-teach ask has already been used. Same pair-key shape as
    /// `keyboardSuppressedPairs`.
    public func mergeAskedPairs() -> Set<String> {
        loadIfNeeded()
        var out: Set<String> = []
        for (termKey, term) in terms {
            for phrase in term.mergeAskedPhrases ?? [] {
                out.insert(CorrectionKey.pairKey(originalWord: phrase, term: termKey))
            }
        }
        return out
    }

    /// Record that a merge-teach ask for `(originalWord → term)` has been
    /// published — its single shot is spent, adjudicated or not.
    public func noteMergeAsked(originalWord: String, term: String) {
        loadIfNeeded()
        let key = term.lowercased()
        let phrase = normalize(originalWord)
        var t = terms[key] ?? Term()
        var asked = t.mergeAskedPhrases ?? []
        guard !asked.contains(phrase) else { return }
        asked.append(phrase)
        t.mergeAskedPhrases = asked
        terms[key] = t
        persist()
    }

    // MARK: - Verdicts (called by the pane)

    /// Owner confirmed a correction `(originalWord → term)` should apply. Raises
    /// the mapping's net; once net clears the threshold the gate's override fires.
    /// Returns false (nothing recorded) when the learning guard refuses a
    /// common original.
    @discardableResult
    public func confirm(originalWord: String, term: String) -> Bool {
        loadIfNeeded()
        if refuse("confirm", originalWord: originalWord, term: term) { return false }
        mutate(originalWord: originalWord, term: term) { $0.confirmations += 1 }
        persist()
        return true
    }

    /// Move the mapping's net by `delta` (a transcript's contribution to learning;
    /// reversible — undo passes the opposite delta). `delta > 0` reinforces (gate
    /// auto-applies once net ≥ 1, rare originals only); `delta < 0` demotes (gate
    /// STOPS auto-applying at net ≤ −1, common AND rare). A single transcript
    /// contributes at most ±1 per mapping (computed in `CorrectionProvenance`), so
    /// reviewing three "name→Jamy" occurrences can't inflate net to 3.
    ///
    /// Returns false when a POSITIVE delta is refused by the learning guard (a
    /// common original); negative deltas (reverts) are always recorded.
    @discardableResult
    public func adjust(originalWord: String, term: String, by delta: Int) -> Bool {
        guard delta != 0 else { return true }
        loadIfNeeded()
        if delta > 0, refuse("adjust", originalWord: originalWord, term: term) { return false }
        mutate(originalWord: originalWord, term: term) {
            if delta > 0 { $0.confirmations += delta } else { $0.reverts += -delta }
            // V2-4: one revert revokes an "always replace" grant — the user
            // changed their mind, the pair goes back to asking.
            if delta < 0 { $0.alwaysReplace = false }
        }
        persist()
        return true
    }

    /// **One-time migration (A3).** Drop every positive rule whose original the
    /// learning guard calls common: confirmations and "Always replace" grants
    /// are cleared, reverts / keeps are kept, and a mapping left with nothing is
    /// removed. Returns how many mappings changed, or `nil` when the migration
    /// did not really run — no guard, no on-disk ledger (in-memory store), or a
    /// corrections.json that exists but could not be read/decoded — so the
    /// caller must NOT mark it done.
    @discardableResult
    public func dropCommonOriginalRules() -> Int? {
        loadIfNeeded()
        guard isCommonOriginal != nil, fileURL != nil, !loadFailed, !loadUnreadable else { return nil }
        var changed = 0
        for (key, var term) in terms {
            var kept: [Mapping] = []
            for var m in term.mappings {
                // An edit-armed grant is the designed common arm (D6), not a
                // pre-guard leftover — the migration leaves it alone.
                guard refusesLearning(originalWord: m.originalWord),
                      m.confirmations > 0 || (m.alwaysReplace && !m.isEditArmed) else {
                    kept.append(m)
                    continue
                }
                changed += 1
                m.confirmations = 0
                if !m.isEditArmed { m.alwaysReplace = false }
                if m.reverts > 0 || m.blockedKeeps > 0 || m.editsToward > 0 || m.editsAway > 0 {
                    kept.append(m)
                }
            }
            term.mappings = kept
            terms[key] = term
        }
        if changed > 0 {
            persist()
            diagnostics.record(
                category: .vocabularyGate,
                message: "dropped common-original learned rules",
                metadata: ["count": "\(changed)"])
        }
        return changed
    }

    /// Owner reverted a correction `(originalWord → term)`. Raises reverts; at
    /// net ≤ 0 the override deactivates and the gate falls back to its safe default.
    public func revert(originalWord: String, term: String) {
        loadIfNeeded()
        mutate(originalWord: originalWord, term: term) { $0.reverts += 1 }
        persist()
    }

    /// Owner tapped "Stop asking" on a *blocked* proposal — hard-suppress it from
    /// keyboard asks immediately (see `keyboardSuppressedPairs`). Transcript review
    /// is unaffected (it doesn't read `suppressedBlocks`).
    public func suppressBlock(originalWord: String, term: String) {
        loadIfNeeded()
        let key = term.lowercased()
        var t = terms[key] ?? Term()
        let ow = normalize(originalWord)
        if !t.suppressedBlocks.contains(ow) { t.suppressedBlocks.append(ow) }
        terms[key] = t
        persist()
    }

    /// Owner said "keep original" on a BLOCKED pair (gate outcome "kept"). The
    /// learning `net` ignores this (contributes 0), so we count it separately;
    /// once it reaches `keyboardKeepSuppressThreshold` the keyboard stops re-asking
    /// the pair. Called from the single verdict choke point (`CorrectionReviewModel.pick`),
    /// so it counts keeps from BOTH the keyboard (drained via `CorrectionInbox`)
    /// and the in-app pane.
    public func noteBlockedKeep(originalWord: String, term: String) {
        loadIfNeeded()
        mutate(originalWord: originalWord, term: term) { $0.blockedKeeps += 1 }
        persist()
    }

    /// Reverse of `noteBlockedKeep` (an Undo of a blocked-pair "keep original").
    /// Floored at 0 so it can never go negative.
    public func clearBlockedKeep(originalWord: String, term: String) {
        loadIfNeeded()
        mutate(originalWord: originalWord, term: term) { $0.blockedKeeps = max(0, $0.blockedKeeps - 1) }
        persist()
    }

    // MARK: - Learn from edits

    /// Record one edit-session lesson for `(originalWord → term)`. NOT guarded
    /// by the learning guard: common originals ("cloud") count here, and the
    /// gate's own safety is untouched — `snapshot()` still clamps common nets,
    /// and the only common arm is the edit-earned one below. `suppressedBlocks`
    /// (ask-only) is irrelevant to this path (D7).
    ///   - toward: `editsToward += 1`, streak up; `heardByModel` marks the pair
    ///     as a real mishearing (D11). A common original arms its text rule at
    ///     `commonEditArmStreak` toward edits in a row (D6).
    ///   - away: `editsAway += 1`, streak reset, any grant cleared — two later
    ///     toward edits re-arm it.
    public func recordEdit(originalWord: String, term: String, direction: EditDirection,
                           heardByModel: Bool = false) {
        loadIfNeeded()
        let common = refusesLearning(originalWord: originalWord)
        mutate(originalWord: originalWord, term: term) { m in
            switch direction {
            case .toward:
                m.editsToward += 1
                m.editStreak += 1
                if heardByModel { m.editHeard = true }
                if common, m.editStreak >= Self.commonEditArmStreak {
                    m.alwaysReplace = true
                }
            case .away:
                m.editsAway += 1
                m.editStreak = 0
                m.alwaysReplace = false
            }
        }
        persist()
    }

    /// Reverse of one `recordEdit` (an Undo of an explicit "keep original" in
    /// the review pane). Counters floor at 0; a cleared grant is not restored —
    /// the next toward-edit re-earns it.
    public func retractEdit(originalWord: String, term: String, direction: EditDirection) {
        loadIfNeeded()
        let key = term.lowercased()
        let ow = normalize(originalWord)
        guard var t = terms[key], let i = t.mappings.firstIndex(where: { $0.originalWord == ow })
        else { return }
        switch direction {
        case .toward:
            t.mappings[i].editsToward = max(0, t.mappings[i].editsToward - 1)
            t.mappings[i].editStreak = max(0, t.mappings[i].editStreak - 1)
        case .away:
            t.mappings[i].editsAway = max(0, t.mappings[i].editsAway - 1)
        }
        terms[key] = t
        persist()
    }

    /// Decode-time strength for `term`, derived from the edit counters (no
    /// stored scalar that can drift): the learned strength when any of its
    /// model-heard pairs has more edits toward than away, the base otherwise.
    /// Confirm/revert verdicts never feed this, so a user who never edits sees
    /// no change.
    public func learnedStrength(term: String) -> Float {
        loadIfNeeded()
        return strength(of: terms[term.lowercased()])
    }

    /// Every term whose strength is above the base, keyed by lowercased term —
    /// one read per dictation instead of one per term.
    public func learnedStrengths() -> [String: Float] {
        loadIfNeeded()
        var out: [String: Float] = [:]
        for (key, term) in terms {
            let s = strength(of: term)
            if s > Self.baseBiasStrength { out[key] = s }
        }
        return out
    }

    /// Active learned pairs for pair-targeted decode bias: model-heard, with
    /// more edits toward the term than away. Sorted for a stable comparison.
    public func learnedPairs() -> [LearnedPair] {
        loadIfNeeded()
        return terms.values
            .flatMap { $0.mappings }
            .filter { $0.editHeard && $0.editsFavorTerm }
            .map { LearnedPair(original: $0.originalWord, term: $0.term) }
            .sorted { ($0.term.lowercased(), $0.original) < ($1.term.lowercased(), $1.original) }
    }

    /// Re-case every stored mapping of `term` to the user's casing (D10). The
    /// store keys terms lowercased, so this only rewrites the display casing.
    public func recase(term: String) {
        loadIfNeeded()
        let key = term.lowercased()
        guard var t = terms[key], t.mappings.contains(where: { $0.term != term }) else { return }
        for i in t.mappings.indices { t.mappings[i].term = term }
        terms[key] = t
        persist()
    }

    private func strength(of term: Term?) -> Float {
        let learned = term?.mappings.contains { $0.editHeard && $0.editsFavorTerm } ?? false
        return learned ? Self.learnedBiasStrength : Self.baseBiasStrength
    }

    // MARK: - Internals

    private func mutate(originalWord: String, term: String, _ change: (inout Mapping) -> Void) {
        let key = term.lowercased()
        let ow = normalize(originalWord)
        var t = terms[key] ?? Term()
        if let i = t.mappings.firstIndex(where: { $0.originalWord == ow }) {
            change(&t.mappings[i])
        } else {
            var m = Mapping(originalWord: ow, term: term)
            change(&m)
            t.mappings.append(m)
        }
        terms[key] = t
    }

    private func normalize(_ s: String) -> String {
        CorrectionKey.normalize(s)
    }

    private var fileURL: URL? {
        guard let containerRoot else { return nil }
        let vocab = containerRoot.appendingPathComponent("Vocabulary", isDirectory: true)
        try? FileManager.default.createDirectory(at: vocab, withIntermediateDirectories: true)
        return vocab.appendingPathComponent("corrections.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL else { return }
        // No file (or unreadable) → start empty; SAFE to persist later. Only a
        // file that EXISTS but fails to DECODE is the data-loss hazard (Q-3):
        // the old `try?`-blob path left `terms` empty and let the next persist()
        // write `{}` over the curated ledger. Distinguish the two here.
        guard let data = try? Data(contentsOf: url) else {
            loadUnreadable = FileManager.default.fileExists(atPath: url.path)
            return
        }
        guard !data.isEmpty else { return }
        do {
            terms = try JSONDecoder().decode([String: Term].self, from: data)
        } catch {
            // File present but undecodable — REFUSE to persist (leave the bytes
            // intact for recovery) and surface the failure.
            loadFailed = true
            diagnostics.record(
                category: .vocabularySaveFailed,
                message: "corrections.json present but failed to decode — refusing to overwrite",
                metadata: ["error": "\(error)"])
        }
    }

    private func persist() {
        // Never overwrite a file we could not decode (see `loadFailed`).
        guard !loadFailed else { return }
        guard let url = fileURL, let data = try? JSONEncoder().encode(terms) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
