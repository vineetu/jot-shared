# Multilingual Inverse Text Normalization (ITN) — options for the shared text pipeline

Decision doc. ITN = spoken numbers/dates → digits ("two hundred" → "200",
"veinticinco por ciento" → "25 %"). Today Jot does this for **English only**.
This asks: should the freshly-extracted `JotTextPipeline` grow per-language ITN,
and if so how.

**TL;DR recommendation (numbers):** Do nothing yet (Option D), but first run a
15-minute empirical test to close the one load-bearing unknown (does Parakeet v3
even emit spoken-form numbers, or does it already print digits?). If — and only
if — the test shows v3 emits written-out words **and** German/Spanish/French
usage actually shows up, take the narrow hybrid (Option C): link FluidAudio's
already-wired NeMo wrapper for those 3 languages **at the app's ASR layer, not
inside the shared package**. Keep English on the battle-tested `NumberNormalizer`
and keep `JotTextPipeline` Foundation-pure.

**TL;DR recommendation (fillers — §5):** Different, easier problem, no NeMo
involved. When (if) v3 European usage appears, ship a small **non-lexical
hesitation-sound** list per language (es "eh", de "äh/ähm", fr "euh", it "ehm",
pt "hum") reusing the existing English regex machinery — cheap and low-risk
because these tokens are never content words. **Do not** strip the lexical
discourse fillers (es "este/pues/o sea", pt "tipo/né", fr "ben/du coup", de
"halt/genau") — they are homographs of real words, deleting them corrupts
meaning, and there is no one to validate the output.

---

## 1. Ground truth (verified in code)

### 1.1 What `NumberNormalizer` is today
`Sources/JotTextPipeline/NumberNormalizer.swift` — a pure-Foundation enum,
**English-pattern-only** (hard-coded English cardinal words `one…nineteen`,
`twenty…ninety`, `hundred/thousand/million`; English month names; `dollars`,
`percent`, `o'clock`, `AM/PM`; US-style thousands commas via `NumberFormatter`).
Rule families present:

| Rule | Example | Location |
|---|---|---|
| Large-scale pass-through | "twenty-five million" stays words | `NumberNormalizer.swift:51`, `:209` |
| Dates (month + day-ordinal) | "March third" → "March 3rd" | `:63` |
| Tens-ordinal combiner | "twenty third" → "23rd" | `:98` |
| Year shapes | "nineteen ninety-eight" → "1998" | `:133`, `parseYearShape :594` |
| Address / room runs | "four oh seven" → "407" | `:162`, `:701` |
| Decimals | "one point five" → "1.5" | `parseDecimalTail :1431` |
| Money | "five dollars and fifty cents" → "$5.50" | `rewriteSequence :1138` |
| Percent | "twenty percent" → "20%" | `:1167` |
| Time-of-day | "at four" → "at 4", "four thirty" → "4:30" | `:1188` |
| Cardinals ≥ 10 | "twenty five" → "25" | `:1238` |
| Phone-shape bail-out | ≥7 spelled digits → leave whole text alone | `containsPhoneShape :527` |

It was tuned with a **harness-first loop over 2,711 real English recordings** (0
false positives — see mobile memory `project_number_itn_decimals_years_dates`).
That validation cost is the reason hand-rolling *another* language is expensive.

### 1.2 It runs English-only, by an explicit gate
Both call sites in the mobile app gate on `LanguageChoice.current.isEnglish`:

- `Jot/App/Transcription/TranscriptionService.swift:1033` (batch/hero/keyboard/wizard/intent)
- `Jot/App/Transcription/TranscriptionService.swift:1314` (live-preview re-transcribe)

The doc comment there (`:1026`) states the reason: `FillerWordCleaner` +
`NumberNormalizer` are "English-oriented regex/lookup passes; running them on a
non-English v3 transcript would mangle it." `ParagraphSegmenter` (pause-based) is
language-agnostic and runs for every language; the two text passes do not.
The Mac app makes the same choice (`jot/docs/features.md:31,36`: the cleanup
chain is "Parakeet v2 only"; v3 / Japanese / Nemotron skip it).

### 1.3 Engine routing (who produces text per language)
From `Jot/App/Transcription/LanguageChoice.swift`:

- **English** → bundled **Parakeet v2** (110M on sub-6GB devices). Raw-ish
  output; `NumberNormalizer` runs. **Confirmed.**
- **~23 European languages** → **Parakeet v3** (FluidAudio, one shared
  multilingual model): es, fr, de, it, pt, ro, pl, cs, sk, sl, hr, bs, sr, ru,
  uk, be, bg, da, nl, fi, el, hu, sv (`common-words-<code>` list per language,
  `LanguageChoice.swift:100`). **No ITN runs today** (isEnglish gate blocks it).
- **CJK + Latin-American Spanish** → Apple **`SpeechTranscriber`**
  (`isAppleOnly`, `LanguageChoice.swift:77`): ja, ko, chineseMandarin,
  chineseTraditional, cantoneseHongKong, cantoneseMainland, spanishLatinAmerica.
  No Jot ITN runs.

The **Mac** app additionally has **Nemotron** (English premium) and **Qwen3-ASR**
(Mandarin/Cantonese/Vietnamese, experimental) — both skip the cleanup chain
(`jot/docs/features.md:27,30,36`).

### 1.4 Does Apple's SpeechTranscriber do native per-locale ITN?
**Assumption, code-consistent, worth a 5-minute device check.** `AppleStreamingSession.swift`
builds the transcriber from the `timeIndexedTranscriptionWithAlternatives`
preset (`:226`) and requests no "raw / unformatted" option. Apple's Speech
framework applies locale-aware formatting (digits, currency, dates) to formatted
transcription by default, and the code neither disables it nor post-processes
Apple output. So Apple-routed languages almost certainly get Apple's native ITN
for free — but this is inferred from the absence of an opt-out, not from an
explicit "formatting on" call, so treat it as an assumption to confirm on device
(dictate "veinticinco por ciento" in es-MX, check for "25 %").

### 1.5 Does Parakeet v3 emit spoken-form or written-form numbers? — **UNKNOWN, load-bearing**
**Not determinable from code or docs.** This is the hinge of the whole decision.
- FluidAudio's benchmark note (`FluidAudio/Documentation/Benchmarks.md:513`)
  normalizes *both* hypothesis and reference through NeMo ITN for FLEURS scoring
  because FLEURS is "digit-bearing" — consistent with the raw model emitting
  **spoken-form** words that need ITN, but not proof.
- The Mac features doc says v3 "emit[s] clean, cased, punctuated text natively"
  (`jot/docs/features.md:36`) — that's about casing/punctuation, **silent on
  whether numbers come out as digits or words.**

If v3 already prints "25 %", there is **no problem to solve** and every option
below is moot. **Test this first** — the owner has one Spanish tester; one
recording answers it.

---

## 2. The need matrix (the surprising part)

| Language group | Engine | Emits numbers as… | ITN today | ITN gap? |
|---|---|---|---|---|
| English | Parakeet v2 (bundled) | spoken-form | `NumberNormalizer` (EN) | **No** — solved |
| es, fr, de | Parakeet v3 | *unknown (§1.5)* | none | Maybe — **NeMo covers these 3** |
| it, pt, ro, pl, cs, sk, sl, hr, bs, sr, ru, uk, be, bg, da, nl, fi, el, hu, sv (20) | Parakeet v3 | *unknown (§1.5)* | none | Maybe — **NeMo covers NONE of these** |
| ja, ko, zh-*, yue-*, es-MX (Apple) | Apple SpeechTranscriber | Apple native ITN (assumed §1.4) | Apple's | Probably no |
| Mandarin/Cantonese/Vietnamese (Mac only) | Qwen3 | native CJK | none | Low priority |

**Most surprising finding:** the "one engine, many languages" NeMo option
(text-processing-rs) supports ITN for **EN, DE, ES, FR, HI, JA, ZH — 7
languages**. Intersected with Jot's ~23 Parakeet-v3 European languages, that is
exactly **three** (de, es, fr). JA/ZH are Apple-routed already, HI isn't a Jot
language. So the multilingual ITN problem is **largely unsolved by any
off-the-shelf tool** — no option here gives ITN to the other 20 European
languages (Slavic, Cyrillic, Nordic, Greek, Hungarian). This reframes the
question from "how do we get multilingual ITN" to "is it worth wiring ITN for de/es/fr."

---

## 3. Options

### A. Hand-rolled per-language normalizers (in the package)
Port the English harness-first approach to each language.
- **Effort:** very high per language. English took a 2,711-recording tuning loop.
  Non-English number grammar (gender/agreement in es/fr; Slavic case; Nordic
  compounding) is materially harder, and **no one on the team can validate the
  output** — the English loop worked because the owner reads English.
- **Risk to pipeline:** stays Foundation-pure ✓, but 23× the surface area of
  hand-tuned regex is a maintenance sink.
- **Fixtures/Windows:** clean — pure fixtures, trivially portable. ✓
- **Verdict:** not worth it for non-English. No validator, no leverage.

### B. NeMo WFST ITN via text-processing-rs (one library, swap English too)
[FluidInference/text-processing-rs](https://github.com/FluidInference/text-processing-rs)
— Rust port of NVIDIA NeMo Text Processing, **Apache 2.0**, ITN for 7 languages
(EN/DE/ES/FR/HI/JA/ZH), 98.6% NeMo-suite compat (1200/1217). C FFI, ships an
**XCFramework** (`aarch64-apple-ios`, `-sim`, `-darwin`) with a generated Swift
wrapper. FluidAudio **already ships the Swift consumer** —
`FluidAudio/Sources/FluidAudio/ITN/TextNormalizer.swift` — which `dlsym`s the
`nemo_*` C symbols at runtime and no-ops (`isNativeAvailable = false`) when the
native lib isn't linked. So the Swift side is *already written*; the cost is
building/linking the Rust binary.
- **Effort:** medium (build Rust → XCFramework → link → enable), one-time.
- **Risk to pipeline:** **high if done inside `JotTextPipeline`** — it would
  turn the just-extracted Foundation-only, Windows-portable-via-fixtures package
  into one carrying a linked native Rust binary, breaking the purity that was the
  whole point of the extraction. Also throws away the 0-FP battle-tested English
  normalizer to gain **only de/es/fr** (§2).
- **Windows:** text-processing-rs also builds Rust/WASM/CLI, so a Windows app can
  consume the same grammars directly. ✓ (Windows is **not mentioned** in the
  repo's platform list — assume unproven, though Rust cross-compiles.)
- **Verdict:** wrong to swap wholesale, and wrong to put in the shared package.

### C. Hybrid — keep English `NumberNormalizer`; add NeMo for de/es/fr only, at the app ASR layer
Leave `JotTextPipeline`/`NumberNormalizer` exactly as-is for English. For the
three NeMo-covered European languages, enable **FluidAudio's `TextNormalizer`**
(§B — already wired via `dlsym`) in the mobile app's ASR layer
(`TranscriptionService`), *outside* the shared package, linked as the
XCFramework. Windows expresses the same behavior via text-processing-rs directly.
- **Effort:** medium, but bounded to 3 languages and reusing FluidAudio's wrapper.
- **Risk to pipeline:** **low** — the shared package stays Foundation-pure; the
  native dependency lives in the app's FluidAudio-adjacent layer where FluidAudio
  (also native) already lives.
- **Fixtures/Windows:** the *English* fixtures stay authoritative; de/es/fr ITN
  is conformance-tested against NeMo's own suite, not ours. Windows uses the same
  Rust grammars → same outputs. ✓
- **Owner-visible change:** German/Spanish/French dictation starts turning
  "veinticinco por ciento" into "25 %". No change for the other 20 languages.
- **Verdict:** the right shape *if* the §1.5 test says v3 emits words and usage warrants.

### D. Do nothing yet
Rely on Apple for Apple-routed languages (native ITN, §1.4); accept written-out
numbers on v3 European until real usage demands otherwise (owner has **one** known
Spanish tester).
- **Effort:** zero. **Risk:** zero. **Pipeline:** untouched, stays pure.
- **Owner-visible change:** none.
- **Verdict:** correct default given the unknown in §1.5 and near-zero non-English
  usage. Cheap to leave; Option C is available the moment demand appears.

---

## 4. Recommendation

**Adopt D now; pre-stage C.** Concretely:

1. **Close the §1.5 unknown first** (15 min): one Spanish recording through v3 —
   does it print "25 %" or "veinticinco por ciento"? This gates everything. If
   v3 already emits digits, stop — there is no problem.
2. **If v3 emits words:** still ship nothing until de/es/fr usage is real. When it
   is, take **Option C** — link the text-processing-rs XCFramework and flip on
   FluidAudio's existing `TextNormalizer` for those three languages only, in the
   app ASR layer. **Do not** put NeMo inside `JotTextPipeline`; keep the package
   Foundation-only so the Windows port stays a pure-fixture reimplementation.
3. **Never** hand-roll non-English normalizers (Option A) — there's no one to
   validate them — and **never** swap English off its 0-FP normalizer (Option B).
4. Accept that **~20 European languages will have no ITN under any option** — that
   is a tool-coverage fact, not a Jot decision, and not worth custom work for
   near-zero usage.

## 5. Filler words (added scope)

Separate feature from ITN, and a genuinely **easier** problem — no arithmetic, no
grammar, just a word list plus (sometimes) position rules. Different enough that
the numbers recommendation does not carry over.

### 5.1 Ground truth
`Sources/JotTextPipeline/FillerWordCleaner.swift` — English-only. It strips
exactly five patterns (case-insensitive, word-boundary), plus their elongations:
`um(m+)?`, `uh(h+)?`, `er(r+)?`, `uhm`, `erm` (`FillerWordCleaner.swift:22`). It
then collapses whitespace, removes orphan punctuation, recapitalizes sentences,
and appends one trailing space. It is **not** position-aware for the filler match
itself — a flat regex sweep works because **every token in that list is
non-lexical**: "um/uh/er/uhm/erm" are hesitation sounds that are never English
content words (the `\b` guard only protects substrings like "umbrella"). Runs
**English-only**, gated by the same `isEnglish` check as `NumberNormalizer`
(`TranscriptionService.swift:1036`, `:1315`) — so non-English v3 transcripts get
**no** filler cleaning today.

### 5.2 Why non-English is harder than it looks (the trap)
English got a free ride: its fillers have no lexical meaning, so a wholesale
word-list delete is safe. **Most other languages' fillers are homographs of real
content words**, so the same approach would silently delete meaning:

| Lang | Safe (non-lexical hesitation) | **Dangerous (lexical/discourse — homographs)** |
|---|---|---|
| es | eh, em | **este** (="this"), **pues** (="then/well"), **o sea**, **digamos** |
| de | äh, ähm, öh, hm | **halt**, **genau** (="exactly"), **eigentlich** (="actually"), **also**, **tja** |
| fr | euh | **ben/bah**, **quoi** (="what"), **du coup**, **tu vois/tu sais**, **eh bien** |
| pt | hum, é (é also ="is") | **tipo** (="type/like"), **né** (="right?"), **então** (="so"), **bem** (="well") |
| it | ehm, mmm | **cioè** (="that is"), **tipo**, **allora** (="so"), **be'** |

The safe column can be swept flat like English. The dangerous column would need
the kind of part-of-speech / position disambiguation that FluidAudio's own ITN
wrapper reaches for with `NLTagger` on English ambiguous words like "period"
(`FluidAudio/Sources/FluidAudio/ITN/TextNormalizer.swift:323`) — and even that is
English-only and imperfect. **No team member can validate, say, Polish or Greek
disfluency edits**, the same blocker as hand-rolled ITN (§3A).

### 5.3 Does NeMo / text-processing-rs help? — **No. Confirmed.**
text-processing-rs is **ITN/TN only** (numbers, currency, dates, ordinals — see
its example table in `FluidAudio/Documentation/ASR/PostProcessing.md`). It has
**no disfluency/filler removal**. So the numbers option (B/C) contributes nothing
here — fillers are entirely a word-list-in-the-package question.

### 5.4 Need matrix (who even emits fillers)

| Language group | Engine | Emits fillers? | Cleaned today | Gap? |
|---|---|---|---|---|
| English | Parakeet v2 | yes (verbatim ASR) | `FillerWordCleaner` (EN) | No — solved |
| ~23 European | Parakeet v3 | **assume yes** (verbatim ASR, same as v2) | none | Yes — safe subset unstripped |
| ja/ko/zh/yue/es-MX | Apple SpeechTranscriber | **assume no** (Apple suppresses hesitations natively) | Apple's | Probably no — **verify on device** |

Both "emits?" cells are assumptions worth a one-recording check: dictate a
hesitant Spanish sentence through v3 (does "eh" survive?) and through Apple es-MX
(does it?). Apple dictation has historically dropped "um/uh" natively, so the
Apple-routed set is likely already clean.

### 5.5 Options & recommendation (fillers)
- **Package resource lists per language** (mirroring the `common-words-<code>`
  dictionaries): natural fit, Windows-portable via fixtures, but overkill as
  *files* for ~5 tokens each — a static per-language map inside `FillerWordCleaner`
  is simpler and stays Foundation-pure. Either keeps the package clean.
- **Recommendation:** when v3 European usage materializes, add the **non-lexical
  hesitation subset only** (es/de/fr/it/pt column 1 above), swept with the
  existing regex — **low effort, low risk** (non-lexical ⇒ no context engine
  needed, no meaning-deletion risk). Explicitly **punt on lexical discourse
  fillers indefinitely** — they need per-language POS/position rules and a
  validator Jot doesn't have, for marginal benefit. This is a cleaner win than
  ITN: no NeMo, no native binary, no blocking unknown — just gated on the same
  "is there non-English usage yet" trigger.

## 6. Open questions
- **§1.5 (blocking, numbers):** v3 number output form — spoken vs written. Test before anything.
- **§5.4 (fillers):** Does v3 emit filler sounds, and does Apple suppress them for es-MX/CJK? One recording each.
- **§1.4:** Confirm Apple SpeechTranscriber applies native ITN for es-MX/CJK on device.
- text-processing-rs **on-device footprint** (XCFramework binary size, load time) —
  not published; measure before committing to C. Keyboard extension has a ~60 MB
  ceiling, so any native lib must be kept out of the keyboard target's link.
- text-processing-rs **Windows** build — Rust cross-compiles but the repo doesn't
  claim Windows support; the Windows team should validate the CLI/WASM path.
- Does the **mobile Parakeet v3** path want ITN at all, or is written-out numbers
  acceptable UX for dictation? (Product call — one Spanish tester can't answer it.)

---

## Addendum (2026-07-16): §1.5 gating unknown CLOSED — measured

TTS-probe (macOS `say` es/de/fr/en clips → v3 via AsrManager, app's cached model, per-language hints; probe in session scratchpad `v3probe/`): **Parakeet v3 emits DIGITS with built-in inline ITN for EN, ES, DE, and FR** — `25%`, locale-correct decimal separators (`3.14` EN / `3,14` ES-DE-FR), 4-digit years, `$100` in EN. Words-form appeared only as an occasional escape on isolated small round cardinals ("Fifty dollars", "Cien euros").

**DECISION CONSEQUENCE: Option D (do nothing) WINS with evidence.** Options A/B/C are dead — there is no de/es/fr written-numbers gap to close, so text-processing-rs is not needed. Residual (parked): the small-round-cardinal escape tail; if it ever grates, a tiny per-language cardinal word-map in NumberNormalizer covers it — no library required. English keeps its battle-tested normalizer for v2's raw output (v2 is the only engine that truly needs it).

## Addendum 2 (2026-07-16): §5 filler need-matrix cell — measured (indicative)

Same TTS probe, hesitation-led clips: **v3 does NOT strip hesitations.** "Um," (EN) and "Euh," (FR) surface VERBATIM; bare-vowel fillers get MANGLED to stray single letters (es "eh"→"E,", de "ähm"→"M,") or occasionally dropped (de "äh"). Numbers stayed digits+ITN in every clip. Caveat: synthesized fillers are cleaner than real disfluencies — treat as directional.

Consequences for §5's recommendation: (a) the per-language NON-LEXICAL filler lists have confirmed value for v3 European languages (fillers do reach transcripts); (b) NEW: the cleaner should also sweep the mangled-filler artifact class — a stray single letter followed by a comma at a clause start ("E,", "M,") — a pattern rule, not a word list; treat as part of the same future work item.

## Addendum 3 (2026-07-20): Nemotron-multilingual "latin" measured — findings do NOT mirror v3

Same TTS-probe method (macOS `say` FR Thomas+Jacques / ES Mónica → 16kHz mono → the app's
`StreamingNemotronMultilingualAsrManager` via the prebuilt `tools/nemotron-headdrop-probe` harness,
raw `finish()` text, one-shot and 100ms-streaming paths agreed on every clip):

- **Numbers are ASYMMETRIC per language, not per model.** ES: inline ITN like v3 (`3,14`, `2026`,
  `600 euros`, `100 dólares`). FR: **fully spelled words, 8/8 clips, 2 voices** — "six cents euros"
  stays words. So Nemotron-latin French HAS a numbers gap that v3 French does not; the premium FR
  path emits less-polished numbers than the free v3 fallback. Decision: PARKED (usage-gated, same
  philosophy as §4) — closing it means Option A (rejected: no validator) or Option C scoped to FR
  (NeMo covers FR; FluidAudio's dlsym TextNormalizer wrapper already ships) at real binary cost.
- **Fillers: Nemotron DROPS hesitations natively** (opposite of v3's verbatim "Euh,"). Residual
  mangle tail ("euh"→"eux", "em"→"en"/stray "m") of the same stray-letter class as v3's. The §5.5
  per-language filler sweep therefore mainly benefits the v3 path (sub-threshold-RAM machines).
- **`<unk>` leak (BUG, user-visible today):** neither latin (2,829 tok) nor multilingual (13,087 tok)
  tokenizer vocab contains `%`/`€`/`$` at all, while multi-digit tokens exist — so ES
  "veinticinco por ciento" emits the literal string `25<unk>`. No `<unk>` scrub exists in FluidAudio's
  decode path or the app's post-processing (grepped). Fix app-side: strip `<unk>`; digit-adjacent
  `<unk>` → `%` (evidence: ITN symbolizes only percent — currency stays words).
- Caveat: TTS clips are cleaner than real speech; filler findings directional (same caveat as Add. 2).

## Addendum 4 (2026-07-20): downloadable-pack plan tested — text-processing-rs ITN is ENGLISH-ONLY; French pack DEAD

Owner approved a download-on-demand ITN pack (ride the model downloader, Developer-ID-sign a dylib,
host on the models-v1 mirror). Feasibility measured before building:
- **Packaging: VALIDATED, cheap.** The release .a links into an arm64-only dylib exporting just the
  4 nemo_* symbols → **11 MB** (not the feared 28-47). dlopen/dlsym works; FluidAudio's wrapper
  pattern adapts. Signing (same-team Developer ID) + mirror hosting straightforward. If upstream ever
  ships non-EN ITN, this pipeline is a week of work, not a month.
- **The library: DISQUALIFYING.** Empirical FFI test (v0.3.0): the ITN direction (`nemo_normalize*`)
  has NO language parameter and is English-grammar-only. The 7-language support (`en fr es de zh hi ja`)
  exists ONLY in the TN direction (`nemo_tn_normalize_lang` — written→spoken, useless for ASR).
  Measured: EN "twenty five percent"→"25 %" ✓; **FR "six cents euros" → "$0.06 euros"** — the exact
  six-cents catastrophe the English gate guards against, now produced by the library itself; ES/DE
  inputs pass through untouched.
- **DECISION: French numbers stay PARKED — upgraded from "not worth it" to "no correct tool exists."**
  German probe moot for the same reason. Revisit only if text-processing-rs (or another maintained
  port) ships language-parameterized ITN; the §2 need-matrix and this packaging validation carry over.
