import XCTest
@testable import JotVocabCore

/// Learn from transcript edits (design `docs/vocabulary-learn-from-edits/
/// design.md`): the pure edit diff (D2/D8/D9/D10/D11, reverse-first) and the
/// store's edit counters, derived strength, learned pairs and D6 arming.
final class EditLearningTests: XCTestCase {

    private var english: Set<String> {
        BundledCommonWordsProvider.shared.words(forResource: "common-words")
    }

    private func learn(
        _ before: String, _ after: String, raw: String? = nil,
        vocabulary: [VocabTerm] = []
    ) -> [EditLearner.Lesson] {
        let common = english
        return EditLearner.learn(
            before: before, after: after, raw: raw ?? before,
            vocabulary: vocabulary, isCommonWord: { common.contains($0) })
    }

    // MARK: - EditLearner

    func testMotivatingCaseLearnsDespiteBothWordsBeingCommon() {
        // "claude" and "cloud" are both in the everyday list; the introduced
        // capital marks a name the user typed.
        XCTAssertTrue(english.contains("cloud") && english.contains("claude"))
        XCTAssertEqual(
            learn("I asked cloud about it.", "I asked Claude about it."),
            [.substitute(original: "cloud", term: "Claude", heardByModel: true)])
    }

    func testCommonToVocabularyTermLearns() {
        XCTAssertEqual(
            learn("ask cloud now", "ask claude now", vocabulary: [VocabTerm(text: "claude")]),
            [.substitute(original: "cloud", term: "claude", heardByModel: true)])
    }

    func testCapitalizedReplacementLearnsWithOtherCapitalsInText() {
        // "Claude" not in vocabulary; the sentence carries other capitals.
        XCTAssertEqual(
            learn("Then Bob asked cloud about Paris.", "Then Bob asked Claude about Paris."),
            [.substitute(original: "cloud", term: "Claude", heardByModel: true)])
    }

    func testSentenceStartSwapIsIgnored() {
        XCTAssertEqual(learn("The cat sat.", "A cat sat."), [])
        XCTAssertEqual(learn("Done. Their going home", "Done. There going home"), [])
    }

    func testBothCommonSwapIsIgnored() {
        XCTAssertEqual(learn("their going home", "there going home"), [])   // D8
        XCTAssertEqual(learn("a cat sat", "the cat sat"), [])
        XCTAssertEqual(learn("I saw a dog", "I saw I dog"), [], "a single capital letter is not a name")
    }

    func testRareOriginalLearns() {
        XCTAssertEqual(
            learn("talk to jammy today", "talk to Jamy today"),
            [.substitute(original: "jammy", term: "Jamy", heardByModel: true)])
    }

    func testInsertsDeletesAndOversizedHunksTeachNothing() {
        XCTAssertEqual(learn("hello world", "hello brave new world"), [])          // insert
        XCTAssertEqual(learn("hello brave new world", "hello world"), [])          // delete
        XCTAssertEqual(learn("we met at the zorbex conference hall today",
                             "we met yesterday"), [], "4+ replaced words is a rewrite")
        XCTAssertEqual(learn("send it to qqq now", "send it to Aaa Bbb Ccc Ddd Eee now"), [],
                       "more than 4 new words is a rewrite")
    }

    func testPunctuationOnlyAndNumberEditsIgnored() {
        XCTAssertEqual(learn("send the email, please", "send the email please."), [])
        XCTAssertEqual(learn("my e-mail box", "my email box"), [])
        XCTAssertEqual(learn("buy 2 apples", "buy 3 apples"), [])
    }

    func testMultiWordSubstitution() {
        XCTAssertEqual(
            learn("open the tensor flow docs", "open the TensorFlow docs"),
            [.substitute(original: "tensor flow", term: "TensorFlow", heardByModel: true)])
    }

    func testReverseIsCheckedFirstAndNeverAddsTheOriginal() {
        XCTAssertEqual(
            learn("store it in Claude storage", "store it in cloud storage",
                  vocabulary: [VocabTerm(text: "Claude")]),
            [.reverse(original: "cloud", term: "Claude")])
        XCTAssertEqual(
            learn("hi Jamy", "hi jammy", vocabulary: [VocabTerm(text: "Jamy", aliases: ["jammy"])]),
            [.reverse(original: "jammy", term: "Jamy")])
    }

    func testCorrectingAVocabularyTermIsAlwaysAReverse() {
        // The bias wrote the term; the user meant ordinary words. Never a
        // substitute — "and the topic" must not become a vocabulary term.
        XCTAssertEqual(
            learn("we discussed Anthropic at length", "we discussed and the topic at length",
                  vocabulary: [VocabTerm(text: "Anthropic")]),
            [.reverse(original: "and the topic", term: "Anthropic")])
        // A hunk that contains a term among other words teaches nothing.
        XCTAssertEqual(
            learn("so Anthropic said no", "so and the topic says no",
                  vocabulary: [VocabTerm(text: "Anthropic")]), [])
    }

    func testContractionSwapIsIgnored() {
        XCTAssertEqual(learn("I think your right", "I think you're right"), [])
        XCTAssertEqual(learn("they said their late", "they said they're late"), [])
        XCTAssertEqual(learn("tell me whose there", "tell me who's there"), [])
    }

    func testRewordingIsNotLearned() {
        XCTAssertEqual(learn("let's meet tomorrow then", "let's meet on Monday then"), [])
        XCTAssertEqual(learn("the aforementioned issue", "the mentioned issue"), [])
    }

    func testSoundAlikesAreLearned() {
        XCTAssertEqual(learn("ask claud now", "ask Claude now"),
                       [.substitute(original: "claud", term: "Claude", heardByModel: true)])
        // "we need" is only a sound-alike of "Vineet" through its alias — the
        // same way the gate reads it.
        XCTAssertEqual(
            learn("so we need to go", "so Vineet to go",
                  vocabulary: [VocabTerm(text: "Vineet", aliases: ["we need"])]),
            [.substitute(original: "we need", term: "Vineet", heardByModel: true)])
    }

    func testChangeBeyondTheCapIsNotLearned() {
        let long = Array(repeating: "alpha", count: EditLearner.maxChangedWords + 1).joined(separator: " ")
        let other = Array(repeating: "omega", count: EditLearner.maxChangedWords + 1).joined(separator: " ")
        XCTAssertEqual(learn("start jammy " + long + " end", "start Jamy " + other + " end"), [])
    }

    func testCaseOnlyEditOfATermIsRecase() {
        XCTAssertEqual(
            learn("ask claude now", "ask Claude now", vocabulary: [VocabTerm(text: "claude")]),
            [.recase(term: "Claude")])
        XCTAssertEqual(
            learn("use open ai here", "use Open AI here", vocabulary: [VocabTerm(text: "open ai")]),
            [.recase(term: "Open AI")])
        // Capitalizing a term at a sentence start is grammar, not its casing.
        XCTAssertEqual(
            learn("Done. claude said hi", "Done. Claude said hi", vocabulary: [VocabTerm(text: "claude")]), [])
        XCTAssertEqual(
            learn("claude said hi", "Claude said hi", vocabulary: [VocabTerm(text: "claude")]), [])
        // Not a vocabulary term → nothing.
        XCTAssertEqual(learn("ask claude now", "ask Claude now"), [])
        // Already the stored casing → nothing.
        XCTAssertEqual(
            learn("ask claude now", "ask Claude now", vocabulary: [VocabTerm(text: "Claude")]), [])
    }

    func testNotHeardByModelWhenAICleanupWroteTheOriginal() {
        // D11: the cleanup layer wrote "cloud"; the model wrote "clawed".
        XCTAssertEqual(
            learn("I asked cloud today", "I asked Claude today", raw: "i asked clawed today"),
            [.substitute(original: "cloud", term: "Claude", heardByModel: false)])
    }

    func testOneLessonPerPairPerSession() {
        // D9: three fixes of the same pair → one lesson.
        XCTAssertEqual(
            learn("cloud said hi. then cloud left. cloud again",
                  "Claude said hi. then Claude left. Claude again"),
            [.substitute(original: "cloud", term: "Claude", heardByModel: true)])
    }

    func testPossessiveIsStrippedFromBothSides() {
        XCTAssertEqual(
            learn("read jammy's notes", "read Jamy's notes"),
            [.substitute(original: "jammy", term: "Jamy", heardByModel: true)])
    }

    func testUnchangedTextTeachesNothing() {
        XCTAssertEqual(learn("same text here", "same text here"), [])
    }

    func testLongTranscriptWithOneLocalEdit() {
        let filler = Array(repeating: "the quick brown fox jumps over the lazy dog", count: 800)
            .joined(separator: " ")
        let lessons = learn(filler + " talk to jammy " + filler, filler + " talk to Jamy " + filler)
        XCTAssertEqual(lessons, [.substitute(original: "jammy", term: "Jamy", heardByModel: true)])
    }

    // MARK: - CorrectionStore edit counters

    private func store(common: Set<String> = ["cloud"]) -> CorrectionStore {
        CorrectionStore(containerRoot: nil, isCommonOriginal: { word in
            VocabularyGate.isCommonOriginal(word, commonWords: common)
        })
    }

    // MARK: - Provenance hand-offs

    private func proposal(_ original: String, _ term: String, outcome: String, at start: Int)
        -> VocabularyGate.Proposal {
        VocabularyGate.Proposal(
            originalWord: original, term: term, decision: outcome == "applied" ? "APPLY" : "BLOCK",
            outcome: outcome, confidence: 0.5, margin: 1, unsure: false, occurrenceIndex: 0,
            originalStart: start, originalLength: original.count,
            publishedStart: start, publishedLength: (outcome == "applied" ? term : original).count,
            alternates: [], shape: nil)
    }

    private func provenanceRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-learning-\(UUID().uuidString)", isDirectory: true)
    }

    func testLiveVerdictBeforeCommitLandsOnTheRecord() async {
        let root = provenanceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = CorrectionProvenance(containerRoot: root)
        let id = UUID()
        await p.record([proposal("cloud", "Claude", outcome: "kept", at: 4)], gatedText: "ask cloud now")
        await p.noteLiveVerdict(originalWord: "cloud", term: "Claude", verdict: "original")
        await p.commit(transcriptID: id)
        let payload = await p.payload(transcriptID: id)
        XCTAssertEqual(payload.verdicts[payload.records[0].key], "original")
    }

    func testLiveVerdictAfterCommitLandsOnTheRecord() async {
        let root = provenanceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = CorrectionProvenance(containerRoot: root)
        let id = UUID()
        await p.record([proposal("cloud", "Claude", outcome: "applied", at: 4)], gatedText: "ask Claude now")
        await p.commit(transcriptID: id)
        await p.noteLiveVerdict(originalWord: "cloud", term: "Claude", verdict: "original")
        let payload = await p.payload(transcriptID: id)
        XCTAssertEqual(payload.verdicts[payload.records[0].key], "original")
        XCTAssertEqual(payload.contributions.values.first, -1, "ledger matches the pill's revert")
    }

    func testEditClosedVerdictIsMarkedAndClearedOnUndo() async {
        let root = provenanceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = CorrectionProvenance(containerRoot: root)
        let id = UUID()
        await p.record([proposal("cloud", "Claude", outcome: "kept", at: 4)], gatedText: "ask cloud now")
        await p.commit(transcriptID: id)
        let record = await p.payload(transcriptID: id).records[0]
        _ = await p.setVerdict(transcriptID: id, record: record, verdict: "term", fromEdit: true)
        var payload = await p.payload(transcriptID: id)
        XCTAssertTrue(payload.isEditClosed(record))
        _ = await p.clearVerdict(transcriptID: id, record: record)
        payload = await p.payload(transcriptID: id)
        XCTAssertFalse(payload.isEditClosed(record))
    }

    func testOldCorrectionsFileLoadsWithDefaults() throws {
        let json = #"{"originalWord":"jammy","term":"Jamy","confirmations":2,"reverts":0}"#
        let m = try JSONDecoder().decode(CorrectionStore.Mapping.self, from: Data(json.utf8))
        XCTAssertEqual(m.confirmations, 2)
        XCTAssertEqual(m.editsToward, 0)
        XCTAssertEqual(m.editsAway, 0)
        XCTAssertFalse(m.editHeard)
        XCTAssertFalse(m.pairPaused)
    }

    func testEditCountersPersistAndReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-learning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CorrectionStore(containerRoot: root)
        await first.recordEdit(originalWord: "cloud", term: "Claude", direction: .toward, heardByModel: true)
        await first.recordEdit(originalWord: "jammy", term: "Jamy", direction: .away)
        let second = CorrectionStore(containerRoot: root)
        let pairs = await second.editLearnedPairs()?.map { "\($0.original)→\($0.term)" }
        XCTAssertEqual(pairs, ["cloud→Claude"])
        let paused = await second.pausedPairKeys()
        XCTAssertEqual(paused, ["jammy|jamy"])
    }

}
