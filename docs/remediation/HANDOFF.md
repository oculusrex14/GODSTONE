# Remediation handoff — AUDIT-003-R1

Ledger: `REMEDIATION_STATE.json`. Protocol: `README.md`. Audit source: `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` (READ-ONLY, and its own
process keepeth writing into the original checkout).

## Status — 14 submitted, 40 open

Not one finding is `VERIFIED_FIXED`: only an INDEPENDENT AUDIT may write that.

| Finding | My status | Wave | Title |
|---|---|---|---|
| GS-CTRL-001 | FIX_SUBMITTED | 1 | Completion validator accepts failed commands, missing logs,  |
| GS-CTRL-002 | FIX_SUBMITTED | 1 | Readiness controls already fail on the audited task sequence |
| GS-GATE-001 | FIX_SUBMITTED | 1 | Release gate validation can bypass exact-SHA and executor ev |
| GS-ARCHIVE-001 | FIX_SUBMITTED | 2 | Archive runtime accepts usable bytes without the required tr |
| GS-ARCHIVE-002 | FIX_SUBMITTED | 2 | Android admits malformed archive schema and reports SQL read |
| GS-ARCHIVE-003 | FIX_SUBMITTED | 2 | Android search results cannot open the full document and NoR |
| GS-ARCHIVE-004 | FIX_SUBMITTED | 2 | The iOS full-document reader has no scrolling container |
| GS-CONTENT-001 | FIX_SUBMITTED | 2 | Final chunk approvals are optional in release builds, and th |
| GS-CONTENT-002 | FIX_SUBMITTED | 2 | Archive bytes and their receipts are published separately, p |
| GS-CONTENT-003 | FIX_SUBMITTED | 2 | The default release validation/check-only path still accepts |
| GS-PACKAGE-001 | FIX_SUBMITTED | 3a | The iOS artifact inspector accepts prohibited signed entitle |
| GS-PACKAGE-002 | FIX_SUBMITTED | 3a | The Android artifact inspector validates AAB names but not i |
| GS-SUPPLY-001 | FIX_SUBMITTED | 3a | Offline cache restore accepts traversal names and symlink so |
| GS-DIAG-001 | FIX_SUBMITTED | 8 | Diagnostics retain an unbounded map of historic relation key |

## The next findings, in the queue's order

- `GS-ARCHIVE-005` — Archive navigation bypasses selection metadata and persistence hel (wave 2, MEDIUM)
- `GS-MODEL-001` — Runtime model staging and loading can omit all provenance verifica (wave 3b, HIGH)
- `ANDROID-01` — The application never starts D2 or key confirmation (wave 4e, HIGH)
- `ANDROID-03` — T24 trusted publication is unused; the real consumer still receive (wave 4e, HIGH)
- `CRYPTO-001` — Session lookup and destruction still use only a peer handle, so an (wave 4b, HIGH)
- `CRYPTO-002` — Session retirement never reaches the transport authority and expir (wave 4b, HIGH)
- `CRYPTO-003` — Destroyed retained controllers and primitive sessions still report (wave 4b, MEDIUM)
- `CRYPTO-004` — The T35 low-order-DH negative tests exercise an unused helper whil (wave 4b, HIGH)
- `CRYPTO-005` — DIRECT intent persistence is only an in-memory seam and is not com (wave 4b, HIGH)
- `CRYPTO-006` — Duplicate journal admission is treated as success for a different  (wave 4b, HIGH)
- `GS-STORE-001` — T29 proves a fake SQLCipher classifier, not the actual Android sto (wave 4a, HIGH)
- `GS-STORE-002` — iOS private stores still use ordinary SQLite without a store DEK (wave 4a, HIGH)
- `GS-STORE-003` — Actual message-store upgrades still drop durable tables (wave 4a, HIGH)
- `GS-STORE-004` — Receipt-relative retention is not stored or executed by the real s (wave 4a, HIGH)

## The suite that measures this work

`tools/readiness/audit_probes/` carrieth the audit's own 12-case final probe suite; it began with
SEVEN reds and is now FULLY GREEN, because GS-SUPPLY-001, GS-DIAG-001, GS-PACKAGE-001 and
GS-PACKAGE-002 are repaired. Each repair MOVED its arms verbatim into the canonical lane
(`tools/readiness/tests/`), inheriting the AUDIT'S OWN FIXTURE rather than re-inventing one — the
card's rule is that moving the assertion is part of the REPAIR.

## How to reproduce a RED reliably

1. `git worktree add --force --detach <tmp> <PRE-REPAIR COMMIT>` (for an UNCOMMITTED repair the
   pre-repair product IS `HEAD`).
2. `cp android/local.properties <tmp>/android/local.properties` — a fresh worktree LACKS IT and
   every Gradle command fails with "SDK location not found"; a compile failure is NOT a red.
3. Copy ONLY the court into the worktree, and write its RED arms against PRE-EXISTING API only.
4. NEVER report a compile failure as a behavioral red.

## Standing traps

- The ORIGINAL checkout carrieth the audit bundle, owned by ANOTHER process: it is declared as a
  GROWING addition (the floor may only RISE; a SHRINK is refused). Re-measure and re-capture the T01
  inventory whenever that court complaineth.
- A mutation rod over DEAD code can never be killed: delete the code, re-anchor the rod on a LIVE guard.
- An arm asserting merely `assertRaises(ValueError)` is satisfied by an UNRELATED refusal: assert the
  REASON by name.
- The green lane must never be red: a probe that is red BY DESIGN liveth in `audit_probes/` until its
  finding's repair moves it into `tests/`.
