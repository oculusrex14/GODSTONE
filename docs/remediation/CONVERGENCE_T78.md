# T78 convergence — THE REPOSITORY-SIDE HALF, at one exact candidate SHA

**Every figure below is RE-DERIVED FROM THE LEDGER** (`docs/remediation/REMEDIATION_STATE.json`) BY A SCRIPT, not copied by hand, so none of it can drift from the record it summariseth.

## 1. T78 IS *NOT* CLAIMED, AND THIS IS THE REASON IN THE REQUIREMENT'S OWN TERMS

T78 requireth that all applicable **hosted** lanes be enabled, executed and green at one clean exact SHA. **No hosted lane, run URL, run id or log existeth here** — no CI service is reachable from this work — so the hosted half is ABSENT, and **the repository-side half is COMPLETE and stated rather than papered over.** Nothing below closeth a gate, and `VERIFIED_FIXED` appeareth nowhere: **only an independent audit may write it.**

## 2. THE CANDIDATE, PER DECLARED SCOPE (reported SEPARATELY, as the audit asketh)

| | |
|---|---|
| **Candidate SHA** (chosen BY COMMIT TIME, see the ledger's numbering-eras note) | `ba033d0555f0` (tree `1b2c0a6c8da3`; worktree clean apart from this record) |
| **Audited SHA** | `c683a2bf0b5b` |
| **Note on later commits** | every commit AFTER that candidate is **documentation, probes or tests only** (no production source), and each says so in its own message; the candidate is the last SHA at which the mandatory lanes were MEASURED, and no later commit claimeth them |
| **LIGHT Archive scope** | **14 findings** — the audit's 'Both' |
| **Mesh/Oracle scope** | **40 findings** |
| **Measured at that SHA** | **android `:mesh` FORCED 1193 tests / 0 failures / 0 errors** and `labmesh-debug.apk` rc 0; iOS foundation `Executed 1218 tests, with 0 failures`; python suite 596 OK; audit probes 12 OK; mandatory lab control PASSED; `check_parity --scope repo` rc 0; `ci/symbols.py` 223 Kotlin files, 0 unresolved; evidence digests 350/350 |
| **NOT claimed at that SHA** | the **iOS lab build** (no lab target changed; *a cached green is not evidence*) |

## 3. THE THREE LISTS THE OBJECTIVE DEMANDETH

### (a) FIX_SUBMITTED — awaiting INDEPENDENT verification (36)

`ANDROID-02`, `ANDROID-04`, `ANDROID-06`, `ANDROID-07`, `CRYPTO-003`, `CRYPTO-004`, `CRYPTO-006`, `GS-ACK-001`, `GS-ACK-002`, `GS-ARCHIVE-001`, `GS-ARCHIVE-002`, `GS-ARCHIVE-003`, `GS-ARCHIVE-004`, `GS-CONTENT-001`, `GS-CONTENT-002`, `GS-CONTENT-003`, `GS-CTRL-001`, `GS-CTRL-002`, `GS-DIAG-001`, `GS-GATE-001`, `GS-LAB-001`, `GS-MODEL-001`, `GS-PACKAGE-001`, `GS-PACKAGE-002`, `GS-SOS-002`, `GS-STORE-001`, `GS-STORE-003`, `GS-SUPPLY-001`, `GS-SYNC-001`, `GS-SYNC-002`, `IOS-01`, `IOS-02`, `IOS-03`, `IOS-04`, `IOS-05`, `IOS-07`

### (b) Findings whose closure DEPENDETH ON EXTERNAL ARTIFACTS

- **A06** — `T73`, `T75`, `T78`, `T79`
- **APPROVED_CONTENT** — `T78`, `T80`
- **HARDWARE** — `T73`, `T74`, `T75`, `T76`, `T78`
- **NATIVE_MODELS** — `T62`, `T63`, `T64`, `T65`, `T78`, `T81`
- **SIGNING** — `T76`, `T78`

**ACQUISITION CLOSES NOTHING**: every one of the five gates is OPEN or BLOCKED, no artifact hath been received, no external party hath been contacted, and **no self-generated fixture may substitute for an approval** — now machine-checkable in `tools/readiness/tests/test_external_input_requests.py`.

### (c) Findings whose CLOSURE EVIDENCE IS STALE because a production owner changed (54 of 54)

Computed at round 205 **from the cards themselves** (unioned with the ledger's references), matched by file name against `git diff --name-only <audited>..HEAD`: **`ANDROID-01`, `ANDROID-02`, `ANDROID-03`, `ANDROID-04`, `ANDROID-05`, `ANDROID-06`, `ANDROID-07`, `CRYPTO-001`, `CRYPTO-002`, `CRYPTO-003`, `CRYPTO-004`, `CRYPTO-005`, `CRYPTO-006`, `GS-ACK-001`, `GS-ACK-002`, `GS-ARCHIVE-001`, `GS-ARCHIVE-002`, `GS-ARCHIVE-003`, `GS-ARCHIVE-004`, `GS-ARCHIVE-005`, `GS-CONTENT-001`, `GS-CONTENT-002`, `GS-CONTENT-003`, `GS-CTRL-001`, `GS-CTRL-002`, `GS-DIAG-001`, `GS-GATE-001`, `GS-INBOX-001`, `GS-INTEGRATION-001`, `GS-LAB-001`, `GS-MODEL-001`, `GS-PACKAGE-001`, `GS-PACKAGE-002`, `GS-RUNTIME-001`, `GS-SOS-001`, `GS-SOS-002`, `GS-STORE-001`, `GS-STORE-002`, `GS-STORE-003`, `GS-STORE-004`, `GS-STORE-005`, `GS-STORE-006`, `GS-STRESS-001`, `GS-SUPPLY-001`, `GS-SYNC-001`, `GS-SYNC-002`, `GS-UX-001`, `IOS-01`, `IOS-02`, `IOS-03`, `IOS-04`, `IOS-05`, `IOS-06`, `IOS-07`**.

**STALENESS IS A FLOOR ON WHAT A LATER CLOSURE COULD CLAIM, NOT A CLEARANCE** — every one of these carrieth evidence bound to a revision a production owner hath changed, so no closure claim for those files can stand until it is re-derived at the converged candidate SHA.

## 4. LIVE COUNTS (my_status)

| status | count |
|---|---|
| FIX_SUBMITTED | 36 |
| OPEN | 14 |
| PARTIAL | 4 |

**Readiness flags: FALSE** (`android LINK_LAYER_READY = false`, `ios linkLayerReady = false`, enforced by `test_blocked_external.py::test_w05`). **The five external gates: OPEN or BLOCKED.** **No finding is `VERIFIED_FIXED`.**
