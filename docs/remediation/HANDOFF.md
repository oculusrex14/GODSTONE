# Remediation handoff — AUDIT-003-R1

Written at round 13 of the remediation goal. The ledger is `REMEDIATION_STATE.json`, the protocol
`README.md`, and the audit source is `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` (READ-ONLY).

## Status

**10 findings submitted** (FIX_SUBMITTED — only an INDEPENDENT AUDIT may ever write
VERIFIED_FIXED; this work never writes it). **44 OPEN**, in waves ['2', '3a', '3b', '4b', '4a', '4e', '4f.1', '4d.1', '4c.1', '4d.2', '4f.2', '4c.2', '4c.3', '5', '6', '7', '8'].

| Finding | My status | Wave | Title |
|---|---|---|---|
| GS-CTRL-001 | FIX_SUBMITTED | 1 | Completion validator accepts failed commands, missing logs, and  |
| GS-CTRL-002 | FIX_SUBMITTED | 1 | Readiness controls already fail on the audited task sequence |
| GS-GATE-001 | FIX_SUBMITTED | 1 | Release gate validation can bypass exact-SHA and executor eviden |
| GS-ARCHIVE-001 | FIX_SUBMITTED | 2 | Archive runtime accepts usable bytes without the required truste |
| GS-ARCHIVE-002 | FIX_SUBMITTED | 2 | Android admits malformed archive schema and reports SQL read fai |
| GS-ARCHIVE-003 | FIX_SUBMITTED | 2 | Android search results cannot open the full document and NoResul |
| GS-ARCHIVE-004 | FIX_SUBMITTED | 2 | The iOS full-document reader has no scrolling container |
| GS-CONTENT-001 | FIX_SUBMITTED | 2 | Final chunk approvals are optional in release builds, and the ap |
| GS-CONTENT-002 | FIX_SUBMITTED | 2 | Archive bytes and their receipts are published separately, produ |
| GS-CONTENT-003 | FIX_SUBMITTED | 2 | The default release validation/check-only path still accepts a s |

## What each submitted finding still oweth (verbatim from the ledger)

- **GS-CTRL-001**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-CTRL-001**: the canonical Kotlin compilation and the full Gradle/Swift rosters rerun at the candidate SHA (a resolver cannot replace the compiler)
- **GS-CTRL-001**: the two gapped T01/T05 records remain gaps: their claims are covered by other commands, and the independent audit must decide whether that coverage is sufficient
- **GS-CTRL-001**: revalidation of every dependent suite after the validator change (every task's completion record is now judged by stricter rules)
- **GS-CTRL-002**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-CTRL-002**: the hosted lane: no hosted run URL/log was available to this work, so every result here is a LOCAL reproduction of the constituent commands; the R1 supplement requireth enabled/executed/green hosted jobs at the candidate SHA, which remains pending
- **GS-CTRL-002**: the resolver's skips (163 types whose inheritance leaveth the project, 7 unread in full) are a VISIBLE limitation: the compiler is the authority for those, and the canonical Kotlin compilation must be rerun at the candidate SHA
- **GS-GATE-001**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-GATE-001**: the hosted lane: no hosted run URL/log was available, so the hosted convergence the R1 supplement requireth remains pending
- **GS-GATE-001**: the card's step 6 (historical vs current closure over the FULL gate inputs) is exercised by T53's classification witnesses and the drift boundary, but the ancestor-to-current mapping has not been revalidated against a real changed-input set for every gate
- **GS-ARCHIVE-001**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-ARCHIVE-001**: the card's iOS steps (4) are NOT done: openAndValidate must resolve only a candidate associated with the descriptor and stream its exact length/hash verification before Ready
- **GS-ARCHIVE-001**: card step 5 (connect the release asset preparation output to the runtime resource/allowlist) is not done
- **GS-ARCHIVE-001**: no emulator or device was used: the harness is the real bundled driver on the HOST
- **GS-ARCHIVE-002**: the card's step 4: make BrowseViewModel CONSUME the checked result and show sanitised Unavailable/ReadFailure with retry, removing `getOrDefault(ArchiveState.Ready(origin="assumed"))` -- NOT yet done (it is an app-layer change with its own court, T49)
- **GS-ARCHIVE-002**: the card's step 5-6: keep repository availability separate from per-request success (the arm already doth) and add source-to-UI integration coverage through the real repository in the view model
- **GS-ARCHIVE-002**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-ARCHIVE-002**: no emulator or device was used: the harness is the real bundled driver on the HOST, which is the same engine the shipping APK installeth, but it is not a device run
- **GS-ARCHIVE-002**: a second RED by reversal was attempted and left the file syntactically broken; a COMPILE FAILURE IS NOT A BEHAVIORAL RED, so it was NOT reported as one -- the first run's XML evidence is the red
- **GS-ARCHIVE-003**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-ARCHIVE-003**: the card requireth a COMPOSE INTERACTION test (enter a query, tap a visible hit, read an unmatched passage from the same document) -- NOT written; the four witnesses are SOURCE assertions, which is the method the audit itself used for this source-confirmed finding
- **GS-ARCHIVE-003**: the card's Dynamic Type / TalkBack pass and the Android system-Back binding are NOT done; no emulator or device was used
- **GS-ARCHIVE-003**: the card's separation of full-document passage rendering from search-hit rendering (so tapping a paragraph in DOCUMENT mode does not reopen the same document) is NOT yet implemented
- **GS-ARCHIVE-004**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-ARCHIVE-004**: the card's closure requireth an ACTUAL iOS UI TEST: a document longer than several screens, scrolled to a unique final sentinel passage, repeated at Dynamic Type sizes with the reading order checked. NO simulator or physical gesture test was run here -- the container and the anchor decision are proven, the READING JOURNEY is not
- **GS-ARCHIVE-004**: no hosted run URL/log was available, so hosted convergence remains pending
- **GS-CONTENT-001**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-CONTENT-001**: the production-corpus lane in release-gates.yml must be given the independently configured reviewer keyset and approval-bundle paths (the card's step 4); with the approvals now mandatory, that lane must pass them explicitly or stop at the external content gate
- **GS-CONTENT-001**: the card's step 3 (one validation date captured in main() from the production clock) and step 5 (ONE release-eligibility routine shared by manifest creation and staging) are partially done: the provenance fields are shared, but a single named routine exercising schema/tier/counts is not yet factored out
- **GS-CONTENT-001**: no hosted run URL/log was available, so hosted convergence remains pending
- **GS-CONTENT-002**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-CONTENT-002**: the card's step 3 names an IMMUTABLE GENERATION DIRECTORY plus ONE atomically replaced POINTER; this repair implementeth the card's permitted alternative (step 4: a journaled publication protocol with backups and explicit recovery states) because the public fixed paths cannot migrate in one step. The generation-pointer migration remains PENDING and is the stronger design
- **GS-CONTENT-002**: the interprocess lock is proven by construction (fcntl.flock + the court's source assertions) but NOT by a genuine two-PROCESS race; the interleaving witness drives two builds in ONE process (as the audit's own probe does)
- **GS-CONTENT-002**: no hosted run URL/log was available, so hosted convergence remains pending
- **GS-CONTENT-003**: INDEPENDENT VERIFICATION: only an independent audit may mark this VERIFIED_FIXED
- **GS-CONTENT-003**: the release lane in release-gates.yml must be updated to pass the operator trust store explicitly (the repair maketh the absence fatal on every path); the workflow edit belongs with the content-lane work of GS-CONTENT-001
- **GS-CONTENT-003**: no hosted run URL/log was available, so hosted convergence remains pending

## The next findings, in the queue's order

- `GS-ARCHIVE-005` — Archive navigation bypasses selection metadata and persistence helpers (wave 2, MEDIUM)
- `GS-MODEL-001` — Runtime model staging and loading can omit all provenance verification (wave 3b, HIGH)
- `GS-PACKAGE-001` — The iOS artifact inspector accepts prohibited signed entitlements and  (wave 3a, HIGH)
- `GS-PACKAGE-002` — The Android artifact inspector validates AAB names but not its native  (wave 3a, HIGH)
- `GS-SUPPLY-001` — Offline cache restore accepts traversal names and symlink sources (wave 3a, HIGH)
- `ANDROID-01` — The application never starts D2 or key confirmation (wave 4e, HIGH)
- `ANDROID-03` — T24 trusted publication is unused; the real consumer still receives lo (wave 4e, HIGH)
- `CRYPTO-001` — Session lookup and destruction still use only a peer handle, so an old (wave 4b, HIGH)
- `CRYPTO-002` — Session retirement never reaches the transport authority and expired s (wave 4b, HIGH)
- `CRYPTO-003` — Destroyed retained controllers and primitive sessions still report rea (wave 4b, MEDIUM)
- `CRYPTO-004` — The T35 low-order-DH negative tests exercise an unused helper while th (wave 4b, HIGH)
- `CRYPTO-005` — DIRECT intent persistence is only an in-memory seam and is not compose (wave 4b, HIGH)

## How to reproduce a RED reliably (learned the hard way)

1. `git worktree add --force --detach <tmp> <PRE-REPAIR COMMIT>` — for an UNCOMMITTED repair the
   pre-repair product IS `HEAD`.
2. `cp android/local.properties <tmp>/android/local.properties` — a fresh worktree LACKS IT and
   every Gradle command fails with "SDK location not found"; a compile failure is NOT a red.
3. Copy ONLY the court into the worktree. Write its RED arms against PRE-EXISTING API only: an arm
   that toucheth an API the repair introduced CANNOT compile against the pre-repair product (four
   reversal attempts failed exactly that way).
4. NEVER report a compile failure as a behavioral red.

## Standing traps

- The ORIGINAL checkout carrieth the audit bundle, which the AUDIT's own process KEEPETH WRITING
  to. `docs/production-readiness/ORIGINAL_CHECKOUT_ADDITIONS.json` declareth it as a GROWING
  addition (the floor may only RISE; a SHRINK is refused). Re-measure the floor and re-capture the
  T01 inventory (`python3 tools/readiness/preserve.py /Users/oculus/Projects/GODSTONE <ev>/T01`)
  whenever the T01 court complaineth.
- A mutation rod over DEAD code can never be killed: delete the dead code and re-anchor the rod on
  a LIVE guard.
- An arm that asserteth merely `assertRaises(ValueError)` is satisfied by an UNRELATED refusal:
  assert the REASON by name.
- Host harnesses: `android/core` carrieth the REAL bundled AndroidX SQLite driver; the Swift
  package `ios/Packages/GodstoneFoundation` is GENERATED (`scripts/sync_ios_foundation_package.py`).
