# JotTextPipeline

Shared, deterministic post-transcription **text-cleanup pipeline** for Jot,
extracted so the iOS app, the macOS app, and any future port build from **one
source** instead of drifting copies.

## What's in it

Three pure, I/O-free components (Foundation only — no ASR engine, no CoreML, no
platform dependency):

| Component | Entry point | Purpose |
|---|---|---|
| `FillerWordCleaner` | `clean(_:) -> String` | Strip "um/uh/…" fillers, recapitalize sentences, single trailing space |
| `NumberNormalizer` | `normalize(_:) -> String` | Spelled-number → digits ITN: cardinals, money, percent, times, years, dates, decimals, durations |
| `ParagraphSegmenter` | `segment(rescoredText:tokenTimings:) -> String` | Insert `\n\n` paragraph breaks from word timing + sentence-final punctuation |

The apps compose them in order: **segment → filler-clean → number-normalize**.

## Token timing

`ParagraphSegmenter` consumes `[TokenTiming]` — a lightweight, engine-neutral
value type (`token`, `startTime`, `endTime`) defined in this package. In the
shipping apps the ASR layer (FluidAudio) produces its own richer `TokenTiming`;
consumers map their engine's timings into this type at the call site. This keeps
the pipeline free of any ASR/CoreML/platform dependency so a non-Apple port is
possible.

## Golden fixtures = the conformance contract

`Tests/JotTextPipelineTests/Fixtures/*.json` are language-neutral
input→expected files fed through the **public** API. They are the
cross-platform conformance contract: a future non-Apple (e.g. Windows) port must
reproduce the same outputs from the same fixtures.

Provenance:

- `number_normalizer.json`, `filler_word_cleaner.json`,
  `paragraph_segmenter_apply.json`, `paragraph_segmenter_reassemble.json` —
  ported verbatim from the hand-authored mobile XCTest suites.
- `number_normalizer_itn.json` — the newer decimals/years/dates/durations ITN
  behavior (mobile build ~269). Expected values frozen from current mobile
  `NumberNormalizer` behavior and cross-checked against
  `docs/plans/number-normalization-improvements.md` in the mobile repo.

```
swift test
```

## Provenance of the sources

The three components were copied **verbatim** from the iOS app
(`Jot/App/Transcription/`), the source of truth. The only deviations required to
compile standalone: `public` access on the enums + entry points and the
`Word`/`TokenTiming` types, and `ParagraphSegmenter` now uses this package's
`TokenTiming` instead of `import FluidAudio`. Doc comments still carry
mobile-flavored surface names (e.g. "keyboard", "hero") pending a genericization
pass.
