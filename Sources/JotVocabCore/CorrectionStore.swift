import Foundation

/// **v1b — the correction store.** Per-pair signals from the owner's answers
/// (review list, live ask) and corrections (`VocabularyLearning.apply`).
///
/// Nothing here auto-applies (owner decision 2026-09-29: no learned
/// auto-replace rules). The gate honours exactly one learned signal: a PAUSED
/// pair — the user's last explicit word on it was "keep the original" (a Keep
/// tap, a review "original" pick, an edit back) — which BLOCKS that exact
/// `(originalWord → term)` proposal. Everything else goes through the gate's
/// evidence steps. `net = confirmations − reverts` survives only as the ask
/// ranking prior (`AskPolicy`).
///
///   - "Stop asking" on a blocked proposal adds the pair to a per-term
///     **suppressed** set so asks stop re-surfacing it.
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
        /// Correction counters (design `vocabulary-learn-from-edits`), written
        /// ONLY by `recordEdit` / `forgetEdits`, i.e. by
        /// `VocabularyLearning.apply` — every correction surface. Separate from
        /// `confirmations`/`reverts` (answers to gate proposals).
        /// Corrections toward the term.
        public var editsToward: Int = 0
        /// Edits back to the original, and explicit "keep original" taps.
        public var editsAway: Int = 0
        /// A toward correction whose original the MODEL wrote (not AI cleanup,
        /// D11). Read by the one-time migration of edit-learned pairs into the list.
        public var editHeard: Bool = false
        /// Pair state (Revision 2 review #4): the LAST explicit signal wins —
        /// `.correct` clears it, `.keepOriginal` / an edit back sets it. A paused
        /// pair keeps its sounds-like in the list, is not sent to the decoder,
        /// and the gate blocks it.
        public var pairPaused: Bool = false
        public var net: Int { confirmations - reverts }

        /// Edits say the user means the term here (toward outweighs away).
        public var editsFavorTerm: Bool { editsToward > editsAway }

        public init(originalWord: String, term: String,
                    confirmations: Int = 0, reverts: Int = 0, blockedKeeps: Int = 0,
                    editsToward: Int = 0, editsAway: Int = 0,
                    editHeard: Bool = false, pairPaused: Bool = false) {
            self.originalWord = originalWord
            self.term = term
            self.confirmations = confirmations
            self.reverts = reverts
            self.blockedKeeps = blockedKeeps
            self.editsToward = editsToward
            self.editsAway = editsAway
            self.editHeard = editHeard
            self.pairPaused = pairPaused
        }

        /// Written keys. Files may still carry `alwaysReplace` / `editStreak`
        /// (the retired auto-replace grant and its arming streak): they decode
        /// as unknown keys and are dropped on the next write.
        enum CodingKeys: String, CodingKey {
            case originalWord, term, confirmations, reverts, blockedKeeps
            case editsToward, editsAway, editHeard, pairPaused
        }

        // Custom decode so an existing corrections.json (missing newer keys)
        // loads cleanly instead of throwing — a throw here makes
        // `loadIfNeeded` silently drop ALL learned signals. Encodable stays
        // synthesized.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            originalWord = try c.decode(String.self, forKey: .originalWord)
            term = try c.decode(String.self, forKey: .term)
            confirmations = try c.decodeIfPresent(Int.self, forKey: .confirmations) ?? 0
            reverts = try c.decodeIfPresent(Int.self, forKey: .reverts) ?? 0
            blockedKeeps = try c.decodeIfPresent(Int.self, forKey: .blockedKeeps) ?? 0
            editsToward = try c.decodeIfPresent(Int.self, forKey: .editsToward) ?? 0
            editsAway = try c.decodeIfPresent(Int.self, forKey: .editsAway) ?? 0
            editHeard = try c.decodeIfPresent(Bool.self, forKey: .editHeard) ?? false
            // Files from before pair state existed: the counters' verdict (more
            // edits away than toward) is the closest to "last signal".
            pairPaused = try c.decodeIfPresent(Bool.self, forKey: .pairPaused) ?? (editsAway > editsToward)
        }

        /// Nothing learned and nothing counted — safe to drop (an undo of the
        /// write that created it).
        var isEmpty: Bool {
            confirmations == 0 && reverts == 0 && blockedKeeps == 0
                && editsToward == 0 && editsAway == 0 && !editHeard && !pairPaused
        }
    }

    /// Direction of one learn-from-edits signal.
    public enum EditDirection: String, Codable, Sendable, Equatable {
        /// The user edited the original into the term.
        case toward
        /// The user edited the term back, or explicitly kept the original.
        case away
    }

    /// What one learning write did to one mapping, so `undo(_:)` can reverse
    /// exactly that write (Revision 2 review #5). Counters move back by their
    /// deltas (later writes by other surfaces survive); a flag goes back to its
    /// value before the write only if nothing changed it since (`after`).
    public struct EditRecord: Codable, Sendable, Equatable {
        /// Store-normalized original.
        public let originalWord: String
        public let term: String
        /// The mapping before the write; nil when the write created it.
        public let before: Mapping?
        /// The mapping right after the write; nil when the write removed it.
        public let after: Mapping?
        public let towardDelta: Int
        public let awayDelta: Int
        /// The term's stored casing before the write re-cased it; nil when unchanged.
        public let previousCasing: String?

        public init(originalWord: String, term: String, before: Mapping?, after: Mapping?,
                    towardDelta: Int = 0, awayDelta: Int = 0, previousCasing: String? = nil) {
            self.originalWord = originalWord
            self.term = term
            self.before = before
            self.after = after
            self.towardDelta = towardDelta
            self.awayDelta = awayDelta
            self.previousCasing = previousCasing
        }

        enum CodingKeys: String, CodingKey {
            case originalWord, term, before, after, towardDelta, awayDelta, previousCasing
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            originalWord = try c.decode(String.self, forKey: .originalWord)
            term = try c.decode(String.self, forKey: .term)
            before = try c.decodeIfPresent(Mapping.self, forKey: .before)
            after = try c.decodeIfPresent(Mapping.self, forKey: .after)
            towardDelta = try c.decodeIfPresent(Int.self, forKey: .towardDelta) ?? 0
            awayDelta = try c.decodeIfPresent(Int.self, forKey: .awayDelta) ?? 0
            previousCasing = try c.decodeIfPresent(String.self, forKey: .previousCasing)
        }
    }

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
        /// Ask ranking prior only (`AskPolicy`); the gate never applies on it.
        public let net: Int
        /// The user's last explicit signal kept the original: the gate blocks
        /// this exact pair (see `Mapping.pairPaused`).
        public let paused: Bool

        public init(originalWord: String, term: String, net: Int, paused: Bool = false) {
            self.originalWord = originalWord
            self.term = term
            self.net = net
            self.paused = paused
        }
    }

    // MARK: - State

    private let containerRoot: URL?
    private let diagnostics: DiagnosticsSink
    /// **Learning guard (A3/R9).** True when an original is common by the
    /// gate's own rule (`VocabularyGate.isCommonOriginal`: ANY word in the
    /// active language's everyday-word set). Confirmations and positive
    /// adjustments for one are refused (reverts are still recorded), and the
    /// snapshot never hands the ask ranking a positive prior for one. nil ⇒ no
    /// guard (tests / legacy callers).
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

    /// Every mapping as an entry: its pause state (the gate's one learned
    /// signal) and net (the ask ranking prior). Fetched once per dictation,
    /// before rescore, and passed into `VocabularyGate.apply`.
    public func snapshot() -> [OverrideEntry] {
        loadIfNeeded()
        return terms.values.flatMap { term in
            term.mappings.map {
                // Defense in depth for priors learned before the guard existed
                // (the migration below persists the same cleanup): a common
                // original never gets a positive prior.
                let guarded = refusesLearning(originalWord: $0.originalWord)
                return OverrideEntry(originalWord: $0.originalWord, term: $0.term,
                                     net: guarded ? min($0.net, 0) : $0.net, paused: $0.pairPaused)
            }
        }
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

    /// Owner confirmed a correction `(originalWord → term)`. Raises the
    /// mapping's net — the ask ranking prior; it never makes the gate apply.
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

    /// Move the mapping's net by `delta` (a transcript's contribution to the ask
    /// ranking prior; reversible — undo passes the opposite delta). A single transcript
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
        }
        persist()
        return true
    }

    /// **One-time migration (A3).** Drop every positive prior whose original the
    /// learning guard calls common: confirmations are cleared, reverts / keeps /
    /// corrections are kept, and a mapping left with nothing is
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
                guard refusesLearning(originalWord: m.originalWord), m.confirmations > 0 else {
                    kept.append(m)
                    continue
                }
                changed += 1
                m.confirmations = 0
                if !m.isEmpty {
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

    /// Owner reverted a correction `(originalWord → term)`. Raises reverts (the
    /// ask ranking prior).
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

    // MARK: - Learn from corrections

    /// Record one explicit correction signal for `(originalWord → term)` —
    /// called only by `VocabularyLearning.apply`, the one path every surface
    /// uses. NOT guarded by the learning guard: common originals ("cloud")
    /// count here. Nothing it records auto-applies.
    ///   - toward: `editsToward += 1`; the pair becomes active (last explicit
    ///     signal wins); `heardByModel` marks a real mishearing (D11).
    ///   - away: `editsAway += 1`; the pair pauses — the gate blocks it and the
    ///     decoder no longer gets it.
    ///   - recasesTerm: the term's stored casing follows `term` — only when the
    ///     user typed it (a proposal's casing may be a sentence start).
    @discardableResult
    public func recordEdit(originalWord: String, term: String, direction: EditDirection,
                           heardByModel: Bool = false, recasesTerm: Bool = false) -> EditRecord {
        loadIfNeeded()
        let ow = normalize(originalWord)
        let before = mapping(ow, term)
        let previousCasing = recasesTerm ? recaseInPlace(term: term) : nil
        mutate(originalWord: originalWord, term: term) { m in
            switch direction {
            case .toward:
                m.editsToward += 1
                m.pairPaused = false
                if heardByModel { m.editHeard = true }
            case .away:
                m.editsAway += 1
                m.pairPaused = true
            }
        }
        persist()
        return EditRecord(
            originalWord: ow, term: term, before: before, after: mapping(ow, term),
            towardDelta: direction == .toward ? 1 : 0, awayDelta: direction == .away ? 1 : 0,
            previousCasing: previousCasing)
    }

    /// The user deleted `originalWord` as a sounds-like of `term`: drop what the
    /// corrections taught about the pair — counters and pair state. Answers to
    /// gate proposals (confirmations / reverts / keeps: the ask prior and
    /// suppression) are a separate mechanism and stay (review #10). nil when
    /// there was nothing.
    @discardableResult
    public func forgetEdits(originalWord: String, term: String) -> EditRecord? {
        loadIfNeeded()
        let key = term.lowercased()
        let ow = normalize(originalWord)
        guard var t = terms[key], let i = t.mappings.firstIndex(where: { $0.originalWord == ow })
        else { return nil }
        let before = t.mappings[i]
        var m = before
        m.editsToward = 0
        m.editsAway = 0
        m.editHeard = false
        m.pairPaused = false
        let after: Mapping? = m.isEmpty ? nil : m
        if let after { t.mappings[i] = after } else { t.mappings.remove(at: i) }
        put(t, key: key)
        persist()
        return EditRecord(
            originalWord: ow, term: before.term, before: before, after: after,
            towardDelta: -before.editsToward, awayDelta: -before.editsAway)
    }

    /// Reverse exactly one `recordEdit` / `forgetEdits` write (an Undo in the
    /// review list). Counters move back by the write's deltas, floored at 0, so
    /// signals other surfaces recorded since are kept; a flag goes back to its
    /// value before the write only when it still holds what the write left
    /// (compare-and-restore). A mapping the write created and nothing else
    /// touched since is removed; a missing mapping is never re-created empty.
    public func undo(_ record: EditRecord) {
        loadIfNeeded()
        let key = record.term.lowercased()
        let prior = record.before ?? Mapping(originalWord: record.originalWord, term: record.term)
        let left = record.after ?? Mapping(originalWord: record.originalWord, term: record.term)
        if var t = terms[key], let i = t.mappings.firstIndex(where: { $0.originalWord == record.originalWord }) {
            var m = t.mappings[i]
            m.editsToward = max(0, m.editsToward - record.towardDelta)
            m.editsAway = max(0, m.editsAway - record.awayDelta)
            if m.editHeard == left.editHeard { m.editHeard = prior.editHeard }
            if m.pairPaused == left.pairPaused { m.pairPaused = prior.pairPaused }
            if record.before == nil, m.isEmpty {
                t.mappings.remove(at: i)
            } else {
                t.mappings[i] = m
            }
            put(t, key: key)
        } else if let before = record.before, record.after == nil {
            // A forget that removed the mapping: put it back.
            var t = terms[key] ?? Term()
            t.mappings.append(before)
            terms[key] = t
        }
        if let casing = record.previousCasing { _ = recaseInPlace(term: casing) }
        persist()
    }

    /// Store `t`, dropping it when nothing is left in it — an undo or forget
    /// never leaves an empty entry behind.
    private func put(_ t: Term, key: String) {
        if t.mappings.isEmpty, t.suppressedBlocks.isEmpty, (t.mergeAskedPhrases ?? []).isEmpty {
            terms.removeValue(forKey: key)
        } else {
            terms[key] = t
        }
    }

    private func mapping(_ normalizedOriginal: String, _ term: String) -> Mapping? {
        terms[term.lowercased()]?.mappings.first { $0.originalWord == normalizedOriginal }
    }

    /// Decoder pair state: `"<original>|<term>"` keys (`CorrectionKey.pairKey`)
    /// of every paused pair. The decoder's pairs themselves come from the
    /// vocabulary list (`DecoderVocabulary`); this only switches some off.
    public func pausedPairKeys() -> Set<String> {
        loadIfNeeded()
        var out: Set<String> = []
        for (termKey, term) in terms {
            for m in term.mappings where m.pairPaused {
                out.insert(CorrectionKey.pairKey(originalWord: m.originalWord, term: termKey))
            }
        }
        return out
    }

    /// Pairs learned from transcript edits before the list became the only
    /// source of decoder pairs (Revision 2 review #1): model-heard, with more
    /// edits toward the term than away. For the one-time migration that writes
    /// them into the list as sounds-likes. nil when the ledger could not be
    /// read, so the caller retries instead of marking the migration done.
    public func editLearnedPairs() -> [(original: String, term: String)]? {
        loadIfNeeded()
        guard !loadFailed, !loadUnreadable else { return nil }
        return terms.values
            .flatMap { $0.mappings }
            .filter { $0.editHeard && $0.editsFavorTerm }
            .map { (original: $0.originalWord, term: $0.term) }
            .sorted { ($0.term.lowercased(), $0.original) < ($1.term.lowercased(), $1.original) }
    }

    /// Re-case every stored mapping of `term` to the user's casing (D10). The
    /// store keys terms lowercased, so this only rewrites the display casing.
    /// Returns the previous casing when it changed.
    @discardableResult
    public func recase(term: String) -> String? {
        loadIfNeeded()
        let previous = recaseInPlace(term: term)
        if previous != nil { persist() }
        return previous
    }

    /// Stored term entries, empty ones included (tests).
    func termEntryCount() -> Int {
        loadIfNeeded()
        return terms.count
    }

    /// Every stored mapping (tests).
    func allMappings() -> [Mapping] {
        loadIfNeeded()
        return terms.values.flatMap(\.mappings)
    }

    private func recaseInPlace(term: String) -> String? {
        let key = term.lowercased()
        guard var t = terms[key], let old = t.mappings.first(where: { $0.term != term })?.term
        else { return nil }
        for i in t.mappings.indices { t.mappings[i].term = term }
        terms[key] = t
        return old
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
