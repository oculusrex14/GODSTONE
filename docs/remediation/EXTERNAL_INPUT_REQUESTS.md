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
