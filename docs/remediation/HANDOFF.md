# Remediation handoff — AUDIT-003-R1

Ledger `REMEDIATION_STATE.json`; protocol `README.md`; external requests `EXTERNAL_INPUT_REQUESTS.md`;
audit source `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` (READ-ONLY; its own process keepeth writing into the original checkout).

## Status — 14 submitted, 40 OPEN

NOT ONE finding is `VERIFIED_FIXED`: only an INDEPENDENT AUDIT may write that.

| Finding | My status | Wave | Title |
|---|---|---|---|
| GS-CTRL-001 | FIX_SUBMITTED | 1 | Completion validator accepts failed commands, missing logs |
| GS-CTRL-002 | FIX_SUBMITTED | 1 | Readiness controls already fail on the audited task sequen |
| GS-GATE-001 | FIX_SUBMITTED | 1 | Release gate validation can bypass exact-SHA and executor  |
| GS-ARCHIVE-001 | FIX_SUBMITTED | 2 | Archive runtime accepts usable bytes without the required  |
| GS-ARCHIVE-002 | FIX_SUBMITTED | 2 | Android admits malformed archive schema and reports SQL re |
| GS-ARCHIVE-003 | FIX_SUBMITTED | 2 | Android search results cannot open the full document and N |
| GS-ARCHIVE-004 | FIX_SUBMITTED | 2 | The iOS full-document reader has no scrolling container |
| GS-CONTENT-001 | FIX_SUBMITTED | 2 | Final chunk approvals are optional in release builds, and  |
| GS-CONTENT-002 | FIX_SUBMITTED | 2 | Archive bytes and their receipts are published separately, |
| GS-CONTENT-003 | FIX_SUBMITTED | 2 | The default release validation/check-only path still accep |
| GS-PACKAGE-001 | FIX_SUBMITTED | 3a | The iOS artifact inspector accepts prohibited signed entit |
| GS-PACKAGE-002 | FIX_SUBMITTED | 3a | The Android artifact inspector validates AAB names but not |
| GS-SUPPLY-001 | FIX_SUBMITTED | 3a | Offline cache restore accepts traversal names and symlink  |
| GS-DIAG-001 | FIX_SUBMITTED | 8 | Diagnostics retain an unbounded map of historic relation k |

## DO THIS FIRST

- `GS-ARCHIVE-005` — Archive navigation bypasses selection metadata and persistence helpers

## Work already IMPLEMENTED but NOT SUBMITTED (no behavioral red yet)

- **GS-ARCHIVE-002**: the card's step 4: make BrowseViewModel CONSUME the checked result and show sanitised Unavailable/ReadFailure with retry, removing `getOrDefault(ArchiveState.Ready(origin="assumed"))` -- NOT yet done (it is an app-layer change with its own court, T49)
- **GS-ARCHIVE-002**: the card's step 5-6: keep repository availability separate from per-request success (the arm already doth) and add source-to-UI integration coverage through the real repository in the view model
(An entry in this list carrieth a code change that no ARM witnesseth. The ledger court REFUSETH a
finding that moveth off OPEN without a red, and it was right to. Write the arm against the
PRE-REPAIR product so it is genuinely RED, then resubmit.)

## The next findings, in the queue's order

- `GS-ARCHIVE-005` — Archive navigation bypasses selection metadata and persistence h (wave 2, MEDIUM)
- `GS-MODEL-001` — Runtime model staging and loading can omit all provenance verifi (wave 3b, HIGH)
- `ANDROID-01` — The application never starts D2 or key confirmation (wave 4e, HIGH)
- `ANDROID-03` — T24 trusted publication is unused; the real consumer still recei (wave 4e, HIGH)
- `CRYPTO-001` — Session lookup and destruction still use only a peer handle, so  (wave 4b, HIGH)
- `CRYPTO-002` — Session retirement never reaches the transport authority and exp (wave 4b, HIGH)
- `CRYPTO-003` — Destroyed retained controllers and primitive sessions still repo (wave 4b, MEDIUM)
- `CRYPTO-004` — The T35 low-order-DH negative tests exercise an unused helper wh (wave 4b, HIGH)
- `CRYPTO-005` — DIRECT intent persistence is only an in-memory seam and is not c (wave 4b, HIGH)
- `CRYPTO-006` — Duplicate journal admission is treated as success for a differen (wave 4b, HIGH)
- `GS-STORE-001` — T29 proves a fake SQLCipher classifier, not the actual Android s (wave 4a, HIGH)
- `GS-STORE-002` — iOS private stores still use ordinary SQLite without a store DEK (wave 4a, HIGH)
- `GS-STORE-003` — Actual message-store upgrades still drop durable tables (wave 4a, HIGH)
- `GS-STORE-004` — Receipt-relative retention is not stored or executed by the real (wave 4a, HIGH)

## The suite that measures this work

`tools/readiness/audit_probes/` carrieth the audit's own 12-case probe suite: it began at SEVEN reds
and is FULLY GREEN, because GS-SUPPLY-001, GS-DIAG-001, GS-PACKAGE-001 and GS-PACKAGE-002 are
repaired. Each repair MOVED its arms verbatim into the canonical lane, inheriting the AUDIT'S OWN
FIXTURE -- moving the assertion is part of the REPAIR.

## How to reproduce a RED reliably

1. `git worktree add --force --detach <tmp> <PRE-REPAIR COMMIT>` (an UNCOMMITTED repair's
   pre-repair product IS `HEAD`).
2. `cp android/local.properties <tmp>/android/local.properties` -- a fresh worktree LACKS it and
   every Gradle command fails with "SDK location not found"; a COMPILE FAILURE IS NOT A RED.
3. Copy ONLY the court in, and write its RED arms against PRE-EXISTING API only.
4. Never report a compile failure as a behavioral red.

## Standing traps

- The original checkout carrieth the audit bundle, owned by ANOTHER process: declared as a GROWING
  addition (the floor may only RISE; a SHRINK is refused). Re-measure and re-capture the T01
  inventory whenever that court complaineth.
- A mutation rod over DEAD code can never be killed: delete the code, re-anchor on a LIVE guard.
- `assertRaises(ValueError)` without a NAMED reason is satisfied by an unrelated refusal.
- The green lane must never be red: a red-by-design probe liveth in `audit_probes/` until its
  finding's repair moves it into `tests/`.
