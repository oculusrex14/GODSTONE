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
