# Phase B — shared `JotVocabCore` package

**Status:** design, no code written. **Repos:** `jot-shared` (package, source), `jot-mobile` (iOS, READ-ONLY here — source of truth for the logic), `jot` (Mac, READ-ONLY here — stale 2026-07-06 fork).

**Goal.** Extract Jot's vocabulary-correction brains into a second target in the existing `jot-shared` Swift package (which already ships `JotTextPipeline`), so iOS and Mac run **one** implementation. The immediate payoff is that the Mac inherits builds 267–278 (unified `CorrectionKey` identity, `alwaysReplace` grant, the teach-lane, honored ask-suppression) as a *consequence* of adoption, and its "asks the same correction forever" complaint is fixed by construction rather than by a Mac-only patch.

This mirrors the Phase A pattern exactly: `JotTextPipeline` was copied verbatim from iOS, made `public`, and freed of `import FluidAudio` by defining an engine-neutral `TokenTiming` that callers map into. `JotVocabCore` does the same for a larger, stateful surface.

---

## 1. Package boundary

New target `JotVocabCore` (Foundation-only, no `import FluidAudio`, no CoreML, no UI, no process/App-Group concept), added alongside `JotTextPipeline` in the same `Package.swift`. Same platform floors (`.iOS(.v17)`, `.macOS(.v14)`).

### Moves IN (with justification)

| Type | From (iOS) | Why it moves |
|---|---|---|
| `CorrectionKey` | `CorrectionStore.swift:40` | Pure string normalization; the single highest-value share. There is **no shared symbol** across the two apps today — Mac reimplements the normalization inline (`CorrectionStore.normalize`, and again in `AppDelegate`), plus a distinct case-insensitive span-trimmer in `CorrectionReviewModel.resolveSpan`. That's drift-prone by construction (the exact class the round-2 review killed, `can't`≠`cant`), and Mac's inline copies already differ from iOS's in substance: they lack NFC precomposition and whitespace-run collapse. Adopting `CorrectionKey` unifies the symbol **and** brings NFC/whitespace normalization to Mac keys for free (see N1 note in §3). |
| `VocabularyGate` | `VocabularyGate.swift` (840 L) | The crown jewel. `import FluidAudio` today (`VocabularyGate.swift:1`) and references `VocabularyRescorer.RescoreOutput`/`RescoringResult`/`TokenTiming` — so it is **not** Foundation-only now; the seam-1 value-type cut (below) is precisely what makes it pure. It is already a *synchronous, stateless* `enum` on both platforms (the whole trust-overhaul — alignment window, dedup guard, occurrence guard, 3-option alternates, merge-shape — lives here), so beyond seam-1 its only couplings are the common-word/diagnostics seams. The `LanguageChoice` dependency reduces cleanly: the gate reads only `language.commonWordsResource` (a `String?`), verified — so seam-2 takes that string, not the FluidAudio-linked enum. |
| `CorrectionStore` (+ `Mapping`, `Term`, `OverrideEntry`) | `CorrectionStore.swift` (348 L) | Pure trust-ledger logic + JSON persistence. Platform coupling is only the file root and the logger — both injected. |
| `CorrectionProvenance` (+ `Record`, `Payload`, `MappingDelta`) | `CorrectionProvenance.swift` (395 L) | Per-occurrence verdict store + the anchor-reconcile diff (`mapOffsets`). Pure logic + JSON; same coupling as the store. |
| `CommonWords` (membership + cache) | `CommonWords.swift` (73 L) | The set-membership guard is pure. The *loading* of the frequency files is injected (each app keeps its own big `.txt` resources). |
| `AskPolicy` (NEW type — extracted) | the pure core of `CorrectionAsksPublisher.swift` | `worthAsking` / `prior` / rank / `maxAsks` cap / merge-teach one-shot / mixed-payload drop is pure decision logic. Extracting it is the *fix vehicle*: Mac currently reimplements a thinner version inline in `AppDelegate.swift`. |
| `VocabTerm` | `VocabTerm.swift` (29 L) | The on-disk simple-format contract value type; shared by the store and the file parser. |
| `VocabularyFile` (NEW type — extracted) | `VocabularyStore.parse/serialize` (statics) | The simple-format parser/serializer is pure and byte-identical across apps and to FluidAudio's `loadFromSimpleFormat`. |

### Stays OUT (with justification)

| Type | Why it stays platform-side |
|---|---|
| `VocabularyRescorerHolder`, `CtcModelCache` | FluidAudio + CoreML actors (model download, `CtcKeywordSpotter`, `VocabularyRescorer`). The engine itself. |
| `VocabularyStore` (the `@MainActor @Observable` class) | SwiftUI-observation-coupled and drives the rescorer-rebuild hook. Thin; only its pure `parse`/`serialize` extract (→ `VocabularyFile`). Keeping the ~identical observable shell duplicated is cheaper than dragging `Observation`/`SwiftUI` into the package. |
| `CorrectionAsksPublisher` **plumbing** | The `CorrectionBridge` / `CrossProcessNotification` / App-Group staging is iOS keyboard IPC. Only its policy core moves (`AskPolicy`). Mac has no process boundary here. |
| `CorrectionReviewModel/Section`, `MarkedTranscriptText`, `VocabularySettingsView`, `VocabRow`, `VocabularyPane`, `CorrectionReviewStrip` | UI. |
| `CorrectionBridge`, `CorrectionInbox`, `VocabularyAddInbox` | Cross-process IPC (App Group). Mac's single-process equivalents stay Mac-side. |
| `StreamingCtcSpotter`, `JapaneseVocabularySubstituter`, `notable()` pill filter | Mac-only, engine/platform-specific. |

### The four protocol/value seams the package exposes

The package is a *pure* island. Everything platform-specific crosses one of these four seams. **Scope of what's proven:** the scratchpad harness's `Stubs.swift` prototypes **only seam-1** — its mirror rescore/token/override structs (the harness keeps FluidAudio's `RescoringResult` name; the package renames it `RescoreProposal`) match the FluidAudio field shapes the gate reads, which de-risks the hardest extraction (the gate compiles against neutral types). It does **not** exercise `CommonWordsProvider`, `DiagnosticsSink`, `containerRoot` injection, `AskPolicy`, or `VocabularyFile` — those are unproven extraction work (see the honest Stage-0 rescope in §4). The harness is a source-level match, not a currently-green build (no built binary exists in the scratchpad; Stage 0 must actually build + run it).

1. **Engine-neutral rescore input** — mirror value types so the gate never imports FluidAudio:
   ```swift
   public struct RescoreProposal: Sendable {          // ← FluidAudio RescoringResult
       public let originalWord: String
       public let replacementWord: String?
       public let shouldReplace: Bool
       public let replacementScore: Float?
       public let originalScore: Float
   }
   public struct RescoreOutput: Sendable {             // ← FluidAudio RescoreOutput
       public let text: String
       public let replacements: [RescoreProposal]
       public let wasModified: Bool
   }
   public struct TokenTiming: Sendable {               // reuse JotTextPipeline's shape
       public let token: String
       public let confidence: Float
   }
   ```
   Each app maps its FluidAudio output into these at the call site — identical to how `ParagraphSegmenter` already consumes a mapped `TokenTiming`.

2. **`CommonWordsProvider`** — the word-set loader (bundle-specific; big `.txt` files stay in each app):
   ```swift
   public protocol CommonWordsProvider: Sendable {
       func words(forResource resource: String?) -> Set<String>   // nil ⇒ no guard
   }
   ```
   The gate takes `commonWordsResource: String?` (a plain string, e.g. `"common-words-es"`) instead of the FluidAudio-linked `LanguageChoice`, and asks the provider. Callers map `LanguageChoice.commonWordsResource → String?`.

3. **`DiagnosticsSink`** — replaces the *two* logger kinds the moved files use today (`os.Logger` **and** `DiagnosticsLog.record(...)` with a typed `Category` enum). **Decision (resolves the old open Q):** the package owns a **small category enum** rather than a bare `String`, preserving the type safety the app's typed category gives today. The moved code emits exactly two categories, so:
   ```swift
   public enum DiagnosticsCategory: Sendable { case vocabularyGate, vocabularySaveFailed }
   public protocol DiagnosticsSink: Sendable {
       func record(category: DiagnosticsCategory, message: String, metadata: [String: String])
   }
   ```
   The direct `os.Logger` lines in the moved code are dropped (their signal is redundant with the sink); the app-side adapter maps `DiagnosticsCategory → DiagnosticsLog.Category` (a 2-case switch) and iOS keeps its own `os.log` at that adapter if desired. Mac wires its equivalent; tests capture into an array.

4. **Storage root** — the actors take an injected directory root instead of constructing `.applicationSupportDirectory` themselves:
   ```swift
   public init(containerRoot: URL?, diagnostics: DiagnosticsSink)   // nil root ⇒ in-memory/no-persist (tests)
   ```
   The package's on-disk layout is fixed **relative to the root**: `<root>/Vocabulary/corrections.json`, `<root>/Vocabulary/provenance/<id>.json`, `<root>/Vocabulary/vocabulary.txt`. Path *policy* (which OS directory is the root, and any relocation) stays in each app — see §3. The package owns no `FileManager` domain logic and no cross-process concept.

**Correction to the inventory brief:** the iOS vocab *files* are NOT in the App Group container. `CorrectionStore.fileURL` (`:322`), `CorrectionProvenance.fileURL` (`:385`), and `VocabularyStore.fileURL` (`:65`) all resolve `.applicationSupportDirectory` (the main-app sandbox); the file header even states "main-app-only". The App Group is used only for the *ask IPC* (`CorrectionBridge`) and history mirror, which stay out of the package. So on both platforms the injected root is `Application Support`-derived, and the package needs no process awareness — a clean cut.

### Package invariants (internal contracts, not seams)

Two behaviors must be pinned as explicit package contracts with conformance fixtures. **These are not a "fifth seam"** — a seam is a platform-injection point; these are internal invariants of the pure core, so they're documented and fixture-locked, not injected.

- **Locale-invariant lowercasing.** `CorrectionKey.normalize` and the ~15 bare `.lowercased()` pair-key sites must fold identically on every machine. **Push-back with receipt:** the review framed this as a *current* runtime bug (Turkish/Azeri `I↔ı` divergence). It is **not** one today — Swift's no-argument `String.lowercased()` is already locale-*independent* (Unicode default case-folding), verified: `"I".lowercased()` → `"i"` (not `"ı"`) and is byte-equal to `lowercased(with: nil)`; only the explicit `lowercased(with: Locale("tr"))` yields `"ı"`. No moved site uses the locale-tailored form, so there is **no** runtime divergence and the contract is byte-compatible with every existing stored key. The value of pinning it is **regression-proofing**: a future refactor to `lowercased(with: .current)` (or an NSString-locale path) would silently break cross-platform key identity, and the fixture (`correction_key_normalize.json`, §5) locks the invariant so that refactor fails the test instead of corrupting keys in the field.
- **Merge-teach one-shot: decide in core, spend in plumbing.** The one-ask-per-phrase-ever rule straddles the cut and must be modeled explicitly so an implementer can't wire it wrong. **Core (`AskPolicy`) decides eligibility** — it *reads* the `mergeAsked` set (passed in from `CorrectionStore.mergeAskedPairs()`) and marks the selected merge-teach asks. **Plumbing performs the spend** — the `noteMergeAsked(...)` write happens *after* publish, in the app-side handoff, never inside `AskPolicy`. (This matches iOS today, where the write sits in `CorrectionAsksPublisher.publish`'s post-selection loop, `:137`.) Extraction cleanup note: the iOS loop currently evaluates `mergeTeachEligible` **twice** per record (once in `worthAsking`, once as `isMergeTeach` in the emit loop) — fold that into one computed flag on the `AskPolicy.Selection` output so the decision is made once and the plumbing only reads it.

---

## 2. The Mac ask-fatigue fix, as a consequence of adoption

**Root cause (confirmed by inventory, file:line).** Mac's transcript-review surface (`CorrectionReviewModel.swift:65`) loads *only* the per-transcript provenance payload and decides what to surface from `payload.verdicts` alone (`:33–37`). It consults **no** cross-recording state: no `keyboardSuppressedPairs`, no `blockedKeeps` gate, and — because Mac's `Mapping` has no `alwaysReplace` field at all (`CorrectionStore.swift:33–75`, absent) — no always-replace promotion path exists. So every unresolved occurrence re-surfaces on every recording, forever.

**The fix is not new Mac code — it is what adoption *is*.** After Mac imports `JotVocabCore`:

- Mac's ask surface routes its "should I surface this?" decision through the shared **`AskPolicy.select(...)`**, which already excludes `keyboardSuppressed` pairs, excludes `granted` (always-replace) pairs, and applies the merge-teach one-shot. (`AskPolicy` folds in the same `keyboardSuppressedPairs()` / `mergeAskedPairs()` reads the iOS publisher uses.)
- Mac's `CorrectionStore` gains `alwaysReplace` + `mergeAskedPhrases` for free (they are in the shared model; Mac's old `corrections.json` decodes them as `false`/`nil` — see §3).
- Mac's review UI gains the **"Always replace"** affordance wired to `grantAlwaysReplace(...)`, and the gate's step-0 `OVERRIDE` path (`VocabularyGate.swift:434`) now fires on Mac.

**What the owner observes on Mac after adoption:**
- A correction they keep rejecting (kept the original ≥ 2 times, or tapped "Stop asking") stops re-prompting — it remains visible for deliberate review but no longer nags.
- A pair they grant "Always replace" auto-applies thereafter and drops out of the ask stream entirely; one revert revokes it.
- Split-word merges ("sri ram" → "Sriram") get exactly one teach ask per phrase, ever.

**Decision (owner, resolved).** iOS deliberately *splits* two surfaces — the keyboard honors suppression, the transcript pane keeps surfacing everything for deliberate correction. Mac has a *single* ask surface, and it takes **keyboard-ask semantics: it honors the shared suppression state exactly like the iOS keyboard path.** "Stop asking" and the ≥2-keeps auto-suppress therefore work **cross-recording on Mac** — this is the direct fix for the owner's ask-fatigue complaint. Rationale: the reported problem is "it asks the same correction forever," so the single Mac surface must consult `keyboardSuppressedPairs()` / `granted` / the merge one-shot rather than re-surfacing every unresolved occurrence. (A separate always-show deliberate-review view remains possible later as additive UI; it is not part of this boundary.)

### 2a. Mac live pill adopts the iOS 3-option ask (owner requirement)

Mac's live "Did you mean?" pill adopts the iOS build-276 **3-option** format — **original / term / one alternate** — the `alt0` flow. Three design impacts:

**(a) The alternate data already survives the extraction cut — confirmed.** The alternate is derived and carried entirely by types that move into the package: `VocabularyGate.extensionAlternates` (`VocabularyGate.swift:648`) produces `VocabularyGate.Alternate{term, find}` (`:55`) → rides on `Proposal.alternates` (`:84`) → persists on `CorrectionProvenance.Record.alternates` (`:50`) → `AskPolicy` surfaces the first via `r.alternates?.first`. So `altTerm`/`altFind` are **package-native**. The only iOS-side piece is the final serialization into `CorrectionBridge.Ask` (`altTerm`/`altFind` at `CorrectionBridge.swift:42–43`), which stays out of the package as IPC plumbing. **Action for the extraction:** ensure `AskPolicy`'s output value type exposes the selected alternate (`altTerm`, `altFind`) so Mac's pill can read it without re-deriving — i.e. `AskPolicy.Selection` carries the alternate fields, not just the base pair.

**(b) Mac platform UI work (Stage 1 scope).** Mac's `PillView`/`PillViewModel` needs a **third choice affordance** plus the **wider-span apply path**: picking the alternate splices `altFind` (the exact in-text slice the longer term extends over) → `altTerm` in the transcript, which is a wider replacement than the base term's span. iOS already does this splice keyboard-side; Mac reimplements the equivalent apply against its own text buffer. This is net-new AppKit work, not covered by the logic extraction.

**(c) Teach write-back goes through the shared store, exactly as iOS.** Picking the alternate teaches the *chosen* mapping ±1 through the same clamp: the `alt0` verdict routes through `CorrectionProvenance.finalize` → `desiredContribution`, which already reconciles the alternate's mapping key alongside the base (`CorrectionProvenance.swift:322–325, 362–365`) and returns the `MappingDelta`s the caller applies to `CorrectionStore`. Because both types are in the package, Mac gets this for free — no Mac-specific ledger code.

---

## 3. Migration — zero data loss, no flags, unconditional

Per repo convention (pre-launch migrations run unconditionally every launch, no feature flags). Migration is **app-side** (it is platform path logic the package deliberately doesn't own); each app normalizes its on-disk layout to `<root>/Vocabulary/...` *before* constructing the package actors.

**Data-format compatibility is already lossless** (verified): `corrections.json` is `[String: Term]` on both; the shared `Term`/`Mapping` model is iOS's **superset**, and every added field decodes through `decodeIfPresent` defaults (`CorrectionStore.swift:101–104`). So:
- **iOS** reading its own file → identity.
- **Mac** reading its old file through the superset model → `blockedKeeps` present (Mac has it), `alwaysReplace` → `false`, `mergeAskedPhrases` → `nil`. Lossless. No content transform, ever.
- Provenance `Payload` and `vocabulary.txt` are already identical shapes.

So migration is purely **physical relocation**, and only Mac needs it:

| App | Today | Action |
|---|---|---|
| iOS | `AppSupport/Vocabulary/{corrections.json, provenance/, vocabulary.txt}` — already the unified layout | **None.** Root = `.applicationSupportDirectory`; files already match. |
| Mac | `corrections.json` + `provenance/` at `AppSupport/Vocabulary/` (match), but `vocabulary.txt` at `AppSupport/Jot/Vocabulary/` (the quirk, `VocabularyStore.swift:58–65`) | Unconditional idempotent **move** of the single file `Jot/Vocabulary/vocabulary.txt → Vocabulary/vocabulary.txt`. Move-if-source-exists-and-dest-absent; a no-op on every subsequent launch. |

Canonical root chosen as `AppSupport/Vocabulary/` because it already matches iOS **and** two of Mac's three paths, so the migration touches exactly one (precious, human-curated) file with a single atomic move rather than relocating the multi-file `provenance/` directory. If the future "keyboard reads the vocab list" feature lands (flagged in `VocabularyStore.swift:14`), the injected-root design already accommodates repointing iOS's root at the App Group container — another unconditional move at that time.

**Migration ordering is load-bearing (L3).** The vocabulary.txt relocation must complete **before** the `VocabularyStore` actor is constructed and before any `save()` can fire. `VocabularyStore` is the `@MainActor` single writer and resolves `fileURL` lazily at first access; if a `save()` (or the store's `init → load()`) runs against the new path while the file still sits at the old one, it either writes an empty list to the new path or races the move (check-then-move TOCTOU). Sequence it as an unconditional startup step that runs to completion **before** package/store construction in the app's launch path.

**Decode-failure must never overwrite (Q-3 — real data-loss risk, fix during extraction).** `CorrectionStore.loadIfNeeded` today is one `try?`-decoded blob: on a decode failure it sets `loaded = true` with `terms` left empty (`CorrectionStore.swift:333–342`), and the very next `persist()` atomically writes `{}` over the file — a **total wipe of the curated ledger**. Stage 1 is the first time the shared store reads the Mac's existing on-disk file, so this latent bug (present on iOS too) becomes a live risk exactly when we point new code at real user data. **Package requirement:** the store must distinguish *file-absent/empty* (safe to start empty and persist) from *file-present-but-undecodable* (must **refuse to persist** — no save may overwrite a file it failed to load; surface the failure via `DiagnosticsSink` and leave the bytes intact for recovery). This is a conformance-fixture case in `correction_store_roundtrip.json` (§5): a corrupt blob in → load fails → a subsequent mutation must NOT write.

**Free bonus, with honest caveat (N1).** Because Mac's inline normalizers lack `.precomposedStringWithCanonicalMapping`, adopting `CorrectionKey` brings NFC precomposition to Mac keys for the first time. Caveat (same class as the locale invariant): for a Mac key stored in *decomposed* form, the new normalize yields the precomposed key, so that one learned mapping would re-key and stop matching until re-learned. This is byte-compatible for realistic data (ASCII names, and macOS text input emits precomposed by default), so the practical blast radius is ~nil; noted for completeness, not as a blocker.

---

## 4. Staging — never both apps broken at once; iOS switches LAST

iOS ships fine today and is the source of truth; it moves last. Mac is the stale fork with the bug; it moves first and gets the payoff. Each stage is independently shippable.

**Stage 0 — Author the package (jot-shared only; neither app touched).**
Copy the eight moving types from iOS verbatim, make them `public`, and cut the four seams (§1). **Honest scope:** only seam-1 (the gate's neutral input types) is de-risked by the scratchpad harness; `CommonWordsProvider`, `DiagnosticsSink`, `containerRoot` injection, `AskPolicy`, and `VocabularyFile` are genuinely new extraction work in this stage — including converting the stateful actors to injected roots/sinks and refactoring `CorrectionAsksPublisher`'s policy core out of its IPC. Bring the gate harness in as the **regression floor** (16 cases — verified by counting the `Case(name:)` entries; the "13" in earlier notes was the superseded 277 P0 slice, now grown to 16 at 278), turn it into an actual `swift test` target (there is no built binary in the scratchpad today), and add the new conformance fixtures (§5). Package builds + tests green standalone, as `JotTextPipeline` does. **Risk to apps: none** — both still build on their own copies.

**Stage 1 — Mac adopts `JotVocabCore` (delivers the fix).**
Add the package dependency; delete `Sources/Vocabulary/{CorrectionStore, VocabularyGate, CorrectionProvenance, CommonWords, VocabTerm}.swift` + the inline ask logic in `AppDelegate.swift`; map FluidAudio rescore output → `RescoreOutput`/`RescoreProposal` at the `VocabularyRescorerHolder.finishRescore`/`gateDetections` seam (`:471`, `:414`); implement `CommonWordsProvider`/`DiagnosticsSink`; run the vocabulary.txt relocation (before store construction — §3, L3); wire the `AskPolicy` + "Always replace" UI; and build the **3-option pill** — `PillView`/`PillViewModel` third choice + wider-span (`altFind`→`altTerm`) apply path (§2a-b). iOS **unchanged and still shipping**.
*Sequencing constraint (corrected — see §6, Q1):* Mac's `Sources/Vocabulary/*` files are all **clean**; the real ordering constraint is that Stage 1 must land **after the in-flight Phase A (`JotTextPipeline`) adoption commits on Mac**. That adoption is mid-flight and uncommitted (Mac has already deleted its `FillerWordCleaner`/`NumberNormalizer`/`ParagraphSegmenter.swift` copies), and it touches the same two files Stage 1 does — `Transcriber.swift` and `Jot.xcodeproj/project.pbxproj`. Landing Phase B on top of an uncommitted Phase A would collide there.

**Stage 2 — iOS adopts `JotVocabCore` (source of truth, done last, carefully).**
Delete `App/Vocabulary/{the eight}.swift`; import the package; map FluidAudio → neutral types at `VocabularyRescorerHolder.mergeWithProposals` (`:455`) and `applyFromDetections`; wire the iOS `DiagnosticsLog`/`CommonWords` bundle provider; keep `CorrectionBridge`/`CrossProcessNotification` as-is (they consume `AskPolicy` output). The keyboard target can now link `JotVocabCore` (pure Foundation — verify it pulls in no FluidAudio and stays well under the 60 MB ceiling), which is *cleaner* than today's compiled-in `CommonWords`. **Re-sync the scratchpad gate harness / splice suite mirrors** against the package (they become the package tests — see §5). Ship only after Mac has soaked.

Because the package *is* iOS's current code, Stage 2 is the lowest-behavior-risk swap (identical logic, different module); it is last only because iOS is the shipping app.

**The between-stages window is drift-safe (Q-2).** Stage 1 (Mac on the package) and Stage 2 (iOS still on its own copy) coexist for a while, but the two apps' vocab data never meets: the files are **per-machine, app-sandbox `Application Support`** with **no App Group sync and no iCloud sync** for these paths (confirmed — only the ask IPC and history mirror touch shared containers, and neither is a vocab data file). There is no shared store for a two-implementations window to corrupt; each app reads and writes its own local files. So the staging can proceed at whatever pace without a data-consistency hazard.

---

## 5. Test strategy

**Regression floor (moves in, day one):** the existing **16-case vocab-gate harness** (scratchpad `vocab-gate-test/`, currently a standalone executable whose `Stubs.swift` mirrors the seam types). Its stub types *are* the package's public input types, so it stops being a stub harness and becomes the package's real XCTest suite — covering jamy-disaster, use-survives, shifted-span-blocks, dedup ×2, occurrence ×2, alternates, mid-span, narrowed-identity, narrowed-punct, widened-demotion, exact-slice-find. This retires the "re-sync gate copy after every app-side edit" chore: there is one copy.

**New conformance fixtures** (golden JSON fed through the public API, matching `JotTextPipeline`'s `Fixtures/*.json` contract):

1. **`correction_key_normalize.json`** — input → normalized. The highest-value cross-platform contract (no shared normalize symbol today; Mac's inline copies lack NFC/whitespace-collapse): NFC precompose, **locale-invariant** case-fold (the invariant pinned in §1), whitespace-collapse, outer-punct-trim, with the round-2 collision guards (`can't`≠`cant`, `"a part"`≠`"apart"`) and an explicit Turkish-`I` row asserting `"I"`→`"i"` (not `"ı"`).
2. **`vocabulary_gate_decide.json`** — full `apply()` goldens: `(originalTranscript, RescoreOutput, tokenTimings, overrides, commonWords, aliases, commonWordsResource)` → `Result(text, applied, blocked, proposals)`. Seed from the measured pairs in the gate doc-comments (cloud→claude apply, jamie→jamy apply, vikram→sriram block, name→jamy block, sri ram→Sriram merge) plus the 16 harness cases.
3. **`correction_store_roundtrip.json`** — a legacy Mac-subset `corrections.json` and an iOS-superset one both decode→encode→decode to a stable shape; net math (`confirm`/`adjust`/`revert`), `alwaysReplace` one-revert-revoke, `blockedKeeps` threshold, `mergeAskedPhrases` spend-once.
4. **`provenance_verdicts.json`** — `setVerdict`/`clearVerdict` `MappingDelta` clamp (≤ ±1 per transcript), alt0 dual-mapping reconcile, `mapOffsets` multi-region diff, legacy-key fallback.
5. **`ask_policy_select.json`** — `(records, overrides, keyboardSuppressed, granted, mergeAsked)` → selected asks: `worthAsking`, prior-desc rank, `maxAsks` cap, merge-teach one-shot, mixed-payload drop.

The splice/19-case suite that currently lives app-side stays app-side if it exercises engine wiring; only the portions that exercise pure gate/store/key logic migrate into fixtures 1–5.

---

## 6. Risks & open questions (for the owner)

*Resolved: (owner) Mac ask surfaces honor shared suppression like the iOS keyboard — cross-recording "stop asking" now works on Mac (§2); Mac live pill adopts the iOS 3-option ask (§2a). (review) Logging is decided — package owns a 2-case `DiagnosticsCategory` enum, direct `os.Logger` lines dropped (§1, seam-3).*

**Q1 — Phase A must land on Mac before Stage 1 (STILL OPEN — timing).** Not a code question but a scheduling one: the in-flight `JotTextPipeline` (Phase A) adoption is uncommitted on Mac and touches the same `Transcriber.swift` + `project.pbxproj` Stage 1 does (§4). Confirm Phase A commits first, or that you want them landed together as one branch. (Mac's `Sources/Vocabulary/*` are all clean — there is no collision *inside* the vocab files.)

**Q2 — `VocabularyStore` stays duplicated.** Only its `parse`/`serialize` extract (→ `VocabularyFile`); the `@Observable` shell stays per-app. Confirm that ~thin duplication is acceptable versus dragging SwiftUI/Observation into the package (recommend: keep out).

**Q3 — Keyboard now links `JotVocabCore`.** Should be strictly better than today (pure Foundation, no FluidAudio), but validate at Stage 2 that the dependency graph pulls in nothing heavy and the 60 MB extension ceiling is untouched.

---

## Sizing (rough, per stage)

- **Stage 0 (author package + fixtures):** ~4–5 d (revised up from 2–3 after the honest rescope). Only seam-1 is de-risked by the harness; the real work is the two actor refactors (injected root + `DiagnosticsSink` + the decode-failure guard), extracting `AskPolicy` out of the IPC-coupled publisher, extracting `VocabularyFile`, standing the harness up as a real `swift test` target, and authoring the five fixture sets. Not mechanical.
- **Stage 1 (Mac adopt + fix + migration):** ~4–5 d (was 3–4; +~1 d for the 3-option pill). New surface: the `AskPolicy` wiring, the "Always replace" UI, the 3-option pill (third choice + wider-span apply, §2a-b), and the on-device verify that the ask-fatigue complaint is actually gone.
- **Stage 2 (iOS adopt, last):** ~2 d. Lowest-logic-risk swap; cost is the careful re-sync of harness mirrors + keyboard-link verification + a full pre-ship device pass since iOS is the shipping app.
