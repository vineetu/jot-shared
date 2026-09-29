import XCTest
@testable import JotVocabCore

/// In-memory list with the Mac `VocabularyStore`'s scrub (file-safe, ≤ 4 words).
@MainActor
private final class FakeList: VocabularyListWriting {
    var terms: [VocabTerm] = []
    var isWritable = true

    init(_ terms: [VocabTerm] = []) { self.terms = terms }

    func cleanEntry(_ raw: String) -> String? {
        let cleaned = String(raw.map { ":,#".contains($0) ? " " : $0 })
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !cleaned.isEmpty, cleaned.split(separator: " ").count <= 4 else { return nil }
        return cleaned
    }

    func addTerm(_ text: String) -> VocabTerm.ID {
        let term = VocabTerm(text: text)
        terms.append(term)
        return term.id
    }

    func removeTerm(id: VocabTerm.ID) { terms.removeAll { $0.id == id } }

    func setText(_ text: String, id: VocabTerm.ID) {
        if let i = terms.firstIndex(where: { $0.id == id }) { terms[i].text = text }
    }

    func setSoundsLikes(_ soundsLikes: [String], id: VocabTerm.ID) {
        if let i = terms.firstIndex(where: { $0.id == id }) { terms[i].aliases = soundsLikes }
    }

    func aliases(_ term: String) -> [String] {
        terms.first { $0.text.lowercased() == term.lowercased() }?.aliases ?? []
    }
}

@MainActor
final class VocabularyLearningTests: XCTestCase {

    private func store(common: Set<String> = ["cloud"]) -> CorrectionStore {
        CorrectionStore(containerRoot: nil, isCommonOriginal: { word in
            VocabularyGate.isCommonOriginal(word, commonWords: common)
        })
    }

    private func decoder(_ list: FakeList, _ store: CorrectionStore) async -> DecoderVocabulary {
        DecoderVocabulary.derive(from: list.terms, pausedPairKeys: await store.pausedPairKeys())
    }

    // MARK: - correct

    func testCorrectAddsTermSoundsLikeAndActivePair() async {
        let list = FakeList(), s = store()
        let receipt = await VocabularyLearning(list: list, store: s)
            .apply(.correct(heard: "cloud", term: "Claude"))
        XCTAssertEqual(receipt.outcome, .added("Claude"))
        XCTAssertEqual(list.terms.map(\.text), ["Claude"])
        XCTAssertEqual(list.aliases("Claude"), ["cloud"])
        let d = await decoder(list, s)
        XCTAssertEqual(d.pairs, [DecoderVocabulary.Pair(original: "cloud", term: "Claude")])
        XCTAssertEqual(d.terms, [DecoderVocabulary.Term(text: "Claude", weight: DecoderVocabulary.pairedWeight)])
    }

    func testCorrectUserCasingWinsAndSecondApplyIsDuplicate() async {
        let list = FakeList([VocabTerm(text: "claude")]), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        let first = await learning.apply(.correct(heard: "cloud", term: "Claude", userCasing: true))
        XCTAssertEqual(first.outcome, .added("Claude"), "a new sounds-like counts as added")
        XCTAssertEqual(list.terms.map(\.text), ["Claude"])
        let second = await learning.apply(.correct(heard: "Cloud", term: "Claude"))
        XCTAssertEqual(second.outcome, .duplicate("Claude"))
        XCTAssertEqual(list.aliases("Claude"), ["cloud"])
    }

    func testCorrectRejectsOverlongTextAndWritesNothing() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        let r1 = await learning.apply(.correct(heard: "one two three four five", term: "Vineet"))
        XCTAssertEqual(r1.outcome, .rejected)
        let r2 = await learning.apply(.correct(heard: "x", term: "   "))
        XCTAssertEqual(r2.outcome, .rejected)
        XCTAssertTrue(list.terms.isEmpty)
        let snapshot = await s.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testCorrectWithNoDifferentHeardIsAPlainAdd() async {
        let list = FakeList([VocabTerm(text: "claude")]), s = store()
        let receipt = await VocabularyLearning(list: list, store: s)
            .apply(.correct(heard: "claude", term: "Claude", userCasing: true))
        XCTAssertEqual(receipt.outcome, .duplicate("Claude"))
        XCTAssertEqual(list.terms.map(\.text), ["Claude"])
        XCTAssertTrue(list.aliases("Claude").isEmpty)
    }

    func testNotHeardByModelAddsTermOnly() async {
        let list = FakeList(), s = store()
        let receipt = await VocabularyLearning(list: list, store: s)
            .apply(.correct(heard: "cloud", term: "Claude", heardByModel: false))
        XCTAssertEqual(receipt.outcome, .added("Claude"))
        XCTAssertTrue(list.aliases("Claude").isEmpty, "D11: no sounds-like, so no pair")
        let d = await decoder(list, s)
        XCTAssertTrue(d.pairs.isEmpty)
        XCTAssertEqual(d.terms.first?.weight, DecoderVocabulary.baseWeight)
    }

    // MARK: - Text rules (D6, review #3, #6)

    // MARK: - Pair state: last explicit signal wins (review #4)

    func testKeepPausesPairAndKeepsSoundsLike() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        await learning.apply(.correct(heard: "cloud", term: "Claude"))
        await learning.apply(.correct(heard: "cloud", term: "Claude"))
        await learning.apply(.keepOriginal(heard: "cloud", term: "Claude"))
        XCTAssertEqual(list.aliases("Claude"), ["cloud"], "a keep never deletes what the user taught")
        var d = await decoder(list, s)
        XCTAssertTrue(d.pairs.isEmpty, "paused even though toward (2) > away (1)")
        XCTAssertEqual(d.terms.first?.weight, DecoderVocabulary.baseWeight)
        await learning.apply(.correct(heard: "cloud", term: "Claude"))
        d = await decoder(list, s)
        XCTAssertEqual(d.pairs.count, 1, "a later correct wins it back")
    }

    func testPairPausedPersistsAndOldFilesDecode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CorrectionStore(containerRoot: root)
        await first.recordEdit(originalWord: "cloud", term: "Claude", direction: .away)
        let second = CorrectionStore(containerRoot: root)
        let paused = await second.pausedPairKeys()
        XCTAssertEqual(paused, ["cloud|claude"])
        let old = #"{"originalWord":"cloud","term":"Claude","editsToward":1}"#
        let m = try JSONDecoder().decode(CorrectionStore.Mapping.self, from: Data(old.utf8))
        XCTAssertFalse(m.pairPaused)
    }

    // MARK: - undo (review #5)

    func testUndoCorrectReversesExactly() async {
        let list = FakeList([VocabTerm(text: "claude")]), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        let receipt = await learning.apply(
            .correct(heard: "vinit", term: "Claude", userCasing: true))
        await learning.apply(.undo(receipt))
        XCTAssertEqual(list.terms.map(\.text), ["claude"], "casing restored")
        XCTAssertTrue(list.aliases("claude").isEmpty, "sounds-like removed")
        let snapshot = await s.snapshot()
        XCTAssertTrue(snapshot.isEmpty, "the mapping it created is gone")

        let fresh = await learning.apply(.correct(heard: "cloud", term: "Anthropic"))
        await learning.apply(.undo(fresh))
        XCTAssertFalse(list.terms.contains { $0.text == "Anthropic" }, "a term it added is removed")
    }

    func testUndoKeepsSignalsOtherSurfacesRecordedSince() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        let first = await learning.apply(.correct(heard: "cloud", term: "Claude"))
        await learning.apply(.correct(heard: "cloud", term: "Claude"))
        await learning.apply(.undo(first))
        let m = await s.mappingProbe(original: "cloud", term: "Claude")
        XCTAssertEqual(m?.editsToward, 1)
        XCTAssertEqual(list.aliases("Claude"), [], "the first apply added the sounds-like; undo removes it")
    }

    func testUndoKeepOriginalReactivatesPair() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        await learning.apply(.correct(heard: "cloud", term: "Claude"))
        let keep = await learning.apply(.keepOriginal(heard: "cloud", term: "Claude"))
        var d = await decoder(list, s)
        XCTAssertTrue(d.pairs.isEmpty)
        await learning.apply(.undo(keep))
        d = await decoder(list, s)
        XCTAssertEqual(d.pairs.count, 1)
        let m = await s.mappingProbe(original: "cloud", term: "Claude")
        XCTAssertEqual(m?.editsAway, 0)
    }

    func testUndoForgetPutsItBack() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        await learning.apply(.correct(heard: "cloud", term: "Claude"))
        let forget = await learning.apply(.forget(heard: "cloud", term: "Claude"))
        XCTAssertTrue(list.aliases("Claude").isEmpty)
        await learning.apply(.undo(forget))
        XCTAssertEqual(list.aliases("Claude"), ["cloud"])
        let m = await s.mappingProbe(original: "cloud", term: "Claude")
        XCTAssertEqual(m?.editsToward, 1)
    }

    // MARK: - forget / addTerm / recase

    func testForgetRemovesSoundsLikeAndItsPairButKeepsGateVerdicts() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        await s.confirm(originalWord: "vinit", term: "Vineet")   // a gate verdict
        await learning.apply(.correct(heard: "vinit", term: "Vineet"))
        await learning.apply(.forget(heard: "Vinit", term: "Vineet"))
        XCTAssertTrue(list.aliases("Vineet").isEmpty)
        let d = await decoder(list, s)
        XCTAssertTrue(d.pairs.isEmpty)
        let m = await s.mappingProbe(original: "vinit", term: "Vineet")
        XCTAssertEqual(m?.editsToward, 0)
        XCTAssertEqual(m?.confirmations, 1, "answers to gate proposals are separate (review #10)")
        let entry = await s.snapshot().first
        XCTAssertEqual(entry?.paused, false)
    }

    func testAddTermAndRecase() async {
        let list = FakeList([VocabTerm(text: "claude")]), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        await s.recordEdit(originalWord: "cloud", term: "claude", direction: .toward)
        let dup = await learning.apply(.addTerm("Claude"))
        XCTAssertEqual(dup.outcome, .duplicate("Claude"))
        XCTAssertEqual(list.terms.map(\.text), ["Claude"], "user casing wins")
        let m = await s.mappingProbe(original: "cloud", term: "Claude")
        XCTAssertEqual(m?.term, "Claude", "the store's casing follows")
        let added = await learning.apply(.addTerm("  Jot  "))
        XCTAssertEqual(added.outcome, .added("Jot"))
        let rejected = await learning.apply(.addTerm("a b c d e"))
        XCTAssertEqual(rejected.outcome, .rejected)
        let recase = await learning.apply(.recase("CLAUDE"))
        XCTAssertEqual(list.terms.first?.text, "CLAUDE")
        await learning.apply(.undo(recase))
        XCTAssertEqual(list.terms.first?.text, "Claude")
        let back = await s.mappingProbe(original: "cloud", term: "Claude")
        XCTAssertEqual(back?.term, "Claude")
    }

    // MARK: - Decoder derivation

    func testPairEligibility() {
        XCTAssertTrue(LearnedPairPolicy.isDecoderPair(original: "cloud", term: "Claude"))
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "chart", term: "Jot"),
                       "different first letter stays with the CTC gate (measured)")
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "beneath", term: "Vineet"))
        XCTAssertTrue(LearnedPairPolicy.isDecoderPair(original: "Venith", term: "Vineet"))
        XCTAssertTrue(LearnedPairPolicy.isDecoderPair(original: "Shrida", term: "Sriram"))
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "Vishnu has been", term: "Vishnuhasan"),
                       "multi-word stays gate-only")
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "jo", term: "Jot"), "< 3 letters")
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "クロード", term: "Claude"), "not Latin")
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "клод", term: "Claude"), "not Latin")
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "abc123", term: "Claude"))
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "claude", term: "Claude"), "the term itself")
        XCTAssertFalse(LearnedPairPolicy.isDecoderPair(original: "cloud", term: "Claude", paused: true))
    }

    func testDeriveFromListOnly() {
        let list = [
            VocabTerm(text: "Claude", aliases: ["Cloud", "clod"]),
            VocabTerm(text: "Vineet", aliases: ["Vishnu has been", "vinit"]),
            VocabTerm(text: "Jot", aliases: ["chart"]),
            VocabTerm(text: "Parakeet"),
            VocabTerm(text: "  "),
            VocabTerm(text: "claude", aliases: ["cloud"]),
        ]
        let d = DecoderVocabulary.derive(from: list, pausedPairKeys: ["vinit|vineet"])
        XCTAssertEqual(d.terms.map(\.text), ["Claude", "Vineet", "Jot", "Parakeet"])
        // chart → Jot has a different first letter: gate-only, so Jot stays 3.5.
        XCTAssertEqual(d.terms.map(\.weight), [5.0, 3.5, 3.5, 3.5])
        XCTAssertEqual(d.pairs.map { "\($0.original)→\($0.term)" }, ["clod→Claude", "cloud→Claude"])
    }

    // MARK: - Migration (review #1)

    func testMigrationWritesEditLearnedPairsIntoTheList() async {
        let list = FakeList([VocabTerm(text: "Claude")]), s = store()
        await s.recordEdit(originalWord: "cloud", term: "Claude", direction: .toward, heardByModel: true)
        await s.recordEdit(originalWord: "anthropik", term: "Anthropic", direction: .toward, heardByModel: true)
        await s.recordEdit(originalWord: "ai cleanup", term: "Jot", direction: .toward, heardByModel: false)
        await s.recordEdit(originalWord: "vinit", term: "Vineet", direction: .toward, heardByModel: true)
        await s.recordEdit(originalWord: "vinit", term: "Vineet", direction: .away)
        let added = await VocabularyLearning(list: list, store: s).migrateEditLearnedPairs()
        XCTAssertEqual(added, 1)
        XCTAssertEqual(list.aliases("Claude"), ["cloud"])
        XCTAssertFalse(list.terms.contains { $0.text == "Anthropic" }, "a deleted term stays deleted")
        XCTAssertTrue(list.aliases("Jot").isEmpty)
        XCTAssertTrue(list.aliases("Vineet").isEmpty)
    }

    // MARK: - Review fixes

    func testProposalCasingNeverRecases() async {
        let list = FakeList([VocabTerm(text: "eBay")]), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        let receipt = await learning.apply(.correct(heard: "ebb", term: "EBay"))
        XCTAssertEqual(list.terms.map(\.text), ["eBay"], "a sentence-start proposal keeps the list's spelling")
        XCTAssertEqual(receipt.term, "eBay")
        let m = await s.mappingProbe(original: "ebb", term: "ebay")
        XCTAssertEqual(m?.term, "eBay")
        await learning.apply(.correct(heard: "ebay", term: "EBAY"))
        XCTAssertEqual(list.terms.map(\.text), ["eBay"], "no plain-add recase either")
        await learning.apply(.correct(heard: "ebb", term: "EBay", userCasing: true))
        XCTAssertEqual(list.terms.map(\.text), ["EBay"], "a typed term's casing wins")
    }

    func testUndoKeepsARowThatGainedOtherSoundsLikesOrWasRenamed() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        let first = await learning.apply(.correct(heard: "cloud", term: "Claude"))
        await learning.apply(.correct(heard: "clod", term: "Claude"))
        await learning.apply(.undo(first))
        XCTAssertEqual(list.aliases("Claude"), ["clod"], "only its own sounds-like goes")
        XCTAssertEqual(list.terms.count, 1, "the row stays while it has other sounds-likes")

        let second = await learning.apply(.correct(heard: "anthropik", term: "Anthropic"))
        list.setText("Anthropic PBC", id: second.termID!)
        await learning.apply(.undo(second))
        XCTAssertTrue(list.terms.contains { $0.text == "Anthropic PBC" }, "a renamed row is the user's now")
        XCTAssertTrue(list.aliases("Anthropic PBC").isEmpty)
    }

    func testForgetMatchesTheListedSoundsLikeAndRoutesByRow() async {
        let a = VocabTerm(text: "Jo", aliases: ["Jay#"]), b = VocabTerm(text: "jo", aliases: ["Jay#"])
        let list = FakeList([a, b]), s = store()
        let receipt = await VocabularyLearning(list: list, store: s)
            .apply(.forget(heard: "Jay#", term: "jo", termID: b.id))
        XCTAssertEqual(receipt.soundsLikeRemoved, "Jay#")
        XCTAssertEqual(list.terms[0].aliases, ["Jay#"], "the other row is untouched")
        XCTAssertTrue(list.terms[1].aliases.isEmpty)
    }

    func testChipAddRoutesByRow() async {
        let a = VocabTerm(text: "Jo"), b = VocabTerm(text: "jo")
        let list = FakeList([a, b]), s = store()
        await VocabularyLearning(list: list, store: s)
            .apply(.correct(heard: "joe", term: "ignored", userCasing: true, termID: b.id))
        XCTAssertTrue(list.terms[0].aliases.isEmpty)
        XCTAssertEqual(list.terms[1].aliases, ["joe"])
        XCTAssertEqual(list.terms.map(\.text), ["Jo", "jo"], "no recase through a row id")
    }

    func testReceiptsAreKeptPerVerdict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = CorrectionProvenance(containerRoot: root)
        let id = UUID()
        let proposal = VocabularyGate.Proposal(
            originalWord: "cloud", term: "Claude", decision: "BLOCK", outcome: "kept", confidence: 0.5,
            margin: 1, unsure: false, occurrenceIndex: 0, originalStart: 4, originalLength: 5,
            publishedStart: 4, publishedLength: 5, alternates: [], shape: nil)
        let sibling = VocabularyGate.Proposal(
            originalWord: "cloud", term: "Claude", decision: "BLOCK", outcome: "kept", confidence: 0.5,
            margin: 1, unsure: false, occurrenceIndex: 1, originalStart: 14, originalLength: 5,
            publishedStart: 14, publishedLength: 5, alternates: [], shape: nil)
        await p.record([proposal, sibling], gatedText: "ask cloud and cloud")
        await p.commit(transcriptID: id)
        let records = await p.payload(transcriptID: id).records
        let term = VocabularyLearning.Receipt(outcome: .added("Claude"), term: "Claude")
        let keep = VocabularyLearning.Receipt(outcome: .recorded, term: "Claude")
        _ = await p.setVerdict(transcriptID: id, record: records[0], verdict: "term", receipt: term)
        _ = await p.setVerdict(transcriptID: id, record: records[0], verdict: "original", receipt: keep)
        var payload = await p.payload(transcriptID: id)
        XCTAssertEqual(payload.receipts(for: records[0]), ["term": term, "original": keep],
                       "switching verdicts keeps the term pick's receipt")
        await p.attachReceipt(term, verdict: "term", transcriptID: id, record: records[1])
        _ = await p.clearVerdict(transcriptID: id, record: records[0])
        payload = await p.payload(transcriptID: id)
        XCTAssertTrue(payload.receipts(for: records[0]).isEmpty)
        XCTAssertEqual(payload.receipts(for: records[1]), ["term": term], "handed to the sibling")
    }

    func testUnreadableListIsNeverWritten() async {
        let list = FakeList([VocabTerm(text: "Claude")]), s = store()
        list.isWritable = false
        await s.recordEdit(originalWord: "cloud", term: "Claude", direction: .toward, heardByModel: true)
        let learning = VocabularyLearning(list: list, store: s)
        let migrated = await learning.migrateEditLearnedPairs()
        XCTAssertNil(migrated, "retried next launch")
        let r = await learning.apply(.correct(heard: "clod", term: "Claude"))
        XCTAssertEqual(r.outcome, .rejected)
        XCTAssertTrue(list.aliases("Claude").isEmpty)
    }

    func testPairPausedDefaultsFromCountersOnOldFiles() throws {
        let away = #"{"originalWord":"cloud","term":"Claude","editsToward":1,"editsAway":2}"#
        let toward = #"{"originalWord":"cloud","term":"Claude","editsToward":2,"editsAway":1}"#
        XCTAssertTrue(try JSONDecoder().decode(CorrectionStore.Mapping.self, from: Data(away.utf8)).pairPaused)
        XCTAssertFalse(try JSONDecoder().decode(CorrectionStore.Mapping.self, from: Data(toward.utf8)).pairPaused)
    }

    func testUndoRestoresFlagsOnlyIfUnchangedSince() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        let correct = await learning.apply(.correct(heard: "cloud", term: "Claude"))   // creates, active
        await learning.apply(.keepOriginal(heard: "cloud", term: "Claude"))   // a later keep owns the flag
        await learning.apply(.undo(correct))
        let m = await s.mappingProbe(original: "cloud", term: "Claude")
        XCTAssertEqual(m?.pairPaused, true, "the later keep stands")
        XCTAssertEqual(m?.editsToward, 0)
        XCTAssertEqual(m?.editsAway, 1)
    }

    func testUndoNeverWritesAnEmptyTerm() async {
        let list = FakeList(), s = store()
        let learning = VocabularyLearning(list: list, store: s)
        let keep = await learning.apply(.keepOriginal(heard: "cloud", term: "Claude"))
        await learning.apply(.forget(heard: "cloud", term: "Claude"))
        await learning.apply(.undo(keep))
        let entries = await s.termEntryCount()
        let mappings = await s.allMappings()
        XCTAssertTrue(mappings.isEmpty)
        XCTAssertEqual(entries, 0, "no empty Term left behind")
    }

    // MARK: - Codable (a keyboard queues these)

    func testCorrectionRoundTrips() async throws {
        let list = FakeList(), s = store()
        let receipt = await VocabularyLearning(list: list, store: s).apply(.correct(heard: "cloud", term: "Claude"))
        let all: [Correction] = [
            .correct(heard: "cloud", term: "Claude"),
            .correct(heard: "cloud", term: "Claude", heardByModel: false, userCasing: true, termID: UUID()),
            .keepOriginal(heard: "cloud", term: "Claude"),
            .undo(receipt),
            .forget(heard: "cloud", term: "Claude"),
            .forget(heard: "Cloud", term: "Claude", termID: UUID()),
            .addTerm("Claude"),
            .recase("Claude"),
        ]
        let data = try JSONEncoder().encode(all)
        XCTAssertEqual(try JSONDecoder().decode([Correction].self, from: data), all)
    }
}

extension CorrectionStore {
    /// Test probe: one mapping by (original, term).
    func mappingProbe(original: String, term: String) -> Mapping? {
        allMappings().first {
            $0.originalWord == CorrectionKey.normalize(original) && $0.term.lowercased() == term.lowercased()
        }
    }
}
