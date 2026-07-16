import Foundation

/// Lightweight, engine-neutral word/subword timing used by
/// `ParagraphSegmenter`. In the shipping apps the ASR layer (FluidAudio)
/// produces its own richer `TokenTiming` (token id, confidence, …); this
/// package deliberately depends only on the three fields the segmenter
/// actually reads so the text pipeline stays free of any ASR-engine or
/// platform (CoreML/ANE) dependency and can run on a future non-Apple
/// port. Consumers map their engine's timings into this value at the two
/// call sites that invoke the segmenter.
public struct TokenTiming: Equatable {
    /// Raw subword token text, including any word-start marker
    /// (`▁` or a leading space) the tokenizer emits.
    public let token: String
    /// Token start time, seconds.
    public let startTime: TimeInterval
    /// Token end time, seconds.
    public let endTime: TimeInterval

    public init(token: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.token = token
        self.startTime = startTime
        self.endTime = endTime
    }
}
