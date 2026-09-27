import XCTest
@testable import JotVocabCore

/// Evidence-typed gate, converged corrector, learning guard, ask ranking and
/// vocabulary hygiene (design `vocabulary-evidence-and-decode-bias.md` A1–A4,
/// R1/R2/R8–R11). New fixtures only — the existing goldens stay untouched and
/// must keep passing unchanged (R7).
final class EvidenceAndLearningTests: XCTestCase {

    private func loadFixture<T: Decodable>(_ file: String, as type: T.Type) throws -> T {
        guard let url = Bundle.module.url(
            forResource: file, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture: \(file).json")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private var english: Set<String> {
        BundledCommonWordsProvider.shared.words(forResource: "common-words")
    }

    // MARK: - Windows §1.4 symptoms through the converged corrector

    private struct SymptomCase: Decodable {
        struct Term: Decodable { let text: String; let aliases: [String]? }
        let name: String
        let transcript: String
        let language: String
        let terms: [Term]
        let expectText: String
        let expectDetectionCount: Int?
    }

    func testCorrectorSymptoms() throws {
        let cases = try loadFixture("corrector_symptoms", as: [SymptomCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let terms = c.terms.map { VocabTerm(text: $0.text, aliases: $0.aliases ?? []) }
            if let expected = c.expectDetectionCount {
                let found = VocabularyCorrector.detections(in: c.transcript, terms: terms, language: c.language)
                XCTAssertEqual(found.count, expected, "symptom[\(c.name)] detection count")
            }
            let result = VocabularyCorrector.correct(
                transcript: c.transcript, terms: terms, language: c.language,
                commonWords: BundledCommonWordsProvider.shared)
            XCTAssertEqual(result.text, c.expectText, "symptom[\(c.name)] text")
        }
    }

    func testCorrectorDetectionsAreTextualWithRealWindows() {
        let found = VocabularyCorrector.detections(
            in: "talk to shriram now", terms: [VocabTerm(text: "Sriram")], language: "en")
        XCTAssertEqual(found.count, 1)
        guard let d = found.first else { return }
        XCTAssertEqual(d.wordRange, 2..<3, "the real word window, not a time fraction")
        XCTAssertFalse(d.acoustic)
        guard case .textual(let distance?) = d.evidence else {
            return XCTFail("corrector evidence must be textual with its distance")
        }
        XCTAssertEqual(distance, 1.0 / 7.0, accuracy: 1e-9)
    }

    func testEditBudgetMatchesWindows() {
        XCTAssertEqual(VocabularyCorrector.editBudget(skeletonLength: 3), 0)
        XCTAssertEqual(VocabularyCorrector.editBudget(skeletonLength: 4), 1)
        XCTAssertEqual(VocabularyCorrector.editBudget(skeletonLength: 5), 1)
        XCTAssertEqual(VocabularyCorrector.editBudget(skeletonLength: 6), 2)
        XCTAssertEqual(VocabularyCorrector.editBudget(skeletonLength: 11), 3)
        XCTAssertEqual(VocabularyCorrector.restrictedEdits(Array("maran"), Array("mraan"), budget: 1), 1,
                       "a transposition is one edit")
        XCTAssertEqual(VocabularyCorrector.restrictedEdits(Array("pavan"), Array("maran"), budget: 1), 2,
                       "abandoned past the budget → budget + 1")
    }

    // MARK: - Evidence typing (A1 / R2)

    func testLegacyDetectionInitMapsToEvidence() {
        let spotted = VocabularyGate.Detection(
            term: "Sriram", aliases: [], score: -0.4, startTime: 0, endTime: 1, acoustic: true)
        XCTAssertEqual(spotted.evidence, .acoustic(score: -0.4, confidence: nil))
        XCTAssertTrue(spotted.acoustic)
        let legacy = VocabularyGate.Detection(
            term: "Sriram", aliases: [], score: 0.9, startTime: 0, endTime: 1)
        XCTAssertEqual(legacy.evidence, .textual(distance: nil))
        XCTAssertFalse(legacy.acoustic)
        XCTAssertEqual(legacy.score, 0.9, "the legacy score is kept verbatim")
    }

    func testDetectionProposalRecordsEvidenceNotStandIns() {
        let det = VocabularyGate.Detection(
            term: "Sriram", aliases: [], evidence: .acoustic(score: -0.7, confidence: nil),
            startTime: 0.4, endTime: 0.6)
        let result = VocabularyGate.applyFromDetections(
            originalTranscript: "talk to shriram", detections: [det], totalAudioDuration: 1,
            commonWords: BundledCommonWordsProvider.shared,
            wordTimes: [WordTime(start: 0, end: 0.2), WordTime(start: 0.2, end: 0.35),
                        WordTime(start: 0.4, end: 0.6)])
        XCTAssertEqual(result.text, "talk to Sriram")
        guard let p = result.proposals.first else { return XCTFail("no proposal") }
        XCTAssertEqual(p.evidence, "acoustic")
        XCTAssertEqual(p.score, -0.7)
        XCTAssertEqual(p.confidence, 0, "no decoder confidence was measured — 0, not a stand-in 0.85")
        XCTAssertEqual(p.margin, 0)
        XCTAssertFalse(p.unsure)
    }

    func testRescoreProposalsAreAcousticWithRealScores() {
        let output = RescoreOutput(
            text: "talk to Sriram",
            replacements: [RescoreProposal(originalWord: "shriram", replacementWord: "Sriram",
                                           shouldReplace: true, replacementScore: 5.5, originalScore: 1.0)],
            wasModified: true)
        let result = VocabularyGate.apply(
            originalTranscript: "talk to shriram", output: output,
            tokenTimings: [TokenTiming(token: " shriram", confidence: 0.5)],
            commonWords: BundledCommonWordsProvider.shared)
        XCTAssertEqual(result.proposals.first?.evidence, "acoustic")
        XCTAssertEqual(result.proposals.first?.score, 5.5)
        XCTAssertEqual(result.proposals.first?.confidence, 0.5, "the real TDT confidence")
    }

    // MARK: - Placement by decoder word times (R10)

    /// Two plausible hosts. The speaker says the first "shriram" early, pauses,
    /// says the second at 2.0 s, and the recording runs on to 10 s. The spotter
    /// heard the term at 2.0–2.4 s — proportional position (0.22 of the audio)
    /// lands on the FIRST word; the decoder's word times put it on the second.
    private let twoHosts = "shriram waited then shriram"
    private let twoHostTimes = [
        WordTime(start: 0.0, end: 0.4), WordTime(start: 0.5, end: 0.9),
        WordTime(start: 1.4, end: 1.8), WordTime(start: 2.0, end: 2.4),
    ]

    func testWordTimesPlaceOnTheWordSpokenThen() {
        let det = VocabularyGate.Detection(
            term: "Sriram", aliases: [], evidence: .acoustic(score: -0.5, confidence: nil),
            startTime: 2.0, endTime: 2.4)
        let proportional = VocabularyGate.applyFromDetections(
            originalTranscript: twoHosts, detections: [det], totalAudioDuration: 10,
            commonWords: BundledCommonWordsProvider.shared)
        XCTAssertEqual(proportional.text, "Sriram waited then shriram", "the legacy rule's wrong word")
        let timed = VocabularyGate.applyFromDetections(
            originalTranscript: twoHosts, detections: [det], totalAudioDuration: 10,
            commonWords: BundledCommonWordsProvider.shared, wordTimes: twoHostTimes)
        XCTAssertEqual(timed.text, "shriram waited then Sriram")
    }

    func testWordTimesDropADetectionNoWordWasSpokenAt() {
        let det = VocabularyGate.Detection(
            term: "Sriram", aliases: [], evidence: .acoustic(score: -0.5, confidence: nil),
            startTime: 7.0, endTime: 7.4)
        let timed = VocabularyGate.applyFromDetections(
            originalTranscript: twoHosts, detections: [det], totalAudioDuration: 10,
            commonWords: BundledCommonWordsProvider.shared, wordTimes: twoHostTimes)
        XCTAssertEqual(timed.text, twoHosts, "dropped past maxTimedPlacementGap, never guessed")
        XCTAssertTrue(timed.proposals.isEmpty)
    }

    func testPassDropsAcousticWithoutWordTimesButKeepsTextual() {
        // "shreeram" is 3 edits from "Sriram" — past the corrector's budget of 2
        // but inside the gate's 0.45 — so only the spotter can reach it.
        let det = VocabularyGate.Detection(
            term: "Sriram", aliases: [], evidence: .acoustic(score: -0.5, confidence: nil),
            startTime: 2.0, endTime: 2.4)
        let terms = [VocabTerm(text: "Sriram"), VocabTerm(text: "Vineet")]
        let transcript = "vinit waited then shreeram"
        let noTimes = VocabularyPass.run(
            transcript: transcript, acoustic: [det], wordTimes: nil,
            terms: terms, correctorLanguage: "en",
            commonWords: BundledCommonWordsProvider.shared, commonWordsResource: "common-words")
        XCTAssertEqual(noTimes.text, "Vineet waited then shreeram",
                       "the corrector still runs; the acoustic hit is never placed proportionally")
        XCTAssertTrue(noTimes.proposals.allSatisfy { $0.evidence == "textual" })

        let timed = VocabularyPass.run(
            transcript: transcript, acoustic: [det], wordTimes: twoHostTimes,
            terms: terms, correctorLanguage: "en",
            commonWords: BundledCommonWordsProvider.shared, commonWordsResource: "common-words")
        XCTAssertEqual(timed.text, "Vineet waited then Sriram")
        let byWord = Dictionary(uniqueKeysWithValues: timed.proposals.map { ($0.originalWord, $0.evidence) })
        XCTAssertEqual(byWord["shreeram"], "acoustic")
        XCTAssertEqual(byWord["vinit"], "textual")
    }

    func testPassLetsASpellingMatchClaimItsWordFirst() {
        // A coarse spotter span for the wrong term covers the word; the close
        // spelling match wins it.
        let wide = VocabularyGate.Detection(
            term: "Jamy", aliases: [], evidence: .acoustic(score: -7.4, confidence: nil),
            startTime: 0.0, endTime: 2.4)
        let result = VocabularyPass.run(
            transcript: "colleague Jamul Areddi", acoustic: [wide],
            wordTimes: [WordTime(start: 0, end: 0.5), WordTime(start: 1.0, end: 1.3), WordTime(start: 1.4, end: 1.7)],
            terms: [VocabTerm(text: "Jamy"), VocabTerm(text: "Jammula")], correctorLanguage: "en",
            commonWords: BundledCommonWordsProvider.shared, commonWordsResource: "common-words")
        XCTAssertEqual(result.text, "colleague Jammula Areddi")
    }

    func testWordTimelineAlignsPiecesToTranscriptWords() {
        let pieces = [
            TimedPiece(token: "\u{2581}Hello", startTime: 0.0, endTime: 0.08),
            TimedPiece(token: "\u{2581}wor", startTime: 0.4, endTime: 0.48),
            TimedPiece(token: "ld", startTime: 0.56, endTime: 0.64),
            TimedPiece(token: ",", startTime: 0.64, endTime: 0.72),
            TimedPiece(token: "\u{2581}Sri", startTime: 1.0, endTime: 1.08),
            TimedPiece(token: "ram", startTime: 1.16, endTime: 1.24),
        ]
        let times = WordTimeline.wordTimes(for: "Hello world, Sriram", pieces: pieces)
        XCTAssertEqual(times, [
            WordTime(start: 0.0, end: 0.08), WordTime(start: 0.4, end: 0.72),
            WordTime(start: 1.0, end: 1.24),
        ])
        XCTAssertNil(WordTimeline.wordTimes(for: "something else entirely here", pieces: pieces),
                     "pieces that describe other text are refused")
    }

    // MARK: - Learning guard (A3 / R9 / R11)

    private func guardedStore(root: URL? = nil) -> CorrectionStore {
        let common = english
        return CorrectionStore(containerRoot: root, isCommonOriginal: {
            VocabularyGate.isCommonOriginal($0, commonWords: common)
        })
    }

    func testCommonOriginalNeverGetsAlwaysReplace() async {
        let store = guardedStore()
        let granted = await store.grantAlwaysReplace(originalWord: "name", term: "Jamy")
        XCTAssertFalse(granted)
        let confirmed = await store.confirm(originalWord: "Name,", term: "Jamy")
        XCTAssertFalse(confirmed)
        let adjusted = await store.adjust(originalWord: "chart", term: "Jot", by: 1)
        XCTAssertFalse(adjusted, "any-word-common: 'chart' is everyday")
        let multi = await store.grantAlwaysReplace(originalWord: "cloud code", term: "Claude Code")
        XCTAssertFalse(multi, "ANY common word blocks (R9), not only all-common")
        let snapshot = await store.snapshot()
        XCTAssertFalse(snapshot.contains { $0.alwaysReplace })
        XCTAssertFalse(snapshot.contains { $0.net > 0 })

        // A rare original still learns and can be granted.
        let rare = await store.grantAlwaysReplace(originalWord: "shriram", term: "Sriram")
        XCTAssertTrue(rare)
        let rareSnapshot = await store.snapshot()
        XCTAssertTrue(rareSnapshot.contains { $0.originalWord == "shriram" && $0.alwaysReplace })
    }

    func testRevertsOfCommonOriginalsAreStillRecorded() async {
        let store = guardedStore()
        let ok = await store.adjust(originalWord: "cloud", term: "Claude", by: -1)
        XCTAssertTrue(ok)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.first { $0.originalWord == "cloud" }?.net, -1)
    }

    func testLegacyCommonRulesAreNeutralizedAndMigrated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JotVocabCoreTests-\(UUID().uuidString)", isDirectory: true)
        let vocab = root.appendingPathComponent("Vocabulary", isDirectory: true)
        try FileManager.default.createDirectory(at: vocab, withIntermediateDirectories: true)
        // A ledger written before the guard existed: two common-original rules
        // (one granted), one with a revert history, and one rare rule.
        let legacy: [String: CorrectionStore.Term] = [
            "jot": .init(mappings: [
                .init(originalWord: "chart", term: "Jot", confirmations: 3, alwaysReplace: true),
                .init(originalWord: "not", term: "Jot", confirmations: 1, reverts: 1),
            ]),
            "sriram": .init(mappings: [.init(originalWord: "shriram", term: "Sriram", confirmations: 2)]),
        ]
        try JSONEncoder().encode(legacy).write(to: vocab.appendingPathComponent("corrections.json"))

        let store = guardedStore(root: root)
        let before = await store.snapshot()
        XCTAssertFalse(before.contains { $0.originalWord == "chart" && ($0.alwaysReplace || $0.net > 0) },
                       "the snapshot never hands the gate a common rule, even before migrating")
        // The gate therefore never OVERRIDE-applies it.
        let gated = VocabularyGate.applyFromDetections(
            originalTranscript: "the chart is ready",
            detections: [.init(term: "Jot", aliases: [], evidence: .textual(distance: 0.2),
                               startTime: 0, endTime: 0, wordRange: 1..<2)],
            totalAudioDuration: 0, commonWords: BundledCommonWordsProvider.shared,
            overrides: before)
        XCTAssertEqual(gated.text, "the chart is ready")

        let changed = await store.dropCommonOriginalRules()
        XCTAssertEqual(changed, 2)
        let after = await store.snapshot()
        XCTAssertNil(after.first { $0.originalWord == "chart" }, "nothing left → mapping removed")
        XCTAssertEqual(after.first { $0.originalWord == "not" }?.net, -1, "the revert history survives")
        XCTAssertEqual(after.first { $0.originalWord == "shriram" }?.net, 2, "rare rules are untouched")

        // Persisted: a fresh store over the same root reads the migrated ledger.
        let reread = await CorrectionStore(containerRoot: root).snapshot()
        XCTAssertNil(reread.first { $0.originalWord == "chart" })
    }

    func testMigrationDoesNotCountAsDoneWithoutALedger() async throws {
        let inMemory = await guardedStore().dropCommonOriginalRules()
        XCTAssertNil(inMemory, "no on-disk ledger ⇒ not done")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-migrate-\(UUID().uuidString)", isDirectory: true)
        let vocab = root.appendingPathComponent("Vocabulary", isDirectory: true)
        try FileManager.default.createDirectory(at: vocab, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not json".utf8).write(to: vocab.appendingPathComponent("corrections.json"))
        let undecodable = await guardedStore(root: root).dropCommonOriginalRules()
        XCTAssertNil(undecodable, "an undecodable ledger ⇒ not done")

        try FileManager.default.removeItem(at: vocab.appendingPathComponent("corrections.json"))
        let fresh = await guardedStore(root: root).dropCommonOriginalRules()
        XCTAssertEqual(fresh, 0, "no file yet ⇒ nothing to migrate, done")
    }

    // MARK: - Asks (A5 / R9)

    private func record(_ original: String, _ term: String, outcome: String,
                        evidence: String?, start: Int) -> CorrectionProvenance.Record {
        CorrectionProvenance.Record(
            originalWord: original, term: term, decision: outcome == "applied" ? "APPLY" : "BLOCK",
            outcome: outcome, confidence: 0, margin: 0, unsure: false, occurrenceIndex: 0,
            originalStart: start, originalLength: original.count, publishedStart: start,
            publishedLength: term.count, evidence: evidence)
    }

    func testAsksNeverTeachACommonOriginalButStillUndoAnApply() {
        let keptCommon = record("cloud", "Claude", outcome: "kept", evidence: "acoustic", start: 0)
        let appliedCommon = record("cloud code", "Claude Code", outcome: "applied", evidence: "acoustic", start: 10)
        let overrides = [CorrectionStore.OverrideEntry(originalWord: "cloud", term: "Claude", net: 1)]
        let selected = AskPolicy.select(
            unresolved: [keptCommon, appliedCommon], overrides: overrides,
            keyboardSuppressed: [], mergeAsked: [],
            isCommonOriginal: { VocabularyGate.isCommonOriginal($0, commonWords: self.english) })
        XCTAssertEqual(selected.map(\.record.originalWord), ["cloud code"])
        // Without the predicate the legacy behaviour is unchanged.
        let legacy = AskPolicy.select(
            unresolved: [keptCommon, appliedCommon], overrides: overrides,
            keyboardSuppressed: [], mergeAsked: [])
        XCTAssertEqual(Set(legacy.map(\.record.originalWord)), ["cloud", "cloud code"])
    }

    func testAsksRankWeakestEvidenceFirst() {
        let records = [
            record("shriram", "Sriram", outcome: "applied", evidence: "acoustic", start: 0),
            record("vinit", "Vineet", outcome: "applied", evidence: "textual", start: 10),
            record("kubetes", "kubernetes", outcome: "applied", evidence: "acoustic", start: 20),
            record("sulagna", "Sulogna", outcome: "applied", evidence: "textual", start: 30),
        ]
        let selected = AskPolicy.select(
            unresolved: records, overrides: [], keyboardSuppressed: [], mergeAsked: [])
        XCTAssertEqual(selected.map(\.record.originalWord), ["vinit", "sulagna", "shriram"],
                       "textual first, then transcript order, capped at 3")
    }

    // MARK: - Vocabulary hygiene (A4)

    func testHygieneWarnsOnCommonFirstWordAndFunctionWordPrefix() {
        let words = english
        XCTAssertEqual(VocabularyHygiene.warning(for: "Andalamma", commonWords: words, language: "en")?.kind,
                       .commonPrefix("and"))
        XCTAssertEqual(VocabularyHygiene.warning(for: "codex", commonWords: words, language: "en")?.kind,
                       .commonFirstWord("codex"))
        XCTAssertNil(VocabularyHygiene.warning(for: "Sriram", commonWords: words, language: "en"),
                     "a syllable that happens to be in the 24k list is not a warning")
        XCTAssertNil(VocabularyHygiene.warning(for: "Andalamma", commonWords: [], language: "es"),
                     "the prefix rule is English-only")
    }
}
