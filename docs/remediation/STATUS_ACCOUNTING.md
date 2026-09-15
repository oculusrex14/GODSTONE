# Status accounting — AUDIT-003-R1 (counts derived at round 88; narrative carried to round 97)

The COUNTS and the class memberships are re-derived from `REMEDIATION_STATE.json`; the narrative
sections are maintained by hand and say so. Nothing here is new evidence. It states the
classes the remediation requires, in the audit's own terms, and it is regenerated rather than
hand-edited so that a status cannot be quietly carried forward.

**Ledger at this refresh: 27 `FIX_SUBMITTED`, 2 `PARTIAL`, 0 `RED_WRITTEN`, 25 `OPEN` — and ZERO `VERIFIED_FIXED`.** Only an independent audit may write `VERIFIED_FIXED`, and the ledger court refuseth the word from this work. NO finding carries any `closure_evidence`.

AT ROUND 97 the AUDIT-004 limb of `GS-CTRL-001` landed (`bf839fa`) and changed NO status: it is a
deeper limb of an already-submitted finding, so 27 `FIX_SUBMITTED` and 2 `PARTIAL` stand unchanged.
What it changed is MEASURABLE: the independent review's own 10-case probe suite
(`AUDIT_FINAL_2026-09-15/evidence/AUDIT-004/independent_repair_probes_v2.py`), which reported
**8 failures / 2 passes** at ae9905e and at the audit's own pin 33be0b0b, now reporteth
**5 failures / 5 passes** at `bf839fa` — its three GS-CTRL-001 probes pass, and the five that
remain (two for `GS-GATE-001`, one each for `GS-CONTENT-001`, `GS-CONTENT-002` and the
`GS-CONTENT-003` regression) are the next rounds' work, each already a reproduced failing assertion.

The same limb exposed, by making the law stricter rather than looser, that **T05's mutation record
was never evidence**: it carrieth no log, no failure roster, no source identity and no
restored-green companion, so the mutation control it asserted is **NOT ESTABLISHED**. It is now
recorded as an explicit evidence gap (never an exemption, and nothing deleted), and `validate-state`
stayeth green with one new, named note.

AT ROUND 88 the four landings of this session (GS-SOS-002 step 6, GS-ACK-001 step 4, GS-SYNC-002
step 3 on BOTH isles, plus the android lane-flake fix) changed NO status: 27 `FIX_SUBMITTED` and
2 `PARTIAL` stand, no gate moved, and `GS-SYNC-002` is the first finding with a captured red on
BOTH isles for the same law.

## 1. Submitted and awaiting INDEPENDENT verification — 29

| Finding | Status | Wave | Fix commit (first limb) |
|---|---|---|---|
| `ANDROID-02` | FIX_SUBMITTED | 4d.2 | 098fcb2 |
| `CRYPTO-003` | FIX_SUBMITTED | 4b | 565c14a |
| `CRYPTO-004` | FIX_SUBMITTED | 4b | 5c03d069506de0dded390071ec9937d8395a94bc |
| `CRYPTO-006` | FIX_SUBMITTED | 4b | 92104a7 |
| `GS-ACK-001` | FIX_SUBMITTED | 5 | 6f7d08c |
| `GS-ACK-002` | FIX_SUBMITTED | 5 | bae4eba |
| `GS-ARCHIVE-001` | FIX_SUBMITTED | 2 | 719772b |
| `GS-ARCHIVE-002` | FIX_SUBMITTED | 2 | 094cf3f |
| `GS-ARCHIVE-003` | FIX_SUBMITTED | 2 | 28f5e5a |
| `GS-ARCHIVE-004` | FIX_SUBMITTED | 2 | ba0dd69 |
| `GS-ARCHIVE-005` | PARTIAL | 2 | 4857a72 |
| `GS-CONTENT-001` | FIX_SUBMITTED | 2 | d4dbd3a |
| `GS-CONTENT-002` | FIX_SUBMITTED | 2 | bd28128 |
| `GS-CONTENT-003` | FIX_SUBMITTED | 2 | dbbc0b4 |
| `GS-CTRL-001` | FIX_SUBMITTED | 1 | 9d39c36d1804aee294b2227d584686453418fd7b |
| `GS-CTRL-002` | FIX_SUBMITTED | 1 | 50fc81b |
| `GS-DIAG-001` | FIX_SUBMITTED | 8 | PENDING |
| `GS-GATE-001` | FIX_SUBMITTED | 1 | e0e0fae |
| `GS-MODEL-001` | FIX_SUBMITTED | 3b | PENDING |
| `GS-PACKAGE-001` | FIX_SUBMITTED | 3a | PENDING |
| `GS-PACKAGE-002` | FIX_SUBMITTED | 3a | PENDING |
| `GS-SOS-002` | FIX_SUBMITTED | 5 | fc13b30 |
| `GS-STORE-001` | FIX_SUBMITTED | 4a | PENDING |
| `GS-STORE-002` | PARTIAL | 4a | PENDING |
| `GS-STORE-003` | FIX_SUBMITTED | 4a | 98c69c58f8420bdf6c5345278d1804f6ca1596dc |
| `GS-SUPPLY-001` | FIX_SUBMITTED | 3a | PENDING-COMMIT |
| `GS-SYNC-001` | FIX_SUBMITTED | 5 | 5b1ace9 |
| `GS-SYNC-002` | FIX_SUBMITTED | 5 | bbe4ffb |
| `IOS-03` | FIX_SUBMITTED | 4d.1 | 19a4635 |

## 2. A captured red — 29 findings

Every finding moved off `OPEN` carries `my_red_case` with argv, log path, sha256 and outcome; the ledger
court refuseth a submission without one. The count is a floor, not a claim: a red proveth the failure
EXISTED, and only an independent audit can call a repair closed.

## 3. Dependent on EXTERNAL artifacts or on a device/hosted lane — 27

Classified mechanically by a STATED rule: a submitted finding is listed when any of its `pending_proof`
entries names a device, an external artifact, SQLCipher, the hosted lane, or a radio — so the
classification can be re-derived rather than trusted. The five external requests (`A06`, `T79`, `T80`,
`T81`, `T76`, plus the `T73`–`T75` hardware lane) live in `EXTERNAL_INPUT_REQUESTS.md`: exact requests,
named owners, immutable acceptance requirements. **ACQUISITION CLOSES NOTHING**, no gate has moved for
any artifact, and every blocker still carries `closure_evidence` = NONE.

| Finding | What it awaits (first matching sentence) |
|---|---|
| `ANDROID-02` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. No real advertisement was scanned and no radio delivered HS2; the whole exchange runs through t |
| `CRYPTO-003` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. Post-destroy PLAINTEXT LEAKAGE and KEY RECOVERY are NOT claimed: the audit itself records that  |
| `CRYPTO-004` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. A hostile sealed frame arriving over a real radio path is not exercised; every result here is a |
| `CRYPTO-006` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED, and the race is a FIXTURE INTERLEAVING on the host (the loser's first read misses), not observe |
| `GS-ACK-001` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED: the arms drive the real inbox commit and the real restart worker on the host; no peer and no ra |
| `GS-ACK-002` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. The TTL-12 return path's reach was NOT exercised over the air or across multiple hops; the repa |
| `GS-ARCHIVE-001` | no emulator or device was used: the harness is the real bundled driver on the HOST |
| `GS-ARCHIVE-002` | no emulator or device was used: the harness is the real bundled driver on the HOST, which is the same engine the shipping APK installeth, bu |
| `GS-ARCHIVE-003` | the card's Dynamic Type / TalkBack pass and the Android system-Back binding are NOT done; no emulator or device was used |
| `GS-ARCHIVE-004` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-ARCHIVE-005` | no simulator or device run: the scene courts are HOST tests, and the card's closure requireth an interaction test |
| `GS-CONTENT-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CONTENT-002` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CONTENT-003` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CTRL-002` | the hosted lane: no hosted run URL/log was available to this work, so every result here is a LOCAL reproduction of the constituent commands; |
| `GS-DIAG-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-GATE-001` | the hosted lane: no hosted run URL/log was available, so the hosted convergence the R1 supplement requireth remains pending |
| `GS-MODEL-001` | NO native inference, no model download and no device were used: the arms build synthetic files and a fixture artifact, and the pinned models |
| `GS-PACKAGE-001` | no signed IPA, no real entitlement blob and no device were used: the arms mock ONLY the codesign OS boundary, and the inspector policy is re |
| `GS-PACKAGE-002` | no real AAB or release artifact was inspected: the arms build SYNTHETIC containers confined to a TemporaryDirectory, and no device or bundle |
| `GS-SOS-002` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED: the red and every green are HOST courts driving each node's own command door with a synthetic callback that c |
| `GS-STORE-001` | no native cipher, no encrypted device store and no real SQLCipher file: the proofs are over REAL FILES' BYTES and the native seam remains a  |
| `GS-STORE-003` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. The Android PRODUCTION road (SQLiteOpenHelper.onUpgrade + DatabaseMigrationExecutor over SQLite |
| `GS-SUPPLY-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-SYNC-001` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED: both arms drive the owner's real control-frame entry on the host with canonical frames; no peer |
| `GS-SYNC-002` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED: the differential is a host court driving each node's own entries with canonical control frames; |
| `IOS-03` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED on either isle: no real advertisement was scanned and no radio delivered HS2. |

## 4. Closure evidence STALE because a production owner changed — 29 findings

The audit's per-finding review records source identity at the audited SHA. For every finding this work has
TOUCHED, a production owner HAS changed: the anchor files no longer match HEAD, so that review is STALE BY
CONSTRUCTION and nothing in it may be quoted as closure. This is the audit's own doctrine — source
identity never proved the whole caller graph unchanged.

Touched, and therefore stale: `ANDROID-02`, `CRYPTO-003`, `CRYPTO-004`, `CRYPTO-006`, `GS-ACK-001`, `GS-ACK-002`, `GS-ARCHIVE-001`, `GS-ARCHIVE-002`, `GS-ARCHIVE-003`, `GS-ARCHIVE-004`, `GS-ARCHIVE-005`, `GS-CONTENT-001`, `GS-CONTENT-002`, `GS-CONTENT-003`, `GS-CTRL-001`, `GS-CTRL-002`, `GS-DIAG-001`, `GS-GATE-001`, `GS-MODEL-001`, `GS-PACKAGE-001`, `GS-PACKAGE-002`, `GS-SOS-002`, `GS-STORE-001`, `GS-STORE-002`, `GS-STORE-003`, `GS-SUPPLY-001`, `GS-SYNC-001`, `GS-SYNC-002`, `IOS-03`.

## 5. What is proven nowhere in this work

- No device, emulator, simulator or radio was used anywhere: every result is a LOCAL host reproduction,
  and no fixture or simulated counter is ever relabelled as a device or runtime result.
- No hosted lane exists in this environment: there is no CI run URL, run id or hosted log for any of it.
- T78 final convergence is NOT run: it needs ONE clean exact candidate SHA with fresh green canonical AND
  hosted controls, and the hosted controls do not exist here.
- Readiness flags stay FALSE and both declared candidates stay `NO_GO` (LIGHT Archive and Mesh/Oracle).
- The in-flight dispatch boundary is NOT expressed anywhere: nothing in the current result taxonomy
  distinguishes "an offer is crossing the writer right now, its outcome unknown" from "no offer ever
  crossed", because `SosCancelResult.wasRelayed` means "bytes had ALREADY gone out" and a pre-existing
  mandatory court pins a mid-flight cancellation to `false`. `GS-SOS-002`'s ordered step 3 (serialize cancel
  with offer admission) therefore remains OPEN, and round 85 withdrew both an unred-gated serialization and
  an arm that would have overloaded that boolean rather than leave either claim in the tree unproven.

## 6. The green-lane claim, and the flake that used to weaken it

The android lane's intermittent FIXTURE flake ('no ascending hint pair within 64 draws') is ROOT-CAUSED and
FIXED at round 86. The earlier reading — 65 non-ascending draws being "statistically impossible", therefore
shared RNG state — was WRONG: the fixture in `ReadinessT17Test`/`ReadinessT18Test` redrew `b` ALONE against a
FIXED `a`, so acceptance probability per draw was `(255 - a.hint[0])/256`, not one half; with `a.hint[0] = 254`
it needed the 1/256 case 65 times and failed ~78% of the time. Measured: `a=(254,25,59,239)`, and NINE of
THIRTY filtered runs failing in fixture setup. The two courts now ORDER the drawn pair instead of fishing on
that coin, verified by the same thirty-iteration protocol; the other five courts carry the both-redrawn shape,
whose acceptance probability is ~1/2 and whose 65-draw failure is genuinely impossible.

The limitation this section used to state is therefore retired for THIS flake — 'the lane is green' now means
the logged passing run AND a fixture that cannot fail on a 1/256 coin — while the older caveat still stands
for anything not re-measured: every claim in this document is a LOCAL host reproduction.
