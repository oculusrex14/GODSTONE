# T78 CONVERGENCE — GODSTONE remediation against AUDIT_FINAL_2026-09-15 (AUDIT-003-R1)

**Candidate SHAs for this round (exact, one per isle, each with a clean tree at the moment its lane ran):**
* **Android isle: `44100c0`** — the full `:mesh` lane was run here, unfiltered.
* **iOS isle: `9153d40`** — the full iOS lane was run here, complete output.
The ledger and this document are recorded in the commits that follow those two, so a reader may anchor to a measured tree
rather than to a document describing one.

Audited baseline the findings were raised against: `c683a2bf0b5bcdd4a662d98f7542351501b57b7c`.
Branch: `codex/production-blueprint` (pushed).

## Ledger at this round

```
FIX_SUBMITTED 47 · OPEN 0 · PARTIAL 7        (54 findings total)
VERIFIED_FIXED  0        — ABSENT BY RULE: only an independent audit may write it.
```

**`OPEN 0` IS DOING PRECISE WORK, AND IT MUST NOT BE MISREAD.** It meaneth **no finding carrieth no landed work at all**.
It doth **not** mean the programme is finished: GS-UX-001 and GS-STRESS-001 moved from `OPEN` to **`PARTIAL`** because each
now carrieth a **measured, landed slice with its remaining limbs named** — the same sense in which ANDROID-05 and
GS-RUNTIME-001 have been `PARTIAL` all along. **`PARTIAL` IS NOT FIXED AND IS NOT WRITTEN AS FIXED.**

The span began with `OPEN 7 · FIX_SUBMITTED 41`, and five findings carrying **no work at all**.

## THE TWO SCOPES, REPORTED SEPARATELY

### Scope A — LIGHT Archive (14 findings)
The LIGHT-Archive findings are **not this span's work**: they were submitted before it began, and this span did not reopen
them. **Nothing in these candidates alters their standing**, and none of them may be treated as verified on the strength of
these SHAs.

### Scope B — Mesh/Oracle (40 findings)
This span's work lies here. Measured this round:

* **the five findings named by the human (CRYPTO-002, CRYPTO-005, GS-INBOX-001, GS-INTEGRATION-001, GS-STORE-006) are ALL `FIX_SUBMITTED`** — unchanged by this round;
* **and the three that remained `OPEN` all moved, each by measurement**:
  * **ANDROID-03 → `FIX_SUBMITTED`.** Its RED, run before the repair and written to print its own census, **found a SECOND
    defect that no amount of reading had found**: the capture was bound to a relation the transport had never published
    (`OUTBOUND` published vs `INBOUND` captured, same address, same generation). The fall now carrieth the same immutable
    peer the rise did. Law paid for: **when a mandatory control cannot resolve an expression, changing the expression until
    the control is satisfied is not satisfying the control — it is moving the evidence** (round 255's trade, carried
    silently for 266 rounds);
  * **GS-UX-001 → `PARTIAL`.** The lab's journey now reacheth a **real durable authority over a caller-named medium** and
    surviveth it. Sixth appearance of this programme's recurring shape: *an instrument built, witnessed by courts, reached
    by no path a user travels*;
  * **GS-STRESS-001 → `PARTIAL`.** One invariant (`no_leaked_sessions`) now readeth a **REAL `SessionManager`** through the
    owner's own hook and **nameth it in the failure**. A model that agreeth with itself is not evidence about a runtime.
* **the lanes, both unfiltered, both grepped for the aggregate line AND for the arm's own name**:
  * Android at `44100c0`: `:mesh` — **tests=1224, failures=0, errors=0** across all 77 test classes (the +1 over 1223 **is**
    the arm written this round), `BUILD SUCCESSFUL`;
  * iOS at `9153d40`: **`LabMeshTests` 4 tests 0 failures · `GodstoneMeshTests` 1187 tests 0 failures · `GodstoneCoreTests`
    82 tests 0 failures**, exit code 0, 0 compile errors;
* **controls: parity `passed=7 failed=0`, all invariants hold · symbols `0 unresolved` · evidence digests `630/630 PASSED`
  · `ci/check_lab_isolation.py` PASSED (0 errors, 14 notes), selftest rc 0**;
* **AND TWO DEFECTS IN THAT LAST CONTROL WERE FOUND AND REPAIRED THIS ROUND, BOTH OF THE SPECIES *A CHECK THAT CANNOT
  JUDGE*:** its accessibility invariant's **identifier half searched the whole source**, so **one tab carrying an
  identifier satisfied it for all five** — *committed by the very function that names the law twelve lines above it,
  "a window that reacheth past the thing it judgeth is not a check"*. **The proof is a
  measurement on one tree, not an argument:** with SOS's identifier removed, the **old** whole-source regex answered
  `True` — it would have passed — while the **new** per-tab check answered `False`, and the repaired control then
  failed **naming the tab**: `the tabs carrieth labels but NO ACCESSIBILITY IDENTIFIER on the tab(s): SOS`.
  **AND A CLAIM I MADE IN THE SAME BREATH IS WITHDRAWN: I ALSO "REPAIRED" THE EIGHT `check_the_lab_*` INVARIANTS TO
  HONOUR THE `--root` THEY ARE HANDED — AND THAT WAS WRONG, BECAUSE THE BEHAVIOUR WAS LOAD-BEARING.** `test_t54.py`
  passes a temp root carrying only `SELFTEST_FILES`, and **three t54 arms depend on those invariants reading the real
  repository**; my change turned 2 failures into 2 failures **plus 3 errors**. It is **reverted exactly** (the diff is
  now the accessibility block alone) and the identifier half is kept, because it is proven by measurement and breaks
  nothing. **I ran the control, it passed, I committed — and the three broken arms surfaced only when the full lane was
  run afterwards: a mandatory control can be green while the repair of it breaks another lane, and the control cannot
  tell you.** *A behaviour that looks like a defect may be load-bearing — measure what depends on it before calling it
  broken.* **Still owed:** the selftest cannot yet exercise those invariants (`SELFTEST_FILES` lacks
  `LabMeshRootApp.swift`), so their proof remains by hand.
* **THE PYTHON LANE, MEASURED HONESTLY BECAUSE THIS SPAN HAD NEVER RUN IT: `python3 -m unittest discover -s
  tools/readiness/tests` → `Ran 637 tests` · `FAILED (failures=2)`.** The two failures are
  `test_t01.InventoryFactsTest.test_inventory_matches_live_git_facts` (480 != 496) and
  `test_t01.OriginalPreservationTest.test_original_status_unchanged` (324 != 340, *"declared addition
  AUDIT_FINAL_2026-09-15 drifted"*). **Neither is this span's:** both concern `/Users/oculus/Projects/GODSTONE`, the
  **main checkout this span never writes to**, and the 16 extra entries are
  `AUDIT_FINAL_2026-09-15/evidence/AUDIT-004/…` written **2026-09-17 15:25–15:32** — including
  `latest-submission-state.json` and `source-snapshot-a3af03de.tar.gz` — **an independent auditor's own working
  files.** The audit bundle is read-only to this span and was **not touched or deleted**. **The lane carried FOUR
  failures; the two that were this record's own doing are FIXED** (see below), and the declaration was deliberately
  **not** edited to match a third party's mid-flight writes, because that would be changing the expression until the
  control is satisfied — moving the evidence.

### A CORRECTION AGAINST THIS RECORD, AND IT IS THE MOST EXPENSIVE OF THE SPAN
**The python lane was red with four failures and this span never ran it**, while writing *"every mandatory lane
green"* into its own commits. Two of the four had stood **since PHASE ONE**:
* `counts.by_status` was re-derived at round 340 into a value `test_remediation.py:131` **can never accept** — that
  control compares the field against the audit's own registry `{OPEN: 54}`. The field carries the snapshot again; the
  derived distribution lives in its own named field;
* **five findings** (CRYPTO-002, CRYPTO-005, GS-INBOX-001, GS-INTEGRATION-001, GS-STORE-006) were submitted with their
  `my_red_case`/`my_fix_commit` **fields empty** while their justification lived only as prose in `my_logs`. They now
  carry their **measured** commits and **measured** arm names — with the honest boundary stated: for CRYPTO-002 and
  GS-STORE-006 the charge was a seam **unbound to a court**, so the "red" is **the absence of a witness** and is not
  dressed as a behavioural RED.

**Law paid for: WHEN A CONTROL COMPARETH A LEDGER FIELD AGAINST AN EXTERNAL REGISTRY, THAT CONTROL OWNS THE FIELD'S
MEANING.** Re-purposing the field without re-reading its control is not a correction — it is **a red lane wearing a
correction's clothes.** And round 340's went unnoticed for **181 rounds because nobody ran the lane**: *a lane that is
never run is a lane that is assumed green.*

## WHAT AWAITS INDEPENDENT VERIFICATION
**ALL OF IT.** `VERIFIED_FIXED` is **zero** across the programme, and **no finding in these candidates has been examined by
anyone but its author**. The arms below are **the author's** proofs; an independent audit is the only thing that may call
them sufficient:
* CRYPTO-005 — `testCRYPTO005_theIntentSurvivesAReopenOfTheDurableStore` and
  `testCRYPTO005_theCompositionPinsTheIntentBeforeTheRadioAndSurvivesAReopen`;
* GS-INBOX-001 — `testDiskFailureYieldsNeitherAckNorClaimedAcceptance` and the durable-inbox / end-to-end ACK arms;
* CRYPTO-002 — the four canonical courts carrying the finding's own id;
* GS-INTEGRATION-001 — `testGSINTEGRATION001_afterAWipeTheDurableIntentMustBeGone` (RED 0.195 s → GREEN 0.010 s);
* **ANDROID-03 (new)** — `testAndroid03_theFallCarriethTheSameImmutablePeerTheRiseDid`, whose **negative case** faileth on
  its own name (*"the fall must publish exactly one LinkLost"*);
* **GS-UX-001 (new)** — `testTheLabJourneyReachethADurableAuthorityAndSurvivethAReopen`, whose **negative case** failED on
  **both judging clauses by name**;
* **GS-STRESS-001 (new)** — `test_w14_the_session_invariant_is_asked_of_a_real_owner`, whose **negative case** failED on
  clause 1's own name (*"a REAL live slot must be reported against the owner that holdeth it: []"*).

## WHAT DEPENDS ON EXTERNAL ARTIFACTS
Nothing in these candidates supplies, or claims to supply, any of the following — **and none was fabricated**:
* **a real process restart.** The card's closure clause for CRYPTO-005 asks for storage *"reopened in a NEW PROCESS"*; the
  arms **reopen the store from the same path**, which is "a new process" as far as the medium is concerned (the isle's own
  courts annotate that idiom) — **but no process is terminated**;
* **device / radio measurements** — for every Android and iOS finding here, **ANDROID-03 and GS-STRESS-001 included**: both
  were driven on the host through their transports' own entries, and neither is a device result;
* **platform-encryption proofs** — GS-INBOX-001's card names them as **explicitly tracked child commits**, and **none of
  those child commits is taken**;
* **a UI-testing target.** GS-UX-001's last clause (*"exercise the rendered controls"*) has **no `XCUIApplication` and no
  `androidTest` target on either isle**, so it is **not reachable today** and is named rather than implied. No VoiceOver,
  TalkBack, text-scale or RTL result is claimed, and **independent human accessibility acceptance remaineth pending**;
* **the Android counterparts.** The Mesh medium landed is **iOS-only**; and the Android lab UI is a `TextView`
  (`LabMainActivity.kt:20-27`) that cannot reach `:app`.

## WHICH CLOSURE EVIDENCE IS STALE
* **Arms predating this span** — *their passing is evidence about the SHA they ran on, not about these*;
* **CRYPTO-005's original restart arm** — it claims a restart while **reusing its medium**; round 430's sibling arm exposed
  exactly that by differing by one argument. Carried as stale rather than quietly renamed;
* **the old in-memory paths** remaining beside the repaired ones — *`ComposedRuntime.sendDirect` still never consults an
  intent journal while its own comment claims "the durable enqueue happeneth FIRST"; the harness's radio is still an
  in-process `LinkFacade`*; **and the lab's own `sendDirect` still taketh the in-memory road beside the new durable door**;
* **`publishAuth` still reacheth no production site** — the T24 card nameth **three** events and **two** travel now;
* **the round-228 blocker record for ANDROID-03** named ANDROID-01's absent D2 chain as its blocker; **ANDROID-01 is
  `FIX_SUBMITTED` and the witness was drivable this round** — the stale blocker was re-measured rather than inherited.

## WHAT THIS ROUND FOUND THAT THE AUDIT DID NOT NAME
* **ANDROID-03's capture spoke for a relation the transport had never published** — found by a RED that printed its own
  census, not by reading;
* **GS-STRESS-001's blocker record was STALE** — it named GS-INTEGRATION-001 as `OPEN` when it standeth `FIX_SUBMITTED`.
  Law paid for: **a blocker recorded once is a claim, not a measurement, and a stale blocker is worse than none**;
* **the single `lastCapturedPeer` slot could carry the wrong relation's peer in the rise itself** — a latent defect closed
  in passing and named as such;
* **a truncated capture is not a capture** — a lane log kept with `tail -120` showed **onely** `GodstoneCoreTests` (82)
  while the lane had in fact run 1187 more; *the truncation is named in the log itself rather than quietly replaced*;
* **two slips of mine are recorded rather than deleted**: a negative-case patch that failed to compile (caught only by
  asking the RC **and** the bundle verdict **and** the arm's name — three questions, all answering "nothing happened"), and
  **a log I overwrote**, recorded as a transcript because the capture is gone.

## ROUND 521, PHASE TWO — WHAT MOVED AND WHAT IT OWES

**GS-STORE-002 moved its central charge from a COMMENT to a CODE LAW.** Its three standing arms (W01–W03) are
**source-substring** laws — *they prove what the composition SAYETH, never what it DOTH* — so a **behavioural RED** was
taken first: **the card's own closure test**, composing the runtime, writing a private store, and reading that file with
**stock unkeyed `sqlite3`**. MEASURED RED, `rc=0` (`SQLITE_OK`) against the composition's private store. The repair makes
`MeshRuntime.create` **refuse without a verifying factory**, and the plaintext road now exists **only under a name a
caller must write down** (`createArchiveOnlyHostComposition`). **A comment is not a measurement; a name is.**
**And a mandatory control broke and was found by RUNNING it, not by reading:** the rename broke two relational
assertions in `check_trusted_runtime_composition_controls.py`, which greps a *neighbour's text*. Measured after:
**iOS lane 1190 tests / 0 failures** (1188 → 1190: the +2 are the new arms), all gates PASS.

**IT IS STILL `PARTIAL`, AND THE OWED PROOF IS NAMED RATHER THAN IMPLIED: the concrete SQLCipher engine is an
EXTERNAL artifact — NOTHING here is evidence that any store IS encrypted.** The card's step 1 needs a *pinned
dependency* (an acquisition, and **acquisition never closes a gate**), and its own third clause demands **device
SQLCipher and locked-device evidence** before T30 may be called complete.

## ROUND 522, PHASE TWO — THE AUDITOR'S OWN ARMS ENTER THE CANONICAL SUITE

**GS-SOS-001's ordered FIRST step is done, and it is the first time in this programme that the assertion is not the
author's.** The card placeth it first — *"Copy `Audit002SosSyncTest.missingSigningAuthorityMustNotQueueUnauthenticatedSos`
into the canonical mesh tests and preserve its empty-store expectation. Keep `configuredAuthorityProducesVerifiableSos`
as the positive control."* — and **the string appeared NOWHERE in the repository, on either isle**: the finding's other
work had landed on *other* arms, so its own first instruction stood undone. **A card's ordered first step is a claim
until it is measured, and it had not been.**

The source is the auditor's own read-only file
(`AUDIT_FINAL_2026-09-15/evidence/AUDIT-002/sos_sync/Audit002SosSyncTest.kt`), **with the auditor's own recorded
verdict beside it**: `tests="4" failures="3"`, that arm **FAILED** with *"Missing signing authority must be typed
failure, got QueuedLocally"*, and the positive control passed. **So the arm AND its failure both pre-date this
remediation, and the repair is measured against a bar THE AUDITOR ERECTED.**

**MEASURED AFTER THE COPY: `tests="2" failures="0" errors="0"`, both arms passing; and in the full Android lane
1226 tests / 0 failures across 78 classes.** Two deviations from the auditor's text are named rather than silent — the
positive control's authority gained `currentIdentityBinding()`, *which is this finding's own second defect*, added in
the auditor's own idiom so the arm could compile at all; nothing else changed.

**AND THE NEGATIVE CASE IS THE STRONGEST EVIDENCE IN THIS FINDING'S HISTORY: with the refusal replaced by the legacy
unauthenticated success, the arm failed with THE AUDITOR'S OWN RECORDED MESSAGE VERBATIM** — *"Missing signing authority
must be typed failure, got QueuedLocally"* — **while the auditor's positive control still passed.** The arm judges; its
green comes from the repair; and the failure is specific rather than a blanket breakage.

**AND THE OTHER TWO OF THE AUDITOR'S FOUR ARMS ARE COPIED TOO — MEASURED FIRST, THEN KEPT: ALL FOUR PASS,
`tests="4" failures="0" errors="0`, AGAINST THE AUDITOR'S RECORDED `tests="4" failures="3"`. EVERY ARM THAT FAILED FOR
THE AUDITOR NOW PASSES.** The full Android lane: **1228 tests / 0 failures across 78 classes.**

**A CORRECTION AGAINST THIS RECORD:** my first ledger entry said those two arms were **"NOT COPIED"**, on the
*assumption* that they would still be red. **The assumption was never measured and it was wrong** — they were one
command away from being measured the whole time, and measuring them closed the auditor's entire file.
**An assumption about what will fail is not a measurement of what fails.** And a second error nearly became a false
measurement: the first transcription **dropped the auditor's `import io.godstone.mesh.router.*`**, and I read the
resulting eight unresolved references as *"the types have moved since the audit"* — **false**, they live exactly where
the auditor's import says. *A cause invented from a plausible story is not a cause*; the truth was found by grepping.

## ROUND 523, PHASE TWO — THE UNMEASURED BECOMES A MEASUREMENT, AND A FINDING MOVES ON IT

**Round 522 named GS-SOS-001's step 6 UNMEASURED and said plainly that the next round measures it rather than
inheriting a guess. This round measured it, and the measurement replaced the note.**

* **half (a) — *"carry the same failure semantics through retry/UI projection"* — IS LANDED on BOTH isles**, read from
  the handlers: Android maps `SosOutcome.Refused -> withAuthorityError("the call could not be placed: " + outcome.reason)`
  and `RetryOutcome.Refused -> withAuthorityError("retry refused: " + outcome.reason)`; iOS carries
  `SosOutcome { enqueued, cancelled, alreadyCancelled, refused(String) }` and `RetryOutcome`. **The typed refusal and its
  reason reach the projection — not collapsed into a generic error.**
* **half (b) — *"wire authenticated receiving observers through the actual runtime when their dependency is available"*
  — is CONDITIONAL IN THE CARD'S OWN WORDS, and its state is now measured:** the `SosObserver` seam exists on both
  isles, is **consulted** at the SOS dispatch site (`MeshNode.swift:1071`, `MeshNode.kt:1123`, `if (observer != null)`),
  and **IS NEVER ASSIGNED IN PRODUCTION ON EITHER ISLE** — the only assignments are two courts. **The seventh
  appearance of this programme's recurring shape**, after ANDROID-04's sweep, IOS-07's deadline sweep, T24's trusted
  publication, GS-RUNTIME-001's ACK pumps, ANDROID-03's fall, and GS-UX-001's durable door. Its wiring is gated by
  GS-RUNTIME-001 (still `PARTIAL`), and **nothing was wired: wiring an observer to a runtime that does not stand would
  be fabricating integration** — the very substitution the card's last sentence forbids.

**SO GS-SOS-001 MOVES TO `FIX_SUBMITTED` ON FOUR MEASURED GROUNDS:** its central charge is closed against **the
auditor's own complete arm set** (`tests="4" failures="0"` versus the auditor's recorded `tests="4" failures="3"`); its
steps 2–5 were landed in earlier rounds; step 6's half (a) is now measured landed on both isles; and half (b) is
conditional on a dependency the card itself names — measured, and named as owed-conditional. **The one thing that must
not be read into this: `VERIFIED_FIXED` is still 0 and may not be written by this span.**

## ROUND 524, PHASE TWO — GS-ARCHIVE-005: A GUARD NOBODY COULD SATISFY

**The finding's own charge, measured and then repaired.** `.navigationDestination(for: ArchiveDocument.self)`
(`ArchiveView.swift:88`) constructs `ArchiveDocumentReader(document:library:scene:)` and calls `scene.open(` **nowhere** —
so `openedDocumentId`/`openedSource` are **never set by the route**, `provenanceLine()`'s guard (`:187`) is **never
satisfied**, and **the required provenance line rendered nothing**: *the card's own words.*
**A guard that cannot be satisfied is not a provenance line; it is an absence with a condition in front of it.**

**The card offered two options, and the second is measurably right:** routing selection through `scene.open(document:)`
would make the destination drive the *scene's* model while the reader drives its *own* — **two loads of one document** —
whereas `ArchiveDocumentReader` **already receives the `ArchiveLibrary` and discarded it**, and `ArchiveLibrary` carries
`nonisolated public func sourceMetadata(documentId:)`. **The metadata now belongs to the document actually on screen**,
so a neighbour's provenance cannot be shown **by construction**.

**The RED was taken first and failed on both clauses**, while its **witness passed in the same run** — so the structural
clause rests on a **measured semantic**, not hope. **The instrument is structural and says so**: the view lives in the
App target and **no test bundle can import it** (measured: a 5-file allowlist; both bundles link only the packages).
*This is not the GS-STORE-002 situation, where a behavioural instrument was available and unused — here its absence was
measured first.* **And the shipping target was verified the way it must be**: `xcodebuild -scheme Godstone-Light …
build` answered **`** BUILD SUCCEEDED **`**, because **the SwiftPM lane never compiles `Godstone/Sources/App/`.**

**THREE ERRORS OF MINE, EACH CAUGHT BY A DIFFERENT INSTRUMENT:** (a) I wrote `model.sourceMetadata(...)` and **the
compiler refused it** — the member belongs to `ArchiveLibrary`, and I had inferred its owner **from the file's name**:
*a file's name is not a type's name, and reading a line is not reading the anchor that owns it*; (b) **my structural
check was fooled by my own repair's comment**, which quotes the very spelling the check forbids — *a check that reads
comments is not a check on code* (round 261's species; the check now **strips comments first**); and (c) **I ran
`git stash` to test a hypothesis the arm's own message had already answered, and stashed the work under verification** —
restored in the same round, and recorded, *because a habit that suspends work to satisfy curiosity is a habit that will
one day lose it.*

**NOT CLAIMED:** the `NavigationStack` is **still unbound** (the second option was taken deliberately), step 4's
persistence and its production `snapshot`/`restore` caller are **untouched**, and **closure test 2 (process recreation)
is not satisfied**. The finding stays **`PARTIAL`**. Measured: iOS lane `SWIFT_RC=0`, `GodstoneCoreTests` **84/0** (82 →
84: the +2 are the new arms), `GodstoneMeshTests` 1190/0; parity `--scope repo` 7/0; symbols 0 unresolved; digests PASSED.

## ROUND 525, PHASE TWO — THE RECORD GAINS ITS FIRST PRODUCTION CALLER, AND A HYPOTHESIS IS REFUTED

**GS-ARCHIVE-005 step 4's defect was the "no production caller" one:** `snapshot(into:)` and `restore(from:)` had
**no caller but courts**, so a process recreation lost the promised query and document place. **The repair uses the
vehicle the card names by name** — `@SceneStorage("godstone.archive.scene")`, written on every scene-phase departure
and on disappear, read back and invoked **before the first browse**, *because the card's clause is an ORDER: a
restoration run after `loadDocuments()` would replace a restored document with the browse's own empty query.*

**AND THE ROUND'S FIRST MEASUREMENT REFUTED THE ROUND'S OWN HYPOTHESIS, WHICH IS WORTH MORE THAN THE REPAIR.** I
suspected an `Int64` would not survive a real plist round-trip through the `[String: Any]` handle, and wrote W16 to test
it. **W16 PASSED** — the handle does survive serialisation into a fresh scene, identity and metadata intact.
**A suspected defect that a measurement refutes is still a measurement**, and it redirected the round to what was
actually broken. *And no arm had ever asked:* **every existing arm round-trips the handle IN MEMORY ONLY**, while the
whole of step 4 is about surviving a **process recreation** — `PropertyListSerialization` appeared **nowhere** in the
repository. **A round-trip nobody ever serialised is not a round-trip.**

**Measured:** RED first (`20 tests, with 4 failures`, all four clauses); negative case fails on the caller clauses
**while W16 still passes**; **the shipping App target built** (`** BUILD SUCCEEDED **`) *because the SwiftPM lane never
compiles `Godstone/Sources/App/`*; iOS lane `SWIFT_RC=0` with `GodstoneCoreTests` **86/0** (84 → 86) and
`GodstoneMeshTests` 1190/0.

**NOT LANDED, AND NAMED:** step 4's *"bind it to `NavigationStack`"* clause (step 1's second option was taken
deliberately, so the stack still carries no `path:`), **step 3 (Android's `SavedStateHandle`) is untouched — this round
is iOS-only**, and **no rendered-screen witness exists** on this isle, so the card's closure test 2 is witnessed at the
**record and the wiring, not by recreating a process**. The finding stays **`PARTIAL`**.

## ROUND 525b, PHASE TWO — THE BOTH-ISLES MIRROR, AND A DEFECT ONLY RUNNING COULD FIND

**The objective's phase-two law requires the shared contract "on BOTH isles where the contract is shared"; round 525
had landed step 4 on iOS alone, so this went to Android.** Measured before any edit: `snapshotTo`/`restoreFrom` existed
on `BrowseViewModel` with **no production caller**, and **`SavedStateHandle` appeared nowhere in the Android tree** —
*so the card's charge was exactly true on this isle too.* The repair takes the card's own second option (the helpers are
**not removed but made the serialisation behind the real handle**) and the vehicle it names.

**AND THE BEHAVIOURAL ARM FOUND A REAL DEFECT IN PRODUCTION CODE ON ITS FIRST RUN:**

```
NullPointerException: Cannot invoke "java.util.concurrent.atomic.AtomicLong.incrementAndGet()"
                      because "this.generation" is null
```

**The cause is the card's own demand meeting Kotlin's initialisation order:** the card says *"Restore them from the
constructor"*, and `init` blocks run **in declaration order** — so a restore placed near the constructor reaches
`generation` (`:168`), `_state` (`:133`) and `returnScene` (`:181`) **while they are still null.** *The code looked right
at both positions, and a structural check would have agreed with it: **only running it could tell.*** The repair moves
the restoration to the class's existing startup `init`, **after every declaration and before the first browse** — and
**suppresses the browse when it restores**, because `loadDocuments()` would otherwise strike out the place just restored.

**The write comes from ONE seam** (a collector over the state flow) rather than from each of nine publishers —
*a rule enforced at one seam beats a rule remembered at N call sites.* **The discriminator:** an empty handle must mean a
**first browse**, not a restoration of nothing.

**Measured:** `:app` lane `BUILD SUCCESSFUL`, **53 tests / 0 failures / 0 errors**; `:mesh` lane re-run, **1228 / 0 / 0**;
parity `--scope repo` all invariants hold; symbols 0 unresolved; digests PASSED.
**NOT claimed:** step 3 also asks for **a valid reading anchor**, and this round persists the *place* but **not the
anchor** (the Android state carries no anchor field) — so that clause is explicitly not claimed; step 4's
`NavigationStack` clause is still undone; and **no rendered screen was ever exercised.** The finding stays **`PARTIAL`**.

## REMAINING WORK
**PHASE TWO** — the **eight `PARTIAL`** (ANDROID-05, GS-ARCHIVE-005, GS-RUNTIME-001, GS-SOS-001, GS-STORE-002,
GS-STORE-004, **GS-UX-001**, **GS-STRESS-001**) and the external artifacts above. **No finding is `OPEN`; none is
`VERIFIED_FIXED`; and the two newly `PARTIAL` ones carrieth a slice, not a fix.**

**Readiness flags remain FALSE and the five external gates remain OPEN. Acquisition never closes a gate.**
