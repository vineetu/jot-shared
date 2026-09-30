import Foundation

/// **Per-transcript correction provenance + per-occurrence resolution store.**
/// Stores the gate's full proposal list for each saved transcript (so the
/// transcript pane can show "here's what Jot corrected / considered") AND the
/// owner's per-occurrence verdicts (so an answered occurrence never re-asks).
///
/// Two stores, deliberately separate (plan §v2-C):
///   - **proposals (`records`)** — what the gate did, per OCCURRENCE. Each record
///     carries a STABLE identity (`originalStart`, the span's offset in the
///     original pre-rescore text) plus a LIVE anchor (`publishedStart`) into the
///     current transcript text, maintained by `reconciledPayload`/`noteSelfEdit`.
///   - **verdicts** — the owner's `term | original` pick per occurrence, keyed by
///     that stable identity. A verdict HIDES the row (resolved) and drives the
///     this-occurrence text edit. It is the ONLY thing that decides "answered."
///   - **mappingsTaught** — guard so a mapping (`original→term`) feeds the
///     MAPPING-level learning store (`CorrectionStore`) at most once per
///     transcript, regardless of how many occurrences the owner adjudicates.
///     Prevents three "name→Jamy" picks from inflating net to 3.
///
/// Timing (the gate runs BEFORE the transcript id exists): the gate fills a
/// transient `pending` slot at rescore time; `commit(transcriptID:)` moves it to
/// a side-JSON keyed by the real id once the transcript is saved. Dictation is
/// serial → the single pending slot is safe.
///
/// Storage: `<containerRoot>/Vocabulary/provenance/<transcriptID>.json`. The
/// root is injected (nil ⇒ in-memory, no persistence — the test mode).
public actor CorrectionProvenance {

    /// One gated occurrence. `originalStart`/`originalLength` are the stable
    /// identity (offset in the ORIGINAL text); `publishedStart` is a LIVE anchor
    /// into the CURRENT transcript text, kept valid by `reconciledPayload` across
    /// every edit — verdict edits AND hand-edits alike (see `anchoredText`).
    public struct Record: Codable, Sendable, Equatable {
        public let originalWord: String     // what TDT wrote ("Jamie")
        public let term: String             // the vocab term ("Jamy")
        public let decision: String         // "APPLY" | "BLOCK" ("OVERRIDE" only in old records)
        public let outcome: String          // "applied" | "kept"
        public let confidence: Float
        public let margin: Float
        public let unsure: Bool
        public let occurrenceIndex: Int     // display-only
        public let originalStart: Int
        public let originalLength: Int
        public var publishedStart: Int      // LIVE anchor — mutated only by reconcile
        public let publishedLength: Int     // gate-time span length (display/diag only)
        /// Alternate candidate terms for this span (3-option ask, 2026-07-13).
        /// Optional so payloads persisted BEFORE this field existed decode as
        /// nil — treat nil and [] identically.
        public var alternates: [VocabularyGate.Alternate]?
        /// V2-3: structural shape ("merge" = split-word class). Optional for
        /// back-compat with payloads persisted before the field existed.
        public var shape: String?
        /// `VocabularyGate.Proposal.evidence` ("acoustic" / "textual" /
        /// "decodeBias"); nil on records written before evidence typing.
        /// Optional so every existing payload decodes unchanged.
        public var evidence: String?
        /// The evidence's own score (`VocabularyGate.Proposal.score`).
        public var score: Float?

        public init(originalWord: String, term: String, decision: String, outcome: String,
                    confidence: Float, margin: Float, unsure: Bool, occurrenceIndex: Int,
                    originalStart: Int, originalLength: Int, publishedStart: Int,
                    publishedLength: Int, alternates: [VocabularyGate.Alternate]? = nil,
                    shape: String? = nil, evidence: String? = nil, score: Float? = nil) {
            self.originalWord = originalWord
            self.term = term
            self.decision = decision
            self.outcome = outcome
            self.confidence = confidence
            self.margin = margin
            self.unsure = unsure
            self.occurrenceIndex = occurrenceIndex
            self.originalStart = originalStart
            self.originalLength = originalLength
            self.publishedStart = publishedStart
            self.publishedLength = publishedLength
            self.alternates = alternates
            self.shape = shape
            self.evidence = evidence
            self.score = score
        }

        /// Stable per-occurrence identity key (verdict + mark lookup).
        public var key: String { "\(originalWord.lowercased())|\(term.lowercased())|\(originalStart)" }
        /// Mapping key (shared by every occurrence of the same original→term).
        /// V2-2: uses the ONE shared normalization (`CorrectionKey`) so the
        /// contributions ledger, CorrectionStore nets, and the ask policy's
        /// prior lookups can never disagree about pair identity. (`key` above
        /// stays raw-lowercased — it's a per-occurrence identity within one
        /// payload, where raw and normalized are equally unique.)
        public var mappingKey: String { "\(CorrectionKey.normalize(originalWord))|\(CorrectionKey.normalize(term))" }
        /// Pre-V2-2 mapping key shape — read-side fallback only, so old
        /// persisted contribution entries keep reconciling.
        public var legacyMappingKey: String { "\(originalWord.lowercased())|\(term.lowercased())" }
    }

    /// On-disk shape: proposals + per-occurrence verdicts + this transcript's
    /// current contribution to each mapping's learning net (+1/−1, reversible).
    public struct Payload: Codable, Sendable {
        public var records: [Record] = []
        public var verdicts: [String: String] = [:]      // record.key → "term" | "original"
        public var contributions: [String: Int] = [:]    // record.mappingKey → this transcript's net contribution
        /// The transcript text the records' `publishedStart` anchors are valid
        /// for. `reconciledPayload` diffs this against the live text and shifts
        /// anchors, so an edit made ANYWHERE (verdict pick, hand-edit in the
        /// detail TextEditor, keyboard-verdict drain) is accounted exactly once —
        /// the reconcile is state-based (fingerprint), not event-based. nil on
        /// payloads written before this field existed (adopted on first read).
        public var anchoredText: String?
        /// Record keys whose verdict was set by a transcript EDIT (learn from
        /// edits), not a pick — so an Undo in the pane can also retract the
        /// edit's count. nil on payloads written before this field existed.
        public var editClosedKeys: [String]?
        /// record.key → verdict → what that verdict's `VocabularyLearning.apply`
        /// did, so the pane's Undo reverses exactly that (Revision 2 review #5).
        /// Kept per verdict: switching "term" → "original" keeps the term
        /// pick's receipt for the Undo too. nil on payloads written before this
        /// field existed.
        public var receipts: [String: [String: VocabularyLearning.Receipt]]?

        public init(records: [Record] = [], verdicts: [String: String] = [:],
                    contributions: [String: Int] = [:], anchoredText: String? = nil,
                    editClosedKeys: [String]? = nil,
                    receipts: [String: [String: VocabularyLearning.Receipt]]? = nil) {
            self.records = records
            self.verdicts = verdicts
            self.contributions = contributions
            self.anchoredText = anchoredText
            self.editClosedKeys = editClosedKeys
            self.receipts = receipts
        }

        private enum CodingKeys: String, CodingKey {
            case records, verdicts, contributions, anchoredText, editClosedKeys, receipts
        }

        // Hand-written so a payload missing newer keys (or holding a receipt
        // shape this build can't read) still loads: a throw here would drop the
        // whole transcript's review records.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            records = try c.decodeIfPresent([Record].self, forKey: .records) ?? []
            verdicts = try c.decodeIfPresent([String: String].self, forKey: .verdicts) ?? [:]
            contributions = try c.decodeIfPresent([String: Int].self, forKey: .contributions) ?? [:]
            anchoredText = try c.decodeIfPresent(String.self, forKey: .anchoredText)
            editClosedKeys = try c.decodeIfPresent([String].self, forKey: .editClosedKeys)
            receipts = try? c.decodeIfPresent(
                [String: [String: VocabularyLearning.Receipt]].self, forKey: .receipts)
        }

        public func isEditClosed(_ record: Record) -> Bool {
            editClosedKeys?.contains(record.key) ?? false
        }

        /// verdict → receipt, for `record`.
        public func receipts(for record: Record) -> [String: VocabularyLearning.Receipt] {
            receipts?[record.key] ?? [:]
        }

        /// The still-unanswered records of the `originalWord → term` pair, in
        /// document order — what a surface answering that pair (the live ask,
        /// a transcript edit) marks.
        public func openRecords(originalWord: String, term: String) -> [Record] {
            let ow = CorrectionKey.normalize(originalWord)
            return records.filter {
                verdicts[$0.key] == nil
                    && CorrectionKey.normalize($0.originalWord) == ow
                    && $0.term.lowercased() == term.lowercased()
            }
        }
    }

    /// What a verdict change does to a mapping's global learning net. The caller
    /// applies it to `CorrectionStore.adjust`. `delta == 0` ⇒ nothing to do.
    public struct MappingDelta: Sendable, Equatable {
        public let originalWord: String
        public let term: String
        public let delta: Int

        public init(originalWord: String, term: String, delta: Int) {
            self.originalWord = originalWord
            self.term = term
            self.delta = delta
        }
    }

    private let containerRoot: URL?
    private let diagnostics: DiagnosticsSink
    private var pending: [Record] = []
    /// The gate-output text `pending`'s `publishedStart` offsets index into —
    /// the ONLY text those offsets are valid for. Becomes the payload's
    /// `anchoredText` baseline at commit; the post-gate transform chain
    /// (segmenter / filler sweep / number normalizer / AI cleanup) changes the
    /// text BEFORE it's saved, and the first `reconciledPayload` absorbs that
    /// drift exactly by diffing from this baseline.
    private var pendingAnchorText: String = ""

    /// - Parameters:
    ///   - containerRoot: directory the `Vocabulary/provenance/` subtree lives
    ///     under. `nil` ⇒ purely in-memory (no persistence) — the test mode.
    ///   - diagnostics: sink for commit trace (design seam 3).
    public init(containerRoot: URL?, diagnostics: DiagnosticsSink = NoopDiagnosticsSink()) {
        self.containerRoot = containerRoot
        self.diagnostics = diagnostics
    }

    // MARK: - Gate side (write)

    /// Called at rescore time (no transcript id yet) — stashes this dictation's
    /// proposals until the transcript is saved. `gatedText` is the gate's output
    /// text, i.e. the string the proposals' `publishedStart` offsets point into.
    public func record(_ proposals: [VocabularyGate.Proposal], gatedText: String) {
        pendingAnchorText = gatedText
        pending = proposals.map {
            Record(
                originalWord: $0.originalWord, term: $0.term, decision: $0.decision,
                outcome: $0.outcome, confidence: $0.confidence, margin: $0.margin,
                unsure: $0.unsure, occurrenceIndex: $0.occurrenceIndex,
                originalStart: $0.originalStart, originalLength: $0.originalLength,
                publishedStart: $0.publishedStart, publishedLength: $0.publishedLength,
                alternates: $0.alternates.isEmpty ? nil : $0.alternates,
                shape: $0.shape, evidence: $0.evidence, score: $0.score)
        }
    }

    /// Clears the pending slot. Called at the START of every transcription so a
    /// no-proposal dictation — or a non-saving caller (Ask/watch/file-import) that
    /// filled the slot — can never have a stale `pending` committed under the next
    /// transcript's id.
    public func clearPending() {
        pending = []
        pendingAnchorText = ""
    }

    /// Persist the pending records under the saved transcript id (fresh verdicts).
    /// The anchor baseline is the GATE-OUTPUT text captured by `record(_:gatedText:)`
    /// — the one string the records' `publishedStart` offsets are actually valid
    /// for. (NOT the published/saved text: post-gate transforms already shifted
    /// that; seeding it would bake the drift in as "valid".)
    ///
    /// A surface that answers this transcript's records (the live ask) waits
    /// for this commit and then marks them by id with `setVerdict` — verdicts
    /// travel with the transcript id, never with "the last commit".
    public func commit(transcriptID: UUID) {
        let records = pending
        let anchorText = pendingAnchorText
        pending = []
        pendingAnchorText = ""
        guard !records.isEmpty, let url = fileURL(transcriptID) else {
            return
        }
        // Commit is once-per-fresh-id, but be defensive: if a payload already
        // exists for this id (a re-commit / retry), PRESERVE the owner's verdicts
        // and the mapping-taught guard — only the records are (re)written. A blind
        // overwrite would silently wipe answered rows.
        let existing = payload(transcriptID: transcriptID)
        let payload = Payload(
            records: records, verdicts: existing.verdicts,
            contributions: existing.contributions, anchoredText: anchorText,
            editClosedKeys: existing.editClosedKeys, receipts: existing.receipts)
        var wrote = false
        if let data = try? JSONEncoder().encode(payload) {
            do { try data.write(to: url, options: .atomic); wrote = true } catch {}
        }
        diagnostics.record(
            category: .vocabularyGate, message: "provenance committed",
            metadata: ["records": "\(records.count)", "wrote": "\(wrote)", "id": transcriptID.uuidString])
    }

    /// Re-transcription of a saved transcript: its old review records described
    /// text that no longer exists, so they must not reattach to the new text.
    /// Every standing verdict is cleared the way an Undo clears it (its mapping
    /// contribution reversed through the same ±1 clamp), then the pending
    /// records (this re-run's gate proposals) replace the old ones with fresh
    /// verdicts. No pending records ⇒ the payload is removed. Returns the
    /// deltas the caller applies to `CorrectionStore` to take back what the old
    /// verdicts taught. One actor turn, so no other transcription can take the
    /// pending slot in between.
    public func replaceRecords(transcriptID: UUID) -> [MappingDelta] {
        let records = pending
        let anchorText = pendingAnchorText
        pending = []
        pendingAnchorText = ""
        var old = payload(transcriptID: transcriptID)
        var deltas: [MappingDelta] = []
        for record in old.records where old.verdicts[record.key] != nil {
            old.verdicts.removeValue(forKey: record.key)
            deltas += reconcileContributions(&old, record: record)
        }
        guard !records.isEmpty else {
            discard(transcriptID: transcriptID)
            return deltas
        }
        persist(transcriptID: transcriptID, Payload(records: records, anchoredText: anchorText))
        diagnostics.record(
            category: .vocabularyGate, message: "provenance replaced",
            metadata: ["records": "\(records.count)", "reversed": "\(deltas.count)", "id": transcriptID.uuidString])
        return deltas
    }

    // MARK: - Pane side (read + verdict)

    /// Full payload for a transcript (proposals + verdicts).
    public func payload(transcriptID: UUID) -> Payload {
        guard
            let url = fileURL(transcriptID),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload() }
        return decoded
    }

    /// Payload with every record's `publishedStart` anchor reconciled to
    /// `currentText`. THE anchor-maintenance entry point — every reader that
    /// will resolve spans (the review model's `reload()`) goes through here.
    ///
    /// State-based, not event-based: the payload remembers the text its anchors
    /// are valid for (`anchoredText`); if the live text differs, the single
    /// contiguous changed region between the two is computed and every anchor
    /// at/after the region's end shifts by the length delta. This accounts for
    /// ANY edit — a verdict pick, a hand-edit in the detail TextEditor, a
    /// keyboard-verdict drain — exactly once, no matter which model instance
    /// made it or whether this one observed it happen. An anchor INSIDE the
    /// changed region keeps its offset and is left to strict span resolution:
    /// if the word still starts there it resolves; if the user edited it away,
    /// resolution fails and the surfaces fail SAFE (no mark, no text edit).
    public func reconciledPayload(transcriptID: UUID, currentText: String) -> Payload {
        var p = payload(transcriptID: transcriptID)
        guard !p.records.isEmpty else { return p }
        guard let anchored = p.anchoredText else {
            // Legacy payload (written before anchoredText existed): adopt the
            // live text as the baseline WITHOUT shifting — anchors are as good
            // as they ever were; strict resolution backstops any prior drift.
            p.anchoredText = currentText
            persist(transcriptID: transcriptID, p)
            return p
        }
        guard anchored != currentText else { return p }
        let mapped = Self.mapOffsets(p.records.map(\.publishedStart), old: anchored, new: currentText)
        for i in p.records.indices {
            p.records[i].publishedStart = mapped[i]
        }
        p.anchoredText = currentText
        persist(transcriptID: transcriptID, p)
        return p
    }

    /// Records mapped into `text` WITHOUT persisting — for a one-off read
    /// against a text that is NOT the transcript's stored text. The keyboard
    /// asks publisher slices `publishedText`, which with AI cleanup ON differs
    /// from the saved raw text; persisting that hop would route the durable
    /// anchor chain through the cleaned text and permanently strand any record
    /// whose word the cleanup rewrote away (re-review finding). The durable
    /// chain stays gate-output → transcript.text, owned by `reconciledPayload`.
    public func mappedPayload(transcriptID: UUID, into text: String) -> Payload {
        var p = payload(transcriptID: transcriptID)
        guard !p.records.isEmpty, let anchored = p.anchoredText, anchored != text else { return p }
        let mapped = Self.mapOffsets(p.records.map(\.publishedStart), old: anchored, new: text)
        for i in p.records.indices {
            p.records[i].publishedStart = mapped[i]
        }
        return p   // NOT persisted — anchoredText keeps the durable baseline
    }

    /// Account EXACTLY for one of OUR OWN verdict edits (a pick/undo replacing
    /// record `recordKey`'s span at Character offset `start`: oldLength →
    /// newLength chars, producing `newText`). A text diff cannot do this safely:
    /// when the replacement shares a suffix with the replaced word ("nathan" →
    /// "Ramanathan") the diff is genuinely ambiguous and can shift the edited
    /// record's own anchor off its word, breaking Undo. Self edits therefore
    /// REPORT their span; the blind diff in `reconciledPayload` is only for
    /// EXTERNAL edits (hand-edits), where strict span resolution backstops it.
    ///
    /// Race-tolerant against the detail view's onChange-triggered reconcile: if
    /// that reconcile already absorbed this edit (anchoredText == newText), the
    /// bulk shift has been applied by the diff and only the self record — the
    /// one span the diff can get wrong — is pinned. Otherwise the exact shift
    /// is applied and the fingerprint advanced (so the racing reconcile no-ops).
    public func noteSelfEdit(
        transcriptID: UUID, recordKey: String,
        start: Int, oldLength: Int, newLength: Int, newText: String
    ) {
        var p = payload(transcriptID: transcriptID)
        guard !p.records.isEmpty else { return }
        if p.anchoredText == newText {
            for i in p.records.indices where p.records[i].key == recordKey {
                p.records[i].publishedStart = start
            }
        } else {
            let delta = newLength - oldLength
            for i in p.records.indices {
                if p.records[i].key == recordKey {
                    p.records[i].publishedStart = start
                } else if p.records[i].publishedStart >= start + oldLength {
                    p.records[i].publishedStart += delta
                }
            }
            p.anchoredText = newText
        }
        persist(transcriptID: transcriptID, p)
    }

    /// Exact old→new Character-offset mapping via a real collection diff —
    /// handles MULTI-region changes (the post-gate segmenter / filler / number
    /// transform chain makes several small edits in one hop; an AI-cleanup or
    /// hand-edit Save can too), which a single prefix/suffix region cannot.
    /// An offset inside a removed region maps to the removal point and relies
    /// on the caller's strict whole-word resolution to fail safe.
    public static func mapOffsets(_ offsets: [Int], old: String, new: String) -> [Int] {
        let diff = Array(new).difference(from: Array(old))
        var removals: [Int] = []     // OLD-space indices
        var insertions: [Int] = []   // NEW-space indices
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removals.append(offset)
            case .insert(let offset, _, _): insertions.append(offset)
            }
        }
        removals.sort()
        insertions.sort()
        return offsets.map { anchor in
            var pos = anchor - removals.prefix(while: { $0 < anchor }).count
            for ins in insertions {
                if ins <= pos { pos += 1 } else { break }
            }
            return max(0, pos)
        }
    }

    /// Record a per-occurrence verdict and return how the mapping's global net
    /// should move (caller applies them to `CorrectionStore`). `verdict` ∈
    /// {"term","original","alt0"}. A transcript contributes at most ±1 per
    /// mapping (recomputed from ALL its verdicts), so three "name→Jamy" picks
    /// can't inflate net to 3, a mixed transcript (some term, some revert)
    /// gives 0 — and an "alt0" pick moves the ALTERNATE's mapping through the
    /// same clamp (V2-2; may return one delta per affected mapping, e.g. a
    /// switch from "term" to "alt0" moves two).
    ///
    /// `fromEdit` marks a verdict set by a transcript edit (learn from edits).
    /// `receipt` is what the verdict's `VocabularyLearning.apply` did, kept
    /// under this verdict for the pane's Undo (nil keeps what is there).
    public func setVerdict(transcriptID: UUID, record: Record, verdict: String,
                           fromEdit: Bool = false,
                           receipt: VocabularyLearning.Receipt? = nil) -> [MappingDelta] {
        var p = payload(transcriptID: transcriptID)
        p.verdicts[record.key] = verdict
        var closed = (p.editClosedKeys ?? []).filter { $0 != record.key }
        if fromEdit { closed.append(record.key) }
        p.editClosedKeys = closed.isEmpty ? nil : closed
        setReceipt(&p, receipt, for: record)
        return finalize(&p, transcriptID: transcriptID, record: record)
    }

    private func setReceipt(_ p: inout Payload, _ receipt: VocabularyLearning.Receipt?, for record: Record) {
        guard let receipt else { return }
        var receipts = p.receipts ?? [:]
        receipts[record.key, default: [:]][verdictKey(p, record)] = receipt
        p.receipts = receipts
    }

    private func verdictKey(_ p: Payload, _ record: Record) -> String {
        p.verdicts[record.key] ?? ""
    }

    /// Hand `receipt` (a verdict's learning) to `record`, a sibling occurrence
    /// that still holds `verdict` — an Undo of one occurrence must not reverse
    /// the pair while another still says so.
    public func attachReceipt(_ receipt: VocabularyLearning.Receipt, verdict: String,
                              transcriptID: UUID, record: Record) {
        var p = payload(transcriptID: transcriptID)
        var receipts = p.receipts ?? [:]
        receipts[record.key, default: [:]][verdict] = receipt
        p.receipts = receipts
        persist(transcriptID: transcriptID, p)
    }

    /// Undo a verdict — clears the pick (row re-surfaces) and reverses this
    /// transcript's mapping contribution if no sibling verdict still supports it.
    public func clearVerdict(transcriptID: UUID, record: Record) -> [MappingDelta] {
        var p = payload(transcriptID: transcriptID)
        p.verdicts.removeValue(forKey: record.key)
        let closed = (p.editClosedKeys ?? []).filter { $0 != record.key }
        p.editClosedKeys = closed.isEmpty ? nil : closed
        p.receipts?.removeValue(forKey: record.key)
        if p.receipts?.isEmpty == true { p.receipts = nil }
        return finalize(&p, transcriptID: transcriptID, record: record)
    }

    /// Recompute this transcript's contribution to `record`'s mapping from its
    /// CURRENT verdicts, store it, and return the delta vs the stored value.
    private func finalize(_ p: inout Payload, transcriptID: UUID, record: Record) -> [MappingDelta] {
        let deltas = reconcileContributions(&p, record: record)
        persist(transcriptID: transcriptID, p)
        return deltas
    }

    /// `finalize` without the write: bring `p.contributions` for every mapping
    /// `record` can affect in line with the current verdicts.
    private func reconcileContributions(_ p: inout Payload, record: Record) -> [MappingDelta] {
        // V2-2 selected-mapping ledger: one verdict can move EITHER the base
        // mapping (term/original picks) OR an alternate mapping ("alt0" picks
        // in the 3-option ask). Reconcile every mapping this record can
        // affect through the same ±1-per-transcript contribution clamp —
        // this replaces the old direct CorrectionStore.adjust(±1) for alt
        // picks, which bypassed the clamp (round-2 confirmed break).
        var targets: [(term: String, key: String, legacy: String?)] = [
            (record.term, record.mappingKey, record.legacyMappingKey)
        ]
        for alt in record.alternates ?? [] {
            let altKey = "\(CorrectionKey.normalize(record.originalWord))|\(CorrectionKey.normalize(alt.term))"
            targets.append((alt.term, altKey, nil))
        }
        var deltas: [MappingDelta] = []
        for t in targets {
            // Legacy-key fallback (V2-2): a payload persisted before the
            // shared normalization may hold this mapping's contribution
            // under the old raw-lowercased key. Migrate in place so an
            // undo/re-pick can't double-count.
            if p.contributions[t.key] == nil, let lk = t.legacy, lk != t.key,
               let legacy = p.contributions[lk] {
                p.contributions[t.key] = legacy
                p.contributions[lk] = nil
            }
            let desired = desiredContribution(p, mappingKey: t.key)
            let old = p.contributions[t.key] ?? 0
            if desired == 0 { p.contributions[t.key] = nil } else { p.contributions[t.key] = desired }
            let delta = desired - old
            if delta != 0 {
                deltas.append(MappingDelta(originalWord: record.originalWord, term: t.term, delta: delta))
            }
        }
        return deltas
    }

    /// +1 if the owner meant the term for this mapping (any "term" pick — or
    /// an "alt0" pick whose alternate IS this mapping — with no revert),
    /// −1 if they reverted an applied one (any revert, no "term"), 0 if mixed or
    /// only "kept-original" (no learning signal).
    private func desiredContribution(_ p: Payload, mappingKey: String) -> Int {
        var anyTerm = false
        var anyDemote = false
        for occ in p.records {
            let v = p.verdicts[occ.key]
            if occ.mappingKey == mappingKey {
                if v == "term" { anyTerm = true }
                if v == "original", occ.outcome == "applied" { anyDemote = true }
            }
            if v == "alt0", let alt = occ.alternates?.first {
                let altKey = "\(CorrectionKey.normalize(occ.originalWord))|\(CorrectionKey.normalize(alt.term))"
                if altKey == mappingKey { anyTerm = true }
            }
        }
        if anyTerm && !anyDemote { return 1 }
        if anyDemote && !anyTerm { return -1 }
        return 0
    }

    /// Drop a transcript's provenance (e.g. when the transcript is deleted).
    public func discard(transcriptID: UUID) {
        guard let url = fileURL(transcriptID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Storage

    private func persist(transcriptID: UUID, _ p: Payload) {
        guard let url = fileURL(transcriptID), let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func fileURL(_ id: UUID) -> URL? {
        guard let containerRoot else { return nil }
        let prov = containerRoot.appendingPathComponent("Vocabulary/provenance", isDirectory: true)
        try? FileManager.default.createDirectory(at: prov, withIntermediateDirectories: true)
        return prov.appendingPathComponent("\(id.uuidString).json")
    }
}
