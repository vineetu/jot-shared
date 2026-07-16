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
        public var net: Int { confirmations - reverts }

        public init(originalWord: String, term: String,
                    confirmations: Int = 0, reverts: Int = 0, blockedKeeps: Int = 0,
                    alwaysReplace: Bool = false) {
            self.originalWord = originalWord
            self.term = term
            self.confirmations = confirmations
            self.reverts = reverts
            self.blockedKeeps = blockedKeeps
            self.alwaysReplace = alwaysReplace
        }

        enum CodingKeys: String, CodingKey {
            case originalWord, term, confirmations, reverts, blockedKeeps, alwaysReplace
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
    private var terms: [String: Term] = [:]   // keyed by lowercased term
    private var loaded = false
    /// Set when `loadIfNeeded` found a file that EXISTS but failed to decode.
    /// While true, `persist()` is a hard no-op — the store must never overwrite
    /// a curated ledger it could not read (Q-3, real data-loss guard). Distinct
    /// from file-absent/empty, which is safe to start empty and persist.
    private var loadFailed = false

    /// - Parameters:
    ///   - containerRoot: directory the `Vocabulary/` subtree lives under. `nil`
    ///     ⇒ purely in-memory (no load, no persist) — the test / no-persist mode.
    ///   - diagnostics: sink for the decode-failure guard (design seam 3).
    public init(containerRoot: URL?, diagnostics: DiagnosticsSink = NoopDiagnosticsSink()) {
        self.containerRoot = containerRoot
        self.diagnostics = diagnostics
    }

    // MARK: - Reads (for the gate + pane)

    /// All confirmed mappings as override entries. Fetched once per dictation,
    /// before rescore, and passed into `VocabularyGate.apply`.
    public func snapshot() -> [OverrideEntry] {
        loadIfNeeded()
        return terms.values.flatMap { term in
            term.mappings.map {
                OverrideEntry(originalWord: $0.originalWord, term: $0.term,
                              net: $0.net, alwaysReplace: $0.alwaysReplace)
            }
        }
    }

    /// V2-4: grant "always replace originalWord with term" — the explicit
    /// user consent that lets the gate auto-apply a common-word pair. Ends
    /// the forever-ask treadmill for a pair the owner has confirmed twice.
    public func grantAlwaysReplace(originalWord: String, term: String) {
        loadIfNeeded()
        mutate(originalWord: originalWord, term: term) { $0.alwaysReplace = true }
        persist()
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
    public func confirm(originalWord: String, term: String) {
        loadIfNeeded()
        mutate(originalWord: originalWord, term: term) { $0.confirmations += 1 }
        persist()
    }

    /// Move the mapping's net by `delta` (a transcript's contribution to learning;
    /// reversible — undo passes the opposite delta). `delta > 0` reinforces (gate
    /// auto-applies once net ≥ 1, rare originals only); `delta < 0` demotes (gate
    /// STOPS auto-applying at net ≤ −1, common AND rare). A single transcript
    /// contributes at most ±1 per mapping (computed in `CorrectionProvenance`), so
    /// reviewing three "name→Jamy" occurrences can't inflate net to 3.
    public func adjust(originalWord: String, term: String, by delta: Int) {
        guard delta != 0 else { return }
        loadIfNeeded()
        mutate(originalWord: originalWord, term: term) {
            if delta > 0 { $0.confirmations += delta } else { $0.reverts += -delta }
            // V2-4: one revert revokes an "always replace" grant — the user
            // changed their mind, the pair goes back to asking.
            if delta < 0 { $0.alwaysReplace = false }
        }
        persist()
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
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
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
