import Foundation

/// **One correction, one path** (design `docs/vocabulary-learn-from-edits/
/// design.md`, Revision 2). A correction is one thing — "when I say X, write
/// Y" — stored once, visibly, as a sounds-like on the term in the vocabulary
/// list. Every surface (transcript edit, Add to Vocabulary, review list, live
/// ask, Settings) describes what the user did as a `Correction` and hands it
/// to `VocabularyLearning.apply`. No surface writes the list's sounds-likes or
/// the store's learning counters itself.
///
/// Codable (hand-written, absent keys default) so a process that can't write
/// the app's vocabulary (the iPhone keyboard) can queue one for the app, and a
/// queue written by an older build still decodes.
public enum Correction: Sendable, Equatable {
    /// "When I say `heard`, write `term`." The term is added if missing; when
    /// `heardByModel`, `heard` becomes a sounds-like of it and the decoder pair
    /// is active. `heardByModel` false = AI cleanup wrote the word, the model
    /// didn't mishear (D11): term only, no sounds-like.
    ///   - userCasing: the user typed `term` (Edit → Done, Add to Vocabulary,
    ///     Settings), so its casing wins over the list's. A proposal's term
    ///     (live ask, review list) can be sentence-start capitalized ("EBay"):
    ///     it resolves to the list's own spelling and never re-cases.
    ///   - termID: the list row, when the surface has one (Settings); routes
    ///     by row instead of by text.
    /// Nothing learned auto-applies: the sounds-like feeds the decoder pair and
    /// the gate's plausibility test; the text itself only changes on evidence.
    case correct(heard: String, term: String, heardByModel: Bool = true,
                 userCasing: Bool = false, termID: UUID? = nil)
    /// Explicit "keep original" (a Keep tap, or editing the term back): the
    /// decoder pair pauses; the sounds-like stays in the list.
    case keepOriginal(heard: String, term: String)
    /// Exact inverse of the `apply` that returned `receipt`.
    case undo(VocabularyLearning.Receipt)
    /// `heard` (exactly as listed) deleted as a sounds-like of `term`.
    case forget(heard: String, term: String, termID: UUID? = nil)
    /// Plain add; the user's casing wins over an existing term's.
    case addTerm(String)
    /// Case-only fix of an existing term (D10).
    case recase(String)
}

extension Correction: Codable {
    private enum Kind: String, Codable { case correct, keepOriginal, undo, forget, addTerm, recase }

    private enum CodingKeys: String, CodingKey {
        case kind, heard, term, heardByModel, userCasing, termID, receipt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let term = try c.decodeIfPresent(String.self, forKey: .term) ?? ""
        let heard = try c.decodeIfPresent(String.self, forKey: .heard) ?? ""
        switch try c.decode(Kind.self, forKey: .kind) {
        case .correct:
            self = .correct(
                heard: heard, term: term,
                heardByModel: try c.decodeIfPresent(Bool.self, forKey: .heardByModel) ?? true,
                userCasing: try c.decodeIfPresent(Bool.self, forKey: .userCasing) ?? false,
                termID: try c.decodeIfPresent(UUID.self, forKey: .termID))
        case .keepOriginal:
            self = .keepOriginal(heard: heard, term: term)
        case .undo:
            self = .undo(try c.decode(VocabularyLearning.Receipt.self, forKey: .receipt))
        case .forget:
            self = .forget(heard: heard, term: term, termID: try c.decodeIfPresent(UUID.self, forKey: .termID))
        case .addTerm:
            self = .addTerm(term)
        case .recase:
            self = .recase(term)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .correct(heard, term, heardByModel, userCasing, termID):
            try c.encode(Kind.correct, forKey: .kind)
            try c.encode(heard, forKey: .heard)
            try c.encode(term, forKey: .term)
            try c.encode(heardByModel, forKey: .heardByModel)
            try c.encode(userCasing, forKey: .userCasing)
            try c.encodeIfPresent(termID, forKey: .termID)
        case let .keepOriginal(heard, term):
            try c.encode(Kind.keepOriginal, forKey: .kind)
            try c.encode(heard, forKey: .heard)
            try c.encode(term, forKey: .term)
        case let .undo(receipt):
            try c.encode(Kind.undo, forKey: .kind)
            try c.encode(receipt, forKey: .receipt)
        case let .forget(heard, term, termID):
            try c.encode(Kind.forget, forKey: .kind)
            try c.encode(heard, forKey: .heard)
            try c.encode(term, forKey: .term)
            try c.encodeIfPresent(termID, forKey: .termID)
        case let .addTerm(term):
            try c.encode(Kind.addTerm, forKey: .kind)
            try c.encode(term, forKey: .term)
        case let .recase(term):
            try c.encode(Kind.recase, forKey: .kind)
            try c.encode(term, forKey: .term)
        }
    }
}

/// The seam onto each app's vocabulary list: plain row writes, by row id.
/// Matching, dedupe and casing rules live in `VocabularyLearning`, so every
/// platform gets the same behaviour. Synchronous and main-actor, so `apply`
/// writes the list before its first suspension and two applies can never
/// interleave their list writes (review #7).
@MainActor
public protocol VocabularyListWriting: AnyObject {
    var terms: [VocabTerm] { get }
    /// False when the list's file exists but could not be read: writing would
    /// replace the user's list with a partial one, so nothing writes.
    var isWritable: Bool { get }
    /// The list's own spelling of free text (its file-safe scrub), or nil when
    /// the list would refuse it (empty, too many words).
    func cleanEntry(_ raw: String) -> String?
    /// Append a new row; returns its id.
    func addTerm(_ text: String) -> VocabTerm.ID
    func removeTerm(id: VocabTerm.ID)
    func setText(_ text: String, id: VocabTerm.ID)
    func setSoundsLikes(_ soundsLikes: [String], id: VocabTerm.ID)
}

/// The one function every correction surface calls.
@MainActor
public final class VocabularyLearning {

    /// What one `apply` did, so `.undo(receipt)` can reverse exactly that and
    /// the caller can phrase its result (review #5, #7). A review verdict
    /// stores it for the list's Undo.
    public struct Receipt: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// The term or its sounds-like is new in the list (the term as listed).
            case added(String)
            /// Already in the list as asked (the term as listed).
            case duplicate(String)
            /// The list refused the text (empty, too long, unwritable) — nothing changed.
            case rejected
            /// A signal with no list add (keep, forget, undo).
            case recorded
        }

        public var outcome: Outcome
        /// The term as listed after the apply, when there is one.
        public var term: String?
        /// The list row the apply wrote.
        public var termID: UUID?
        /// The row was new.
        public var termAdded = false
        /// The sounds-like this apply added, to remove on undo.
        public var soundsLikeAdded: String?
        /// The sounds-like this apply removed (a forget), to put back on undo.
        public var soundsLikeRemoved: String?
        /// The row's text before this apply re-cased it.
        public var previousListCasing: String?
        /// The store write, for its exact inverse.
        public var storeRecord: CorrectionStore.EditRecord?
        /// The store's casing before a re-case with no store record.
        public var previousStoreCasing: String?

        public init(outcome: Outcome, term: String? = nil) {
            self.outcome = outcome
            self.term = term
        }
    }

    private let list: any VocabularyListWriting
    private let store: CorrectionStore

    public init(list: any VocabularyListWriting, store: CorrectionStore) {
        self.list = list
        self.store = store
    }

    /// Apply one correction: the list write happens synchronously first, then
    /// one awaited store write.
    @discardableResult
    public func apply(_ correction: Correction) async -> Receipt {
        switch correction {
        case let .correct(heard, term, heardByModel, userCasing, termID):
            return await correct(heard: heard, term: term, heardByModel: heardByModel,
                                 userCasing: userCasing, termID: termID)
        case let .keepOriginal(heard, term):
            guard let cleaned = list.cleanEntry(term), !CorrectionKey.normalize(heard).isEmpty
            else { return Receipt(outcome: .rejected) }
            let listed = row(matching: cleaned).map { Self.text(of: $0) } ?? cleaned
            var receipt = Receipt(outcome: .recorded, term: listed)
            receipt.storeRecord = await store.recordEdit(
                originalWord: heard, term: listed, direction: .away)
            return receipt
        case let .forget(heard, term, termID):
            guard list.isWritable, let entry = row(id: termID, text: term),
                  !CorrectionKey.normalize(heard).isEmpty
            else { return Receipt(outcome: .rejected) }
            let listed = Self.text(of: entry)
            var receipt = Receipt(outcome: .recorded, term: listed)
            receipt.termID = entry.id
            // Match the sounds-like exactly as listed (case aside) — no scrub,
            // so a hand-edited file's "Jo: Jay" chip still deletes.
            if let removed = entry.aliases.first(where: { $0.lowercased() == heard.lowercased() }) {
                list.setSoundsLikes(entry.aliases.filter { $0 != removed }, id: entry.id)
                receipt.soundsLikeRemoved = removed
            }
            receipt.storeRecord = await store.forgetEdits(originalWord: heard, term: listed)
            return receipt
        case let .addTerm(raw):
            guard list.isWritable, let cleaned = list.cleanEntry(raw) else { return Receipt(outcome: .rejected) }
            guard let entry = row(matching: cleaned) else {
                var receipt = Receipt(outcome: .added(cleaned), term: cleaned)
                receipt.termID = list.addTerm(cleaned)
                receipt.termAdded = true
                receipt.previousStoreCasing = await store.recase(term: cleaned)
                return receipt
            }
            return await recase(entry, to: cleaned, outcome: .duplicate(cleaned))
        case let .recase(raw):
            guard list.isWritable, let cleaned = list.cleanEntry(raw), let entry = row(matching: cleaned)
            else { return Receipt(outcome: .rejected) }
            return await recase(entry, to: cleaned, outcome: .duplicate(cleaned))
        case let .undo(receipt):
            await undo(receipt)
            return Receipt(outcome: .recorded, term: receipt.term)
        }
    }

    private func recase(_ entry: VocabTerm, to text: String, outcome: Receipt.Outcome) async -> Receipt {
        var receipt = Receipt(outcome: outcome, term: text)
        receipt.termID = entry.id
        if entry.text != text {
            receipt.previousListCasing = entry.text
            list.setText(text, id: entry.id)
        }
        receipt.previousStoreCasing = await store.recase(term: text)
        return receipt
    }

    private func correct(heard rawHeard: String, term rawTerm: String, heardByModel: Bool,
                         userCasing: Bool, termID: UUID?) async -> Receipt {
        guard list.isWritable else { return Receipt(outcome: .rejected) }
        let existing: VocabTerm?
        let cleaned: String
        if let termID {
            guard let entry = list.terms.first(where: { $0.id == termID }), !entry.isBlank
            else { return Receipt(outcome: .rejected) }
            existing = entry
            cleaned = Self.text(of: entry)
        } else {
            guard let text = list.cleanEntry(rawTerm) else { return Receipt(outcome: .rejected) }
            existing = row(matching: text)
            cleaned = text
        }
        let trimmedHeard = rawHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing heard differently (empty, or the term itself in other casing)
        // is a plain add; the user's casing wins only when the user typed it.
        guard !trimmedHeard.isEmpty,
              CorrectionKey.normalize(trimmedHeard) != CorrectionKey.normalize(cleaned)
        else {
            if userCasing { return await apply(.addTerm(cleaned)) }
            if let existing {
                var receipt = Receipt(outcome: .duplicate(Self.text(of: existing)), term: Self.text(of: existing))
                receipt.termID = existing.id
                return receipt
            }
            var receipt = Receipt(outcome: .added(cleaned), term: cleaned)
            receipt.termID = list.addTerm(cleaned)
            receipt.termAdded = true
            return receipt
        }
        // Refuse before writing anything, as the "Add to Vocabulary" button
        // always has for an overlong sounds-like.
        guard let heard = list.cleanEntry(trimmedHeard) else { return Receipt(outcome: .rejected) }

        var receipt = Receipt(outcome: .duplicate(cleaned))
        var entry: VocabTerm
        if let existing {
            entry = existing
            if userCasing, termID == nil, existing.text != cleaned {
                receipt.previousListCasing = existing.text
                list.setText(cleaned, id: existing.id)
                entry.text = cleaned
            }
        } else {
            entry = VocabTerm(id: list.addTerm(cleaned), text: cleaned)
            receipt.termAdded = true
        }
        let term = Self.text(of: entry)
        receipt.term = term
        receipt.termID = entry.id
        if heardByModel, !entry.aliases.contains(where: { $0.lowercased() == heard.lowercased() }) {
            list.setSoundsLikes(entry.aliases + [heard], id: entry.id)
            receipt.soundsLikeAdded = heard
        }
        receipt.outcome = receipt.termAdded || receipt.soundsLikeAdded != nil ? .added(term) : .duplicate(term)
        receipt.storeRecord = await store.recordEdit(
            originalWord: heard, term: term, direction: .toward, heardByModel: heardByModel,
            recasesTerm: userCasing)
        return receipt
    }

    /// Reverse the list writes first — the added sounds-like, then the row it
    /// added only if that row has no other sounds-likes and still reads as the
    /// apply left it — then the store write.
    private func undo(_ receipt: Receipt) async {
        if list.isWritable, let id = receipt.termID, let entry = list.terms.first(where: { $0.id == id }) {
            var aliases = entry.aliases
            if let added = receipt.soundsLikeAdded,
               let i = aliases.firstIndex(where: { $0.lowercased() == added.lowercased() }) {
                aliases.remove(at: i)
            }
            if let removed = receipt.soundsLikeRemoved,
               !aliases.contains(where: { $0.lowercased() == removed.lowercased() }) {
                aliases.append(removed)
            }
            if aliases != entry.aliases { list.setSoundsLikes(aliases, id: id) }
            let unchanged = Self.text(of: entry) == receipt.term
            if receipt.termAdded {
                if unchanged, aliases.isEmpty { list.removeTerm(id: id) }
            } else if let previous = receipt.previousListCasing, unchanged {
                list.setText(previous, id: id)
            }
        }
        if let record = receipt.storeRecord {
            await store.undo(record)
        } else if let previous = receipt.previousStoreCasing {
            await store.recase(term: previous)
        }
    }

    /// **One-time migration (review #1).** Writes the pairs learned from
    /// transcript edits before Revision 2 into the list as sounds-likes, so the
    /// list is the only source of decoder pairs and nothing learned is lost. A
    /// pair whose term the user has since deleted stays deleted. Returns how
    /// many sounds-likes were added, or nil when the list or the correction
    /// ledger could not be read (the caller must not mark the migration done).
    public func migrateEditLearnedPairs() async -> Int? {
        guard list.isWritable, let pairs = await store.editLearnedPairs(), list.isWritable else { return nil }
        var added = 0
        for pair in pairs {
            guard let heard = list.cleanEntry(pair.original), let entry = row(matching: pair.term),
                  !entry.aliases.contains(where: { $0.lowercased() == heard.lowercased() })
            else { continue }
            list.setSoundsLikes(entry.aliases + [heard], id: entry.id)
            added += 1
        }
        return added
    }

    // MARK: - Rows

    private static func text(of entry: VocabTerm) -> String {
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first row spelling `text` (case-insensitive), as the list dedupes.
    private func row(matching text: String) -> VocabTerm? {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        return list.terms.first { Self.text(of: $0).lowercased() == lower }
    }

    private func row(id: UUID?, text: String) -> VocabTerm? {
        if let id { return list.terms.first { $0.id == id } }
        return row(matching: text)
    }
}

extension VocabularyLearning.Receipt.Outcome: Codable {
    private enum CodingKeys: String, CodingKey { case kind, term }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let term = try c.decodeIfPresent(String.self, forKey: .term) ?? ""
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "recorded" {
        case "added": self = .added(term)
        case "duplicate": self = .duplicate(term)
        case "rejected": self = .rejected
        default: self = .recorded
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .added(let term):
            try c.encode("added", forKey: .kind)
            try c.encode(term, forKey: .term)
        case .duplicate(let term):
            try c.encode("duplicate", forKey: .kind)
            try c.encode(term, forKey: .term)
        case .rejected:
            try c.encode("rejected", forKey: .kind)
        case .recorded:
            try c.encode("recorded", forKey: .kind)
        }
    }
}

extension VocabularyLearning.Receipt: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome, term, termID, termAdded, soundsLikeAdded, soundsLikeRemoved
        case previousListCasing, storeRecord, previousStoreCasing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(outcome: try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? .recorded,
                  term: try c.decodeIfPresent(String.self, forKey: .term))
        termID = try c.decodeIfPresent(UUID.self, forKey: .termID)
        termAdded = try c.decodeIfPresent(Bool.self, forKey: .termAdded) ?? false
        soundsLikeAdded = try c.decodeIfPresent(String.self, forKey: .soundsLikeAdded)
        soundsLikeRemoved = try c.decodeIfPresent(String.self, forKey: .soundsLikeRemoved)
        previousListCasing = try c.decodeIfPresent(String.self, forKey: .previousListCasing)
        storeRecord = try c.decodeIfPresent(CorrectionStore.EditRecord.self, forKey: .storeRecord)
        previousStoreCasing = try c.decodeIfPresent(String.self, forKey: .previousStoreCasing)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outcome, forKey: .outcome)
        try c.encodeIfPresent(term, forKey: .term)
        try c.encodeIfPresent(termID, forKey: .termID)
        try c.encode(termAdded, forKey: .termAdded)
        try c.encodeIfPresent(soundsLikeAdded, forKey: .soundsLikeAdded)
        try c.encodeIfPresent(soundsLikeRemoved, forKey: .soundsLikeRemoved)
        try c.encodeIfPresent(previousListCasing, forKey: .previousListCasing)
        try c.encodeIfPresent(storeRecord, forKey: .storeRecord)
        try c.encodeIfPresent(previousStoreCasing, forKey: .previousStoreCasing)
    }
}
