# External-input requests — prepared, NOT acquired

This is the parallel acquisition lane the queue requireth: **exact requests, named owners and
immutable acceptance requirements** for the five external artifacts, prepared while internal
repairs continue.

## THE LAW THIS LANE OBEYETH

1. **ACQUISITION CLOSES NOTHING.** Receiving an artifact starteth a *recheck* of the tasks it
   blocketh; it never turneth a gate green by itself, and no ledger status moveth because a file
   arrived.
2. **NO SELF-GENERATED FIXTURE MAY SUBSTITUTE FOR AN APPROVAL.** A fixture proveth that a rule
   FIREth; it proveth nothing about the world. Every blocker below carrieth `closure_evidence` =
   NULL and no lane in this work has ever written one.
3. **A RECEIPT IS AN EVENT, NOT A DATE.** Each recheck trigger nameth a receipt, an access, an
   approval or a provisioning — never "soon" or a calendar boundary.
4. **EACH ARTIFACT IS BOUND TO THE CANDIDATE IT WAS APPROVED FOR.** Acceptance executeth against
   the converged candidate SHA and the pinned inputs; an approval of an older revision is stale the
   moment a production owner changes.

## The five requests

### A06 — independent-review

| | |
|---|---|
| **Blocks (still unfinished)** | T73, T75, T78, T79 |
| **The artifact required** | structured PINNED/matched-case conformance report + tamper controls |
| **Who alone can approve it** | external auditor |
| **How it is verified on receipt** | `python -m crypto.noise_lock --status` ; `python -m crypto.noise_lock --release` ; `python -m crypto.cacophony --check --write-status` |
| **Recheck trigger (an EVENT, never a date)** | receipt of reviewed artifact |
| **Closure evidence today** | `None` — NONE. This work never writes one. |
| **Internal prerequisites** | COMPLETE (the task awaiteth only its artifact) |

### APPROVED_CONTENT — content

| | |
|---|---|
| **Blocks (still unfinished)** | T78, T80 |
| **The artifact required** | release manifest + independent trust store |
| **Who alone can approve it** | content editor / releasing authority |
| **How it is verified on receipt** | `python3 -m tools.readiness.run task T80 --stage narrow` ; `python3 ci/check_release_gates_status.py` |
| **Recheck trigger (an EVENT, never a date)** | approved manifest staged |
| **Closure evidence today** | `None` — NONE. This work never writes one. |
| **Internal prerequisites** | COMPLETE (the task awaiteth only its artifact) |

### NATIVE_MODELS — native

| | |
|---|---|
| **Blocks (still unfinished)** | T62, T63, T64, T65, T78, T81 |
| **The artifact required** | hash-pinned binaries with license metadata |
| **Who alone can approve it** | native build owner |
| **How it is verified on receipt** | `python3 -m tools.readiness.run task T81 --stage narrow` ; `python3 -m tools.readiness.promises` |
| **Recheck trigger (an EVENT, never a date)** | binary drop received |
| **Closure evidence today** | `None` — NONE. This work never writes one. |
| **Internal prerequisites** | COMPLETE (the task awaiteth only its artifact) |

### HARDWARE — device

| | |
|---|---|
| **Blocks (still unfinished)** | T73, T74, T75, T76, T78 |
| **The artifact required** | device matrix results |
| **Who alone can approve it** | device lab |
| **How it is verified on receipt** | `python3 -m tools.readiness.run task T74 --stage narrow` ; `python3 ci/check_release_gates_status.py` |
| **Recheck trigger (an EVENT, never a date)** | device access established |
| **Closure evidence today** | `None` — NONE. This work never writes one. |
| **Internal prerequisites** | COMPLETE (the task awaiteth only its artifact) |

### SIGNING — release

| | |
|---|---|
| **Blocks (still unfinished)** | T76, T78 |
| **The artifact required** | signing metadata without key material |
| **Who alone can approve it** | release owner |
| **How it is verified on receipt** | `python3 -m tools.readiness.run task T76 --stage narrow` ; `python3 ci/check_release_gates_status.py` |
| **Recheck trigger (an EVENT, never a date)** | credentials provisioned |
| **Closure evidence today** | `None` — NONE. This work never writes one. |
| **Internal prerequisites** | not complete |

## What this document is NOT

It is not acquisition, not an approval, not a status change, and not evidence that any gate may
close. **No external party has been contacted by this work**, and no artifact has been received.
The register's own `frontier_note` and the task ledger remain the authority on the frontier; this
document only maketh the REQUEST exact enough to act upon.

---

# RE-VERIFIED AT ROUND 119 (source `223592689021`, tree `0f3977a5f8b7`)

This document was written when the lane was prepared; nothing has been acquired since, and this block
recordeth that the lane was RE-CHECKED rather than assumed. Every fact below is READ FROM THE
ARTEFACTS at that SHA, not remembered:

* **NO EXTERNAL PARTY HAS BEEN CONTACTED and NO ARTIFACT HAS BEEN RECEIVED** — the ledger's own
  `external_input_lane.audit_has_contacted_external_parties` is `False`.
* **EVERY EXTERNAL GATE IS STILL OPEN OR BLOCKED** (read from
  `docs/production/RELEASE_GATES_STATUS.json` at this SHA):
  * `A-06-independent-noise-vectors` — **OPEN**
  * `accessibility` — **BLOCKED**
  * `battery-thermal` — **BLOCKED**
  * `device-interoperability` — **BLOCKED**
  * `model-native-stack` — **OPEN**
  * `production-corpus` — **OPEN**
  * `signing-store-approval` — **BLOCKED**
* **NO FINDING CARRETH CLOSURE EVIDENCE** — the list is `[]` — so the five requests' own
  "Closure evidence today" rows above remain `None`, and **ACQUISITION CLOSES NOTHING** stayeth the law.
* **THE READINESS FLAGS ARE FALSE AND ENFORCED FALSE** by the canonical control
  `tools/readiness/tests/test_blocked_external.py::test_w05_the_readiness_flags_stay_false`, which
  PASSETH in the readiness suite at this SHA (`android_LINK_LAYER_READY = false`,
  `ios_linkLayerReady = false`, read through `tools/readiness/blockers.py::readiness_flags`).
* **THE LANE'S OWN ACCEPTANCE RULE STANDS**: "an approval of an older revision is stale the moment a
  production owner changes" — and production owners HAVE changed repeatedly since the audited snapshot,
  so any artifact that arriveth must be re-bound to the converged candidate SHA before it proveth
  anything.

WHAT THIS BLOCK IS NOT: it is not acquisition, not an approval, not a status change and not evidence
that any gate may close. A self-generated fixture is still never a substitute for an approval
(True).

## NATIVE_MODELS — a newly identified dependent (ledger round 180)

**`GS-ARCHIVE-005`'s iOS App-layer steps join the dependents of this gate.** Measured, twice: `swift build --package-path
ios/Godstone` fails at the app package's own native target — `ios/Godstone/Sources/GodstoneLLMBridge/LlamaBridge.mm:3:10:
fatal error: 'llama.h' file not found` — and **`third_party/llama.cpp` does not exist** (`third_party/` carries only a
README). The app target's `unable to resolve module dependency: 'GodstoneCore'` is the **downstream symptom** of the
package producing no products, not a wiring defect.

**Why no earlier round could see it:** the mirror package used by the SwiftPM lane **omits the native-dependent targets
entirely** (`ios/Packages/GodstoneFoundation/Package.swift`: 0 references to `GodstoneLLM`/`GodstoneLLMBridge`; the app's
own `ios/Godstone/Package.swift`: 3), and the App directory is in no lane.

**Consequence, stated in the gate's own terms:** the App-layer steps (the reader/scene ownership change, visible passage
anchors, and the app-level kill/recreate tests) **cannot be verified until this artifact arrives** — their verdict would
be an `xcodebuild` that cannot run. **The programme may not vendor, stub or synthesize `llama.cpp` to make its own app
build**, exactly as it may not manufacture an approval. Adding an app-layer lane that excludes the native targets is a
possible second path, and it is written down rather than taken: it would have to be weighed against the audit's rule that
no mandatory lane may be weakened, and against whether such a lane proves anything the audit accepts.

---

# RE-VERIFIED AT ROUND 607 (`945b8294`, tree clean)

Written because the last re-verification block above is bound to round 119 / source `223592689021`, and **the lane's own
acceptance rule sayeth that an approval of an older revision is stale the moment a production owner changes — the same
rule obligeth this REQUEST document to be re-read at the current revision rather than quoted from memory.** Every fact
below was READ FROM THE ARTEFACTS at this revision, and the commands are printed so a reader may repeat them.

* **NO EXTERNAL PARTY HAS BEEN CONTACTED and NO ARTIFACT HAS BEEN RECEIVED** — the ledger's own
  `external_input_lane.audit_has_contacted_external_parties` is **`False`**.
* **EVERY EXTERNAL GATE IS STILL OPEN OR BLOCKED**, read from `docs/production/RELEASE_GATES_STATUS.json` at this
  revision:
  * `A-06-independent-noise-vectors` — **OPEN**
  * `production-corpus` — **OPEN**
  * `model-native-stack` — **OPEN**
  * `device-interoperability` — **BLOCKED**
  * `accessibility` — **BLOCKED**
  * `battery-thermal` — **BLOCKED**
  * `signing-store-approval` — **BLOCKED**
  * (`android-archive-only-release` — **CLOSED**, and classified **HISTORICAL: inputs changed since (34)** by
    `ci/check_release_gates_status.py`, so it closeth nothing for the candidate.)
* **THE LANE'S OWN CONTROL PASSETH, AND ITS SELFTESTS REFUSE AMPUTATION**: `test_external_input_requests.py` —
  **12 passed**; `ci/check_release_gates_status.py` — the gate-evidence selftest **refuseth 15 of 15** evidence controls,
  the repo-owned lane selftest **refuseth 7 of 7** amputation controls, and *"2 repository-owned lanes carry every face
  they must hold; an amputated lane is refused by name."*
* **NO FINDING CARRETH CLOSURE EVIDENCE**, so every "Closure evidence today" row above remaineth `None`.
* **THE READINESS FLAGS REMAIN FALSE** (`android LINK_LAYER_READY = false`, `ios linkLayerReady = false`).

**AND ONE NEWLY IDENTIFIED DEPENDENT, NAMED RATHER THAN FOLDED IN: `GS-FINAL-004`'s CLAUSES (a)(b)(c).** The audit's
finding asketh for *"an owned verified connection with restricted construction"* and *"typed open errors"*. **MEASURED
THIS ROUND: NO PRODUCTION `EncryptedStoreEngine` EXISTS AT ALL** — `grep -rln ": EncryptedStoreEngine"` over the canonical
sources returneth the protocol DECLARATION alone; the only implementors in the tree are courts' `FakeEngine`s, because
the real SQLCipher binding **is** the injected seam this gate owns. A handle cannot be asked to carry a connection that
no production code produces. **CLAUSE (d) — the resumable migration with preserved rollback evidence — NEEDED NO NATIVE
ENGINE AND IS LANDED (round 605)**, so this gate blocketh three clauses of that finding and not four.

**WHAT THIS BLOCK IS NOT:** not acquisition, not an approval, not a status change, and not evidence that any gate may
close. **ACQUISITION CLOSES NOTHING**, and no self-generated fixture may substitute for an approval.

---

# ROUND 621 — THE FIVE CARDS COMPLETED WITH THE AUDIT'S OWN ACCEPTANCE FIELDS

Written because `godstone-audit/reports/13_external_gate_test_book.md` sayeth of itself that it is *"a procedure to
execute"* and carrieth **per-gate acceptance fields this document did not**: an OBJECTIVE, an explicit WHY-EXTERNAL, a
PROCEDURE, an EXPECTED, a FAILURE list, a RETAIN list, RELATED findings and a PERMITTED TRANSITION. **THE AUDIT ALSO
NAMED THIS AS AN OPEN ITEM (`NEXT_EXECUTION.md` step 7: *"Complete the five external acceptance cards"*).** Every field
below is COPIED FROM THE AUDIT'S BOOK OR THE REPOSITORY'S OWN ARTIFACTS, and where a field is unavailable the document
sayeth so rather than inventing a threshold. **THE BOOK'S OWN RULE IS REPEATED HERE BECAUSE IT IS THE ONE THAT MATTERS:
*"This test book is executable preparation guidance; where the original acceptance card or harness is unavailable, that
missing prerequisite is explicit rather than replaced by an invented acceptance threshold."***

## THE RETAIN CONTRACT, IDENTICAL FOR ALL FIVE (the book's own list, verbatim in substance)

Per-run evidence directory carrying: candidate and source tree IDs; exact profile; toolchain/device/OS identity;
artifact hashes; commands; test-case identifiers; stdout/stderr; structured outcomes; screenshots/video where relevant;
and an independent review result. **Synthetic private data only.** `gate-<NAME>/results.json` are PROPOSED OUTPUT
FILENAMES, NOT FILES CLAIMED TO EXIST.

## A06 — independent contract vectors

| | |
|---|---|
| **Objective** | Establish the exact A06 independent-vector acceptance, **not agreement between two implementations sharing fixtures**. |
| **Why external** | The independent approved vector source/approval is not available here; **the original acceptance text was not recovered.** The vector runner and negative corpus are internal deliverables. |
| **Prerequisites** | Recover the original A06 card; identify vector authority, algorithm/protocol/version, approved digests, required platforms, all acceptance cases; repair the relevant internal paths first. **Do not guess which fields or units A06 covers from its name.** |
| **Procedure** | Record approved vector provenance; run the same fixed bytes through each REAL implementation entry, not a helper created for the test; compare canonical output and exact rejection behaviour; substitute one unapproved/tampered vector and one semantic implementation mutant; rerun unmutated. Establish independence of expected outputs from the builder's implementation. |
| **Expected** | Every specified positive/negative vector has its required outcome **on both platforms**, and the mutant is caught. |
| **Failure** | Unapproved vectors, regenerated expected values, a skipped case, a helper-only path, mismatch, or unrecorded execution. |
| **Related** | CRYPTO/ACK/SOS and parity requirements as assigned by the original card. |
| **Permitted transition** | **A06 alone** may become satisfied after independent acceptance; **no other gate or original finding closes automatically.** |
| **Closure evidence today** | `None` — NONE. This work never writes one. |

## APPROVED_CONTENT — exact approved archive publication

| | |
|---|---|
| **Objective** | Prove the release uses the approved content/manifest/receipts **as one coherent generation**. |
| **Why external** | Human/content approval and its signing authority are owner-supplied; staging, trust selection and atomic publication must be engineered internally. |
| **Prerequisites** | Original approval policy; approved exact chunk/archive identities; signer trust roots; fixed internal content/availability paths; the final shipping build. |
| **Procedure** | Verify approval signatures and exact byte digests; install the release archive; open non-default documents/search hits through the SHIPPING reader; replace one chunk, receipt or manifest independently; interrupt publication between each step and restart; concurrently stage two different approved generations and verify no mixed result is accepted. |
| **Expected** | **Only a complete approved generation becomes readable**; tampering and stale approvals are rejected **without partial publication**. |
| **Failure** | Self-nominated signer accepted; unknown status shown Ready; mismatched archive/receipt; stale generation; silent empty success. |
| **Related** | GS-ARCHIVE-001/002/005, GS-CONTENT-001/002/003, **GS-FINAL-006/007/008**. |
| **Permitted transition** | Content gate only after the exact final profile passes; **internal findings still require independent closure.** |
| **Closure evidence today** | `None` — NONE. |

## NATIVE_MODELS — approved model identity and real loading

| | |
|---|---|
| **Objective** | Prove approved model/native components are authentic, compatible, bounded, and included only in the intended profile. |
| **Why external** | Approved model bytes, the required native artifact, and the real memory/performance environment may be unavailable. Provenance checks, loader failure handling and isolation are internal. |
| **Prerequisites** | Approved artifact/source/licence identity, digests and model format; exact supported ABI/device matrix; **recovered task acceptance thresholds**; a testable loader. |
| **Procedure** | Load the exact approved bytes via the real application/lab entry appropriate to the profile; capture initialization/result identity, memory and cancellation behaviour; test truncated/corrupt/substituted model and mismatched runtime format; interrupt loading and restart; **inspect the LIGHT payload to ensure excluded native models remain absent.** |
| **Expected** | Identity matches approval; invalid inputs fail safely; cancellation releases owned resources; **thresholds from the original card are met.** |
| **Failure** | Fabricated provenance; silent fallback to another model; unsupported ABI; leaked allocation; unbounded load; missing threshold evidence. |
| **Related** | GS-MODEL-001, package/supply findings, **and — newly identified — `GS-FINAL-004` clauses (a)(b)(c)**, because no production `EncryptedStoreEngine` exists and the SQLCipher binding IS this gate's artifact. |
| **Permitted transition** | **Native-model gate only. NO THRESHOLD IS INVENTED IN THIS AUDIT; missing acceptance thresholds block the gate.** |
| **Closure evidence today** | `None` — NONE. |

*(The repository's own measured dependency, restated: `swift build --package-path ios/Godstone` fails at
`LlamaBridge.mm:3:10: fatal error: 'llama.h' file not found`, and `third_party/llama.cpp` does not exist. **The
programme may not vendor, stub or synthesize `llama.cpp` to make its own app build**, exactly as it may not manufacture
an approval.)*

## HARDWARE — real transport, lifecycle and resource behaviour

| | |
|---|---|
| **Objective** | Validate the actual bounded authenticated runtime and its OS lifecycle **on supported physical devices**. |
| **Why external** | Real radios, OS behaviour and resource measurements **cannot be inferred from a host fake.** The runtime road, OS-facade injection, guard mutant and stress driver are internal prerequisites. |
| **Prerequisites** | All internal wipe/store/runtime defects fixed; a non-shipping instrumented profile with controlled activation and production state machines; shipping readiness flags unchanged; at least the supported Android/iOS pairing matrix; exact accepted packet/latency/resource criteria; real ownership telemetry. **Do not attempt the message path on a binary intentionally unable to activate it and then relabel the empty run a pass.** |
| **Procedure** | Connect real devices; discovery, GATT-bound identity, D2/key confirmation, authenticated receive, durable inbox/ACK commit, physical ACK return, recipient-verified delivery; each direction and duplicate/interrupted delivery; toggle radio/permission and foreground/background; stop/restart with work pending; **run the required 10000 real lifecycle cycles**, returning to a demonstrably drained runtime after each accepted cycle; inject OS-facade failures at defined boundaries and execute the real resource-guard mutant in the instrumented profile. |
| **Expected** | No delivery reported before its defined durable/authenticated milestone; old relations cannot affect replacements; bounded resources return to accepted baseline; every cycle's actual transitions are recorded; the guard mutant causes the specified named failure. |
| **Failure** | Simulated cycle counter; missing drain; stale callback; unbounded growth; substituted helper path; absent mutation confirmation; unauthenticated success; skipped device pairing. |
| **Related** | runtime, Android/iOS transport/lifecycle, stress, ACK, SOS, and **`GS-FINAL-006`'s Robolectric half is NOT this gate** — *Robolectric rendereth the composition but is not a device*, the audit's own distinction. |
| **Permitted transition** | Hardware gate only after its own acceptance on the declared matrix. |
| **Closure evidence today** | `None` — NONE. |

## SIGNING — exact release identity and packaged surface

| | |
|---|---|
| **Objective** | Establish final signed distribution identity, entitlements/permissions and profile isolation. |
| **Why external** | Owner signing authority and the intended distribution environment are not available. Build configuration and package inspectors remain internal engineering. |
| **Prerequisites** | Exact approved signing identity/provisioning; bundle/application IDs from the real project; intended platform/profile; clean final artifacts. |
| **Procedure** | Build/archive with the approved configuration; **inspect ALL nested executable identities and native platform/ABI slices**; compare effective signed entitlements and Android permissions to a versioned allowlist; verify no lab/native/model payload prohibited for LIGHT; install and launch the exact signed artifact and repeat critical smoke/regression gates. |
| **Expected** | Valid intended signature and platform; exact policy-conforming entitlements/permissions/payload; **successful install/launch of that same artifact.** |
| **Failure** | Debug or wrong signer; unapproved entitlement; wrong platform slice; lab inclusion; a different tested artifact; missing nested verification. |
| **Read-only verification commands** (the book's own, for a Mac / the pinned SDK — **these alone do not validate the complete package policy**) | `codesign --verify --strict --verbose=4 "$APP_PATH"` ; `codesign -d --entitlements :- "$APP_PATH"` ; `apksigner verify --verbose --print-certs "$APK_PATH"` |
| **Related** | GS-PACKAGE-001/002, GS-LAB-001, GS-SUPPLY-001. |
| **Permitted transition** | Signing gate only after its own acceptance; **acquisition of credentials is not a pass.** `ci/check_release_surface.py` PASSES today and is an INTERNAL control, not this gate. |
| **Closure evidence today** | `None` — NONE. |

## THE TWO SUPPLEMENTAL ACCEPTANCES THE BOOK NAMES, AND WHERE THEY STAND

* **Native-store acceptance — `GS-STORE-001/002`:** *"After repairing connection ownership, use the exact pinned
  SQLCipher engine on every supported platform... Inspect the actual linked native artifact, not a Boolean
  classifier."* **THE CONNECTION-OWNERSHIP REPAIR IS EXACTLY `GS-FINAL-004`'s CLAUSES (a)(b)(c), WHICH ARE BLOCKED ON
  THIS GATE** — measured this round: no production `EncryptedStoreEngine` exists. *"A pass may satisfy the native-engine
  evidence portion of the store findings, not fresh-wipe composition or all five readiness gates."*
* **UI/protection acceptance — `GS-UX-001` / `GS-ARCHIVE-005`:** *"Create and execute real UI targets internally
  first."* **THE ANDROID UI TARGET NOW EXISTS AND REALLY RENDERS, LAYS OUT AND SCROLLS under Robolectric** (round 564),
  which is the internal half this sentence asks for. On Android the physical half includes **reboot before first unlock
  when applicable — do not equate ordinary relock with Direct Boot**; on iOS validate the configured protection class
  and actual app lifecycle/availability notifications **under device conditions**, and note the iOS App layer cannot be
  compiled here at all. *"These tests close only their applicable acceptance layers."*

## WHAT THIS ROUND IS NOT

Not acquisition, not an approval, not a status transition, not evidence that any gate may close, and not an invented
threshold. **NO EXTERNAL PARTY HAS BEEN CONTACTED and NO ARTIFACT HAS BEEN RECEIVED.** The readiness flags remain
**FALSE**. **ACQUISITION CLOSES NOTHING.**
