import XCTest
@testable import JotVocabCore

/// Golden-fixture conformance suite for `JotVocabCore` (Phase B). Each JSON file
/// under `Fixtures/` is an input→expected contract fed through the PUBLIC package
/// API — the cross-platform conformance contract (same role as
/// `JotTextPipelineTests/Fixtures`). `vocabulary_gate_decide.json` also IS the
/// former standalone 16-case vocab-gate harness (scratchpad `vocab-gate-test/`),
/// now a real XCTest suite against the package rather than a stub executable.
final class GoldenFixtureTests: XCTestCase {

    // MARK: - Fixture loading

    private func loadFixture<T: Decodable>(_ file: String, as type: T.Type) throws -> T {
        guard let url = Bundle.module.url(
            forResource: file, withExtension: "json", subdirectory: "Fixtures"
        ) else {
            XCTFail("Missing fixture: \(file).json")
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JotVocabCoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Test sink that records every emitted (category, message) under a lock.
    private final class CapturingSink: DiagnosticsSink, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(DiagnosticsCategory, String)] = []
        func record(category: DiagnosticsCategory, message: String, metadata: [String: String]) {
            lock.lock(); events.append((category, message)); lock.unlock()
        }
        var categories: [DiagnosticsCategory] {
            lock.lock(); defer { lock.unlock() }; return events.map(\.0)
        }
    }

    // MARK: - 1 · CorrectionKey.normalize

    private struct StringCase: Decodable { let name: String; let input: String; let expected: String }

    func testCorrectionKeyNormalizeGolden() throws {
        let cases = try loadFixture("correction_key_normalize", as: [StringCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(
                CorrectionKey.normalize(c.input), c.expected,
                "correction_key_normalize[\(c.name)] input=\(c.input.debugDescription)")
        }
    }

    // MARK: - 2 · VocabularyGate.apply (subsumes the 16-case harness)

    private struct RescoreProposalFixture: Decodable {
        let originalWord: String
        let replacementWord: String?
        let shouldReplace: Bool
        let replacementScore: Float?
        let originalScore: Float
    }
    private struct TokenTimingFixture: Decodable { let token: String; let confidence: Float }
    private struct OverrideFixture: Decodable {
        let originalWord: String; let term: String; let net: Int; let paused: Bool?
    }
    private struct AlternateFixture: Decodable { let term: String; let find: String }
    private struct ExpectProposalFixture: Decodable {
        let originalWord: String
        let shape: String?
        let alternates: [AlternateFixture]?
        let askCandidate: Bool?
    }
    private struct GateCase: Decodable {
        let name: String
        let transcript: String
        let replacements: [RescoreProposalFixture]
        let tokenTimings: [TokenTimingFixture]?
        let overrides: [OverrideFixture]?
        let aliases: [String: [String]]?
        let allTerms: [String]?
        let commonWordsResource: String?
        let expectText: String
        let expectOutcomes: [String: String]?
        let expectProposals: [ExpectProposalFixture]?
    }

    func testVocabularyGateDecideGolden() throws {
        let cases = try loadFixture("vocabulary_gate_decide", as: [GateCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let reps = c.replacements.map {
                RescoreProposal(
                    originalWord: $0.originalWord, replacementWord: $0.replacementWord,
                    shouldReplace: $0.shouldReplace, replacementScore: $0.replacementScore,
                    originalScore: $0.originalScore)
            }
            let out = RescoreOutput(text: c.transcript, replacements: reps, wasModified: true)
            let timings = (c.tokenTimings ?? []).map { TokenTiming(token: $0.token, confidence: $0.confidence) }
            let overrides = (c.overrides ?? []).map {
                CorrectionStore.OverrideEntry(
                    originalWord: $0.originalWord, term: $0.term, net: $0.net, paused: $0.paused ?? false)
            }
            let result = VocabularyGate.apply(
                originalTranscript: c.transcript, output: out, tokenTimings: timings,
                commonWords: BundledCommonWordsProvider.shared,
                overrides: overrides, termAliases: c.aliases ?? [:],
                commonWordsResource: c.commonWordsResource ?? "common-words",
                allTerms: c.allTerms ?? [])

            XCTAssertEqual(result.text, c.expectText, "gate[\(c.name)] text")
            for (ow, expected) in c.expectOutcomes ?? [:] {
                let p = result.proposals.first { $0.originalWord.lowercased() == ow }
                XCTAssertEqual(p?.outcome, expected, "gate[\(c.name)] outcome[\(ow)]")
            }
            for ep in c.expectProposals ?? [] {
                guard let p = result.proposals.first(where: { $0.originalWord.lowercased() == ep.originalWord.lowercased() }) else {
                    XCTFail("gate[\(c.name)] missing proposal for \(ep.originalWord)"); continue
                }
                if let shape = ep.shape { XCTAssertEqual(p.shape, shape, "gate[\(c.name)] shape") }
                if let ask = ep.askCandidate { XCTAssertEqual(p.askCandidate, ask, "gate[\(c.name)] askCandidate") }
                if let alts = ep.alternates {
                    XCTAssertEqual(p.alternates.count, alts.count, "gate[\(c.name)] alt count")
                    for (i, a) in alts.enumerated() where i < p.alternates.count {
                        XCTAssertEqual(p.alternates[i].term, a.term, "gate[\(c.name)] alt[\(i)].term")
                        XCTAssertEqual(p.alternates[i].find, a.find, "gate[\(c.name)] alt[\(i)].find")
                    }
                }
            }
        }
    }

    // MARK: - 3 · CorrectionStore round-trip + decode-failure guard

    private struct StoreOp: Decodable {
        let op: String
        let originalWord: String?
        let term: String?
        let delta: Int?
    }
    private struct SnapshotExpect: Decodable {
        let originalWord: String; let term: String; let net: Int; let paused: Bool?
    }
    private struct StoreCase: Decodable {
        let name: String
        let initialJSON: String
        let operations: [StoreOp]
        let expectSnapshot: [SnapshotExpect]?
        let expectKeyboardSuppressed: [String]?
        let expectMergeAsked: [String]?
        let expectFileContains: [String]?
        let expectFileUnchanged: Bool?
        let expectDiagnosticsCategory: String?
    }

    func testCorrectionStoreRoundtripGolden() async throws {
        let cases = try loadFixture("correction_store_roundtrip", as: [StoreCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let root = makeTempRoot()
            let vocabDir = root.appendingPathComponent("Vocabulary", isDirectory: true)
            try FileManager.default.createDirectory(at: vocabDir, withIntermediateDirectories: true)
            let fileURL = vocabDir.appendingPathComponent("corrections.json")
            try c.initialJSON.write(to: fileURL, atomically: true, encoding: .utf8)

            let sink = CapturingSink()
            let store = CorrectionStore(containerRoot: root, diagnostics: sink)
            for op in c.operations {
                let ow = op.originalWord ?? ""
                let term = op.term ?? ""
                switch op.op {
                case "confirm": await store.confirm(originalWord: ow, term: term)
                case "revert": await store.revert(originalWord: ow, term: term)
                case "adjust": await store.adjust(originalWord: ow, term: term, by: op.delta ?? 0)
                case "suppressBlock": await store.suppressBlock(originalWord: ow, term: term)
                case "noteBlockedKeep": await store.noteBlockedKeep(originalWord: ow, term: term)
                case "clearBlockedKeep": await store.clearBlockedKeep(originalWord: ow, term: term)
                case "noteMergeAsked": await store.noteMergeAsked(originalWord: ow, term: term)
                default: XCTFail("store[\(c.name)] unknown op \(op.op)")
                }
            }

            if let expect = c.expectSnapshot {
                let snap = await store.snapshot()
                for e in expect {
                    let m = snap.first { $0.originalWord == CorrectionKey.normalize(e.originalWord) && $0.term == e.term }
                    XCTAssertNotNil(m, "store[\(c.name)] snapshot missing \(e.originalWord)→\(e.term)")
                    XCTAssertEqual(m?.net, e.net, "store[\(c.name)] net")
                    XCTAssertEqual(m?.paused, e.paused ?? false, "store[\(c.name)] paused")
                }
            }
            if let expect = c.expectKeyboardSuppressed {
                let got = await store.keyboardSuppressedPairs()
                XCTAssertEqual(got, Set(expect), "store[\(c.name)] keyboardSuppressed")
            }
            if let expect = c.expectMergeAsked {
                let got = await store.mergeAskedPairs()
                XCTAssertEqual(got, Set(expect), "store[\(c.name)] mergeAsked")
            }
            if c.expectFileUnchanged == true {
                let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
                XCTAssertEqual(onDisk, c.initialJSON, "store[\(c.name)] file must be UNCHANGED (no overwrite)")
            }
            if let contains = c.expectFileContains {
                let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
                for needle in contains {
                    XCTAssertTrue(onDisk.contains(needle), "store[\(c.name)] persisted file should contain \(needle)")
                }
            }
            if let cat = c.expectDiagnosticsCategory {
                let expected: DiagnosticsCategory = (cat == "vocabularySaveFailed") ? .vocabularySaveFailed : .vocabularyGate
                XCTAssertTrue(sink.categories.contains(expected), "store[\(c.name)] should emit \(cat)")
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 4 · CorrectionProvenance (mapOffsets + verdict deltas)

    private struct MapOffsetsCase: Decodable {
        let name: String; let offsets: [Int]; let old: String; let new: String; let expected: [Int]
    }
    private struct VerdictOp: Decodable { let op: String; let recordKey: String; let verdict: String? }
    private struct DeltaExpect: Decodable { let originalWord: String; let term: String; let delta: Int }
    private struct VerdictCase: Decodable {
        let name: String
        let seedPayloadJSON: String
        let operations: [VerdictOp]
        let expectDeltas: [[DeltaExpect]]
    }
    private struct ProvenanceFixture: Decodable {
        let mapOffsets: [MapOffsetsCase]
        let verdicts: [VerdictCase]
    }

    func testProvenanceMapOffsetsGolden() throws {
        let fixture = try loadFixture("provenance_verdicts", as: ProvenanceFixture.self)
        XCTAssertFalse(fixture.mapOffsets.isEmpty)
        for c in fixture.mapOffsets {
            XCTAssertEqual(
                CorrectionProvenance.mapOffsets(c.offsets, old: c.old, new: c.new), c.expected,
                "mapOffsets[\(c.name)]")
        }
    }

    func testProvenanceVerdictDeltasGolden() async throws {
        let fixture = try loadFixture("provenance_verdicts", as: ProvenanceFixture.self)
        XCTAssertFalse(fixture.verdicts.isEmpty)
        for c in fixture.verdicts {
            let root = makeTempRoot()
            let provDir = root.appendingPathComponent("Vocabulary/provenance", isDirectory: true)
            try FileManager.default.createDirectory(at: provDir, withIntermediateDirectories: true)
            let id = UUID()
            let fileURL = provDir.appendingPathComponent("\(id.uuidString).json")
            try c.seedPayloadJSON.write(to: fileURL, atomically: true, encoding: .utf8)

            let prov = CorrectionProvenance(containerRoot: root)
            for (i, op) in c.operations.enumerated() {
                let payload = await prov.payload(transcriptID: id)
                guard let record = payload.records.first(where: { $0.key == op.recordKey }) else {
                    XCTFail("provenance[\(c.name)] no record for key \(op.recordKey)"); continue
                }
                let deltas: [CorrectionProvenance.MappingDelta]
                switch op.op {
                case "setVerdict": deltas = await prov.setVerdict(transcriptID: id, record: record, verdict: op.verdict ?? "")
                case "clearVerdict": deltas = await prov.clearVerdict(transcriptID: id, record: record)
                default: XCTFail("provenance[\(c.name)] unknown op \(op.op)"); continue
                }
                let expected = c.expectDeltas[i]
                XCTAssertEqual(deltas.count, expected.count, "provenance[\(c.name)] op\(i) delta count")
                for (j, e) in expected.enumerated() where j < deltas.count {
                    XCTAssertEqual(deltas[j].originalWord, e.originalWord, "provenance[\(c.name)] op\(i) delta[\(j)].originalWord")
                    XCTAssertEqual(deltas[j].term, e.term, "provenance[\(c.name)] op\(i) delta[\(j)].term")
                    XCTAssertEqual(deltas[j].delta, e.delta, "provenance[\(c.name)] op\(i) delta[\(j)].delta")
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 5 · AskPolicy.select

    private struct AskOverrideFixture: Decodable {
        let originalWord: String; let term: String; let net: Int; let paused: Bool?
    }
    private struct AskExpect: Decodable {
        let originalWord: String; let isMergeTeach: Bool; let altTerm: String?; let altFind: String?
    }
    private struct AskCase: Decodable {
        let name: String
        let records: [CorrectionProvenance.Record]
        let overrides: [AskOverrideFixture]
        let keyboardSuppressed: [String]
        let mergeAsked: [String]
        let expectSelected: [AskExpect]
    }

    func testAskPolicySelectGolden() throws {
        let cases = try loadFixture("ask_policy_select", as: [AskCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let overrides = c.overrides.map {
                CorrectionStore.OverrideEntry(
                    originalWord: $0.originalWord, term: $0.term, net: $0.net, paused: $0.paused ?? false)
            }
            let selected = AskPolicy.select(
                unresolved: c.records, overrides: overrides,
                keyboardSuppressed: Set(c.keyboardSuppressed), mergeAsked: Set(c.mergeAsked))

            XCTAssertEqual(selected.count, c.expectSelected.count, "askpolicy[\(c.name)] count")
            for (i, e) in c.expectSelected.enumerated() where i < selected.count {
                XCTAssertEqual(selected[i].record.originalWord, e.originalWord, "askpolicy[\(c.name)][\(i)] originalWord")
                XCTAssertEqual(selected[i].isMergeTeach, e.isMergeTeach, "askpolicy[\(c.name)][\(i)] isMergeTeach")
                XCTAssertEqual(selected[i].altTerm, e.altTerm, "askpolicy[\(c.name)][\(i)] altTerm")
                XCTAssertEqual(selected[i].altFind, e.altFind, "askpolicy[\(c.name)][\(i)] altFind")
            }
        }
    }

    // MARK: - CorrectionKey.pairKey (membership-key shape)

    private struct PairKeyCase: Decodable {
        let name: String; let originalWord: String; let term: String; let expected: String
    }

    func testCorrectionPairKeyGolden() throws {
        let cases = try loadFixture("pair_key", as: [PairKeyCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(
                CorrectionKey.pairKey(originalWord: c.originalWord, term: c.term), c.expected,
                "pair_key[\(c.name)]")
        }
    }

    // MARK: - VocabularyCorrector (§1 — the model-free 19-language corrector)

    private struct CorrectorTermFixture: Decodable {
        let text: String; let aliases: [String]?
    }
    private struct CorrectorCase: Decodable {
        let name: String
        let transcript: String
        let language: String
        let terms: [CorrectorTermFixture]
        let expectText: String
        let expectProposals: [DetectionExpectProposal]?
        let expectProposalCount: Int?
        let expectDetectionCount: Int?
    }

    func testVocabularyCorrectorGolden() throws {
        let cases = try loadFixture("corrector_apply", as: [CorrectorCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let terms = c.terms.map { VocabTerm(text: $0.text, aliases: $0.aliases ?? []) }
            if let expected = c.expectDetectionCount {
                let found = VocabularyCorrector.detections(
                    in: c.transcript, terms: terms, language: c.language)
                XCTAssertEqual(found.count, expected, "corrector[\(c.name)] detection count")
            }
            let result = VocabularyCorrector.correct(
                transcript: c.transcript, terms: terms, language: c.language,
                commonWords: BundledCommonWordsProvider.shared)

            XCTAssertEqual(result.text, c.expectText, "corrector[\(c.name)] text")
            if let count = c.expectProposalCount {
                XCTAssertEqual(result.proposals.count, count, "corrector[\(c.name)] proposal count")
            }
            for ep in c.expectProposals ?? [] {
                guard let p = result.proposals.first(where: {
                    $0.originalWord.lowercased() == ep.originalWord.lowercased()
                }) else {
                    XCTFail("corrector[\(c.name)] missing proposal for \(ep.originalWord)"); continue
                }
                XCTAssertEqual(p.outcome, ep.outcome, "corrector[\(c.name)] outcome")
                if let ask = ep.askCandidate {
                    XCTAssertEqual(p.askCandidate, ask, "corrector[\(c.name)] askCandidate")
                }
            }
        }
    }

    /// The language table IS the deliverable of §1 — "shipping to 19 languages on
    /// an English measurement would have been unsafe". This pins its shape, and
    /// pins that every served language actually has the frequency list its safety
    /// depends on: a served language whose list is missing would run with the
    /// common-word brake ABSENT, which is the one thing §1.1 forbids outright.
    func testCorrectorLanguageTableIntegrity() throws {
        XCTAssertEqual(VocabularyCorrector.supported.count, 19, "the 19-language capability")

        let uncapped = VocabularyCorrector.supported.filter { $0.value.maxDistance == nil }
        XCTAssertEqual(Set(uncapped.keys),
                       ["en", "cs", "da", "es", "fi", "fr", "hu", "it", "nl", "pt", "ro", "sk", "sv"],
                       "uncapped languages (E6)")
        XCTAssertEqual(VocabularyCorrector.supported["bg"]?.maxDistance, 0.25)
        XCTAssertEqual(VocabularyCorrector.supported["de"]?.maxDistance, 0.15, "tightest shipped cap")
        for code in ["el", "pl", "ru", "uk"] {
            XCTAssertEqual(VocabularyCorrector.supported[code]?.maxDistance, 0.20, "\(code) cap")
        }

        // Every served language's brake must actually load.
        for code in VocabularyCorrector.supported.keys {
            let resource = VocabularyCorrector.commonWordsResource(for: code)
            XCTAssertNotNil(resource, "\(code) resource name")
            let words = BundledCommonWordsProvider.shared.words(forResource: resource)
            XCTAssertGreaterThan(words.count, 1000, "\(code) frequency list must actually load")
        }

        // Deliberate absences, each for a DIFFERENT reason — all four are
        // decisions someone will otherwise "fix".
        for code in ["sl", "sr", "hr", "ar", "xx"] {
            XCTAssertFalse(VocabularyCorrector.isServed(code), "\(code) must not be served")
            XCTAssertNotNil(VocabularyCorrector.unservedReason(code), "\(code) needs a recorded reason")
        }
        XCTAssertNil(VocabularyCorrector.unservedReason("en"))
        // §1.2 — fail closed, at the TIGHTEST value.
        XCTAssertEqual(VocabularyCorrector.acceptanceDistance(for: "xx"),
                       VocabularyCorrector.unmeasuredMaxDistance)
        // Locale identifiers must not fall off the table.
        XCTAssertTrue(VocabularyCorrector.isServed("es-MX"))
        XCTAssertTrue(VocabularyCorrector.isServed("pt_BR"))
        XCTAssertEqual(VocabularyCorrector.commonWordsResource(for: "es-MX"), "common-words-es")
        XCTAssertEqual(VocabularyCorrector.commonWordsResource(for: "en-GB"), "common-words")
    }

    /// §5 is a CONJUNCTION of two arms, and the spec is emphatic that neither is
    /// safe alone — firing on the structural shape by itself destroys 30 real
    /// corrections to prevent 33 bad ones. A pipeline fixture can only show the
    /// pair firing together, so pin each arm independently here, using the
    /// spec's own German example.
    func testInflectionGuardRequiresBothArms() {
        let resource = "test-inflection-\(#function)"
        let everyday: Set<String> = ["gewürzte", "abläufe", "kurz"]

        // BOTH arms: stem "gewürz" (6), tails "ten"/"en" (3 and 2), span is 9
        // scalars and is "gewürzte" widened by one trailing character.
        XCTAssertTrue(
            VocabularyGate.inflectionOverwrite(
                span: "gewürzten", term: "Gewürzen",
                commonWords: everyday, resource: resource),
            "both arms satisfied → block")

        // STRUCTURAL only — the span is nowhere near the frequency list.
        XCTAssertFalse(
            VocabularyGate.inflectionOverwrite(
                span: "zzzürzten", term: "Zzzürzen",
                commonWords: everyday, resource: resource),
            "structural alone must NOT block")

        // LEXICAL only — same span, but the term shares no stem with it.
        XCTAssertFalse(
            VocabularyGate.inflectionOverwrite(
                span: "gewürzten", term: "Paprika",
                commonWords: everyday, resource: resource),
            "lexical alone must NOT block")

        // The ≥7-scalar floor.
        XCTAssertFalse(
            VocabularyGate.inflectionOverwrite(
                span: "kurzy", term: "Kurzi",
                commonWords: everyday, resource: resource),
            "under the 7-scalar floor must NOT block")

        // A tail longer than 3 either side is a different word, not an inflection.
        XCTAssertFalse(
            VocabularyGate.inflectionOverwrite(
                span: "gewürzten", term: "Gewürabcde",
                commonWords: everyday, resource: resource),
            "tail > 3 must NOT block")

        // No resource ⇒ no frequency list ⇒ the lexical arm cannot be evaluated,
        // so the guard must fail SAFE (not block) rather than guess.
        XCTAssertFalse(
            VocabularyGate.inflectionOverwrite(
                span: "gewürzten", term: "Gewürzen",
                commonWords: everyday, resource: nil),
            "no resource → cannot evaluate the lexical arm → do not block")
    }

    // MARK: - VocabularyGate.applyFromDetections (Mac no-fork path)

    private struct DetectionFixture: Decodable {
        let term: String; let aliases: [String]; let score: Float
        let startTime: TimeInterval; let endTime: TimeInterval
        /// §6 — omitted means `false`, matching `Detection`'s own default.
        let acoustic: Bool?
    }
    private struct DetectionExpectProposal: Decodable {
        let originalWord: String; let outcome: String; let askCandidate: Bool?
    }
    private struct DetectionCase: Decodable {
        let name: String
        let transcript: String
        let totalAudioDuration: TimeInterval
        let detections: [DetectionFixture]
        let overrides: [OverrideFixture]?
        let commonWordsResource: String?
        let expectText: String
        let expectProposals: [DetectionExpectProposal]?
        let expectProposalCount: Int?
    }

    func testApplyFromDetectionsGolden() throws {
        let cases = try loadFixture("detections_apply", as: [DetectionCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let dets = c.detections.map {
                VocabularyGate.Detection(
                    term: $0.term, aliases: $0.aliases, score: $0.score,
                    startTime: $0.startTime, endTime: $0.endTime,
                    acoustic: $0.acoustic ?? false)
            }
            let overrides = (c.overrides ?? []).map {
                CorrectionStore.OverrideEntry(
                    originalWord: $0.originalWord, term: $0.term, net: $0.net, paused: $0.paused ?? false)
            }
            let result = VocabularyGate.applyFromDetections(
                originalTranscript: c.transcript, detections: dets,
                totalAudioDuration: c.totalAudioDuration,
                commonWords: BundledCommonWordsProvider.shared,
                commonWordsResource: c.commonWordsResource ?? "common-words",
                overrides: overrides)

            XCTAssertEqual(result.text, c.expectText, "detections[\(c.name)] text")
            if let count = c.expectProposalCount {
                XCTAssertEqual(result.proposals.count, count, "detections[\(c.name)] proposal count")
            }
            for ep in c.expectProposals ?? [] {
                guard let p = result.proposals.first(where: { $0.originalWord.lowercased() == ep.originalWord.lowercased() }) else {
                    XCTFail("detections[\(c.name)] missing proposal for \(ep.originalWord)"); continue
                }
                XCTAssertEqual(p.outcome, ep.outcome, "detections[\(c.name)] outcome")
                if let ask = ep.askCandidate { XCTAssertEqual(p.askCandidate, ask, "detections[\(c.name)] askCandidate") }
            }
        }
    }

    // MARK: - Byte-agreement: store produce-key == AskPolicy check-key (finding 2)

    /// The produce-key / check-key invariant in ONE case: pipe the store's
    /// `keyboardSuppressedPairs()` output DIRECTLY into `AskPolicy.select`'s
    /// `keyboardSuppressed` and assert suppression actually fires. If the two
    /// ever normalized the pair key differently, the record would leak through as
    /// an ask — this pins that they agree byte-for-byte through `CorrectionKey.pairKey`.
    func testKeyboardSuppressionByteAgreement() async throws {
        let store = CorrectionStore(containerRoot: nil)   // in-memory
        // Suppress a blocked pair the way the app does: "Stop asking" on a
        // punctuated, mixed-case original so normalization is actually exercised.
        await store.suppressBlock(originalWord: "Cloud.", term: "Claude")
        let suppressed = await store.keyboardSuppressedPairs()
        XCTAssertEqual(suppressed, ["cloud|claude"], "store produce-key shape")

        // An unresolved APPLIED record for the SAME pair (differently cased/
        // punctuated original) — would be worth asking if not suppressed.
        let record = CorrectionProvenance.Record(
            originalWord: "cloud", term: "Claude", decision: "APPLY", outcome: "applied",
            confidence: 0.85, margin: 3.5, unsure: false, occurrenceIndex: 0,
            originalStart: 0, originalLength: 5, publishedStart: 0, publishedLength: 6)

        // Sanity: WITHOUT the suppressed set it IS selected.
        let unsuppressed = AskPolicy.select(
            unresolved: [record], overrides: [], keyboardSuppressed: [], mergeAsked: [])
        XCTAssertEqual(unsuppressed.count, 1, "control: applied record is worth asking")

        // WITH the store's own output piped in, suppression fires (check-key ==
        // produce-key). A mismatch here would leave count == 1.
        let selected = AskPolicy.select(
            unresolved: [record], overrides: [], keyboardSuppressed: suppressed, mergeAsked: [])
        XCTAssertTrue(selected.isEmpty, "keyboardSuppressedPairs() must suppress via AskPolicy (byte agreement)")
    }

    // MARK: - Loud common-words provider (finding 1)

    /// A non-nil resource whose `.txt` is missing must emit a diagnostic (the
    /// common-word brake silently disabling is the over-correction hazard), while
    /// a `nil` resource is intentional and stays silent.
    func testBundledCommonWordsProviderFailsLoudly() {
        let sink = CapturingSink()
        let provider = BundledCommonWordsProvider(diagnostics: sink)

        // Bogus resource → empty set + a loud diagnostic.
        let missing = provider.words(forResource: "common-words-NOPE")
        XCTAssertTrue(missing.isEmpty)
        XCTAssertTrue(sink.categories.contains(.vocabularyGate),
                      "missing dictionary resource must emit a diagnostic")

        // nil resource → intentional no-guard, NO diagnostic added.
        let before = sink.categories.count
        let none = provider.words(forResource: nil)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(sink.categories.count, before, "nil resource is silent (intentional no-guard)")

        // A real resource loads non-empty and stays silent.
        let real = provider.words(forResource: "common-words")
        XCTAssertFalse(real.isEmpty, "real English list should load")
        XCTAssertEqual(sink.categories.count, before, "successful load emits nothing")
    }

    // MARK: - VocabularyFile round-trip

    func testVocabularyFileRoundTrip() {
        let body = "UJET: you jet, ew jet\nOsiris\n# a comment\nD'Andre: dandre, dahndray\nParakeet\n"
        let terms = VocabularyFile.parse(body)
        XCTAssertEqual(terms.map(\.text), ["UJET", "Osiris", "D'Andre", "Parakeet"])
        XCTAssertEqual(terms[0].aliases, ["you jet", "ew jet"])
        XCTAssertEqual(terms[3].aliases, [])
        // Re-serialize → re-parse is stable.
        let round = VocabularyFile.parse(VocabularyFile.serialize(terms))
        XCTAssertEqual(round.map(\.text), terms.map(\.text))
        XCTAssertEqual(round.map(\.aliases), terms.map(\.aliases))
    }

    // MARK: - PasteEditResolver (F3 — exact paste-edit spans)

    private struct ResolveCase: Decodable {
        let name: String
        let baseline: String
        let needle: String
        let anchor: Int
        let contextBefore: String
        let contextAfter: String
        let primaryLengthInNeedle: Int?
        /// Both null = the edit is NOT honorable and must fail safe.
        let expectStart: Int?
        let expectText: String?
    }

    func testPasteEditResolveGolden() throws {
        let cases = try loadFixture("paste_edit_resolve", as: [ResolveCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let span = PasteEditResolver.resolve(
                needle: c.needle, anchoredAt: c.anchor, in: c.baseline,
                contextBefore: c.contextBefore, contextAfter: c.contextAfter,
                primaryLengthInNeedle: c.primaryLengthInNeedle)
            guard let expectStart = c.expectStart, let expectText = c.expectText else {
                XCTAssertNil(span, "paste_edit_resolve[\(c.name)] must fail safe")
                continue
            }
            XCTAssertEqual(span?.start, expectStart, "paste_edit_resolve[\(c.name)] start")
            XCTAssertEqual(span?.text, expectText, "paste_edit_resolve[\(c.name)] text")
            // The descriptor's whole point: the consumer can re-derive the exact
            // substring from (start, text.count) against its own baseline copy.
            if let span {
                let chars = Array(c.baseline)
                XCTAssertEqual(span.end, span.start + span.text.count,
                               "paste_edit_resolve[\(c.name)] end")
                XCTAssertEqual(String(chars[span.start..<span.end]), span.text,
                               "paste_edit_resolve[\(c.name)] substring agreement")
            }
        }
    }

    private struct OverlapCase: Decodable {
        let name: String
        let ranges: [[Int]]
        let expected: Bool
    }

    func testPasteEditOverlapGolden() throws {
        let cases = try loadFixture("paste_edit_overlap", as: [OverlapCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let ranges = c.ranges.map { $0[0]..<$0[1] }
            XCTAssertEqual(PasteEditResolver.hasOverlap(ranges), c.expected,
                           "paste_edit_overlap[\(c.name)]")
            // Pairwise `overlaps` must agree with the batch check.
            var pairwise = false
            for i in ranges.indices {
                for j in ranges.indices where j > i && PasteEditResolver.overlaps(ranges[i], ranges[j]) {
                    pairwise = true
                }
            }
            XCTAssertEqual(pairwise, c.expected, "paste_edit_overlap[\(c.name)] pairwise")
        }
    }

    /// Review finding 8's concrete shape: an alternate's `find` deliberately
    /// widens through the FOLLOWING words, so it can cover a separate ask's word.
    /// The two spans resolve individually — only interval validation catches it.
    func testAlternateSpanCanCoverTheNextAsk() {
        let baseline = "I use Claude code daily"
        let alt = PasteEditResolver.resolve(
            needle: "Claude code", anchoredAt: 6, in: baseline,
            contextBefore: "I use ", contextAfter: " daily", primaryLengthInNeedle: 6)
        let next = PasteEditResolver.resolve(
            needle: "code", anchoredAt: 13, in: baseline,
            contextBefore: "I use Claude ", contextAfter: " daily")
        XCTAssertNotNil(alt)
        XCTAssertNotNil(next)
        guard let alt, let next else { return }
        XCTAssertTrue(PasteEditResolver.overlaps(alt.range, next.range),
                      "the alternate's widened span covers the following ask's word")
        XCTAssertTrue(PasteEditResolver.hasOverlap([alt.range, next.range]))
    }

    private struct ApplyCase: Decodable {
        struct E: Decodable { let start: Int; let end: Int; let text: String }
        let name: String
        let baseline: String
        let edits: [E]
        /// null = the batch must be rejected WHOLE (overlapping, degenerate, or
        /// out of bounds) — never half-applied.
        let expected: String?
    }

    func testPasteEditApplyGolden() throws {
        let cases = try loadFixture("paste_edit_apply", as: [ApplyCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let edits = c.edits.map {
                PasteEditResolver.Replacement(start: $0.start, end: $0.end, text: $0.text)
            }
            let got = PasteEditResolver.apply(edits, to: Array(c.baseline))
            XCTAssertEqual(got, c.expected, "paste_edit_apply[\(c.name)]")
        }
    }

    /// Closing note 1 — the degenerate-span guard. An empty range replaces
    /// nothing, is invisible to `overlaps`/`hasOverlap`, and would therefore
    /// ship as an unvalidated INSERT. `resolve` must never produce one, `verify`
    /// must never accept one, and `apply` must reject a batch containing one.
    func testDegenerateSpansCannotExist() throws {
        // 1. resolve: every honorable span replaces at least one character.
        for c in try loadFixture("paste_edit_resolve", as: [ResolveCase].self) {
            let span = PasteEditResolver.resolve(
                needle: c.needle, anchoredAt: c.anchor, in: c.baseline,
                contextBefore: c.contextBefore, contextAfter: c.contextAfter,
                primaryLengthInNeedle: c.primaryLengthInNeedle)
            if let span {
                XCTAssertTrue(span.isWellFormed, "paste_edit_resolve[\(c.name)] degenerate span")
            }
        }
        // Needles that trim to nothing can never resolve a span.
        for needle in ["", " ", ".", "\u{201D})]}"] {
            XCTAssertNil(PasteEditResolver.resolve(
                needle: PasteEditResolver.trimGatedWord(needle), anchoredAt: 0,
                in: "I met Jamy at noon.", contextBefore: "", contextAfter: ""),
                "needle \"\(needle)\" must not resolve")
        }
        // 2. verify: a zero-length descriptor is refused even though its start
        //    is in range and its (empty) text trivially "matches".
        let baseline = Array("I met Jamy at noon.")
        XCTAssertNil(PasteEditResolver.verify(start: 6, text: "", in: baseline))
        XCTAssertNotNil(PasteEditResolver.verify(start: 6, text: "Jamy", in: baseline))
        // Case-SENSITIVE: the descriptor carries the baseline's own casing, so a
        // casing difference means the two sides hold different strings (D2a).
        XCTAssertNil(PasteEditResolver.verify(start: 6, text: "jamy", in: baseline))
        // 3. An empty range conflicts with nothing — which is exactly why it
        //    must never reach the overlap validation as a real edit.
        XCTAssertFalse(PasteEditResolver.overlaps(6..<6, 0..<19))
        XCTAssertFalse(PasteEditResolver.hasOverlap([6..<6, 6..<6]))
    }

    /// A descriptor resolved against one baseline must not silently apply to a
    /// different one — the consumer's verification is `text` vs the substring at
    /// `start`, so a shifted baseline has to disagree.
    func testDescriptorFailsClosedOnAShiftedBaseline() {
        let published = "I met Jamy at noon."
        guard let span = PasteEditResolver.resolve(
            needle: "Jamy", anchoredAt: 6, in: published,
            contextBefore: "I met ", contextAfter: " at noon.")
        else { return XCTFail("expected a resolved span") }
        let shifted = Array("Well, I met Jamy at noon.")
        XCTAssertNotEqual(String(shifted[span.start..<span.end]), span.text)
    }
}
