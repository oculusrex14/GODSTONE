# Candidate status — AUDIT-003-R1, COMPUTED at round 122 (every figure re-derived from the ledger)

**BOTH CANDIDATES REMAIN NO-GO.** The readiness flags are FALSE and enforced false by a passing canonical
control; THE FIVE EXTERNAL GATES REMAIN OPEN OR BLOCKED; NO finding carrieth `closure_evidence`.

## LIGHT Archive — the shared scope (the audit's 'Both')

**14 findings** — FIX_SUBMITTED 13, PARTIAL 1

* ACCEPTANCE BOUNDARY: final approved lexical content, trust/signing, applicable Archive device/accessibility/security evidence, green canonical controls, and actual release artifacts PROVING Mesh/LabMesh/Oracle/inference-native/model ABSENCE in the shipping graph.
* Still unfinished (1): GS-ARCHIVE-005
* Awaiting EXTERNAL or device/hosted input (14): GS-ARCHIVE-001, GS-ARCHIVE-002, GS-ARCHIVE-003, GS-ARCHIVE-004, GS-ARCHIVE-005, GS-CONTENT-001, GS-CONTENT-002, GS-CONTENT-003, GS-CTRL-001, GS-CTRL-002, GS-GATE-001, GS-PACKAGE-001, GS-PACKAGE-002, GS-SUPPLY-001
* Carrying COMPUTED-stale closure evidence (5) — a production owner changed since the audited SHA:
  GS-ARCHIVE-001, GS-ARCHIVE-002, GS-ARCHIVE-003, GS-ARCHIVE-004, GS-ARCHIVE-005
* LIGHT needeth none of the excluded runtime work once its own gates pass and EXCLUSION IS PROVED — but it may not skip a mandatory repository lane, and any new shared dependency makes an expanded-scope defect relevant to it.

## Mesh/Oracle — the additional scope

**40 findings** — FIX_SUBMITTED 14, OPEN 23, PARTIAL 3

* ACCEPTANCE BOUNDARY: the expanded store/crypto/transport/runtime/lab/model work, plus revalidation of affected shared repairs, and applicable independent protocol/native/device/interoperability/resource/signing evidence.
* Still unfinished (26): ANDROID-01, ANDROID-03, ANDROID-04, ANDROID-05, ANDROID-06, ANDROID-07, CRYPTO-001, CRYPTO-002, CRYPTO-005, GS-INBOX-001, GS-INTEGRATION-001, GS-LAB-001, GS-RUNTIME-001, GS-SOS-001, GS-STORE-002, GS-STORE-004, GS-STORE-005, GS-STORE-006, GS-STRESS-001, GS-UX-001, IOS-01, IOS-02, IOS-04, IOS-05, IOS-06, IOS-07
* Awaiting EXTERNAL or device/hosted input (17): ANDROID-02, ANDROID-04, ANDROID-05, CRYPTO-003, CRYPTO-004, CRYPTO-006, GS-ACK-001, GS-ACK-002, GS-DIAG-001, GS-MODEL-001, GS-SOS-002, GS-STORE-001, GS-STORE-002, GS-STORE-003, GS-SYNC-001, GS-SYNC-002, IOS-03
* Carrying COMPUTED-stale closure evidence (26) — a production owner changed since the audited SHA:
  ANDROID-01, ANDROID-02, ANDROID-03, ANDROID-04, ANDROID-06, ANDROID-07, GS-DIAG-001, GS-MODEL-001, GS-RUNTIME-001, GS-SOS-001, GS-SOS-002, GS-STORE-001, GS-STORE-002, GS-STORE-003, GS-STORE-004, GS-STORE-005, GS-STORE-006, GS-SYNC-001, GS-SYNC-002, IOS-01, IOS-02, IOS-03, IOS-04, IOS-05, IOS-06, IOS-07
* These 40 concern NONSHIPPING code and future acceptance; they are not claims of deployed physical-radio failures, and LIGHT does not wait on them.

## What NEITHER candidate can obtain from this work

* **No hosted lane existeth here** — no run URL, run id or hosted log for any lane — so **T78 final convergence has NOT run for either candidate**, and a local bundle cannot supersede that.
* **No device, emulator, simulator, radio, native-inference or signing operation was performed by this work.** Every result here is a LOCAL host reproduction, and no fixture or simulated counter was relabelled as a device or runtime result.
* **No human content approval is claimed**: every digest and coverage count the fixtures install is SYNTHETIC and closeth APPROVED_CONTENT for nothing.
* **Closure evidence is stale by construction wherever an owner changed** — COMPUTED, not asserted (see the ledger's `closure_evidence_staleness_COMPUTED_AT_ROUND_120`), and that block also recordeth why a computed verdict is a FLOOR and not a clearance.
* **Only an independent audit may write VERIFIED_FIXED**, and the ledger recordeth ZERO.

## Candidate verification at `03fd92b` (ledger round 178) — measured, per declared scope

| Item | Result at this exact SHA (tree `d4abed5`) |
|---|---|
| Android `:mesh` lane | **1175 tests, 0 failures, 0 errors** (forced re-run: `cleanTest`) |
| iOS lane (mirrored package) | **1198 tests, 0 failures (0 unexpected)**, 155.3s |
| Python readiness suite | **OK** |
| Repository controls | **every `ci/check_*.py` rc 0**; the only non-zero is `check_parity` under its **default** scope = the **external A-06 arm**, and `--scope repo` is rc 0 |
| Control instruments | `local_identity` **38/38**, `trusted_runtime_composition` **55/55**, `ble_link_substrate` **158/158** — all three of the audit's red controls green **and** their batteries run |
| Symbols (GS-CTRL-002's own item) | `ci/symbols.py` rc 0 — 219 Kotlin files, **0 unresolved** |

**Declared scopes, reported separately:** LIGHT Archive **14** findings; Mesh/Oracle **40** findings.

**Not claimed, and why:** **T78 convergence is NOT claimed** — its requirement is that all applicable **hosted** lanes be
enabled, executed and green at this SHA, and **no hosted lane, run URL, run id or log exists here**; the repository-side
half is complete and the missing half is stated rather than papered over. **No finding is `VERIFIED_FIXED`** (only an
independent audit may write that): live counts are **27 FIX_SUBMITTED, 5 PARTIAL, 22 OPEN**. Readiness flags stay
**false** and the five external gates stay **OPEN**. **Closure evidence is stale for 31 findings** whose card files
changed after the audited SHA — a *floor* on any later closure, not a clearance.

## Candidate verification at `4497542` (ledger round 200) — measured, per declared scope

| Item | Result at this exact SHA (tree `8e437d7`) |
|---|---|
| Android `:mesh` lane | **1187 tests, 0 failures, 0 errors** (forced re-run: `cleanTest`) |
| iOS lane (mirrored package) | **1203 tests, 0 failures (0 unexpected)**, 211.1s |
| Python readiness suite | **OK** |
| Repository controls | **every `ci/check_*.py` rc 0**; only `check_parity` under its **default** scope is non-zero = the **external A-06 arm**; `--scope repo` rc 0 |
| Ledger court | **OK** |
| Symbols | `ci/symbols.py` — 0 unresolved |

**Declared scopes, separately:** LIGHT Archive **14**; Mesh/Oracle **40**.

**Since round 178:** GS-CTRL-002's three red controls were **resolved** (ble_link_substrate 33 arms → 0, battery 158/158);
ANDROID-07's **four card steps** landed (186–193, including the retained full NodeID); ANDROID-05's T18, measured drain and
bounded in-flight drain landed (181–184); IOS-05's steps 2, 3 and 5 landed (194–199) with the iOS admission budget and the
behavioural full-NodeID witness; GS-ARCHIVE-005's App-layer blocker was classified as the **NATIVE_MODELS** external
artifact (180).

**Not claimed, and why:** **T78 convergence is NOT claimed** (no hosted lane/run URL/id/log exists here); **no finding is
`VERIFIED_FIXED`** (28 FIX_SUBMITTED / 20 OPEN / 6 PARTIAL); readiness flags **false** and the five external gates
**OPEN**; **closure evidence stale for 31 findings**. **IOS-05 is NOT complete:** steps 2, 3 and 5 are carried, but
**step 1** (the existing `PeerGovernor` itself under the runtime owner with one shared configuration) and **step 4's
separated-penalty witness** remain — this session built a purpose-built `AdmissionBudget` for the ingress rather than
wiring the governor, and that divergence is stated rather than hidden.

## Candidate verification at `1f110b1` (ledger round 222) — measured, per declared scope

| Item | Result at this exact SHA (tree `74b2dd8`) |
|---|---|
| Android `:mesh` lane | **1192 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`) after a first attempt finished in 2 s |
| iOS lane (mirrored package) | **1205 tests, 0 failures (0 unexpected)**, 181.1s |
| Python readiness suite / ledger court | **OK / OK** |
| Repository controls | every `ci/check_*.py` **rc 0**; only `check_parity` under its **default** scope non-zero = the external **A-06** arm; `--scope repo` rc 0 |
| Symbols | `ci/symbols.py` — 0 unresolved |

**A cached green is not evidence:** the first Android attempt returned in **2 s** (task up-to-date), so the lane was re-run
**forced** and the count re-read from the run's XML. The number happened to be identical — but it was not *evidence* until
it was fresh.

**Since round 200:** ANDROID-04's scheduler **proven by a controlled experiment** (210 — a silent peer tripped by time
alone); IOS-05's steps 1–4 landed with a behavioural full-NodeID witness and a durable-trust separation witnessed against
a **real** repository (202–203); IOS-07's owned deadline sweep landed with its own controlled-experiment witness (213);
ANDROID-06's reservations repaired (a slot **taken**, a generation and capacity epoch **captured**, cancellation at the
**writer and the caller**, the bound counting **reserved** records) with its caller-side law then **witnessed
behaviourally** through a named seam (216–221); and the **connection's lease clock made monotonic** at both creation
sites (208).

**Not claimed, and why:** **T78 is NOT claimed** (no hosted lane/run URL/id/log exists here); **no finding is
`VERIFIED_FIXED`** (32 FIX_SUBMITTED / 18 OPEN / 4 PARTIAL); readiness flags **false** and the five external gates
**OPEN**; **closure evidence stale for 31 findings**.

## Candidate verification at `5d75d21` (ledger round 254) — measured, with one REGRESSION recorded

| Item | Result at this exact SHA (tree `1dde121`) |
|---|---|
| Android `:mesh` lane | **1192 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`, 45s) |
| iOS lane (mirrored package) | **1205 tests, 0 failures (0 unexpected)**, 182.0s |
| Python readiness suite / ledger court | **OK / OK** |
| Repository controls | every `ci/check_*.py` **rc 0 EXCEPT `check_parity`, which is rc 1 IN BOTH SCOPES** |
| Symbols | `ci/symbols.py` — **1 unresolved** (221 Kotlin files) |

**A REGRESSION, FOUND AND RECORDED RATHER THAN EXPLAINED AWAY:** `check_parity --scope repo` **was rc 0 at round 222 and is rc 1
now**, so a landing between rounds 223 and 253 caused it. **Invariant F names `BleTransport.kt: conn.relationKeyProvider()`** — the
round-226 edit of ANDROID-03 slice (b) — and `ci/symbols.py` agrees (1 unresolved). **But the compiler disagrees, and the tool
itself says the compiler is the authority:** `BleConnection` carries `internal var relationKeyProvider: () -> RelationKey`
(`BleConnection.kt:120`), and the **whole Android `:mesh` lane (1192 tests, forced) compiles the call cleanly**. The tool's own
report notes *"175 type(s) whose inheritance leaves the project, 8 whose declaration was not read in full — a visible limitation,
and the compiler is the authority."*

**Two resolutions, named:** (a) **avoid the construct** — carry the relation from a source the tool resolves (e.g. the same
`relationGeneration` the writer already uses) so the mandatory control returns to rc 0; or (b) **declare the limitation in
writing** if (a) proves impossible. **The first is preferred, because a mandatory lane must be green, not explained.**

**Not claimed:** T78 (no hosted lane); no finding `VERIFIED_FIXED` (34/16/4); readiness flags **false**; five gates **OPEN**;
**and one mandatory control is non-zero at this SHA, which the next round must either fix or declare.**

## Candidate verification at `38406d0` (ledger round 256) — FULLY GREEN, with the round-254 regression CLOSED

| Item | Result at this exact SHA (tree `96fe578`) |
|---|---|
| Android `:mesh` lane | **1192 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`, 47s) |
| iOS lane (mirrored package) | **1205 tests, 0 failures (0 unexpected)**, 135.1s |
| Python readiness + ledger courts | **OK** |
| Repository controls | **every `ci/check_*.py` rc 0, AND `check_parity --scope repo` rc 0 AGAIN**; the only non-zero is `check_parity` under its **default** scope = the **external A-06** arm |
| Symbols | `ci/symbols.py` — **0 unresolved** (221 Kotlin files) |

**The regression is closed:** the round-254 candidate carried the red (`check_parity --scope repo` rc 1, Invariant F,
`conn.relationKeyProvider`); **this candidate carries the green**, with the construct **avoided** rather than the tool's
limitation declared.

**Not claimed:** T78 (no hosted lane/run URL/id/log); no finding `VERIFIED_FIXED` (34/16/4); readiness flags **false**; five
gates **OPEN**; closure evidence **stale for 31 findings**; and the programme's own debt is named — **31 self-inflicted
corrections recorded across this session's rounds**, each kept beside the repair it accompanied, *because a record that
carries only successes teaches nothing*.

## Candidate verification at `e47e779` (ledger round 275) — FULLY GREEN, INCLUDING BOTH LAB APPLICATION TARGETS

| Item | Result at this exact SHA (tree `a3824ea`) |
|---|---|
| Android `:mesh` lane | **1192 tests, 0 failures, 0 errors** — **forced** (`--rerun-tasks`, 45s) |
| **Android lab application target** | **0 compile errors (forced)**, `labmesh-debug.apk` **15,133,266 bytes** |
| **iOS lab application target** | **`BUILD SUCCEEDED`** (simulator SDK, unsigned, `CODE_SIGNING_ALLOWED=NO`) |
| iOS lane (mirrored package) | **1205 tests, 0 failures (0 unexpected)**, 211.8s |
| Python readiness + ledger courts | **OK** |
| Repository controls | every `ci/check_*.py` **rc 0 — including `check_parity` under its default scope**; `--scope repo` rc 0 |
| Symbols | `ci/symbols.py` — **0 unresolved** (223 Kotlin files, two more than round 256: GS-LAB-001's own lab sources) |

**Since round 256:** GS-LAB-001 carried **four of six steps on real artifacts** — the Android APK whose **merged manifest** carries the
launcher activity, the retained runtime owner, **INTERNET removed** and `BLUETOOTH_SCAN` present; and the iOS `GodstoneLabMesh.app`
with its **own** bundle identity `io.godstone.labmesh` — plus **five lab invariants each proven to judge by a negative case**;
GS-UX-001's step 5 landed the SOS as a **real cancellable hold on a monotonic threshold** with an accessible alternative; the
round-254 mandatory-control regression was **closed**; and ANDROID-01's reconciliation was measured to **three of six arms
reconciled**, with three failures **each described by kind**.

**Not claimed:** **T78** (no hosted lane, run URL, run id or log exists here); **no finding is `VERIFIED_FIXED`** (35 FIX_SUBMITTED /
15 OPEN / 4 PARTIAL); readiness flags **false**; five gates **OPEN**; closure evidence **stale for 31 findings**; and the
hardware-dependent work is explicitly outstanding — **GS-LAB-001's step 6 awaits T73–T75 and IOS-01's behavioural half awaits a real
CoreBluetooth manager. No simulator or fixture result is offered as a device result anywhere in this record.**
