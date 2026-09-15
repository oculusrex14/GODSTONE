# Status accounting — AUDIT-003-R1 (refreshed at round 62)

Derived from `REMEDIATION_STATE.json` programmatically; nothing here is new evidence. It states the
classes the remediation requires, in the audit's own terms, and it is regenerated rather than
hand-edited so that a status cannot be quietly carried forward.

**Ledger at this refresh: 23 `FIX_SUBMITTED`, 2 `PARTIAL`, 0 `RED_WRITTEN`, 29 `OPEN` — and ZERO `VERIFIED_FIXED`.** Only an independent audit may write `VERIFIED_FIXED`, and the ledger court refuseth the word from this work. NO finding in the ledger carries any `closure_evidence`.

## 1. Submitted and awaiting INDEPENDENT verification — 25

| Finding | Status | Wave | Title (truncated) |
|---|---|---|---|
| `ANDROID-02` | FIX_SUBMITTED | 4d.2 | Canonical advertising makes the initiator's HS2 hint lookup fail |
| `CRYPTO-003` | FIX_SUBMITTED | 4b | Destroyed retained controllers and primitive sessions still repo |
| `CRYPTO-004` | FIX_SUBMITTED | 4b | The T35 low-order-DH negative tests exercise an unused helper wh |
| `CRYPTO-006` | FIX_SUBMITTED | 4b | Duplicate journal admission is treated as success for a differen |
| `GS-ACK-002` | FIX_SUBMITTED | 5 | Restart ACK worker uses TTL 4 while immediate recipient ACKs use |
| `GS-ARCHIVE-001` | FIX_SUBMITTED | 2 | Archive runtime accepts usable bytes without the required truste |
| `GS-ARCHIVE-002` | FIX_SUBMITTED | 2 | Android admits malformed archive schema and reports SQL read fai |
| `GS-ARCHIVE-003` | FIX_SUBMITTED | 2 | Android search results cannot open the full document and NoResul |
| `GS-ARCHIVE-004` | FIX_SUBMITTED | 2 | The iOS full-document reader has no scrolling container |
| `GS-CONTENT-001` | FIX_SUBMITTED | 2 | Final chunk approvals are optional in release builds, and the ap |
| `GS-CONTENT-002` | FIX_SUBMITTED | 2 | Archive bytes and their receipts are published separately, produ |
| `GS-CONTENT-003` | FIX_SUBMITTED | 2 | The default release validation/check-only path still accepts a s |
| `GS-CTRL-001` | FIX_SUBMITTED | 1 | Completion validator accepts failed commands, missing logs, and  |
| `GS-CTRL-002` | FIX_SUBMITTED | 1 | Readiness controls already fail on the audited task sequence |
| `GS-DIAG-001` | FIX_SUBMITTED | 8 | Diagnostics retain an unbounded map of historic relation keys |
| `GS-GATE-001` | FIX_SUBMITTED | 1 | Release gate validation can bypass exact-SHA and executor eviden |
| `GS-MODEL-001` | FIX_SUBMITTED | 3b | Runtime model staging and loading can omit all provenance verifi |
| `GS-PACKAGE-001` | FIX_SUBMITTED | 3a | The iOS artifact inspector accepts prohibited signed entitlement |
| `GS-PACKAGE-002` | FIX_SUBMITTED | 3a | The Android artifact inspector validates AAB names but not its n |
| `GS-STORE-001` | FIX_SUBMITTED | 4a | T29 proves a fake SQLCipher classifier, not the actual Android s |
| `GS-STORE-003` | FIX_SUBMITTED | 4a | Actual message-store upgrades still drop durable tables |
| `GS-SUPPLY-001` | FIX_SUBMITTED | 3a | Offline cache restore accepts traversal names and symlink source |
| `IOS-03` | FIX_SUBMITTED | 4d.1 | HS2 hint uses optional advertisement instead of GATT-bound relat |
| `GS-ARCHIVE-005` | PARTIAL | 2 | Archive navigation bypasses selection metadata and persistence h |
| `GS-STORE-002` | PARTIAL | 4a | iOS private stores still use ordinary SQLite without a store DEK |

## 2. A captured red — 25 findings

Every submitted finding carries `my_red_case` with its argv, log path, sha256 and outcome, and no
finding was moved off `OPEN` without one (the ledger court refuseth that). The count is a floor, not a
claim: a red proveth the failure EXISTED, and only an independent audit can call a repair closed.

## 3. Dependent on EXTERNAL artifacts or on a device/hosted lane

Classified mechanically: a submitted finding is listed here when ANY of its `pending_proof` entries names
a device, an external artifact, SQLCipher, the hosted lane, or a radio. The rule is stated so the
classification can be re-derived rather than trusted.

| Finding | What it is waiting for (first matching sentence) |
|---|---|
| `ANDROID-02` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. No real advertisement was scanned and no radio delivered HS2; the whole exchange runs through the transpo |
| `CRYPTO-003` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. Post-destroy PLAINTEXT LEAKAGE and KEY RECOVERY are NOT claimed: the audit itself records that its proof  |
| `CRYPTO-004` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. A hostile sealed frame arriving over a real radio path is not exercised; every result here is a LOCAL hos |
| `CRYPTO-006` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED, and the race is a FIXTURE INTERLEAVING on the host (the loser's first read misses), not observed thread s |
| `GS-ACK-002` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. The TTL-12 return path's reach was NOT exercised over the air or across multiple hops; the repair is prov |
| `GS-ARCHIVE-001` | no emulator or device was used: the harness is the real bundled driver on the HOST |
| `GS-ARCHIVE-002` | no emulator or device was used: the harness is the real bundled driver on the HOST, which is the same engine the shipping APK installeth, but it is no |
| `GS-ARCHIVE-003` | the card's Dynamic Type / TalkBack pass and the Android system-Back binding are NOT done; no emulator or device was used |
| `GS-ARCHIVE-004` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CONTENT-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CONTENT-002` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CONTENT-003` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CTRL-002` | the hosted lane: no hosted run URL/log was available to this work, so every result here is a LOCAL reproduction of the constituent commands; the R1 su |
| `GS-DIAG-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-GATE-001` | the hosted lane: no hosted run URL/log was available, so the hosted convergence the R1 supplement requireth remains pending |
| `GS-MODEL-001` | NO native inference, no model download and no device were used: the arms build synthetic files and a fixture artifact, and the pinned models are an EX |
| `GS-PACKAGE-001` | no signed IPA, no real entitlement blob and no device were used: the arms mock ONLY the codesign OS boundary, and the inspector policy is real source |
| `GS-PACKAGE-002` | no real AAB or release artifact was inspected: the arms build SYNTHETIC containers confined to a TemporaryDirectory, and no device or bundle-toolchain |
| `GS-STORE-001` | no native cipher, no encrypted device store and no real SQLCipher file: the proofs are over REAL FILES' BYTES and the native seam remains a labelled f |
| `GS-STORE-003` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. The Android PRODUCTION road (SQLiteOpenHelper.onUpgrade + DatabaseMigrationExecutor over SQLiteDatabase)  |
| `GS-SUPPLY-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `IOS-03` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED on either isle: no real advertisement was scanned and no radio delivered HS2. |
| `GS-ARCHIVE-005` | no simulator or device run: the scene courts are HOST tests, and the card's closure requireth an interaction test |

The five external requests themselves — `A06` independent review, `T79` independent fixtures, `T80`
approved content, `T81` native/model artifacts, `T76` signing inputs, plus `T73`–`T75` hardware — are in
`EXTERNAL_INPUT_REQUESTS.md`: exact requests, named owners, immutable acceptance requirements. **ACQUISITION CLOSES NOTHING**, no gate has moved for any artifact, and every blocker still carries `closure_evidence` = NONE.

## 4. Closure evidence STALE because a production owner changed — 25 findings

The audit's per-finding review records source identity at the audited SHA with the classification
`SOURCE_ANCHORS_IDENTICAL_NO_RUNTIME_RETEST` (or `CARRIED_OPEN_CHANGED_SOURCE_REVIEW_NO_FULL_RETEST`). For
every finding this work has TOUCHED, a production owner HAS changed: the anchor files no longer match
HEAD, so that review is STALE BY CONSTRUCTION and nothing in it may be quoted as closure. This is the
audit's own doctrine, not a hedge — source identity never proved the whole caller graph unchanged.

Touched, and therefore stale: `ANDROID-02`, `CRYPTO-003`, `CRYPTO-004`, `CRYPTO-006`, `GS-ACK-002`, `GS-ARCHIVE-001`, `GS-ARCHIVE-002`, `GS-ARCHIVE-003`, `GS-ARCHIVE-004`, `GS-ARCHIVE-005`, `GS-CONTENT-001`, `GS-CONTENT-002`, `GS-CONTENT-003`, `GS-CTRL-001`, `GS-CTRL-002`, `GS-DIAG-001`, `GS-GATE-001`, `GS-MODEL-001`, `GS-PACKAGE-001`, `GS-PACKAGE-002`, `GS-STORE-001`, `GS-STORE-002`, `GS-STORE-003`, `GS-SUPPLY-001`, `IOS-03`.

## 5. What is proven nowhere in this work

- No device, emulator, simulator or radio was used anywhere. Every result is a LOCAL host reproduction,
  and no fixture or simulated counter is ever relabelled as a device or runtime result.
- No hosted lane exists in this environment: there is no CI run URL, run id or hosted log for any of it.
- T78 final convergence is NOT run: it needs ONE clean exact candidate SHA with fresh green canonical AND
  hosted controls, and the hosted controls do not exist here.
- Readiness flags stay FALSE and both declared candidates stay `NO_GO` (LIGHT Archive and Mesh/Oracle).
