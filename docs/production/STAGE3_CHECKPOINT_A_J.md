# Stage 3 durability — checkpoint report (Phases A–J)

Branch `remediation/stage-3-durability`, created from the frozen Stage-2 tip
`b7bac64341c1214e05d0436fcb29c5b671d710e9` (not rewritten, not force-pushed).
Main baseline `b7daf5aceb642277807e9bfbe3bbb486112a64ec`. The pushed GitHub
repository is authoritative. This checkpoint covers Phases A–J; Phases K (A-06
independent Noise vectors) and L (A-01 BLE/device) are explicitly **out of
checkpoint** and listed below as remaining work.

Test/evidence counts cited are repo-owned and CI-executed (not stale Stage 0/2
bundle logs). The verdict is unchanged.

---

1. **Verdict: PARTIALLY REMEDIATED — NOT READY.** `FINDINGS_STATUS.json.verdict`
   stays `PARTIALLY_REMEDIATED_NOT_READY`. No repo-controlled Critical/material-High
   finding is claimed closed; none of the 11 open repository Critical/High items
   (item 16) is contradicted by a missing executable evidence path.

2. **Branch + clean-commit provenance (Phase A, `f9a9e61`..`a390c57`).**
   Verification evidence is bound to clean commits: iOS foundation mirror drift
   fixed + release-build scheme (`fffcc64`), build artifacts excluded from the
   iOS foundation manifest (`b74ed7d`), content archive-manifest crypto pinned
   (`e2afc35`), xcodegen installed on the iOS runner (`9e01887`), GodstoneMeshTests
   executed via xcodebuild (`d97763a`), Android Oracle ViewModel runtime tests run
   in CI (`a390c57`). Provenance (`ci/provenance.py`) bounds every job to a clean
   checkout and a clean final tree.

3. **Stale evidence reconciled (Phase B, `1774c4b`).** `VERIFICATION_MATRIX.md`,
   `PLATFORM_VERIFICATION_MATRIX.md`, `FINAL_STATUS.md`,
   `PRODUCTION_READINESS_REPORT.md`, `RELEASE_MANIFEST.json`,
   `patches/MANIFEST.md` now derive from the committed branch state, not stale
   bundle logs. Machine-readable `FINDINGS_STATUS.json` emitted.

4. **GMP/2.1 semantic fixes — byte-identical cross-platform (Phase C,
   `b62e143`..`0758c4c`).** `msg_id = BLAKE2s-128(sender ‖ created_at_le ‖
   payload)` canonical bytes enforced on Android (`b62e143`) and iOS (`d562358`);
   Bloom anti-entropy byte-identical (`453fec4`); PoW cross-platform conformance
   (`2386429`) with deterministic binding assertions (`0758c4c`). `check_parity`
   Invariants A/B/C green repo-scope.

5. **Tier invariant — LIGHT-only shipping (Phase D, `1cc1a6c`).** Research tiers
   (MEDIUM/LARGE) are source-level only; only LIGHT is `shipping: true`.
   `check_tiers.py` / `check_parity` Invariant E green. Fixes the root cause
   instead of tolerating a red Invariant E.

6. **Android durable store — bounded capacity + real SQLCipher (Phase E,
   `049ba3c`; A-10, GST-DATA-001/002/003).** Bounded-capacity durable store with
   real SQLCipher (not a mock) tests. A-10 → NONSHIPPING_TESTED (repo evidence;
   on-device encryption pending). NOT closed.

7. **Coordinated resumable panic wipe — both platforms (Phase F, `2027c9a` +
   `7de1f66`; GST-WIPE-001).** Resumable, crash-safe panic wipe on both platforms;
   GodstoneMeshTests count guard made non-brittle (≥50 floor). GST-WIPE-001 →
   NONSHIPPING_TESTED (repo evidence; on-device wipe pending). NOT closed. CI
   green.

8. **iOS durable DTN store (Phase G, `657247b`; ADR-004, A-04).** SQLite3 durable
   DTN store, byte-identical StoreSchema, criterion-6 digest. ADR-004 design
   updated first. CI green. A-04 advances (iOS store repo evidence) but stays
   OPEN (on-device store + Android↔iOS byte-identity on device pending).

9. **Authenticated ACK delivery state machine (Phase H, `410ef2b`; ADR-005,
   A-03).** Durable recipient-authenticated delivery (UNAVAILABLE |
   QUEUED_DURABLY → HANDED_TO_RELAY → ACKNOWLEDGED_BY_RECIPIENT, \→ EXPIRED |
   CANCELLED_LOCALLY), truth-table + idempotent terminal semantics; Ed25519 ACK
   binds msgId AND recipientNodeId. Repo-tested both platforms: Android :mesh=92,
   iOS swift=94, xcodebuild GodstoneMeshTests=81. A-03 → NONSHIPPING_TESTED, NOT
   closed (radio disabled; on-device delivery + production RecipientKeyResolver
   pending). CI green.

10. **Archive-only Android release — `:llm` out of the LIGHT graph (Phase I,
    `1c64648` + fixup `e695236`; A-17).** `:app` links ONLY `:core`; `:llm`
    non-shipping like `:mesh` (`testImplementation` only, so `OracleViewModelTest`
    still compiles). `ArchiveRepository` moved `:llm`→`:core`; Oracle UI dormant;
    OracleViewModel demoted to test source. Config-aware `check_shipping_path.py`
    forbids a shipping `:llm`/`:mesh` edge; `inspect_android_artifacts.py` rejects
    `.gguf`/`libgodstone_llm`/`libllama`/cross-tier. Fixup followed the
    Oracle-private-draft tripwire to the new path and fixed a Kotlin nested-KDoc
    `/**` comment bug. A-17 → NONSHIPPING_TESTED, NOT closed (real APK/AAB build
    = Phase J/device). CI green.

11. **CI tells the truth (Phase J, `aff8be3`; GST-CI-001).** repository-verification
    EXECUTES on every push and is GREEN. The release-gates workflow fails CLOSED
    for the **verified truthful** reason on each external gate (a red
    release-gates job is the truthful state, not a bug): noise-conformance now
    fails on Invariant D (A-06), after a `build_archive` step stopped it dying
    spuriously on Invariant C; production-corpus now runs `fetch_models.sh`
    (exec-bit fixed) and fails closed with exit 1 on UNPINNED (a bash `var=$(cmd)`
    gotcha previously swallowed the SystemExit into a false-green exit 0);
    android-release fails at `:llm` cmake `add_subdirectory(third_party/llama.cpp)`
    (native stack not restored — already truthful). GST-CI-001 →
    REPOSITORY_GATE_CLOSED_EXTERNAL_CONTENT_OPEN, NOT closed.

12. **repository-verification CI — GREEN.** Latest run `31359755820` (head
    `aff8be3`), all 6 jobs success: constraint audit (C1/C2 + tiers +
    release-gate status); invariants A,B,C,E,F,G,H; content pipeline (LIGHT
    archive, no model); mesh simulation; android `:core:assembleDebug`,
    `:mesh:testDebugUnitTest`, `:llm:testDebugUnitTest`, `:app:compileLightDebugKotlin`,
    `:app:testLightDebugUnitTest --tests '*OracleViewModelTest*'`; ios sync --check,
    swift test, xcodegen, xcodebuild Godstone-Light build + GodstoneMeshTests
    (≥50 floor).

13. **release-gates CI — fail-closed truthfully.** Latest run `31359755767`,
    all 3 external jobs red for the truthful reason: A-06 Noise = Invariant D;
    production corpus = `fetch_models.sh` exit 1 UNPINNED; Android LIGHT release
    = cmake llama.cpp native stack not restored. No spurious failures, no false
    greens. `check_release_gates_status.py` green (7 release gates represented;
    required external gates OPEN/BLOCKED, not skipped).

14. **ADR-008 criteria 4–6 NOT ticked green.** Per the standing constraint,
    criteria 4 (msg_id), 5 (PoW `HAS_POW`), 6 (bloom) remain `[ ]`: they are
    implemented in the Android `:mesh` runtime but their own executed unit tests
    are not yet cited, and production-path builders on both platforms have not
    executed them. Criteria 1–3 are green by execution; 8 is blocked on the
    provisioned build.

15. **No finding falsely closed.** `FINDINGS_STATUS.json.open_repository_critical_or_high`
    still lists 11 items; every advanced finding (A-03, A-10, A-17, GST-DATA-002/003,
    GST-WIPE-001, GST-CI-001) carries explicit "NOT closed" rationale + the
    pending external/device evidence. The findings register contains no
    contradictory OPEN_REPOSITORY Critical/High item without executable evidence.

16. **Open repository Critical/High findings (unchanged set).** A-01 (Critical,
    Phase C+L); A-03 (Phase H); A-04 (Critical, Phase F+G); A-10 (Phase E);
    A-17 (Phase I repo done; J/device artifact build); GST-DATA-001 (Critical,
    Phase E+G); GST-DATA-002 (Phase E); GST-DATA-003 (Phase E); GST-WIPE-001
    (Phase F); GST-CI-001 (Phase J repo truthfulness verified; external green
    pending model/native/A-06 pin); GST-WORKBOOK-001.

17. **Findings advanced to NONSHIPPING_TESTED / gate-closed but NOT closed.**
    A-03 (ACK — radio/on-device + RecipientKeyResolver pending); A-10 (durable
    store — on-device encryption pending); A-17 (Archive-only release — real
    APK/AAB binary inspection pending Phase J/device); GST-DATA-002/003 (on-device
    store pending); GST-WIPE-001 (on-device wipe pending); GST-CI-001 (green
    release jobs pending external pin). Each is repo-evidenced but awaits
    external/device/pinning verification.

18. **Out of checkpoint — Phase K: A-06 independent Noise vectors
    (GST-CRYPTO-001).** `crypto/cacophony_vectors.json` holds no approved
    EXTERNAL Noise fixture; Invariant D is fail-closed (`--scope all` red). Phase
    K pins + reviews an independent vector file consumed by both platform tests.
    Not attempted in this checkpoint.

19. **Out of checkpoint — Phase L: A-01 BLE/device (+ A-02, A-04 device,
    GST-DATA-001 device).** A-01 stays OPEN_REPOSITORY (a clean shipping path is
    not GMP/2.1 canonical-frame evidence); BLE record-layer + on-device canonical
    frame evidence is Phase L. A-02 (disabled), A-04 (on-device store), and
    GST-DATA-001 (on-device) also await device work. Not attempted in this
    checkpoint.

20. **What remains before READY (external / device / pinning gates).** Pin the
    model lock to PINNED with verified checksums (`fetch_models.sh`); restore the
    pinned llama.cpp native stack so `assembleLightRelease`/`bundleLightRelease`
    succeed and `inspect_android_artifacts.py` runs against a real artifact;
    pin the approved independent Noise fixture (Phase K / A-06); on-device
    interop, accessibility, battery/thermal, and signing evidence; external
    approvals (store/legal/privacy). These are fail-closed release gates, not
    repo-owned greens — turning them green requires external input, not further
    repo work on this branch.

---

**Checkpoint conclusion.** Phases A–J are complete and CI-verified
(repository-verification green; release-gates fail-closed truthfully). The repo
tells the truth about its own state. The verdict remains PARTIALLY REMEDIATED —
NOT READY: closure of the open Critical/High findings requires the
external/device/pinning gates in items 18–20, which are out of this checkpoint.