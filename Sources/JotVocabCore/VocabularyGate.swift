import Foundation

/// **v1a — the gate.** A safety filter over FluidAudio's proposed vocabulary
/// replacements so a custom term can *never silently overwrite a word the
/// transcriber already got right.*
///
/// FluidAudio's rescorer (CTC word-spotting, NeMo arXiv:2406.07096) proposes
/// "replace word X with term Y when Y's acoustic score beats X". That swap has
/// no brake — it fires even on a 0.998-confidence correct word (the shipped
/// over-correction bug: adding "Jamy" turned every "name" into "Jamy"). This
/// gate adds the brake:
///   1. **Plausibility** — the heard word must be an acoustic cousin of the
///      term/alias (edit-distance bound). Kills "Vikram"→"Sriram"-class garbage.
///   2. **Confidence ceiling** — never auto-correct a word the TDT transcriber
///      was very sure about (the 0.998 protector).
///   3. **Common-word guard** — never overwrite an everyday word (frequency set)
///      unless the override is earned.
///   4. **Earned override** — a shaky word, or a term that wins by a large
///      margin, may still be corrected.
/// Multi-word phrase *terms* ("Claude Code") are precise and self-gating → allowed
/// (but only after plausibility).
///
/// Per-occurrence: TDT gives a separate confidence for each word occurrence
/// (no FluidAudio fork needed). See docs/plans/adaptive-vocabulary-correction.md
/// §3.2 / §0d / §0g.
///
/// NOTE: thresholds below are START values. A wider on-device calibration is a
/// pre-enable task; keep the master vocabulary toggle off until calibrated.
///
/// Engine-neutral (Phase B): the gate imports no FluidAudio. It consumes the
/// package's `RescoreOutput`/`RescoreProposal`/`TokenTiming` mirror types, asks
/// a `CommonWordsProvider` for the everyday-word set (keyed by a plain resource
/// string, not a `LanguageChoice`), and emits trace via a `DiagnosticsSink`.
public enum VocabularyGate {

    /// A word above this TDT confidence is never auto-corrected unless the term
    /// wins by a large margin. The 0.998-"name" protector.
    public static let confidenceCeiling: Float = 0.95
    /// Below this confidence a word is "unsure" enough to be override-eligible.
    public static let lowConfidence: Float = 0.85
    /// Boosted CTC margin (`replacementScore − originalScore`; includes the
    /// engine's cbw≈3.0) above which a correction counts as "earned" even
    /// against a confident or common word.
    public static let earnedMargin: Float = 4.0

    /// An alternate candidate term for a proposal's span (3-option ask,
    /// 2026-07-13). `term` is the vocab term to offer; `find` is the EXACT
    /// in-text string it would replace (the winning span's published text
    /// plus the following transcript words the longer term extends over,
    /// e.g. find "Claude code" → term "Claude Code"). Computed at gate time
    /// because FluidAudio's merge prefers the SHORTER span and drops the
    /// longer term inside the package — Jot re-detects it here.
    public struct Alternate: Codable, Sendable, Equatable {
        public let term: String
        public let find: String

        public init(term: String, find: String) {
            self.term = term
            self.find = find
        }
    }

    /// One proposal the CTC spotter surfaced, with the gate's verdict — kept so
    /// the review surface can persist it per-transcript and let the owner
    /// adjudicate each **occurrence** later (plan §v2-A).
    public struct Proposal: Sendable, Equatable {
        public let originalWord: String     // what TDT wrote (e.g. "Jamie")
        public let term: String             // the vocab term (e.g. "Jamy")
        public let decision: String         // "APPLY" | "BLOCK" | "OVERRIDE"
        public let outcome: String          // "applied" (text became `term`) | "kept" (text left `original`)
        public let confidence: Float
        public let margin: Float
        public let unsure: Bool             // gate confidence near the decision boundary
        // Slice D (Mac ask-before-paste, §9 Option B): this proposal is a
        // candidate for the live "Did you mean X?" pill. ADDITIVE metadata only —
        // it never changes the apply/block decision. True for exactly two
        // intent-matched cases: (i) a single-word term APPLIED to a non-common
        // original the model wasn't confident about (silent-OOV "did you mean
        // Vikram?"), and (ii) a common-word near-miss BLOCKED by the common-word
        // brake that is otherwise plausible (the "did you mean Lisa?" case).
        // Ported from the Mac gate as part of the superset merge; iOS's keyboard
        // path ignores it (it selects asks via `AskPolicy`), Mac's live pill reads it.
        public let askCandidate: Bool
        public let occurrenceIndex: Int     // DISPLAY-ONLY FIFO arrival index — NOT an identity key
        // STABLE identity: char offset of the matched span in the ORIGINAL
        // (pre-rescore) transcript. Immutable provenance → safe as a verdict key.
        public let originalStart: Int
        public let originalLength: Int
        // Char span in the GATE-OUTPUT text. Becomes the provenance record's
        // LIVE anchor — kept valid across every later text change by
        // CorrectionProvenance's reconcile; resolution is strict (exact offset
        // or fail-safe), never proximity-guessed.
        public let publishedStart: Int
        public let publishedLength: Int
        // Alternate candidate terms for this span (3-option ask). Empty for
        // the common single-candidate case.
        public let alternates: [Alternate]
        // V2-3: structural shape of the proposal. "merge" = the heard span
        // has MORE words than the term and its concatenation matches the
        // term (or an alias) — the split-word class ("sri ram" → "Sriram").
        // nil for ordinary proposals.
        public let shape: String?
        /// What the proposal's claim rests on — `Evidence.label` ("acoustic",
        /// "textual", "decodeBias"). nil only for proposals built by callers
        /// that predate evidence typing. On the detection path `confidence` and
        /// `margin` are 0 = NOT MEASURED (no decoder confidence, no comparable
        /// margin); read `evidence` + `score` there, never those two.
        public let evidence: String?
        /// The evidence's own strength on its own scale: the CTC log-prob score
        /// for "acoustic", the negated string distance for "textual". nil when
        /// the evidence carries none.
        public let score: Float?

        public init(originalWord: String, term: String, decision: String, outcome: String,
                    confidence: Float, margin: Float, unsure: Bool, askCandidate: Bool = false,
                    occurrenceIndex: Int,
                    originalStart: Int, originalLength: Int, publishedStart: Int,
                    publishedLength: Int, alternates: [Alternate], shape: String?,
                    evidence: String? = nil, score: Float? = nil) {
            self.originalWord = originalWord
            self.term = term
            self.decision = decision
            self.outcome = outcome
            self.confidence = confidence
            self.margin = margin
            self.unsure = unsure
            self.askCandidate = askCandidate
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
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        public let applied: Int
        public let blocked: [String]        // originalWords that were protected
        public let proposals: [Proposal]    // every decision, for per-transcript review (v1b)

        public init(text: String, applied: Int, blocked: [String], proposals: [Proposal]) {
            self.text = text
            self.applied = applied
            self.blocked = blocked
            self.proposals = proposals
        }
    }

    /// Apply the gate to the rescorer output. Returns the gated transcript:
    /// each proposed replacement is re-checked and either kept or reverted to
    /// the original word. Reconstructs from `originalTranscript` (the un-boosted
    /// TDT text) so a blocked replacement cleanly leaves the original word.
    ///
    /// Replacements are resolved to their position in the transcript and applied
    /// in **positional order** — `output.replacements` is NOT left-to-right
    /// (the rescorer sorts by span length / similarity), so a forward-only pass
    /// would silently drop edits.
    public static func apply(
        originalTranscript: String,
        output: RescoreOutput,
        tokenTimings: [TokenTiming],
        commonWords: CommonWordsProvider,
        diagnostics: DiagnosticsSink = NoopDiagnosticsSink(),
        overrides: [CorrectionStore.OverrideEntry] = [],
        termAliases: [String: [String]] = [:],
        commonWordsResource: String? = "common-words",
        allTerms: [String] = []
    ) -> Result {
        guard output.wasModified, !output.replacements.isEmpty else {
            return Result(text: output.text, applied: 0, blocked: [], proposals: [])
        }
        let wordConfidence = perWordMinConfidence(tokenTimings)
        // Resolve the everyday-word set ONCE (seam 2). nil resource ⇒ empty set
        // ⇒ the common-word guard is inert, exactly as `CommonWords.isCommon`
        // returned false for a nil resource.
        let commonWordSet = commonWords.words(forResource: commonWordsResource)

        // Resolve each replacement to a transcript range + its gate decision.
        // `occurrenceIndex` (FIFO arrival) is display-only; the STABLE identity is
        // `originalStart` (the span's char offset in the original text), computed
        // here while we still hold the authoritative range. Proposals are emitted
        // ONLY for spans that survive the positional overlap guard below, so the
        // provenance never contains a phantom record for a span that isn't in the
        // published text (plan §v2-A).
        struct Item {
            let r: RescoreProposal
            let d: (pass: Bool, confidence: Float, margin: Float, label: String, unsure: Bool, askCandidate: Bool)
            let range: Range<String.Index>
            // The effective original span text — normally `r.originalWord`,
            // but WIDER when the dedup guard absorbed a following duplicate
            // word ("clawed" + following "code" for term "Claude Code" →
            // "clawed code"), so reverts/chips restore the full span.
            let originalWord: String
            let originalStart: Int
            let originalLength: Int
            let occurrenceIndex: Int
            let publishedText: String   // what occupies this span in the output (term if pass, else original)
        }
        var occurrence: [String: Int] = [:]
        var items: [Item] = []

        for r in output.replacements where r.shouldReplace {
            let key = r.originalWord.lowercased()
            let n = occurrence[key, default: 0]
            guard var range = nthWholeWordRange(of: r.originalWord, in: originalTranscript, occurrence: n) else {
                continue
            }
            occurrence[key] = n + 1

            // V2-1 · Alignment window (round-2 amendment). A multi-word term
            // must align to ONE unique edge-touching window inside its span;
            // extra span words survive; anything ambiguous blocks. Runs
            // BEFORE decide() so identity/learning use the aligned span.
            var alignmentBlocked = false
            var effectiveOriginal = r.originalWord
            if let term = r.replacementWord {
                let termWords = term.split(separator: " ").map(String.init)
                let spanWords = r.originalWord.split(separator: " ").map(String.init)
                if termWords.count >= 2, spanWords.count >= termWords.count {
                    switch Self.alignmentWindow(termWords: termWords, spanWords: spanWords) {
                    case .unique(let wordIndex):
                        if spanWords.count > termWords.count,
                           let sub = Self.wordSubrange(
                               of: range, wordIndex: wordIndex,
                               count: termWords.count, in: originalTranscript) {
                            range = sub
                            effectiveOriginal = String(originalTranscript[sub])
                            diagnostics.record(
                                category: .vocabularyGate,
                                message: "align-narrowed \(r.originalWord) → \(effectiveOriginal)",
                                metadata: ["term": term])
                        }
                    case .blocked:
                        alignmentBlocked = true
                    }
                }
            }
            // Repeated-occurrence guard (round-2): the package gives no span
            // position, so the k-th-arrival→k-th-occurrence mapping can hit
            // the WRONG occurrence when the word repeats. Safe only when the
            // word occurs once, OR every occurrence has a proposal with the
            // SAME replacement (then order can't change the text). Otherwise
            // block to the pane.
            if !alignmentBlocked,
               nthWholeWordRange(of: r.originalWord, in: originalTranscript, occurrence: 1) != nil {
                // ≥2 textual occurrences. Count them + the proposals.
                var occCount = 2
                while nthWholeWordRange(of: r.originalWord, in: originalTranscript, occurrence: occCount) != nil {
                    occCount += 1
                }
                let siblings = output.replacements.filter {
                    $0.shouldReplace && $0.originalWord.lowercased() == key
                }
                let sameTerm = Set(siblings.map { ($0.replacementWord ?? "").lowercased() }).count == 1
                if siblings.count != occCount || !sameTerm {
                    alignmentBlocked = true
                    diagnostics.record(
                        category: .vocabularyGate,
                        message: "occurrence-ambiguous \(r.originalWord) → \(r.replacementWord ?? "—")",
                        metadata: ["occurrences": "\(occCount)", "proposals": "\(siblings.count)"])
                }
            }

            // Dedup guard (owner bug 2026-07-13: saying "Claude code" heard
            // as "clawed code" applied the two-word term over just "clawed"
            // → "Claude Code code"). When a multi-word term covers FEWER
            // words than the term has, and the term's trailing word(s)
            // duplicate the transcript word(s) right after the span, widen
            // the span to absorb them so an apply can't double a word.
            // Runs BEFORE decide() (diff-review fix): the widened span IS the
            // proposal's identity, so learned demotions/overrides key on
            // "clawed code", and a revert actually blocks the next occurrence.
            // (Shape-gated only — widening a proposal that then blocks is
            // harmless; the record just shows the true span.)
            if let term = r.replacementWord, !alignmentBlocked,
               let widened = absorbTrailingDuplicates(
                   term: term, spanWord: effectiveOriginal,
                   range: range, in: originalTranscript) {
                range = widened
                effectiveOriginal = String(originalTranscript[widened])
                diagnostics.record(
                    category: .vocabularyGate,
                    message: "dedup-absorbed \(r.originalWord) → \(effectiveOriginal)",
                    metadata: ["term": term])
            }

            // decide() consumes the EFFECTIVE identity (aligned-narrowed or
            // dedup-widened span text), not the raw engine span (diff-review
            // fix): plausibility/confidence/common-word/learned lookups must
            // all see the same words the replacement actually touches.
            var d = decide(
                r, originalWord: effectiveOriginal,
                wordConfidence: wordConfidence, overrides: overrides,
                aliases: termAliases[(r.replacementWord ?? "").lowercased()] ?? [],
                commonWords: commonWordSet)
            if alignmentBlocked, d.pass {
                // Force-block a proposal whose span identity is unsafe. The
                // proposal stays visible in the transcript pane for review.
                // A force-blocked unsafe span is never a live-pill ask candidate.
                d = (false, d.confidence, d.margin, "BLOCK", d.unsure, false)
            }
            // Surface each decision in the in-app Help → Diagnostics card.
            // `netMargin` (R3 bootstrap, 2026-07-13): the margin with the
            // engine's context-biasing head-start (cbw≈3.0) subtracted — an
            // APPROXIMATION of "did the term win on acoustic merit alone?"
            // (long multi-token terms get an adaptive cbw slightly above 3.0,
            // so their true net is a bit lower than logged). Read these off
            // real dictations, join with the verdict logs, and calibrate the
            // R3 un-boosted-margin gate from the distribution.
            diagnostics.record(
                category: .vocabularyGate,
                message: "\(r.originalWord) → \(r.replacementWord ?? "—")",
                metadata: [
                    "decision": d.label,
                    "conf": String(format: "%.3f", d.confidence),
                    "margin": String(format: "%.2f", d.margin),
                    "netMargin": String(format: "%.2f", d.margin - 3.0),
                ])
            items.append(
                Item(
                    r: r,
                    d: d,
                    range: range,
                    originalWord: effectiveOriginal,
                    originalStart: originalTranscript.distance(from: originalTranscript.startIndex, to: range.lowerBound),
                    originalLength: originalTranscript.distance(from: range.lowerBound, to: range.upperBound),
                    occurrenceIndex: n,
                    publishedText: d.pass ? (r.replacementWord ?? r.originalWord) : String(originalTranscript[range])
                )
            )
        }

        items.sort {
            // Positional order; on an equal start (possible after V2-1
            // narrowing), the LONGER span wins the slot — it's the more
            // specific match (diff-review tie-break).
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }

        var result = ""
        var cursor = originalTranscript.startIndex
        var applied = 0
        var blocked: [String] = []
        var proposals: [Proposal] = []
        for item in items {
            // Overlap guard — when two proposals claim overlapping spans
            // (e.g. terms "Claude" AND "Claude Code" both matching the same
            // audio), the leftmost-starting one wins and the rest are
            // dropped. Log the drop (2026-07-13): this was silent, which made
            // "I added Claude and Claude Code but only one works" untraceable.
            guard item.range.lowerBound >= cursor else {
                diagnostics.record(
                    category: .vocabularyGate,
                    message: "overlap-dropped \(item.originalWord) → \(item.r.replacementWord ?? "—")",
                    metadata: [
                        "decision": item.d.label,
                        "margin": String(format: "%.2f", item.d.margin),
                    ])
                continue
            }
            result += originalTranscript[cursor..<item.range.lowerBound]
            let publishedStart = result.count
            result += item.publishedText
            // 3-option ask (2026-07-13): detect LONGER vocab siblings of the
            // winning term whose extension matches the words that follow in
            // the transcript ("Claude" won but "Claude Code" fits the audio +
            // next word). FluidAudio's merge prefers the shorter span and
            // drops the longer candidate inside the package, so it can never
            // reach this gate — re-derive it here so the ask can offer it.
            let alternates = extensionAlternates(
                winnerTerm: item.r.replacementWord,
                publishedText: item.publishedText,
                after: item.range.upperBound,
                in: originalTranscript,
                allTerms: allTerms)
            // V2-3 · merge-shape classification: span words > term words AND
            // the concatenated span EXACTLY equals the normalized term (or
            // one of its aliases) — the split-word class ("sri ram" →
            // "Sriram"). Shape rides the proposal so the ask publisher can
            // route it to the post-paste teach strip instead of silence.
            let shape: String? = {
                guard let term = item.r.replacementWord else { return nil }
                let spanWords = item.originalWord.split(separator: " ").map(String.init)
                let termWords = term.split(separator: " ")
                guard spanWords.count > termWords.count else { return nil }
                let concat = skeleton(spanWords.joined())
                let candidates = [term] + (termAliases[term.lowercased()] ?? [])
                for c in candidates where skeleton(c) == concat { return "merge" }
                return nil
            }()
            proposals.append(
                Proposal(
                    // Effective span text (dedup-widened when the guard
                    // absorbed a following duplicate) — reverts and ask
                    // chips must restore/show the FULL replaced span.
                    originalWord: item.originalWord,
                    term: item.r.replacementWord ?? item.r.originalWord,
                    decision: item.d.label,
                    outcome: item.d.pass ? "applied" : "kept",
                    confidence: item.d.confidence,
                    margin: item.d.margin,
                    unsure: item.d.unsure,
                    askCandidate: item.d.askCandidate,
                    occurrenceIndex: item.occurrenceIndex,
                    originalStart: item.originalStart,
                    originalLength: item.originalLength,
                    publishedStart: publishedStart,
                    publishedLength: item.publishedText.count,
                    alternates: alternates,
                    shape: shape,
                    // The rescorer's proposals are CTC-rescored against real
                    // TDT confidences — acoustic evidence with real values.
                    evidence: Evidence.rescoreLabel,
                    score: item.r.replacementScore
                )
            )
            if item.d.pass { applied += 1 } else { blocked.append(String(originalTranscript[item.range])) }
            cursor = item.range.upperBound
        }
        result += originalTranscript[cursor...]
        return Result(text: result, applied: applied, blocked: blocked, proposals: proposals)
    }

    // MARK: - Detection-driven gate (Mac no-fork Nemotron path)

    /// One acoustically-spotted vocabulary term and where it lives in the audio.
    /// The Mac Nemotron-path adapter (`VocabularyRescorerHolder.gateDetections`)
    /// builds these straight from FluidAudio's `CtcKeywordSpotter.KeywordDetection`
    /// — no `RescoreOutput` (which needs decoder timings the Nemotron stream never
    /// produces) is involved. Engine-neutral value type (Foundation only), ported
    /// from the Mac gate as part of the superset merge.
    /// **What a detection's claim rests on** (evidence-typed gate, design
    /// `vocabulary-evidence-and-decode-bias.md` A1/R1/R2). The gate never
    /// synthesizes a signal a detection doesn't carry: no stand-in decoder
    /// confidence, no zero "margin", no position guessed from a time fraction.
    public enum Evidence: Sendable, Equatable {
        /// The decoder itself wrote the term under decode-time bias. Reserved
        /// for the Nemotron bias hook (workstream B3); nothing emits it yet.
        case decodeBias
        /// A real acoustic score: the CTC keyword spotter's log-prob `score`,
        /// plus the decoder's own per-word `confidence` when the engine measures
        /// one (nil = not measured — NEVER a stand-in such as FluidAudio's
        /// constant 1.0 Nemotron token confidence). Only this kind earns the §6
        /// confidence-conditional plausibility ceiling.
        case acoustic(score: Float, confidence: Float?)
        /// A string-only match from the model-free corrector: `distance` is its
        /// normalized edit distance (nil for legacy callers). Applies only
        /// through the corrector's per-language distance table plus every gate
        /// guard, and keeps the flat 0.45 ceiling (R1).
        case textual(distance: Double?)

        /// Stable persisted label (`Proposal.evidence` / `Record.evidence`).
        public var label: String {
            switch self {
            case .decodeBias: return "decodeBias"
            case .acoustic: return "acoustic"
            case .textual: return "textual"
            }
        }

        /// Label for the TDT rescore path (`apply`): CTC-rescored proposals with
        /// real TDT confidences — acoustic evidence.
        public static let rescoreLabel = "acoustic"
    }

    public struct Detection: Sendable, Equatable {
        public let term: String           // the vocab term spotted in the audio
        public let aliases: [String]      // enriched aliases for the term (plausibility)
        /// The evidence's own strength, on the evidence's own scale: the CTC
        /// log-prob for `.acoustic`, the negated string distance for `.textual`.
        /// Logged and carried to the proposal; never compared across kinds.
        public let score: Float
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        /// What this detection's claim rests on. Drives the §6 ceiling (acoustic
        /// only) and is persisted on the proposal so asks can rank by it.
        public let evidence: Evidence
        /// An EXACT word window (indices into the transcript's whitespace-split
        /// words) the detection was found at. The model-free corrector knows the
        /// real window it matched, so it hands it over instead of encoding it as
        /// a time fraction for the gate to re-derive. nil = place by time.
        public let wordRange: Range<Int>?

        /// **§6 — `score` is an ACOUSTIC CTC score** on the spotter's scale, so
        /// the confidence-conditional plausibility ceiling applies. Derived from
        /// `evidence`; kept so existing readers compile unchanged.
        public var acoustic: Bool {
            if case .acoustic = evidence { return true }
            return false
        }

        /// Legacy shim (R2: the Detection API stays additive). `acoustic: true`
        /// maps to `.acoustic(score:, confidence: nil)`; false to a textual
        /// detection with no recorded distance — the pre-evidence meaning.
        public init(term: String, aliases: [String], score: Float,
                    startTime: TimeInterval, endTime: TimeInterval,
                    acoustic: Bool = false) {
            self.term = term
            self.aliases = aliases
            self.score = score
            self.startTime = startTime
            self.endTime = endTime
            self.evidence = acoustic
                ? .acoustic(score: score, confidence: nil)
                : .textual(distance: nil)
            self.wordRange = nil
        }

        /// Evidence-typed detection. `score` is derived from the evidence.
        public init(term: String, aliases: [String], evidence: Evidence,
                    startTime: TimeInterval, endTime: TimeInterval,
                    wordRange: Range<Int>? = nil) {
            self.term = term
            self.aliases = aliases
            switch evidence {
            case .acoustic(let score, _): self.score = score
            case .textual(let distance): self.score = Float(-(distance ?? 0))
            case .decodeBias: self.score = 0
            }
            self.startTime = startTime
            self.endTime = endTime
            self.evidence = evidence
            self.wordRange = wordRange
        }

        /// The decoder's measured per-word confidence, when the evidence has one.
        var measuredConfidence: Float? {
            if case .acoustic(_, let confidence) = evidence { return confidence }
            return nil
        }
    }

    /// When a detection is placed by audio time (`wordTimes`), the farthest a
    /// window may sit from the detection's own time span. Past this the spotter
    /// and the decoder are talking about different moments, and the detection
    /// is dropped instead of guessed onto the nearest plausible word. Nemotron
    /// emits at 80 ms encoder frames and the spotter at 40 ms, so honest pairs
    /// overlap or sit within a frame or two; 1 s is generous slack for a term
    /// the decoder smeared across a pause.
    public static let maxTimedPlacementGap: TimeInterval = 1.0

    // MARK: - Confidence-conditional plausibility ceiling (§6)

    /// The widest string distance an ACOUSTIC detection may span. Read off 433
    /// real detections (E8): the widest gap the spotter was right about beyond
    /// the ceiling is 0.615, and past 0.65 its far tail turns 5-right-to-10-wrong.
    public static let acousticCeilingMax: Double = 0.65
    /// Below this acoustic score the flat 0.45 ceiling holds: −1.793 is the
    /// strongest score among beyond-ceiling detections whose term was never spoken.
    public static let acousticScoreFloor: Float = -1.8
    /// At or above this score the full 0.65 applies — 0.8 nats clear of the floor.
    public static let acousticScoreCeiling: Float = -1.0

    /// **§6 · confidence-conditional plausibility ceiling.** 29 % of all
    /// correction opportunities sit beyond the flat 0.45 ceiling, and 35 of them
    /// were already *detected* by the spotter and then discarded — "Herrakit" →
    /// "Parakeet" is 0.62 string distance but was heard at −0.313, the best score
    /// of five terms. Acoustic evidence is doing work string similarity cannot see.
    ///
    /// It must be CONDITIONAL, not a flat raise. A flat 0.65 admits 30 right and
    /// 25 wrong. Beyond 0.45, score > −1.5 is 17 right / 1 wrong; below it,
    /// 19 / 34 — two populations. Measured effect of the ramp: **+4.7 points of
    /// end-to-end recall for zero additional false applies** (the
    /// 0-in-22,490-words baseline holds), WER improved in all four measured arms.
    public static func effectiveCeiling(acousticScore score: Float) -> Double {
        if score <= acousticScoreFloor { return plausibilityCeiling }
        if score >= acousticScoreCeiling { return acousticCeilingMax }
        let t = Double(score - acousticScoreFloor) / Double(acousticScoreCeiling - acousticScoreFloor)
        return plausibilityCeiling + t * (acousticCeilingMax - plausibilityCeiling)
    }

    /// **Detection-driven gate.** The Mac no-fork Nemotron entry point. Nemotron's
    /// stream returns a plain `String` with NO per-word timings and NO confidence,
    /// so the timing-dependent rescore is inert there. Instead we run the CTC
    /// keyword spotter on the AUDIO — which yields each term that was actually
    /// spoken plus its audio TIME RANGE — and place each spotted term onto the
    /// transcript ourselves.
    ///
    /// Placement: for each detection we look for a transcript word that is an
    /// acoustic near-miss of the term (REUSING the shared `plausible(...)`, the
    /// exact metric `apply(...)` uses). When several occurrences qualify we
    /// disambiguate by PROPORTIONAL position — mapping the detection's mid-audio
    /// time over `totalAudioDuration` to a fractional index across the words. A
    /// term already present correctly is a no-op (identity skip below).
    ///
    /// Decision: the SAME `decide(...)` the TDT path uses, fed only what the
    /// detection's `Evidence` actually measured. With no decoder confidence the
    /// 0.998-protector ceiling can't fire (correct: no confidence to protect),
    /// while plausibility, the common-word brake, learned overrides, and the
    /// ask-candidate flags all still run. There is no margin (the spotter score
    /// is on a different scale), so the earned-margin branch can't mis-fire.
    /// The proposal records `confidence`/`margin` as 0 = not measured, plus the
    /// evidence kind and its own score — no stand-in values.
    ///
    /// Reconciliation note (superset merge): this reuses the POST-OVERHAUL iOS
    /// `decide`/`plausible` (case-insensitive override match, NFC/whitespace
    /// `CorrectionKey` normalization, no `commonArmThreshold` auto-arm), NOT the
    /// Mac fork's older versions — iOS logic wins on the shared decision path.
    /// The additive multi-candidate alternates / merge-shape / dedup machinery in
    /// `apply(...)` has no analogue here (the spotter yields one term per span),
    /// so detection proposals carry `alternates: []` and `shape: nil`.
    ///
    /// **Evidence-typed placement (2026-09-25).** Proportional position is the
    /// legacy fallback only. A detection with a `wordRange` is placed on exactly
    /// that window. When the caller passes `wordTimes` (one entry per
    /// whitespace-split transcript word, from the decoder's own token timings),
    /// a time-placed detection goes to the plausible window whose audio span is
    /// nearest its own, and is DROPPED past `maxTimedPlacementGap` rather than
    /// guessed. A `wordTimes` whose count disagrees with the transcript is
    /// ignored (fail closed to the explicit-window / proportional rules).
    public static func applyFromDetections(
        originalTranscript: String,
        detections: [Detection],
        totalAudioDuration: TimeInterval,
        commonWords: CommonWordsProvider,
        commonWordsResource: String? = "common-words",
        overrides: [CorrectionStore.OverrideEntry] = [],
        diagnostics: DiagnosticsSink = NoopDiagnosticsSink(),
        wordTimes: [WordTime]? = nil
    ) -> Result {
        guard !detections.isEmpty, !originalTranscript.isEmpty else {
            return Result(text: originalTranscript, applied: 0, blocked: [], proposals: [])
        }
        let commonWordSet = commonWords.words(forResource: commonWordsResource)

        // Tokenize the transcript into whole words with their char ranges, in
        // document order. Used both to score proportional position and to resolve
        // the chosen candidate's range for splicing.
        struct Word {
            let text: String
            let range: Range<String.Index>
        }
        var words: [Word] = []
        var idx = originalTranscript.startIndex
        while idx < originalTranscript.endIndex {
            while idx < originalTranscript.endIndex, originalTranscript[idx].isWhitespace {
                idx = originalTranscript.index(after: idx)
            }
            guard idx < originalTranscript.endIndex else { break }
            let start = idx
            while idx < originalTranscript.endIndex, !originalTranscript[idx].isWhitespace {
                idx = originalTranscript.index(after: idx)
            }
            words.append(Word(text: String(originalTranscript[start..<idx]), range: start..<idx))
        }
        guard !words.isEmpty else {
            return Result(text: originalTranscript, applied: 0, blocked: [], proposals: [])
        }
        let n = words.count

        // V2-5 · §3 — a multi-word window may only fuse words separated by PLAIN
        // spaces, and may NEVER cross a word's own punctuation. Interior
        // boundaries must be clean on both sides; a trailing mark on the
        // window's LAST word is fine, because the span stops before it.
        func windowIsFusable(_ lo: Int, _ hi: Int) -> Bool {
            guard hi - lo > 1 else { return true }
            for k in lo..<(hi - 1) {
                guard let last = words[k].text.last, last.isLetter || last.isNumber else { return false }
                guard let first = words[k + 1].text.first, first.isLetter || first.isNumber else { return false }
                let gap = originalTranscript[words[k].range.upperBound..<words[k + 1].range.lowerBound]
                guard !gap.isEmpty, gap.allSatisfy({ $0 == " " }) else { return false }
            }
            return true
        }

        // §3 — per-word alignment against a term/alias of the SAME width.
        // Whole-window plausibility alone is a text-corrupting brake: "claude
        // wrote" measures 0.27 against "Claude Code" and "load code" 0.40 —
        // both inside the ceiling. Per-word alignment (wrote↔Code = 0.60) is
        // what refuses them.
        func windowAligns(_ lo: Int, _ hi: Int, surfaces: [String]) -> Bool {
            let width = hi - lo
            let windowWords = (lo..<hi).map { words[$0].text }
            for surface in surfaces {
                let surfaceWords = surface.split(separator: " ").map(String.init)
                guard surfaceWords.count == width else { continue }
                if zip(windowWords, surfaceWords).allSatisfy({ wordAligns($0, $1) }) { return true }
            }
            return false
        }

        /// §3 — a multi-word span ends at the last alphanumeric of its final
        /// word: the SAME boundary `absorbTrailingDuplicates` picks, so both
        /// mechanisms produce identically-shaped spans.
        func lastAlphanumericEnd(of range: Range<String.Index>) -> String.Index {
            var hi = range.upperBound
            while hi > range.lowerBound {
                let prev = originalTranscript.index(before: hi)
                if originalTranscript[prev].isLetter || originalTranscript[prev].isNumber { break }
                hi = prev
            }
            return hi
        }

        // For each detection, choose the best transcript WINDOW to (maybe)
        // replace. §3: scanning single tokens only meant a multi-word term
        // matched purely by luck — when the engine happened to merge it into
        // one token — because the loop compared one token against the WHOLE
        // term ("cloud" vs "claudecode" = 0.60, rejected; the window
        // "cloudcode" vs "claudecode" = 0.20, accepted). Widths are driven by
        // the word count of the term and each alias; width 1 is ALWAYS tried,
        // so single-word behaviour is byte-identical to the old path.
        //
        // Every word of the chosen window is claimed, so two detections can
        // never take the same words. The chosen range is the SINGLE identity —
        // anchors, decide input, published text, review row, revert range.
        struct Pick {
            let wordRange: Range<Int>           // window word indices, PRE-absorb
            let span: Range<String.Index>       // final char span, POST-absorb
            let absorbed: Bool                  // absorbTrailingDuplicates widened it
            let punctuationBlocked: Bool        // §2 host-token-punctuation sub-case
            let ceiling: Double                 // §6 ceiling that admitted it
            let detection: Detection
        }
        var claimed = Set<Int>()
        var picks: [Pick] = []
        // Real per-word audio spans, only when they describe THIS transcript.
        let timed: [WordTime]? = {
            guard let wordTimes, wordTimes.count == n else {
                if let wordTimes {
                    diagnostics.record(
                        category: .vocabularyGate,
                        message: "word-times ignored: \(wordTimes.count) times for \(n) words",
                        metadata: [:])
                }
                return nil
            }
            return wordTimes
        }()

        for det in detections {
            let mid: TimeInterval = (det.startTime + det.endTime) / 2
            let frac: Double = totalAudioDuration > 0
                ? min(max(mid / totalAudioDuration, 0), 1)
                : 0.5
            // An explicit window must lie inside the transcript, or the
            // detection describes some other text — drop it, never re-guess.
            if let range = det.wordRange,
               range.isEmpty || range.lowerBound < 0 || range.upperBound > n {
                diagnostics.record(
                    category: .vocabularyGate,
                    message: "word-range out of bounds \(det.term)",
                    metadata: ["range": "\(range)", "words": "\(n)"])
                continue
            }

            // §6 — an ACOUSTIC detection earns a wider string-distance budget in
            // proportion to how strongly it was heard; anything else keeps the
            // flat 0.45. Computed once here and carried all the way into
            // `decide`, so a span admitted at 0.60 cannot vanish there.
            let ceiling = det.acoustic
                ? Self.effectiveCeiling(acousticScore: det.score)
                : Self.plausibilityCeiling

            let surfaces = [det.term] + det.aliases
            var widths: Set<Int> = [1]
            for surface in surfaces {
                let count = surface.split(separator: " ").count
                if count >= 1 { widths.insert(count) }
            }

            // Selection: position distance among plausible candidates; on an
            // EXACT tie the wider window wins. Ascending widths + the `>`
            // tie-break below make that ordering explicit. Position is, in
            // order of preference: the detection's own explicit window, the
            // audio-time gap to the decoder's word spans, or (legacy) the
            // proportional index.
            var best: (wordRange: Range<Int>, distance: Double)?
            let candidateWidths: [Int] = det.wordRange.map { [$0.count] } ?? widths.sorted()
            for width in candidateWidths where width <= n {
                let starts: ClosedRange<Int> = det.wordRange.map { $0.lowerBound...$0.lowerBound }
                    ?? 0...(n - width)
                for lo in starts {
                    let hi = lo + width
                    // Timed placement rejects any window more than
                    // `maxTimedPlacementGap` from the detection. Test that
                    // cheap bound FIRST: otherwise every detection pays a
                    // string-distance check at every word of the transcript,
                    // which is quadratic in dictation length (a 30-min
                    // dictation spent minutes here). Same candidates survive.
                    if det.wordRange == nil, let timed {
                        let gap = max(0, max(timed[lo].start - det.endTime,
                                             det.startTime - timed[hi - 1].end))
                        guard gap <= Self.maxTimedPlacementGap else { continue }
                    }
                    guard !(lo..<hi).contains(where: { claimed.contains($0) }) else { continue }
                    guard windowIsFusable(lo, hi) else { continue }
                    let windowText = (lo..<hi).map { words[$0].text }.joined(separator: " ")
                    guard plausible(original: normalize(windowText), term: det.term,
                                    aliases: det.aliases, ceiling: ceiling) else {
                        continue
                    }
                    // The three rules apply to MULTI-WORD windows only.
                    if width >= 2 {
                        guard windowAligns(lo, hi, surfaces: surfaces) else { continue }
                        guard lastAlphanumericEnd(of: words[hi - 1].range) > words[hi - 1].range.lowerBound else {
                            continue
                        }
                    }
                    let distance: Double
                    if det.wordRange != nil {
                        distance = 0
                    } else if let timed {
                        let windowStart = timed[lo].start
                        let windowEnd = timed[hi - 1].end
                        let gap = max(0, max(windowStart - det.endTime, det.startTime - windowEnd))
                        guard gap <= Self.maxTimedPlacementGap else { continue }
                        // Overlapping windows tie at gap 0; the nearer centre
                        // breaks it (scaled well below one frame so it can never
                        // outvote a real gap).
                        let centreOffset = abs((windowStart + windowEnd) / 2 - mid)
                        distance = gap + min(centreOffset, 1_000) * 1e-6
                    } else {
                        let center = (Double(lo) + Double(hi)) / 2 / Double(n)
                        distance = abs(center - frac)
                    }
                    let wins = best.map {
                        distance < $0.distance || (distance == $0.distance && width > $0.wordRange.count)
                    } ?? true
                    if wins { best = (lo..<hi, distance) }
                }
            }

            guard let chosen = best else { continue }
            let lo = chosen.wordRange.lowerBound
            let hi = chosen.wordRange.upperBound
            // Width 1 keeps the FULL token (byte-identical to the old path —
            // `preservingEdgePunctuation` re-attaches its edges). A multi-word
            // window stops at the last alphanumeric of its final word.
            var span = words[lo].range.lowerBound..<words[hi - 1].range.upperBound
            if hi - lo > 1 {
                span = span.lowerBound..<lastAlphanumericEnd(of: words[hi - 1].range)
            }

            // §2 · jot-shared#1 — reuse the rescore path's dedup guard verbatim.
            // A multi-word term placed on a NARROWER span leaves the transcript's
            // own copy of the term's trailing word(s) standing right after it
            // ("Claude Code" over "Claude" → "Claude Code code"). Absorb them.
            var absorbed = false
            var punctuationBlocked = false
            let spanText = String(originalTranscript[span])
            if let widened = absorbTrailingDuplicates(
                term: det.term, spanWord: spanText, range: span, in: originalTranscript) {
                if let last = spanText.last, !(last.isLetter || last.isNumber) {
                    // The host token carries its OWN trailing punctuation
                    // ("ask Claude, code review"). Widening eats the comma;
                    // not widening publishes the duplicate. Both mutate text
                    // on a guess → block and log instead.
                    punctuationBlocked = true
                } else {
                    span = widened
                    absorbed = true
                }
            }

            // Partial-term guard (see `spanIsOnlyPartOfTerm`). Checked AFTER
            // absorb, so a span the widening completed is judged on its full
            // width. No pick at all — a review row here would only ever read
            // "we considered Claude Code over 'claude'", which is noise.
            if !punctuationBlocked,
               Self.spanIsOnlyPartOfTerm(span: String(originalTranscript[span]), term: det.term) {
                diagnostics.record(
                    category: .vocabularyGate,
                    message: "partial-term-skipped \(originalTranscript[span]) → \(det.term)",
                    metadata: ["score": String(format: "%.2f", det.score)])
                continue
            }

            // Claim every word the final span covers, absorbed tail included.
            var claimUpper = hi
            if absorbed {
                while claimUpper < n, words[claimUpper].range.lowerBound < span.upperBound {
                    claimUpper += 1
                }
            }
            for i in lo..<claimUpper { claimed.insert(i) }
            picks.append(
                Pick(wordRange: lo..<hi, span: span, absorbed: absorbed,
                     punctuationBlocked: punctuationBlocked, ceiling: ceiling, detection: det))
        }

        guard !picks.isEmpty else {
            return Result(text: originalTranscript, applied: 0, blocked: [], proposals: [])
        }

        // Resolve decisions in positional (document) order so splicing is forward.
        picks.sort { $0.span.lowerBound < $1.span.lowerBound }

        var result = ""
        var cursor = originalTranscript.startIndex
        var applied = 0
        var blocked: [String] = []
        var proposals: [Proposal] = []

        for pick in picks {
            guard pick.span.lowerBound >= cursor else { continue }   // overlap guard
            let originalWord = String(originalTranscript[pick.span])
            // Identity no-op: the spotter fires on the audio whether or not the
            // decoder ALREADY wrote the term correctly. If the matched span is
            // already the term, there is nothing to correct — skip it so we don't
            // emit a spurious applied "Vikram → Vikram" verdict.
            //
            // §2 — this MUST be re-checked AFTER widening, otherwise an
            // already-correct "Claude Code" publishes unchanged text but still
            // fires a UI chip and a review row. The identity relation differs by
            // span: NOT-absorbed → normalized (case-insensitive); ABSORBED →
            // ordinal, because the widening already proved the term's words are
            // present, and casing IS the term for a multi-word proper noun.
            if pick.absorbed {
                if originalWord == pick.detection.term { continue }
            } else if Self.normalize(originalWord) == Self.normalize(pick.detection.term) {
                continue
            }
            // Run the SAME iOS `decide` over the detection. The request carries
            // no margin (replacementScore nil — a spotter score is not a margin
            // over the decoder's word) and only the confidence the evidence
            // actually measured; unknown confidence leaves the 0.998-protector
            // with nothing to protect, exactly as before, without pretending
            // a value.
            let request = RescoreProposal(
                originalWord: originalWord, replacementWord: pick.detection.term,
                shouldReplace: true, replacementScore: nil, originalScore: 0)
            var d = decide(
                request, originalWord: originalWord,
                wordConfidence: [:], overrides: overrides,
                aliases: pick.detection.aliases, commonWords: commonWordSet,
                ceiling: pick.ceiling,
                measuredConfidence: pick.detection.measuredConfidence)
            // Force-blocks that live HERE and not in `decide` — `decide` is
            // pinned byte-for-byte by the shared `vocabulary_gate_decide`
            // fixtures, and both of these are measured properties of the
            // SPOTTER path, not of the decision rules.
            let forcedBlock: String? = {
                if pick.punctuationBlocked { return "host-token-punctuation" }
                if Self.possessiveOverwrite(span: originalWord, term: pick.detection.term) {
                    return "possessive"
                }
                if Self.inflectionOverwrite(
                    span: originalWord, term: pick.detection.term,
                    commonWords: commonWordSet, resource: commonWordsResource) {
                    return "inflection"
                }
                return nil
            }()
            if let reason = forcedBlock {
                // An unsafe span is never a live-pill ask candidate.
                d = (false, d.confidence, d.margin, "BLOCK", d.unsure, false)
                diagnostics.record(
                    category: .vocabularyGate,
                    message: "force-block(\(reason)) \(originalWord) → \(pick.detection.term)",
                    metadata: ["score": String(format: "%.2f", pick.detection.score)])
            }
            diagnostics.record(
                category: .vocabularyGate,
                message: "gate(spot) \(originalWord) → \(pick.detection.term)",
                metadata: [
                    "decision": d.label,
                    "evidence": pick.detection.evidence.label,
                    "score": String(format: "%.2f", pick.detection.score),
                ])

            result += originalTranscript[cursor..<pick.span.lowerBound]
            let publishedStart = result.count
            // Preserve edge punctuation attached to the original word so a bare
            // term doesn't eat the original's comma/period.
            let publishedText: String = d.pass
                ? Self.preservingEdgePunctuation(replacement: pick.detection.term, original: originalWord)
                : originalWord
            result += publishedText

            let originalStart = originalTranscript.distance(from: originalTranscript.startIndex, to: pick.span.lowerBound)
            proposals.append(
                Proposal(
                    originalWord: originalWord,
                    term: pick.detection.term,
                    decision: d.label,
                    outcome: d.pass ? "applied" : "kept",
                    // 0 = not measured on this path (see `Proposal.evidence`).
                    confidence: pick.detection.measuredConfidence ?? 0,
                    margin: 0,
                    unsure: d.unsure,
                    askCandidate: d.askCandidate,
                    occurrenceIndex: pick.wordRange.lowerBound,
                    originalStart: originalStart,
                    originalLength: originalTranscript.distance(from: pick.span.lowerBound, to: pick.span.upperBound),
                    publishedStart: publishedStart,
                    publishedLength: publishedText.count,
                    alternates: [],
                    shape: nil,
                    evidence: pick.detection.evidence.label,
                    score: pick.detection.score
                )
            )
            if d.pass { applied += 1 } else { blocked.append(originalWord) }
            cursor = pick.span.upperBound
        }
        result += originalTranscript[cursor...]
        return Result(text: result, applied: applied, blocked: blocked, proposals: proposals)
    }

    // MARK: - Inflection guard (§5 — PARTIAL, read the limits)

    /// **§5 — the worst failure class outside English, and only partly solved.**
    ///
    /// The corrector overwrites a *correctly transcribed inflected form* with a
    /// term's base form:
    ///
    ///     Russian:  Версали (Versailles) → Версаче (Versace)   ← brake blocked nothing
    ///               Аризона → Аризоны
    ///     Finnish:  jaavalainen → Jaavalaisten
    ///     Czech:    Fatima → Fatimě
    ///     German:   gewürzten → Gewürzen
    ///
    /// **The honest result: shape alone does not discriminate.** Over 1207
    /// applied corrections (17.4 % base false rate) the inflection shape appears
    /// in 76 false applies and 266 correct ones — firing on shape alone destroys
    /// 30 real corrections to prevent 33 bad ones. Proper nouns in an oblique
    /// case are simply unreachable: the same Russian corpus contains
    /// Аризона→Аризоны (wrong) and Аризоне→Аризоны (right) from the SAME term —
    /// identical length, stem, tail and distance, neither in any frequency list.
    /// No threshold separates them. Do not try; that is measured, not assumed.
    ///
    /// What ships is the CONJUNCTION of both arms below, which lifts precision
    /// ×4.65 on a small slice: it catches 5 of 29 overwrites, taking Greek from
    /// 1.42 → 0.89 FP/1k, Polish overwrites 3 → 0 and Russian 4 → 2, at a cost of
    /// 4 correct corrections (all Greek). English is unaffected — it fires zero
    /// times there.
    static func inflectionOverwrite(
        span: String, term: String, commonWords: Set<String>, resource: String?
    ) -> Bool {
        let heard = skeleton(span)
        let base = skeleton(term)
        // ARM 1 · structural — span and term share a stem of ≥ 4 scalars and
        // diverge only in a tail of ≤ 3 either side.
        var stem = 0
        while stem < heard.count, stem < base.count, heard[stem] == base[stem] { stem += 1 }
        guard stem >= 4, heard.count - stem <= 3, base.count - stem <= 3 else { return false }
        // ARM 2 · lexical — the span is ≥ 7 scalars and is an everyday word
        // carrying one extra trailing character: "the frequency list widened by
        // one trailing character". That is what makes the span a real INFLECTED
        // FORM rather than a mishearing, which is the whole failure class.
        // Neither arm is safe alone; the conjunction is the point.
        //
        // AMBIGUITY, flagged for reconciliation with jot-windows: the spec's
        // phrase "the span ... is an everyday word minus its final character"
        // also reads as span+1char ∈ list. That reading was tried and rejected —
        // it selects spans that are a real word with its last letter LOPPED OFF,
        // which are not words at all, so protecting them contradicts the guard's
        // own purpose sentence. Neither reading fires on any of the spec's five
        // illustrative examples, so they cannot settle it. If the two ports
        // disagree on a real corpus, this is the line to look at.
        guard heard.count >= 7, let resource else { return false }
        return NormalizedCommonWords.shared
            .words(forResource: resource, from: commonWords)
            .contains(String(heard.dropLast()))
    }

    /// The frequency list under the gate's OWN normalization, built lazily per
    /// language and cached. Comparing a `skeleton` against raw file lines would
    /// silently miss on any list that ships decomposed Unicode — both sides must
    /// be normalized the same way, and 24,000 entries is too much to re-derive
    /// per correction.
    private final class NormalizedCommonWords: @unchecked Sendable {
        static let shared = NormalizedCommonWords()
        private let lock = NSLock()
        private var cache: [String: Set<String>] = [:]

        func words(forResource resource: String, from raw: Set<String>) -> Set<String> {
            lock.lock()
            if let cached = cache[resource] { lock.unlock(); return cached }
            lock.unlock()
            var built = Set<String>()
            built.reserveCapacity(raw.count)
            for word in raw {
                let s = skeleton(word)
                if !s.isEmpty { built.insert(String(s)) }
            }
            lock.lock()
            cache[resource] = built
            lock.unlock()
            return built
        }
    }

    // MARK: - Partial-term guard (Swift-side addition, reported upstream)

    /// **Not in the Windows spec — a third bug in the §2/§3 family, found while
    /// implementing §6. Reported upstream so the two ports can re-converge; do
    /// not drop this on a fixture re-sync without checking that jot-windows has
    /// its own equivalent.**
    ///
    /// A multi-word term must never be placed on a span that ONE of the term's
    /// OWN words explains better than the whole term does — that span is the
    /// term's first word, correctly transcribed, and the term's remaining words
    /// are simply not in the text. Publishing over it INSERTS words the decoder
    /// never wrote:
    ///
    ///     "I love claude wrote today" + "Claude Code"
    ///       → "I love Claude Code wrote today"      ← measured, pre-existing
    ///     "I love load code today"   + "Claude Code" (acoustic, −0.3)
    ///       → "I love load Claude Code today"       ← measured, opened by §6
    ///
    /// The second is why this cannot wait: §6 widens the ceiling to 0.65, and
    /// "code" vs "claudecode" is 0.60 — the acoustic ramp hands a bare "code"
    /// the whole two-word term. §6 reports zero additional false applies, so
    /// jot-windows must already refuse this somehow.
    ///
    /// Threshold-free on purpose: it compares the span's distance to the whole
    /// term against its distance to each of the term's words, so it needs no new
    /// tunable. The legitimate merged-token case — the ONLY way a multi-word
    /// term ever landed before §3 — is untouched, because "claudecode" is
    /// 0.00 from the whole term and 0.40 from "claude".
    static func spanIsOnlyPartOfTerm(span: String, term: String) -> Bool {
        let termWords = term.split(separator: " ").map(String.init)
        guard termWords.count >= 2 else { return false }
        // Only the narrower-span shape §2/§3 flagged. A span that already covers
        // every term word (directly, or after absorbTrailingDuplicates widened
        // it) is out of scope.
        guard span.split(separator: " ").count < termWords.count else { return false }
        let heard = skeleton(span)
        let whole = skeleton(term)
        guard !heard.isEmpty, !whole.isEmpty else { return false }
        let toWholeTerm = Double(levenshtein(heard, whole)) / Double(max(heard.count, whole.count))
        for word in termWords {
            let s = skeleton(word)
            guard !s.isEmpty else { continue }
            let toWord = Double(levenshtein(heard, s)) / Double(max(heard.count, s.count))
            if toWord < toWholeTerm { return true }
        }
        return false
    }

    // MARK: - Possessive guard (§4)

    /// **§4 — never swap a possessive span for a non-possessive term.**
    ///
    /// `skeleton` drops apostrophes, so a *correctly transcribed* "Mariana's"
    /// measures **0.00** against the term "Marianas" — a perfect match — and the
    /// gate silently rewrites a word the engine got right. This was 5 of the 20
    /// false applies in the English measurement (E5); adding the guard took the
    /// shipping spotter from 0.89 → 0.67 false applies per 1000 words.
    ///
    /// Deliberately narrow: only the *trailing* `'s` / `'` shape counts, so an
    /// internal apostrophe ("O'Brien" → term "OBrien") is untouched, and a
    /// possessive TERM ("Mariana's") can still be applied to a misheard
    /// possessive span.
    static func possessiveOverwrite(span: String, term: String) -> Bool {
        isPossessive(span) && !isPossessive(term)
    }

    private static func isPossessive(_ s: String) -> Bool {
        // Drop trailing punctuation that is NOT an apostrophe, so "Mariana's,"
        // is still recognised as a possessive.
        var t = Substring(s)
        while let last = t.last, !(last.isLetter || last.isNumber),
              last != "'", last != "\u{2019}" {
            t = t.dropLast()
        }
        guard let last = t.last else { return false }
        guard last == "'" || last == "\u{2019}" || last == "s" || last == "S" else { return false }
        if last == "'" || last == "\u{2019}" {
            // Plural possessive ("Marianas'") — the mark must follow a real word.
            let head = t.dropLast()
            return head.last.map { $0.isLetter || $0.isNumber } ?? false
        }
        // "...'s" / "...’s": the apostrophe must sit before the final s, and
        // before it a real word ("as" and "its" are not possessives).
        let head = t.dropLast()
        guard let mark = head.last, mark == "'" || mark == "\u{2019}" else { return false }
        return head.dropLast().last.map { $0.isLetter || $0.isNumber } ?? false
    }

    /// Carry any LEADING and TRAILING punctuation from the original token onto
    /// the bare vocab term, so "(Jamie," → "(Jamy," not "Jamy". Only
    /// NON-letter/NON-digit edge characters are moved; an internal apostrophe in
    /// the term is left intact. If the original is all punctuation, return the
    /// bare term. (Mac-only helper, ported for `applyFromDetections`.)
    private static func preservingEdgePunctuation(replacement: String, original: String) -> String {
        let leading = original.prefix { !$0.isLetter && !$0.isNumber }
        let trailing = original.reversed().prefix { !$0.isLetter && !$0.isNumber }
        guard leading.count + trailing.count < original.count else { return replacement }
        return String(leading) + replacement + String(trailing.reversed())
    }

    // MARK: - Gate decision

    /// Returns (pass, confidence, margin, label, unsure). `label` is APPLY /
    /// BLOCK / OVERRIDE so the caller can log + persist the verdict. `unsure` is
    /// true when the gate's confidence sits near the decision boundary (plan
    /// §v2-H) — used to prioritise the keyboard's quick-review asks.
    private static func decide(
        _ r: RescoreProposal,
        originalWord: String? = nil,
        wordConfidence: [String: Float],
        overrides: [CorrectionStore.OverrideEntry],
        aliases: [String],
        commonWords: Set<String>,
        // §6 — whatever admits a detection at 0.60 during PLACEMENT must pass the
        // same ceiling in here, or the correction vanishes with no proposal, no
        // review row and no log. Defaults to the flat 0.45, so the rescore path
        // and the `vocabulary_gate_decide` fixtures are untouched.
        ceiling: Double = plausibilityCeiling,
        // A confidence the caller's evidence MEASURED for this span (detection
        // path). Takes precedence over the token-timing map; nil = unknown.
        measuredConfidence: Float? = nil
    ) -> (pass: Bool, confidence: Float, margin: Float, label: String, unsure: Bool, askCandidate: Bool) {
        let margin = (r.replacementScore ?? r.originalScore) - r.originalScore
        // The EFFECTIVE span identity (aligned-narrowed / dedup-widened) when
        // the caller adjusted it; every guard below keys on this, so the
        // decision matches the words the replacement actually touches.
        let base = normalize(originalWord ?? r.originalWord)
        let term = r.replacementWord ?? ""
        let baseWords = base.split(separator: " ").map(String.init)
        let measured = measuredConfidence ?? baseWords.compactMap { wordConfidence[$0] }.min()
        let confidence = measured ?? lowConfidence
        let isCommon = isCommonOriginal(base, commonWords: commonWords)
        // Genuine acoustic uncertainty: a MEASURED confidence between "shaky" and
        // "sure". Unknown confidence (tokens missed the confidence map — common
        // for the OOV names this feature targets) is NOT unsure, so it doesn't
        // over-prioritise the keyboard asks. (NOT raw block-margin either — a
        // confident word blocked by a big margin is the gate working. plan §v2-H.)
        let unsure = measured.map { $0 >= lowConfidence && $0 < confidenceCeiling } ?? false

        // (0) USER-CONFIRMED OVERRIDE (top of the gate). A confirmed mapping
        //     fires on the spotter's proposal alone — bypassing the guards — for
        //     this exact (originalWord → term) pair only. **A common-word original
        //     is NEVER auto-applied** (plan §v2-B): silently rewriting an everyday
        //     word everywhere is the headline over-correction bug, and per-
        //     occurrence review can't undo a paste that already left the device.
        //     For common originals the gate keeps proposing-and-asking; only the
        //     UI pre-highlights the learned term. Auto-apply is reserved for
        //     rare/OOV originals (net ≥ 1) and multi-word terms (self-gating below).
        // Case-insensitive term compare (V2-2 identity fix, diff-reviewed
        // round 2): the engine re-cases replacements from sentence context
        // ("Claude" vs "claude"), while the store keys terms lowercased — a
        // case-sensitive compare here silently missed learned overrides and
        // demotions for differently-capitalized occurrences.
        if let ov = overrides.first(where: {
            $0.originalWord == base && $0.term.lowercased() == term.lowercased()
        }) {
            // DEMOTED: the owner reverted this mapping (via the marks/bubble or the
            // accordion) → stop auto-applying it. Works for common AND rare
            // originals, so a wrong auto-correction the owner undid stays undone.
            if ov.net <= -1 {
                return (false, confidence, margin, "BLOCK", unsure, false)
            }
            // V2-4 EXPLICIT GRANT: the owner tapped "Always replace 'X' with
            // 'Y'" — auto-apply even for a common-word original. §v2-B's
            // intent holds: the user consented explicitly, on-screen, for
            // this EXACT pair; one revert revokes the grant (store-side).
            // An armed override auto-applies silently — never an ask candidate.
            if ov.alwaysReplace {
                return (true, confidence, margin, "OVERRIDE", unsure, false)
            }
            // CONFIRMED: auto-apply — rare/OOV originals only (common words never
            // auto-apply without the explicit grant, §v2-B). Armed → not an ask.
            if !isCommon, ov.net >= 1 {
                return (true, confidence, margin, "OVERRIDE", unsure, false)
            }
        }

        // (1) PLAUSIBILITY — the heard word must be an acoustically plausible
        //     cousin of the term (or of ANY of its aliases — an alias is the user
        //     TELLING us the pair is plausible). The CTC matcher fuzzy-matches
        //     with a low similarity floor and concatenates neighbouring words, so
        //     it can propose "Vikram"→"Sriram" or "Ramanathan"→"Ramaa" — half the
        //     letters different. No acoustic margin makes those right. Spaces are
        //     ignored in the measure so a merged ASR word ("ramanathan") scores
        //     fairly against a multi-word term ("Ramaa Nathan"). Sits after (0)
        //     so an owner-confirmed mapping (net ≥ 1) is never second-guessed,
        //     and BEFORE the multi-word fast-path so it closes that bypass too.
        //     A block here still emits a reviewable "kept" record — confirming
        //     it in review teaches the exception (net ≥ 1 → step 0 override).
        if !plausible(original: base, term: term, aliases: aliases, ceiling: ceiling) {
            // Implausible garbage ("Vikram"→"Sriram") — never an ask candidate.
            return (false, confidence, margin, "BLOCK", unsure, false)
        }

        // (2) A multi-word vocabulary TERM is precise and self-gating. Applied
        //     silently → not an ask candidate (§9(i) scopes the silent-OOV ask to
        //     single-word terms).
        if term.contains(" ") {
            return (true, confidence, margin, "APPLY", unsure, false)
        }
        // (3) Never overwrite a very confident word unless the term wins big.
        //     The gate working as intended (the "0.998 name" protector) — not an ask.
        if confidence >= confidenceCeiling && margin <= earnedMargin {
            return (false, confidence, margin, "BLOCK", unsure, false)
        }
        // (4) Everyday word → NEVER silently rewrite (plan §v2-B). A common word
        //     is always proposed-and-asked per occurrence; the only paths that
        //     auto-apply are the rare/OOV override (step 0) and multi-word terms
        //     (step 2), both above. This is the headline "every name becomes Jamy"
        //     protection — a common original is surfaced for review, never swapped.
        if isCommon {
            // §9 Option B (ii): an unarmed common-word near-miss that IS plausible
            // and a single-word term ("did you mean Lisa?"). Surface as an ask
            // candidate (Mac live pill) so the user can pick the term this time;
            // iOS's `AskPolicy` reads its own signals, not this flag. NOTE this is
            // the superset-merge reconciliation point: the Mac fork auto-ARMED a
            // common word at `commonArmThreshold` net here; iOS deliberately
            // REMOVED that (replaced by the explicit `alwaysReplace` grant at
            // step 0), and iOS wins — so no auto-arm, just the ask-candidate flag.
            return (false, confidence, margin, "BLOCK", unsure, true)
        }
        // (5) OOV-ish word (a likely name/jargon mis-hear) → allow.
        //     §9 Option B (i): single-word term APPLIED to a non-common original
        //     the model wasn't confident about — the silent-OOV "did you mean
        //     Vikram?" ask candidate.
        return (true, confidence, margin, "APPLY", unsure, true)
    }

    // MARK: - Alignment window (V2-1 — multi-word term over a WIDER span)

    /// Where a multi-word term's words sit inside a wider matched span.
    public enum AlignmentResult: Equatable {
        /// Exactly one contiguous window aligns, touching a span edge —
        /// `wordIndex` is the window's first word index within the span.
        case unique(wordIndex: Int)
        /// No window aligns (e.g. span "Claude Claude" vs term "Claude
        /// Code") or more than one does (repeated words) or the only
        /// window is mid-span (extra words on BOTH sides). Precision-first:
        /// the proposal must BLOCK, never trim-and-guess.
        case blocked
    }

    /// V2-1 (round-2 amendment): a multi-word term may only apply to a span
    /// with MORE words than the term when the term's words form ONE unique,
    /// ordered, contiguous, edge-touching window inside the span (per-word
    /// skeleton alignment at the plausibility ceiling). Extra words outside
    /// the window SURVIVE the replacement ("use Claude code" → window
    /// "Claude code", "use" survives). Anything ambiguous blocks. This
    /// closes both round-2 breaks: the eaten leading word (ledger #1) and
    /// the equal-width-shifted span ("Claude Claude" never aligns to
    /// "Claude Code" because word 2 fails per-word alignment).
    public static func alignmentWindow(termWords: [String], spanWords: [String]) -> AlignmentResult {
        guard termWords.count >= 2, spanWords.count > termWords.count else {
            // Equal width: require EVERY word to align (shifted spans block).
            if spanWords.count == termWords.count {
                let ok = zip(spanWords, termWords).allSatisfy { wordAligns($0, $1) }
                return ok ? .unique(wordIndex: 0) : .blocked
            }
            return .unique(wordIndex: 0)  // narrower span — dedup guard's domain
        }
        var matches: [Int] = []
        for start in 0...(spanWords.count - termWords.count) {
            let window = spanWords[start..<(start + termWords.count)]
            if zip(window, termWords).allSatisfy({ wordAligns($0, $1) }) {
                matches.append(start)
            }
        }
        guard matches.count == 1, let start = matches.first else { return .blocked }
        // Edge-touching: leading edge (start == 0) or trailing edge.
        let touchesEdge = start == 0 || start + termWords.count == spanWords.count
        return touchesEdge ? .unique(wordIndex: start) : .blocked
    }

    /// Per-word alignment at the same ceiling as the plausibility guard.
    private static func wordAligns(_ spanWord: String, _ termWord: String) -> Bool {
        let a = skeleton(spanWord)
        let b = skeleton(termWord)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(levenshtein(a, b)) / Double(max(a.count, b.count)) <= plausibilityCeiling
    }

    /// Character range of `count` whole words starting at word index
    /// `wordIndex` within `range` in `text`. nil if the slice doesn't have
    /// that many words (defensive).
    private static func wordSubrange(
        of range: Range<String.Index>, wordIndex: Int, count: Int, in text: String
    ) -> Range<String.Index>? {
        var starts: [String.Index] = []
        var ends: [String.Index] = []
        var i = range.lowerBound
        var inWord = false
        while i < range.upperBound {
            if text[i] == " " {
                if inWord { ends.append(i); inWord = false }
            } else if !inWord {
                starts.append(i); inWord = true
            }
            i = text.index(after: i)
        }
        if inWord { ends.append(range.upperBound) }
        guard wordIndex + count <= starts.count, ends.count == starts.count else { return nil }
        // Trim the window's ends to alphanumerics (diff-review fix): boundary
        // punctuation must stay OUTSIDE the replaced range so "cloud code,"
        // → "Claude Code," keeps its comma. Leading trim on the first word,
        // trailing trim on the last.
        var lo = starts[wordIndex]
        let wordEnd = ends[wordIndex]
        while lo < wordEnd, !(text[lo].isLetter || text[lo].isNumber) {
            lo = text.index(after: lo)
        }
        var hi = ends[wordIndex + count - 1]
        let lastStart = starts[wordIndex + count - 1]
        while hi > lastStart {
            let prev = text.index(before: hi)
            if text[prev].isLetter || text[prev].isNumber { break }
            hi = prev
        }
        guard lo < hi else { return nil }
        return lo..<hi
    }

    // MARK: - Dedup guard (multi-word term over a narrower span)

    /// When a multi-word term is applied over a span with FEWER words than
    /// the term ("Claude Code" over just "clawed"), and the term's trailing
    /// word(s) duplicate the transcript word(s) immediately after the span,
    /// return the span widened to absorb those duplicates — so the apply
    /// yields "Claude Code" once, never "Claude Code code". Returns nil when
    /// nothing should be absorbed.
    ///
    /// Precision rules: absorb at most (term words − span words) words — a
    /// span that already covers every term word absorbs NOTHING, so a real
    /// following "code" ("Claude Code code review") is never eaten; only
    /// cross plain spaces (any punctuation or newline between blocks it);
    /// compare letter skeletons (case/punctuation-insensitive) and require
    /// EXACT equality; the widened span ends at the absorbed word's last
    /// alphanumeric so its trailing punctuation survives outside the span.
    private static func absorbTrailingDuplicates(
        term: String,
        spanWord: String,
        range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        let termSkels = term.split(separator: " ").map { skeleton(String($0)) }
        let spanWordCount = spanWord.split(separator: " ").count
        let maxAbsorb = termSkels.count - spanWordCount
        guard maxAbsorb >= 1 else { return nil }

        // Collect up to `maxAbsorb` following words (plain-space separated).
        var follow: [(skel: [Character], letterEnd: String.Index)] = []
        var i = range.upperBound
        scan: while follow.count < maxAbsorb, i < text.endIndex {
            // Cross plain spaces only — punctuation/newline ends the run.
            guard text[i] == " " else { break }
            while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
            guard i < text.endIndex, text[i].isLetter || text[i].isNumber else { break }
            // Read the token up to the next space/newline; track its last
            // alphanumeric so "code," absorbs as "code" and keeps the comma.
            var wordEnd = i
            var lastAlnum = i
            while wordEnd < text.endIndex, text[wordEnd] != " ", text[wordEnd] != "\n" {
                if text[wordEnd].isLetter || text[wordEnd].isNumber { lastAlnum = wordEnd }
                wordEnd = text.index(after: wordEnd)
            }
            let letterEnd = text.index(after: lastAlnum)
            follow.append((skeleton(String(text[i..<letterEnd])), letterEnd))
            // Trailing punctuation on this token ends the absorbable run.
            if letterEnd != wordEnd { break scan }
            i = wordEnd
        }
        guard !follow.isEmpty else { return nil }

        // Longest suffix of the term's words that equals the following words.
        var n = min(maxAbsorb, follow.count)
        while n > 0 {
            let tail = Array(termSkels.suffix(n))
            let head = follow.prefix(n).map(\.skel)
            if tail == head {
                return range.lowerBound..<follow[n - 1].letterEnd
            }
            n -= 1
        }
        return nil
    }

    // MARK: - Extension alternates (3-option ask)

    /// Longer vocab siblings of the winning term whose extra words match the
    /// transcript words that FOLLOW the span. FluidAudio's greedy merge
    /// prefers the SHORTER span ("Prefer shorter spans", its Pass 2), so when
    /// the user's list has both "Claude" and "Claude Code", "Claude" always
    /// wins and the longer candidate is dropped inside the package — this
    /// re-derives it so the ask card can offer all three choices. The
    /// extension words must be an acoustic cousin of what follows (same
    /// skeleton-distance ceiling as the plausibility guard), and never cross
    /// a paragraph break. Capped at 2 (the keyboard card surfaces 1).
    private static func extensionAlternates(
        winnerTerm: String?,
        publishedText: String,
        after upperBound: String.Index,
        in transcript: String,
        allTerms: [String]
    ) -> [Alternate] {
        guard let winner = winnerTerm, !winner.isEmpty, !allTerms.isEmpty else { return [] }
        let winnerLower = winner.lowercased()
        var out: [Alternate] = []
        for term in allTerms {
            guard out.count < 2 else { break }
            let termLower = term.lowercased()
            guard termLower != winnerLower,
                  termLower.hasPrefix(winnerLower + " ") else { continue }
            let extensionText = String(term.dropFirst(winner.count))
                .trimmingCharacters(in: .whitespaces)
            let extWords = extensionText.split(separator: " ").map(String.init)
            guard !extWords.isEmpty else { continue }
            let follow = nextWords(count: extWords.count, after: upperBound, in: transcript)
            guard follow.count == extWords.count, let lastEnd = follow.last?.end else { continue }
            let a = skeleton(follow.map(\.word).joined())
            let b = skeleton(extensionText)
            guard !a.isEmpty, !b.isEmpty else { continue }
            let ratio = Double(levenshtein(a, b)) / Double(max(a.count, b.count))
            guard ratio <= plausibilityCeiling else { continue }
            // `find` is built from the EXACT transcript slice after the span
            // (diff-review fix): double spaces / odd separators are preserved
            // verbatim so the strict anchored splice can actually match.
            out.append(
                Alternate(
                    term: term,
                    find: publishedText + String(transcript[upperBound..<lastEnd])
                )
            )
        }
        return out
    }

    /// The next `count` space-separated words after `start` in `text`,
    /// each with its end index (trailing punctuation retained — consumers
    /// trim it; stops at a newline so an alternate never extends across a
    /// paragraph break).
    private static func nextWords(
        count: Int, after start: String.Index, in text: String
    ) -> [(word: String, end: String.Index)] {
        var words: [(word: String, end: String.Index)] = []
        var current = ""
        var i = start
        while i < text.endIndex, words.count < count {
            let ch = text[i]
            if ch == "\n" { break }
            if ch == " " {
                if !current.isEmpty { words.append((current, i)); current = "" }
            } else {
                current.append(ch)
            }
            i = text.index(after: i)
        }
        if !current.isEmpty, words.count < count { words.append((current, i)) }
        return words
    }

    // MARK: - Plausibility (guard 1)

    /// Max normalized edit distance (Levenshtein over letter-skeletons, divided
    /// by the longer skeleton) for the heard word to count as an acoustic cousin
    /// of the term. Measured on real pairs: shriram→sriram 0.14, cloud→claude
    /// 0.33, jamie→jamy 0.40 (all pass); vikram→sriram 0.50, ramanathan→ramaa
    /// 0.50, name→jamy 0.50 (all block).
    public static let plausibilityCeiling: Double = 0.45

    /// Internal, not private: the edit learner (`EditLearner`) admits only
    /// sound-alike substitutions by this exact test.
    static func plausible(
        original: String, term: String, aliases: [String],
        ceiling: Double = plausibilityCeiling
    ) -> Bool {
        let heard = skeleton(original)
        guard !heard.isEmpty else { return true }
        for candidate in [term] + aliases {
            let c = skeleton(candidate)
            guard !c.isEmpty else { continue }
            let ratio = Double(levenshtein(heard, c)) / Double(max(heard.count, c.count))
            if ratio <= ceiling { return true }
        }
        return false
    }

    /// Lowercased alphanumerics only — spaces and punctuation dropped so a
    /// merged ASR word ("ramanathan") measures fairly against a multi-word
    /// term ("Ramaa Nathan" → "ramaanathan"). NFC-precomposed first
    /// (diff-review fix) so canonically-equivalent Unicode (composed vs
    /// decomposed "é") skeletons identically instead of dropping a
    /// combining mark.
    /// Internal, not private: `VocabularyCorrector` (§1) matches with the EXACT
    /// same metric the gate judges with. Two metrics that drift apart would let
    /// the corrector propose spans the gate then silently refuses.
    static func skeleton(_ s: String) -> [Character] {
        s.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
    }

    /// Plain two-row Levenshtein. Inputs are short (words/short phrases), so
    /// O(a·b) is trivially cheap even on the transcription hot path.
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: - Helpers

    /// **The gate's own common-word test**, exposed so learning (A3/R9) and asks
    /// judge an original by exactly the rule the brake applies: the original is
    /// common when ANY of its words is in the language's everyday-word set.
    /// `original` is normalized the way the store keys it, so a stored mapping
    /// key and a raw span give the same answer.
    public static func isCommonOriginal(_ original: String, commonWords: Set<String>) -> Bool {
        guard !commonWords.isEmpty else { return false }
        return normalize(original)
            .split(separator: " ")
            .contains { commonWords.contains($0.lowercased()) }
    }

    private static func normalize(_ s: String) -> String {
        // Diff-review fix: MUST be the same normalization the store keys use
        // (`CorrectionKey`) — the override lookup compares this output to
        // store-normalized keys, and any divergence (NFC, whitespace runs)
        // silently misses learned overrides/demotions.
        CorrectionKey.normalize(s)
    }

    /// Per-word minimum *content-token* confidence, keyed by lowercased word.
    /// A new word begins at a token with a leading space / `▁` boundary; the
    /// minimum is taken over alphabetic (content) tokens only — punctuation and
    /// casing tokens would otherwise produce false low-confidence flags. When a
    /// word repeats, the lowest occurrence's confidence is kept (conservative).
    private static func perWordMinConfidence(_ timings: [TokenTiming]) -> [String: Float] {
        var out: [String: Float] = [:]
        var word = ""
        var minConf: Float = 1.0

        func flush() {
            let key = normalize(word)
            if !key.isEmpty {
                out[key] = min(out[key] ?? 1.0, minConf)
            }
            word = ""
            minConf = 1.0
        }

        for t in timings {
            let startsWord = t.token.hasPrefix(" ") || t.token.hasPrefix("\u{2581}")
            let piece = t.token
                .replacingOccurrences(of: "\u{2581}", with: "")
                .trimmingCharacters(in: .whitespaces)
            if startsWord { flush() }
            word += piece
            if piece.rangeOfCharacter(from: .letters) != nil {
                minConf = min(minConf, t.confidence)
            }
        }
        flush()
        return out
    }

    /// The `occurrence`-th (0-based) whole-word range of `word` in `text`.
    private static func nthWholeWordRange(
        of word: String,
        in text: String,
        occurrence n: Int
    ) -> Range<String.Index>? {
        var search = text.startIndex
        var count = 0
        while let r = wholeWordRange(of: word, in: text, from: search) {
            if count == n { return r }
            count += 1
            search = r.upperBound
        }
        return nil
    }

    /// Whole-word range of `word` in `text` at/after `from` (so "name" does not
    /// match inside "rename"). `word` may itself be a multi-word phrase.
    private static func wholeWordRange(
        of word: String,
        in text: String,
        from: String.Index
    ) -> Range<String.Index>? {
        var search = from
        while let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
            let before: Character? = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after: Character? = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let okBefore = !(before?.isLetter ?? false)
            let okAfter = !(after?.isLetter ?? false)
            if okBefore && okAfter { return r }
            search = r.upperBound
        }
        return nil
    }
}
