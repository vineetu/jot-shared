import XCTest
@testable import JotTextPipeline

/// Golden-fixture conformance suite. Each JSON file under `Fixtures/` is a
/// language-neutral input→expected contract fed through the PUBLIC pipeline
/// API. These files are the cross-platform conformance contract: a future
/// non-Apple (e.g. Windows) port of the pipeline must reproduce the same
/// outputs from the same fixtures.
///
/// Provenance:
///   - `number_normalizer.json`, `filler_word_cleaner.json`,
///     `paragraph_segmenter_apply.json`, `paragraph_segmenter_reassemble.json`
///     are ported verbatim from the hand-authored mobile XCTest suites
///     (NumberNormalizerTests / FillerWordCleanerTests / ParagraphSegmenterTests).
///   - `number_normalizer_itn.json` covers the newer decimals/years/dates/
///     durations ITN work (mobile build ~269) whose behavior post-dates the
///     hand-authored NumberNormalizer suite. Its expected values are frozen
///     from current mobile `NumberNormalizer` behavior (generated-from-mobile-
///     behavior) and cross-checked against the canonical examples in
///     docs/plans/number-normalization-improvements.md.
final class GoldenFixtureTests: XCTestCase {

    // MARK: - Fixture loading

    private struct StringCase: Decodable {
        let name: String
        let input: String
        let expected: String
    }

    /// StringCase plus an optional language code. An absent `language` key
    /// deliberately decodes to `nil` so the fixture also pins the nil ⇒
    /// English default of `FillerWordCleaner.clean(_:language:)`.
    private struct LanguageStringCase: Decodable {
        let name: String
        let language: String?
        let input: String
        let expected: String
    }

    private struct WordFixture: Decodable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct TokenFixture: Decodable {
        let token: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct ApplyCase: Decodable {
        let name: String
        let words: [WordFixture]
        let text: String
        let expected: String
    }

    private struct ReassembleCase: Decodable {
        let name: String
        let tokens: [TokenFixture]
        let expectedWords: [WordFixture]
    }

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

    // MARK: - NumberNormalizer

    func testNumberNormalizerGolden() throws {
        let cases = try loadFixture("number_normalizer", as: [StringCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(
                NumberNormalizer.normalize(c.input), c.expected,
                "number_normalizer[\(c.name)] input=\(c.input.debugDescription)"
            )
        }
    }

    func testNumberNormalizerITNGolden() throws {
        let cases = try loadFixture("number_normalizer_itn", as: [StringCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(
                NumberNormalizer.normalize(c.input), c.expected,
                "number_normalizer_itn[\(c.name)] input=\(c.input.debugDescription)"
            )
        }
    }

    // MARK: - FillerWordCleaner

    func testFillerWordCleanerGolden() throws {
        let cases = try loadFixture("filler_word_cleaner", as: [StringCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(
                FillerWordCleaner.clean(c.input), c.expected,
                "filler_word_cleaner[\(c.name)] input=\(c.input.debugDescription)"
            )
        }
    }

    /// Multilingual hesitation stripping (es/de/fr/it/pt), the umlaut
    /// full-match word-boundary guard ("ähnlich" untouched), the strict
    /// identity no-op for unknown language codes, and region-subtag
    /// normalization ("de-DE" ⇒ "de").
    func testFillerWordCleanerMultilingualGolden() throws {
        let cases = try loadFixture(
            "filler_word_cleaner_multilingual", as: [LanguageStringCase].self
        )
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(
                FillerWordCleaner.clean(c.input, language: c.language), c.expected,
                "filler_word_cleaner_multilingual[\(c.name)] "
                    + "lang=\(c.language ?? "nil") input=\(c.input.debugDescription)"
            )
        }
    }

    // MARK: - ModelArtifactScrubber

    /// `<unk>` tokenizer-artifact scrub: digit-adjacent `<unk>` ⇒ "%",
    /// everything else dropped with boundary cleanup. Ported from the
    /// validated macOS battery (PostProcessing.scrubModelArtifacts). Each
    /// case also pins idempotence: scrub(scrub(x)) == scrub(x).
    func testModelArtifactScrubberGolden() throws {
        let cases = try loadFixture("model_artifact_scrubber", as: [StringCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let out = ModelArtifactScrubber.scrub(c.input)
            XCTAssertEqual(
                out, c.expected,
                "model_artifact_scrubber[\(c.name)] input=\(c.input.debugDescription)"
            )
            XCTAssertEqual(
                ModelArtifactScrubber.scrub(out), out,
                "model_artifact_scrubber[\(c.name)] not idempotent"
            )
        }
    }

    // MARK: - ParagraphSegmenter

    func testParagraphSegmenterApplyGolden() throws {
        let cases = try loadFixture("paragraph_segmenter_apply", as: [ApplyCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let words = c.words.map {
                ParagraphSegmenter.Word(text: $0.text, start: $0.start, end: $0.end)
            }
            XCTAssertEqual(
                ParagraphSegmenter.apply(breaks: words, to: c.text), c.expected,
                "paragraph_segmenter_apply[\(c.name)]"
            )
        }
    }

    func testParagraphSegmenterReassembleGolden() throws {
        let cases = try loadFixture("paragraph_segmenter_reassemble", as: [ReassembleCase].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let tokens = c.tokens.map {
                TokenTiming(token: $0.token, startTime: $0.start, endTime: $0.end)
            }
            let expected = c.expectedWords.map {
                ParagraphSegmenter.Word(text: $0.text, start: $0.start, end: $0.end)
            }
            XCTAssertEqual(
                ParagraphSegmenter.reassembleWords(from: tokens), expected,
                "paragraph_segmenter_reassemble[\(c.name)]"
            )
        }
    }

    // MARK: - End-to-end segment() sanity

    /// Exercises the public `segment(rescoredText:tokenTimings:)` entry
    /// point (reassemble + apply composed) so the top-level API — the one
    /// the apps actually call — is covered, not just its two halves.
    func testSegmentEndToEndBoundaryMarker() {
        // Padded to clear the "no break before word 10" cap: 10 filler
        // tokens, then a sentence-final word, a >1.4s pause, then the next.
        var tokens: [TokenTiming] = []
        for i in 0..<10 {
            tokens.append(TokenTiming(token: "▁w\(i)", startTime: Double(i) * 0.1,
                                      endTime: Double(i) * 0.1 + 0.05))
        }
        tokens.append(TokenTiming(token: "▁Hello.", startTime: 1.0, endTime: 1.05))
        tokens.append(TokenTiming(token: "▁World.", startTime: 2.7, endTime: 3.0))
        let prefix = (0..<10).map { "w\($0)" }.joined(separator: " ")
        let text = "\(prefix) Hello. World."
        let out = ParagraphSegmenter.segment(rescoredText: text, tokenTimings: tokens)
        XCTAssertEqual(out, "\(prefix) Hello.\n\nWorld.")
    }
}
