import Foundation

/// **The post-decode vocabulary pass for engines without a rescore hook**
/// (Mac Nemotron English + multilingual, design A5 / R10 interim). One gate
/// call over two evidence sources:
///
/// 1. **Acoustic** — the CTC keyword spotter's detections (`.acoustic`, real
///    log-prob scores), placed on the word the decoder wrote at that moment via
///    the decoder's own token timings (`wordTimes`). Without word times they are
///    DROPPED, never placed by proportional position (R10).
/// 2. **Textual** — the model-free corrector's detections (`.textual`, real
///    word windows), for what the spotter can't produce: split words,
///    misspelled entries, languages with no acoustic checkpoint.
///
/// Textual detections go first, so a close spelling match claims its words
/// before a time-placed spotter hit can. Measured on the owner's 40 recordings
/// (5 runs): textual-first 35/48 right with 1 wrong apply in 4 of 5 runs,
/// acoustic-first 34–35 with 1–2 wrong. The corrector names its exact window
/// and a tight measured distance; the spotter's time spans are coarse (spans of
/// several seconds are common) and its scores uniformly weak (−6…−11), so when
/// both reach the same word the spelling match is the better witness — e.g.
/// "Jamul" goes to "Jammula" (textual 0.29), not to a 7-second "Jamy" span.
/// The spotter adds what spelling can't reach. Every detection then runs the
/// gate's full guard set.
public enum VocabularyPass {

    public static func run(
        transcript: String,
        acoustic: [VocabularyGate.Detection],
        wordTimes: [WordTime]?,
        terms: [VocabTerm],
        correctorLanguage: String?,
        commonWords: CommonWordsProvider,
        commonWordsResource: String?,
        overrides: [CorrectionStore.OverrideEntry] = [],
        diagnostics: DiagnosticsSink = NoopDiagnosticsSink()
    ) -> VocabularyGate.Result {
        var detections: [VocabularyGate.Detection] = []
        if let correctorLanguage {
            detections += VocabularyCorrector.detections(
                in: transcript, terms: terms, language: correctorLanguage, diagnostics: diagnostics)
        }
        // Word times must describe THIS transcript word-for-word, or the gate
        // would fall back to proportional placement for the acoustic hits.
        let wordCount = transcript.split(whereSeparator: { $0.isWhitespace }).count
        let wordTimes = wordTimes.flatMap { $0.count == wordCount ? $0 : nil }
        if !acoustic.isEmpty {
            if wordTimes != nil {
                detections += acoustic
            } else {
                diagnostics.record(
                    category: .vocabularyGate,
                    message: "acoustic detections dropped: no decoder word times",
                    metadata: ["count": "\(acoustic.count)"])
            }
        }
        guard !detections.isEmpty else {
            return VocabularyGate.Result(text: transcript, applied: 0, blocked: [], proposals: [])
        }
        return VocabularyGate.applyFromDetections(
            originalTranscript: transcript,
            detections: detections,
            // Time-placed detections use `wordTimes`; windowed ones their own
            // range. The duration only matters to the legacy proportional rule,
            // which no detection here reaches.
            totalAudioDuration: wordTimes?.last?.end ?? 0,
            commonWords: commonWords,
            commonWordsResource: commonWordsResource,
            overrides: overrides,
            diagnostics: diagnostics,
            wordTimes: wordTimes)
    }
}
