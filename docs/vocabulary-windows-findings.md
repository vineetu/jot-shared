# What the Windows port found in `VocabularyGate.applyFromDetections`

**Status:** fixtures + measured data + this note. **No Swift implementation.** The new cases in
`Tests/JotVocabCoreTests/Fixtures/detections_apply.json` are expected to **FAIL** against
`JotVocabCore` today — that is the point of adding them. They are an executable statement of what the
shipping Swift path gets wrong, written so that whoever implements this on a Mac has a target instead
of a description.

Full prose spec (do not duplicate it here):
<https://sites.simple-host.app/jot-transcribe/jot-vocabulary-spec/>

Upstream issue: <https://github.com/vineetu/jot-shared/issues/1> — this note and the fixtures cover
that issue and one more finding on the same method.

**Provenance of every number and every expectation below:** the Windows port,
`jot-windows @ ae2ce1c`, `src/Jot/Vocabulary/VocabularyGate.cs`, 749 tests green. Expectations were
not authored — a throwaway harness ran each case through the real
`VocabularyGate.ApplyFromDetections` and dumped the result in this fixture's JSON shape. The same
28 cases are committed in the Windows repo (`tests/Jot.Tests/Fixtures/vocab/detections_apply.json`)
and pass there, which is what stops the two implementations drifting.

---

## 0 · Why none of this was ever caught

Every one of the five pre-existing `detections_apply.json` cases uses a **single-word term with no
aliases**:

| case | term | aliases |
|---|---|---|
| `spot-applies-oov-name` | `Sriram` | none |
| `spot-blocks-common-word` | `Claude` | none |
| `spot-preserves-edge-punctuation` | `Sriram` | none |
| `spot-identity-is-noop` | `Sriram` | none |
| `spot-implausible-skips` | `Sriram` | none |

Both multi-word defects below are *unreachable* from that population. Worth remembering when writing
future fixtures: a fixture family that only ever exercises the simplest shape of its input will look
comprehensive and specify nothing. The five existing cases are untouched (262 insertions, 0
deletions, on both sides).

---

## 1 · Multi-word placement — the tail-duplication defect

**Observed end-to-end**, shipping Nemotron + CTC spotter, 2026-07-25:

```
engine wrote:   "Claude code generated most of the boiler plate"
vocabulary ON:  "Claude Code code generated most of the boiler plate"
```

**Cause.** A placement is one whitespace-delimited word measured against the *whole* term. The
two-word term `Claude Code` lands on just `Claude` (0.40, inside the 0.45 ceiling) and the
transcript's own `code` is left standing behind it. `Decide` step (2) then waves every multi-word
term through as "precise and self-gating", so nothing downstream objects. This corrupts text the
transcriber **already got right**, and the result is pasted before anyone can review it.

**Behaviour the fixtures pin.** When a multi-word term lands on a span with fewer words than the
term, and the term's trailing words duplicate what follows, widen the span to absorb them.

| case | pins |
|---|---|
| `spot-multiword-absorbs-duplicated-tail` | the defect itself: one `Claude Code`, not `Claude Code code` |
| `spot-multiword-never-absorbs-a-real-following-word` | absorb at most (term words − span words), so `Claude code code review` keeps the second `code` |
| `spot-multiword-absorb-keeps-trailing-punctuation` | the widened span ends at the last alphanumeric; `we ship Claude code.` keeps its period |
| `spot-multiword-absorb-across-punctuation-blocks` | `ask Claude, code review` — widening would eat a comma the engine deliberately wrote, so **block**, publish the original, leave a reviewable `kept` row (`BLOCK`, `askCandidate: false`) |
| `spot-multiword-tail-that-differs-is-an-insertion` | `Claude wrote the installer` → `Claude Code wrote…`; the tail does not duplicate, so this is an insertion, not an absorption |
| `spot-multiword-already-written-correctly-is-noop` | an already-correct `Claude Code` fires no chip and no review row |
| `spot-multiword-wrong-case-still-corrects` | `claude code` → `Claude Code`; for a multi-word proper noun the casing **is** the term |

Note the deliberate asymmetry the last two encode: the identity no-op is **normalized** (case
insensitive) for a single-word span — locked by the pre-existing `spot-identity-is-noop` — and
**ordinal** for a multi-word span. Either multi-word route only arrives via a word-for-word skeleton
match, so the transcript really does contain the term's words and the only thing left to fix is their
casing. No prior fixture covered a multi-word span, so this relation was a choice; these cases make
it a contract.

---

## 2 · Multi-word placement — the dropped-term defect

Same cause, opposite symptom. **Observed end-to-end**, same session:

```
engine wrote:   "I love cloud code."
vocabulary ON:  "I love cloud code."      (term silently dropped)
```

`skeleton("cloud")` vs `skeleton("Claude Code")` measures **0.60** against a 0.45 ceiling, so the
detection is discarded outright — even though the two-word **window** `cloud code` measures **0.20**
and is obviously the right host. Defect 1 corrupts; this one is the feature simply not working on the
shape of term users add most.

**Behaviour the fixtures pin.** A candidate host is a contiguous N-word *window*, with widths taken
from the term **and its aliases**.

| case | pins |
|---|---|
| `spot-multiword-placed-on-two-word-window` | `I love cloud code.` → `I love Claude Code.` |
| `spot-threeword-term-placed-on-three-word-window` | width 3 works too: `model context protocall` → `Model Context Protocol` |
| `spot-window-words-must-each-align` | whole-window plausibility alone is far too loose — `Claude wrote` measures **0.27** against `Claude Code`, comfortably inside the ceiling, and would silently overwrite `wrote`. Every word must align individually, so `the load code runs` must **not** place |
| `spot-merged-single-token-still-hosts-multiword-term` | width 1 is still tried and is byte-identical to the old behaviour: `ramanathan` → `Ramaa Nathan` |
| `spot-alias-word-count-drives-window-width` | a 2-word **alias** (`pera keet`) hosts a 1-word term (`Parakeet`) |
| `spot-window-claims-every-word-it-covers` | a window claims all its words, so a second detection (`Kode`) can never take a word this one spliced over — 1 proposal, not 2 |

Two boundary rules the window shares with the dedup guard, so a window-placed span and a
dedup-widened span are the same shape and carry the same anchors: cross **plain spaces only**, never
a word's own punctuation; and end at the **last alphanumeric** of the final word.

---

## 3 · The apostrophe guard

`Skeleton()` drops the apostrophe, so a possessive measures **0.00** against its own plural:
`skeleton("Mariana's") == skeleton("Marianas")`. The term is applied over a word the engine got
right, deleting a grammatical inflection.

**Measured**, 1041 FLEURS clips through the shipping Nemotron + CTC spotter (2026-07-25): **5 of the
spotter's 20 false applies were exactly this shape** — `Mariana's`→`Marianas`, `USOC's`→`USOC`,
`Shayam's`→`Shyam`, `Falkland's`→`Falkland`.

`PreservingEdgePunctuation` cannot rescue it (the trailing `s` is alphanumeric, so nothing is
carried) and narrowing to `Mariana` would publish `Marianas's`. Blocking is the only answer that
neither corrupts nor guesses.

| case | pins |
|---|---|
| `spot-possessive-is-not-rewritten-as-the-plural` | the straight apostrophe |
| `spot-possessive-curly-apostrophe-counts-too` | `’` counts (so does the modifier letter `ʼ`) |
| `spot-possessive-guard-measured-usoc` | one of the five measured rows, verbatim |
| `spot-term-carrying-an-apostrophe-still-corrects` | **one-directional on purpose**: `obrien` → `O'Brien` must still work |
| `spot-alias-carrying-the-apostrophe-unblocks-it` | an **alias** carrying the apostrophe unblocks it too |

---

## 4 · The inflection guard — and it is partial, by measurement

The suffix shape of §3, and the reason it needed its own guard: the apostrophe is the one inflection
the skeleton happens to erase; outside English the endings are letters. The common-word brake is a
**type** lookup over a 24 000-entry frequency list, so `пирамид` walks straight past it while
`пирамиды` is right there in the list, one character longer.

Two conditions, and the conjunction is the whole design:

1. **structural** — span and term share a stem of ≥ 4 scalars and diverge only in a tail of ≤ 3 on
   either side;
2. **lexical** — the span is ≥ 7 scalars and is an everyday word **minus its final character**.

### Be honest about what it does not do

Measured on E6's corpus, 20 languages, guard off → guard on:

| | off | on |
|---|---|---|
| false applies, realistic arm | 64 | **58** |
| false applies, adversarial arm | 146 | **135** |
| of which FP-**overwrote** (the class this targets) | **29** | **24** |
| correct corrections lost | — | **4, all in Greek** |
| languages whose numbers move at all | — | **3** (el, pl, ru) |
| English (E5, 1041 clips, 22 490 words) | 0.27 / 0.22 FP/1k | 0.27 / 0.22 — **inert** |

So: **it catches 5 of the 29 measured overwrites, and those 5 are all the same word** —
`piramid`/`пирамид` against `Piramida`/`Пирамида`. That is the entire overwrite population it
reaches. It buys that for **4 correct corrections lost, all in Greek** (Greek's frequency list is
inflection-dense and its engine runs at 47 % WER, so more of what it writes lands one character from
a listed word — in both directions). It is worth shipping — Greek's realistic arm goes from
**1.42 → 0.89 FP/1k**, inside the 1.0 budget, and net WER still improves (47.10 → 46.80 %) — but it
is not a fix for the class.

**What it structurally cannot do.** A span that is a **proper noun in another case** — `Аризона`
against the term `Аризоны`, `Fatima` against `Fatimě`, `Версали` against `Версаче` — is absent from
the frequency list at any truncation, so condition 2 is false and the guard stays out of the way.
That is the answer, not an omission: those rows are structurally **indistinguishable** from
`Аризоне` → `Аризоны`, which is **correct** and was measured in the same corpus from the same term.
No threshold separates them. A guard that fired on the shape alone would destroy **30 correct
corrections to prevent 33 false ones**. Only a lexicon of inflected proper nouns would close it, and
we ship none.

| case | pins |
|---|---|
| `spot-inflected-everyday-word-is-not-overwritten-ru` | `пирамид` survives (`BLOCK`, `askCandidate: false`) |
| `spot-inflected-everyday-word-is-not-overwritten-pl` | `piramid` survives |
| `spot-inflection-guard-limit-proper-noun-is-still-overwritten` | **the limit, pinned as a limit**: `Аризона` → `Аризоны` still applies |
| `spot-inflection-guard-limit-short-span-is-below-the-floor` | the 7-scalar floor: `wigili` (6) → `Wigilii` still applies |
| `spot-inflection-guard-ordinary-near-miss-still-corrects` | `shriram` → `Sriram` is untouched by the guard |

`askCandidate: false` on the two blocking cases is what distinguishes the inflection guard from the
ordinary common-word brake, which blocks with `askCandidate: true`. If a port implemented the brake
but not the guard, those cases fail on that field alone.

The 7-scalar floor is the one number chosen from a small sample and is reported as such: at six it
also blocks `wigili`→`Wigilii` and three more real corrections to catch two more false ones; at eight
it loses the `piramid`/`пирамид` rows, which are the only overwrites it catches at all.

---

## 5 · The confidence-conditional plausibility ceiling

`Herrakit` → `Parakeet` sits **beyond** the fixed 0.45 ceiling and was heard at **−0.313**, the best
score of five terms in that dictation — refused, with no proposal and no row. E5 measured **214
chances the engine missed** and found **61 of them (29 %) sitting beyond the fixed 0.45 ceiling**, a
band the acoustic spotter *hears* 35 of and the gate applied exactly none of.

String similarity and acoustic evidence are substitutes, so the ceiling ramps with the score rather
than moving: fixed **0.45** for anything that is not a measured acoustic score, ramping from **−1.8**
(no headroom) to **−1.0** (full headroom) up to a cap of **0.65**.

Every number is measured on E5's 433 detections over 1041 clips. Admitted rows in the loosened band,
all-155 stress list / realistic 25-term list:

| mapping | stress | realistic |
|---|---|---|
| **this mapping** | **14 right / 0 wrong** | **6 / 0** |
| ramp anchored at −2.2 | 15 / 3 | 7 / 0 |
| cap 0.75 instead of 0.65 | 16 / 1 | 6 / 0 |
| flat 0.65, unconditional | 30 / 25 | ← the reason it is conditional |

It sits on a plateau, not a cliff: every neighbouring (floor, full, cap) triple in
{−2.0, −1.8, −1.6} × {−1.0, −0.75} × {0.60, 0.65} also lands on zero false applies.

`acoustic` is a **new boolean on `Detection`, defaulting to false.** That default is why every
pre-existing case — including `spot-implausible-skips` (`vikram` vs `Sriram`, 0.50), which is exactly
the row this would otherwise flip — stays byte-identical. The divergence is confined to detections a
real acoustic model produced; a textual corrector that puts a negated string distance in the same
field gets the fixed ceiling, because the two are not comparable.

All four `Parakeet` cases below use the same transcript, `"Herrakit remains the fallback engine"`.
Measured on the shipped `VocabularyGate.Gap`: **gap(`Herrakit`, `Parakeet`) = 0.625**. So the four
cases are a clean sweep of the ramp against one fixed gap:

| case | score | `acoustic` | earned ceiling | vs gap 0.625 | pins |
|---|---|---|---|---|---|
| `spot-strongly-heard-term-earns-headroom` | −0.313 | yes | **0.650** | admits | `Herrakit` → `Parakeet` |
| `spot-ramp-midpoint-earns-partial-headroom` | −1.4 | yes | **0.550** | refuses | partial headroom is really partial — the ramp is not a switch |
| `spot-weakly-heard-term-earns-no-headroom` | −2.4 | yes | **0.450** | refuses | below the floor ⇒ no headroom at all |
| `spot-non-acoustic-score-earns-no-headroom` | −0.313 | **absent** | **0.450** | refuses | same score, no flag ⇒ nothing. **This is the case that keeps the default honest** |

| case | pins |
|---|---|
| `spot-earned-headroom-does-not-beat-the-common-word-brake` | `Prochet` measures 0.4286 against `project` — inside even the *fixed* ceiling — but `project` is an everyday word, so `BLOCK` with `askCandidate: true`. Earned headroom moves the *plausibility* ceiling and nothing else |

> **Provenance discrepancy, flagged not smoothed.** Three illustrative gap figures in the shipped C#
> comments do not reproduce against the shipped `Gap()`: `Herrakit`/`Parakeet` is quoted as 0.50 and
> measures **0.625**; `cloud`/`Claude Code` is quoted as 0.56 and measures **0.60**;
> `Claude wrote`/`Claude Code` is quoted as 0.36 and measures **0.27**. No behaviour changes — each
> figure is on the same side of its ceiling either way, and every fixture expectation here is dumped
> from the implementation rather than computed from a comment — but the comments are wrong and
> someone reading them for a threshold will be misled. The measured values are the ones above.

---

## 6 · The per-language corrector table

Carried as data, not as fixtures, in
[`Tests/JotVocabCoreTests/Fixtures/vocabulary_limits.json`](../Tests/JotVocabCoreTests/Fixtures/vocabulary_limits.json).
**No test in this package reads it.** It is here so a Swift implementation has the measured values to
build against, and so a change to the shipped table can be diffed against something.

Transcribed from `src/Jot/Vocabulary/VocabularyLimits.cs` in `jot-windows @ ae2ce1c` (the source of
truth), measured 2026-07-26 by experiment E6: 9500 FLEURS clips through the shipping Nemotron engine
and the real gate. Budget: **1.0 false applies per 1000 reference words**, on a realistic 25-term
list *and* on a mechanically adversarial one.

- **13 languages at no cap** (`en cs da es fi fr hu it nl pt ro sk sv`) — inside budget at the
  English setting, so untouched. `cs` is the closest pass (0.55 / 0.88).
- **6 languages tightened** — `bg` 0.25, `de` 0.15, `el` 0.20, `pl` 0.20, `ru` 0.20, `uk` 0.20. Each
  row carries the over-budget arm it was cut for, the post-cap rates, and the recall it cost
  (`de`, worst: 54.3 % → 31.4 %).
- **`sl` (Slovenian) is CUT**, recorded as an exclusion with a reason rather than an absence: 1.72
  adversarial FP/1k, and the only setting under 0.5 recovers one missed term in six (43 % of what it
  recovers uncapped). The engine is also at 58.6 % WER there, so the premise — a mostly-right
  transcript with a few mis-spelled terms — does not hold. A frequency list ships and the locale
  exists; it is still refused.
- **`sr` (Serbian) is absent for a different reason**: it *has* a 24 000-entry list, so the brake
  would work — but there is no engine locale, so no setting can select it.
- **`hr` (Croatian) and `ar` (Arabic) have no frequency list at all**, so the brake would be
  **absent**, not merely weak. "No brake ⇒ no run" is the rule that keeps them off, and the same rule
  covers `ja`, `tr`, `mt` and `auto`.

---

## 7 · What could NOT be expressed as a fixture

This is the part that would otherwise silently go unspecified. **Everything below is real shipped
behaviour with no test in this package guarding it.**

1. **Every diagnostic.** `detections_apply.json` has no diagnostics channel, so nothing pins
   `spot-unplaced`, `dedup-absorbed`, `dedup-ambiguous`, `align-narrowed`, `inflection-ambiguous`,
   `inflected-common` or `overlap-dropped` — their existence, their message text, or their fields.
   This matters most for **`spot-unplaced`**: a detection the spotter heard but could not place
   produces *no proposal and no text change*, which in fixture terms is identical to "the spotter
   found nothing". `spot-weakly-heard-term-earns-no-headroom` and
   `spot-non-acoustic-score-earns-no-headroom` both assert `expectProposalCount: 0` and cannot tell
   those two apart. The log carries `nearest` / `gap` / **the ceiling this detection actually
   earned** (not the constant), and that triple is the only thing that distinguishes a recall bug
   from a precision block in the field — opposite bugs with opposite fixes.
2. **Provenance anchors.** `originalStart`, `originalLength`, `publishedStart`, `publishedLength`
   are not in the case schema at all. They are **grapheme-cluster counts**, they are persisted, and
   they are compared against records written by Mac/iOS. A multi-word placement or a dedup widening
   changes them by construction, and no fixture would notice if a port got them wrong.
3. **Other `Proposal` fields on this path.** `term`, `shape`, `alternates`, `occurrenceIndex`,
   `confidence`, `margin`, `unsure` — the schema asserts only `originalWord`, `outcome`, `decision`
   and `askCandidate`. (On the detection path `confidence` is pinned at `LowConfidence`, `margin` is
   always 0 and `unsure` is always false, so any downstream filter on them is dead code that looks
   like a control. That trap has a Windows-only unit test and no fixture.)
4. **The per-language limits table** (§6) — the corrector that consults it is not part of
   `JotVocabCore`, so there is nothing for a fixture to call. Hence the JSON data file.
5. **The measured rates themselves.** FP/1k, recall and WER are corpus statistics over 1041 and 9500
   clips. No per-case fixture can express them; they live in this note and in the data file, and
   re-deriving them needs the corpus, not the repo.
6. **The `inflectionGuard` counterfactual seam.** The Windows `ApplyFromDetections` takes a
   `inflectionGuard: bool = true` parameter that no product code ever passes — it exists so the
   measurement harness can score the guard's own counterfactual arm on the same transcripts in the
   same build. Nothing in a fixture expresses "and here is what would have happened without it".
7. **⚠ The Swift fixture harness does not read the two new keys.**
   `Tests/JotVocabCoreTests/GoldenFixtureTests.swift` declares
   `DetectionFixture` without `acoustic` and `DetectionExpectProposal` without `decision`, and
   `Decodable` ignores unknown keys **silently**. So on Swift today the §5 cases would run with
   `acoustic = false` and the `decision` field would assert nothing at all. Whoever implements this
   must extend those two structs, or four of the five earned-ceiling cases become vacuous in the one
   direction that looks like success. *This note deliberately does not make that edit: there is no
   Swift toolchain on the machine these findings came from, and an untested Swift change is exactly
   what this PR is avoiding.* The C# harness was extended accordingly and the change is
   mutation-checked (dropping `acoustic` from one case, and flipping one `decision`, each fail the
   suite).
8. **Vacuity, in general.** The C# side now pins the case **count** (33) and requires every case to
   assert something about proposals, because a truncated or mis-parsed fixture file previously passed
   the golden test while testing nothing. A Swift port should do the same.
