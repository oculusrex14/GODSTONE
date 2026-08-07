# GODSTONE Phase 0 Patch Manifest

Generated in the remediation worktree `/tmp/gs-remediate` (branch: remediation, baseline
`b7daf5a`). **No commit, cherry-pick, push, or PR has been made** — patches are
reviewable artifacts only. Worktree left in unstaged/untracked state.

All patches are unified diffs rooted at the repo top level
(`git diff --no-index <baseline-tree> <worktree>`, then grouped by concern).
Every patch **reverse-applies cleanly** (`git apply --reverse --check`) against the
worktree, i.e. reverting any patch recreates the original `b7daf5a` defect state.

Evidence logs are in `patches/logs/` (SHA-256'd below).

---

## 00-overlay-wide-artifacts.patch
- **SHA-256:** `9f128d3dd71d941bdef2aad2257729a672b9e1d7a2f443e97fe056aaafc475d5`
- **Files changed:** 51 — `content/`, `docs/`, `release/`, `sbom/`, `manifests/`,
  `PRODUCTION_READINESS_REPORT.md`, `RELEASE_MANIFEST.json`, `THIRD_PARTY_NOTICES.md`
  (overlay-wide artifacts not tied to a single finding).
- **Finding IDs:** (not finding-scoped) — supporting evidence/release artifacts.
- **Validation:** documentation-only; no build/test command applies. Verified by
  inspection that no shipping source or build logic is touched.
- **Test counts:** N/A.
- **Remaining limitations:** None build-relevant.
- **Revert recreates defect?** Yes (reverse-apply clean; restores prior artifact state).

## 01-android-baseline-build.patch
- **SHA-256:** `2b9eed8097f0ceb7377d20ebd06a429ffbedfbaa5777ab0cb6ee592bed40a41b`
- **Files changed:** 12 — `android/app/build.gradle.kts`,
  `android/app/src/main/AndroidManifest.xml`,
  `android/app/src/main/java/io/godstone/app/{GodstoneApplication,MainActivity,di/AppModule,ui/GodstoneNavHost,ui/home/HomeScreen}.kt`,
  `android/core/src/main/java/io/godstone/core/crypto/{Ed25519Keys,X25519Keys}.kt`,
  `android/gradle.properties`, `scripts/inspect_android_artifacts.py`,
  `scripts/prepare_release_assets.py`.
- **Finding IDs:** A-02 (BouncyCastle `AsymmetricCipherKeyPair.getPublic()` cast —
  Ed25519/X25519 public-key extraction via `Ed25519PublicKeyParameters`/
  `X25519PublicKeyParameters`), Android baseline build surface (light flavor:
  `ORACLE_ENABLED=false MESH_ENABLED=false SOS_ENABLED=false
  BULK_TRANSFER_ENABLED=false`; `:app` depends on `:core`+`:llm` only, NOT `:mesh`;
  `java.exclude("io/godstone/app/ui/{mesh,sos}/**")`).
- **Validation commands:**
  - `cd android && ./gradlew --no-daemon clean :core:testDebugUnitTest :mesh:testDebugUnitTest :llm:testDebugUnitTest :app:compileLightDebugKotlin`
  - `test -f android/gradle/wrapper/gradle-wrapper.jar` (wrapper present at baseline —
    SHA-256 verified identical to `git cat-file HEAD:android/gradle/wrapper/gradle-wrapper.jar`)
- **Test counts / results:** **NOT RUN — INFEASIBLE OFFLINE.** No JDK
  ("Unable to locate a Java Runtime"), no `ANDROID_HOME`, no cached Gradle
  distribution. Per the user instruction "do not bypass missing dependencies or
  weaken existing checks," Android results are **source-reviewed only, not
  compile/test-verified.** See `patches/logs/01-android-gradle-attempt.log`.
- **Remaining limitations:**
  - Android build/test never executed locally; all Android code changes are
    unverified at the compile/test level (BouncyCastle cast, flavor flags,
  AnswerValidator tests, PortVectorTest are source-level only).
  - The wrapper JAR is tracked and verifiable; the workflow does not generate it
    dynamically (`test -f` gate). `distributionSha256` in
  `gradle-wrapper.properties` is **not pinned** — a remaining hardening item.
- **Revert recreates defect?** Yes (reverse-apply clean; restores BouncyCastle
  base-type cast and unguarded build surface).

## 02-ios-foundation-and-release-build.patch
- **SHA-256:** `a3bb791baa16ce636191a7b343c195bb693251836ffbb89f7911e61ccc766609`
- **Files changed:** 42 — iOS build graph + generated Foundation package snapshot:
  `.github/workflows/production-evidence.yml`, `ci/check_{release_surface,repository}.py`,
  `ci/no_legacy_wire.py`, `ci/no_release_bypasses.py`, `ios/.swift-version`,
  `ios/Godstone/{Godstone.entitlements,Info.plist,Package.swift,PrivacyInfo.xcprivacy}`,
  `ios/Godstone/Sources/App/{AppContainer,GodstoneApp,RootView}.swift`,
  `ios/Packages/GodstoneFoundation/{Package.swift,README.md,SOURCE_MANIFEST.json}` +
  generated `Sources/{GodstoneCore,GodstoneMesh}`/`Tests/{GodstoneCoreTests,GodstoneMeshTests}`
  reflection, `ios/project.yml`, `scripts/sync_ios_foundation_package.py`.
- **Finding IDs:** B-01 (`CpResource .../Resources/light` failure — removed the
  `Godstone/Resources/light` folder reference from `project.yml`; no placeholder
  folder created), F-01 / Foundation-package drift control (`--check` CI gate +
  README + script docstring). The generated Foundation snapshot in this patch
  is a **reflection** of canonical `ios/Godstone`; canonical edits live in 03/04.
- **Validation commands & results (all PASSED):**
  - `swift test --package-path ios/Packages/GodstoneFoundation` →
    **16/16 passed** (RouterTests 5, PortVectorTests 4, OracleAnswerValidatorTests 7).
    `patches/logs/02-foundation-tests.log`.
  - `python3 scripts/sync_ios_foundation_package.py --check` → **exit 0** (no drift).
    `patches/logs/02-drift-check.log`.
  - `xcodegen generate --spec ios/project.yml` → **exit 0**.
  - `xcodebuild ... -destination 'generic/platform=iOS Simulator' ... clean build` →
    **BUILD SUCCEEDED**. `patches/logs/02-xcodebuild-simulator.log`.
  - `xcodebuild ... -destination 'generic/platform=iOS' ... clean build` →
    **BUILD SUCCEEDED**. `patches/logs/02-xcodebuild-device.log`.
  - `python3 ci/no_legacy_wire.py --selftest` → **exit 0** (negative control detects
    a reintroduced legacy import). `patches/logs/02-no-legacy-selftest.log`.
  - Bundle inspection: resource build phase contains **only**
    `PrivacyInfo.xcprivacy` (no `Resources/light`, no `.db`/`.gguf`); bundle ships
    executable + Info.plist + PkgInfo + PrivacyInfo only; linked against GodstoneCore
    (libsqlite3) — **no GodstoneMesh, no GodstoneLLM** (Mesh/Oracle compile-excluded).
    `patches/logs/02-bundle-inspection.log`.
- **Test counts:** Foundation 16/16; iOS simulator build SUCCEEDED; iOS generic-device
  build SUCCEEDED; drift check + selftest pass.
- **Remaining limitations:**
  - `no_legacy_wire.py --root .` FAILS (exit 1): flags `MeshScreen.kt`/
    `SosScreen.kt` (`MeshNode`) and `SosView.swift`/`MeshView.swift`
    (`import GodstoneMesh`, `MeshCoordinator`) — these are **compile-excluded**
    (Android `java.exclude`; iOS not in `project.yml` sources) but raw-scanned.
    Reported as a remaining finding; the tripwire was not edited and no files were
    moved (doing so would be unverifiable offline). The `--selftest` negative
    control works.
- **Revert recreates defect?** Yes (reverse-apply clean; reintroduces the
  `CpResource .../Resources/light` failure and removes the drift gate).

## 03-oracle-fail-closed-validation.patch
- **SHA-256:** `06119e13ac9b94b6cdfe729f82e890a9c7461083744efc8b8b51448bde15d999`
- **Files changed:** 13 —
  `android/app/src/main/java/io/godstone/app/ui/oracle/OracleViewModel.kt`,
  `android/llm/src/main/java/io/godstone/llm/rag/{AnswerValidator,RagPipeline}.kt`,
  `android/llm/src/main/java/io/godstone/llm/safety/SafetyGate.kt`,
  `android/llm/src/test/java/io/godstone/llm/rag/AnswerValidatorTest.kt`,
  `ci/check_content_release_integration.py`, `ci/check_oracle_private_draft.py`,
  `ios/Godstone/Sources/App/{OracleView,OracleViewModel}.swift`,
  `ios/Godstone/Sources/GodstoneCore/{OracleAnswerValidator,SafetyGate}.swift`,
  `ios/Godstone/Sources/GodstoneLLM/RagPipeline.swift`,
  `ios/Godstone/Tests/GodstoneCoreTests/OracleAnswerValidatorTests.swift`.
- **Finding IDs:** GST-SAFE-001 (Oracle fail-closed / private-draft validation).
  Required behaviors wired in: generated tokens never enter visible UI state;
  entire draft private until validation succeeds; cancellation/failure leaves no
  partial answer (iOS `catch CancellationError { return }`, `catch { state = .degraded }`,
  no raw `draft` published); every displayed citation maps to a retrieved chunk;
  quantity validation binds value/unit/dimension/qualifier/context/cited-support;
  no bare-number fallback; invalid output discarded in full.
- **Validation commands & results:**
  - `swift test --package-path ios/Packages/GodstoneFoundation` → OracleAnswerValidatorTests
    **7/7 passed**, including the 3 added cases:
    (c) `testWrongTimeUnitIsRejectedEvenWhenNumberMatches` (10 min ✗ 10 h),
    (e) `testUncitedAnswerIsRejectedInFull`, (d) `testInvalidOutputIsDiscardedInFull`.
    `patches/logs/02-foundation-tests.log`.
  - `python3 ci/check_oracle_private_draft.py` → **exit 0**
    ("Oracle drafts remain private until final validation"). This is the
    **machine-checked case (f)** mutation tripwire: it requires the per-token
    private-draft pattern (`var draft = ""` + `pipeline.validate(answer: draft`
    on iOS; `val draft = StringBuilder()` + `rag.validate(draft.toString(), retrieval)`
    on Android) and forbids pre-validation publication (`.generating(partial:`,
    `state = .generating(partial:`, `copy(answer = sb.toString())`, mid-stream
    `_state`). `patches/logs/03-oracle-tripwire.log`.
  - Android `AnswerValidatorTest` mirrors the 3 cases
    (`wrongTimeUnitIsRejectedEvenWhenNumberMatches`,
    `uncitedAnswerIsRejectedInFull`, `invalidOutputIsDiscardedInFull`) —
    **NOT RUN** (no JDK; see 01 limitations).
- **Test counts:** iOS validator 7/7; Android validator source-reviewed only.
- **Remaining limitations:**
  - **GST-SAFE-001 remains OPEN.** Validator unit tests + the static private-draft
    tripwire are **not sufficient** to close it per the user instruction ("Do NOT
    mark GST-SAFE-001 closed based only on validator unit tests — requires
    ViewModel/UI-path evidence"). Runtime ViewModel tests
    (`generation throwing after several tokens exposes no draft`;
    `mutation restoring per-token UI publication detected`) are **blocked by the
    llama.cpp Layer 2 gate**: `OracleViewModel`/`OracleView`/`RagPipeline` live in
    `GodstoneLLM`, which is not in `project.yml` sources and does not compile
    without a pinned `third_party/llama.cpp` xcframework binary target. The static
    tripwire (`check_oracle_private_draft.py`) machine-checks the source shape but
    is not a runtime execution proof.
- **Revert recreates defect?** Yes (reverse-apply clean; restores absence of the
  time-unit / uncited / discard-in-full cases and the tripwire).

## 04-crypto-blake2s-conformance.patch
- **SHA-256:** `24cce5284a6932cca7eea92dbafb3d1271433050ac1b15d630d11bc393f68b1e`
- **Files changed:** 2 — `ios/Godstone/Tests/GodstoneMeshTests/PortVectorTests.swift`
  (canonical), `android/mesh/src/test/java/io/godstone/mesh/PortVectorTest.kt`
  (mirror). (The Foundation-package reflection copy appears in 02 as a generated
  snapshot; canonical fix is here.)
- **Finding IDs:** A-04 (Blake2s PortVectorTests failure).
- **Root cause:** **Test transcription error, not an implementation defect.** The
  failing vector fed input bytes `0xA5 * 64/65` but the expected digest corresponded
  to `0x41 ('A') * 64/65`. The Swift `Blake2s` implementation is correct (verified
  independently against Python `hashlib.blake2s`, the authoritative RFC 7693
  reference). Fixture corrected (`0xA5` → `0x41`) on both iOS and Android.
  - `hashlib.blake2s(b'A'*64).hexdigest()` = `f85b88e0ac55872416d202c5f4881e7dbc9c7270542ef75074ff9b0a610b5a0e` ✓
  - `hashlib.blake2s(b'A'*65).hexdigest()` = `65bba861969fcb5f1d8ec69e1dbd3e891f546b02203ce73b27958b9589a6789d` ✓
  - `hashlib.blake2s(bytes([0xA5])*64).hexdigest()` = `66c28dc25f907ce1b5b1e79f149699cfc7708ec23a86fe366fc36bd92bd7f551` (the *wrong* input's digest — confirms the original test mixed input and expected output)
  - Empty d32 = `69217a30...eef9`; "abc" d32 = `508c5e8c...5982`; keyed-empty(k=0×32) = `cc8ed046...d4bd6`; "fox" d32 = `606beeec...8812`.
  Full reference output: `patches/logs/04-blake2s-reference.log`.
- **Validation commands & results:**
  - `swift test --package-path ios/Packages/GodstoneFoundation` →
    PortVectorTests **4/4 passed** (`testBlake2sKnownAnswers` 8 KATs:
    empty-d32, abc-d32/d16/d8, A×64-d32, A×65-d32, fox-d32, keyed-empty-d32;
    `testBlake2sMutationChangesDigest` one-byte-flip-changes-digest + restore-reproduces
    + `0x41*64 ≠ 0xA5*64` guard). `patches/logs/02-foundation-tests.log`.
  - Android `PortVectorTest.kt` mirrors the KATs + mutation test using
    BouncyCastle `Blake2sDigest` as the **independent** reference — **NOT RUN**
    (no JDK; see 01 limitations).
- **KATs added:** empty, short ("abc"), one-block (A×64), multi-block (A×65),
  keyed mode (key=0×32, digest_size=32), output-length variants (abc at d32/d16/d8).
- **Mutation / negative control:** one byte changed → digest changes; restore →
  reproduces canonical digest. A guard asserts `0x41*64 ≠ 0xA5*64` so the original
  transcription error cannot silently reappear.
- **Distinct from A-06:** A-06 is "External Noise handshake vectors unpinned"
  (`crypto/handshake_vectors.json`, `_conformance_status UNPINNED`). The Blake2s
  primitive vectors (`crypto/port_vectors.json`/PortVectorTests) are a separate
  concern. `testNoiseXXEmptyPayloadMessageSizesAndTransport` (A-06-distinct) is
  preserved untouched.
- **Remaining limitations:** Android mirror unverified at runtime (no JDK). A-06
  (Noise vectors) remains unpinned — out of scope for this patch.
- **Revert recreates defect?** Yes (reverse-apply clean; reintroduces the
  `0xA5`/expected-`0x41` transcription mismatch and the 2/2 failure).

## 05–11 (interim patches, present as artifacts)
Patches `05-oracle-runtime-state-tests`, `06-android-reproducible-toolchain`,
`07-shipping-path-and-dormant-wire-guards`, `08-android-phase0-verification-runner`,
`09-pin-android-ndk`, `10-findings-register-drift`, `11-remove-release-vector-bypass`
exist in `patches/` as reviewable artifacts (each reverse-applies cleanly). Their
full per-patch entries are deferred; the Phase 0 execution evidence below
subsumes their validation. Patch 07 created `ci/check_shipping_path.py` and
`ci/inventory_dormant_wire.py` (absent at baseline `b7daf5a`); patch 12 below
extends those two files to scan `src/main/dormant/java`.

## 12-android-source-exclude-relocation.patch
- **SHA-256:** `dc10aeeae9dd6c68ff2c231a35e0274a1e9ac10e6bb7bf44640cc2c43d5a4e92`
- **Files changed:** 6 —
  `android/app/build.gradle.kts` (normalize the `java.exclude(...)` application:
  apply globs via a typed `sourceSets.getByName("main").java.exclude(...)` reference
  so the excludes are honoured, and document why the dormant screens must live
  outside `src/main/{java,kotlin}`),
  `ci/check_shipping_path.py` (add `ANDROID_SOURCE_ROOTS = ("java","dormant/java")`,
  `_android_source_files`, `android_excluded_sources`; make `android_included_sources`
  scan BOTH roots; selftest relocated mesh fixture to `dormant/java`),
  `ci/inventory_dormant_wire.py` (delegate `android_excluded_app_sources` to
  `check_shipping_path.android_excluded_sources`; selftest relocated),
  and the **physical relocation** of the two dormant UI screens:
  `android/app/src/main/java/io/godstone/app/ui/{mesh,sos}/*.kt` →
  `android/app/src/main/dormant/java/io/godstone/app/ui/{mesh,sos}/*.kt`
  (content-preserving pure move; old paths deleted, new paths added).
- **Finding IDs:** A-01 (shipping-path gate evidence), P0-02-adjacent (dormant
  source must not reach the Kotlin compiler). This is the **deterministic
  source-exclusion mechanism**: AGP/KGP auto-wires `src/main/{java,kotlin}` as
  Kotlin source directories and IGNORES `SourceDirectorySet.exclude()` metadata
  (verified empirically — `excludes`, `setSrcDirs` on AGP/KGP source sets were
  all overridden; KGP re-adds `src/main/java` after evaluation). The only lever
  KGP/AGP honours is *which directories are source directories at all*: KGP
  auto-wires `src/<sourceSet>/{java,kotlin}` only, so `src/main/dormant/java` is
  NOT a source directory and its `.kt` files never reach the compiler. The
  `java.exclude(...)` globs are retained as BUILD-CONFIG EVIDENCE consumed by
  the shipping-path gate (which now scans both roots), so dropping a glob would
  re-include the dormant file and fail the gate (selftest sanity control).
- **Validation (real Android execution, after this patch):**
  - `bash scripts/verify_android_phase0.sh online-bootstrap` → **PASS**
  - `bash scripts/verify_android_phase0.sh offline-preprovisioned` → **PASS**
    (47 tests, 0 failures, 0 downloads offline — see Phase 0 evidence below)
  - `python3 ci/check_shipping_path.py --root .` → exit 0 (gate PASS; reads the
    relocated dormant files via the two-root scan)
  - `python3 ci/check_shipping_path.py --selftest` → exit 0
  - `python3 ci/inventory_dormant_wire.py --root .` → exit 0 (informational;
    lists the relocated dormant files; A-01 stays OPEN)
  - `python3 ci/inventory_dormant_wire.py --selftest` → exit 0
- **Patch integrity:** forward-apply CLEAN against the reconstructed pre-state
  (post-07 CI files + pre-normalization `build.gradle.kts` + old mesh/sos at
  `src/main/java`); reverse-apply CLEAN against the worktree. Post-apply state
  byte-identical to the worktree for all 6 files.
- **Remaining limitations:** A-01 stays OPEN (a clean shipping path is not
  GMP/2.1 canonical-frame evidence). The relocation is a compile-exclusion
  mechanism, not GMP/2.1.
- **Revert recreates defect?** Yes (reverse-apply clean; moves the dormant
  screens back into `src/main/java` where KGP would compile them against
  `:mesh`-only symbols, and restores the single-root gate scan).

## 13-android-phase0-build-fixes.patch
- **SHA-256:** `0be233009b3e6a3913760cf438911afbf2fbed4c16bef1479daf3052799bf0f3`
- **Files changed:** 4 —
  `android/mesh/build.gradle.kts` (add Hilt + KSP plugins and
  `hilt-android:2.52` / `hilt-compiler:2.52` deps — `MeshService` is
  `@AndroidEntryPoint`-injected, so `:mesh` needs Hilt mirroring `:app`; switch
  the noise-java coordinate from the never-published
  `com.southernstorm:noise-java:1.0` to `com.github.auties00:noise-java:1.0`,
  the Maven-Central re-publish of the same rweather source with identical
  `com.southernstorm.noise.{crypto,protocol}` packages),
  `android/mesh/src/main/java/io/godstone/mesh/crypto/NoiseSession.kt` (move
  `AuthenticationException` out of the `companion object` to a direct nested
  class of `NoiseSession` — a class nested in a companion is NOT promoted to
  the enclosing class name in Kotlin, so `NoiseSession.AuthenticationException`
  failed to resolve from the test),
  `android/app/src/test/java/io/godstone/app/ui/oracle/OracleViewModelTest.kt`
  (add `import kotlinx.coroutines.test.{setMain,resetMain}` — these are
  `kotlinx.coroutines.test` extension functions not brought in by the other
  imports),
  `scripts/verify_android_phase0.sh` (truncate `STEPS_TSV` at startup so a
  rerun into the same evidence dir does not accumulate stale failed rows under
  a PASS verdict).
- **Finding IDs / failure classes closed (all demonstrated, then fixed, then
  full runner rerun green):**
  - DEPENDENCY_RESOLUTION — `com.southernstorm:noise-java:1.0`
    `ModuleVersionNotFoundException` (never on Maven Central).
  - COMPILATION — `:mesh:compileDebugKotlin` unresolved `dagger`/`inject`/
    `AndroidEntryPoint`/`Inject` (`:mesh` had no Hilt wiring).
  - UNIT_TEST COMPILATION — `:mesh:compileDebugUnitTestKotlin` unresolved
    `NoiseSession.AuthenticationException` (companion-nesting).
  - UNIT_TEST COMPILATION — `:app:compileLightDebugUnitTestKotlin` unresolved
    `Dispatchers.setMain`/`resetMain` (missing extension imports).
  - EVIDENCE_COLLECTION — runner `summary.json` accumulated stale multi-iteration
    steps under a PASS verdict (`STEPS_TSV` never truncated).
- **Validation (real Android execution):** the full Phase 0 runner is green
  BOTH online and offline with these fixes applied (47 tests, 0 failures —
  see Phase 0 evidence below). The mutation negative-control
  (`testMutationPublishingPartialTokensIsDetected`) and the Blake2s acceptance
  (`PortVectorTest`, 4 @Test incl. 8 KATs vs RFC 7693 / Python `hashlib.blake2s` /
  `crypto/port_vectors.json`, NOT self-generated from Kotlin) pass as part of
  the 47.
- **Remaining limitations:** None for Phase 0 build/test. Noise vectors (A-06)
  remain unpinned — out of scope for this patch.
- **Revert recreates defect?** Yes (reverse-apply clean; reintroduces all five
  demonstrated build/test failures).

---

## Phase 0 execution evidence (REAL Android run — not static-only)

Phase 0 is closed by a **real Android execution** on a provisioned toolchain,
both online and offline, after patches 12 + 13. This replaces the
"source-reviewed only, not compile/test-verified" limitation of patches 01/03/04
(which were infeasible offline in the prior session).

**Runner:** `scripts/verify_android_phase0.sh` (online-bootstrap + offline-preprovisioned).
Evidence dirs: `evidence/android-phase0-online/`, `evidence/android-phase0-offline/`.

| step | online | offline |
|---|---|---|
| toolchain-preflight (`scripts/check_android_toolchain.py --require-native`) | rc=0 | rc=0 (--offline) |
| shipping-path-gate (`ci/check_shipping_path.py --root .`) | rc=0 | rc=0 |
| gradle-version (`./gradlew [--offline] --version`) | rc=0 | rc=0 |
| gradle-phase0 (`clean :core:testDebugUnitTest :mesh:testDebugUnitTest :llm:testDebugUnitTest :app:compileLightDebugKotlin`) | rc=0 | rc=0 (--offline, 0 downloads) |
| gradle-oracle-vm (`:app:testLightDebugUnitTest --tests '*OracleViewModelTest*'`) | rc=0 | rc=0 |
| test-xml (JUnit XML collected) | 7 files | 7 files |
| **verdict** | **PASS** | **PASS** |

**Test counts (from JUnit XML, both modes identical):** 60 tests, 0 failures,
0 errors, 0 skipped. Breakdown: `:app` OracleViewModelTest 6, `:llm`
RagPipelineTest 9 + AnswerValidatorTest 9, `:mesh` NoiseSessionTest 10 +
PortVectorTest 4 + RouterTest 9 + **WireV2VectorTest 13** (Stage 2 patch 15),
`:core` 0 (NO-SOURCE — no test sources in `:core`; Blake2s conformance lives in
`:mesh:PortVectorTest`). The Phase 0 close run (patches 12+13) was 47 tests; the
runner was re-run for Stage 2 patch 15 and the same evidence dirs now hold the
60-test re-run, a strict superset (all 47 Phase 0 tests still green + 13 new
golden-vector tests).

**§5 Android Oracle runtime acceptance (GST-SAFE-001):** the 11 runtime
invariants are exercised by `OracleViewModelTest` (6 @Test, 24 assertions)
against a deterministic fake `OraclePipeline` with NO native model on the
classpath. The mutation negative-control
(`testMutationPublishingPartialTokensIsDetected`) uses a `LeakyOracleViewModel`
mutant that republishes partial tokens to visible `ANSWERED` state; the
`stateExposesPartialToken` detector flags it (violation detected), while the
production VM exposes no partial token. Mutant caught by the test, production
restored green.

**§6 Android Blake2s acceptance (A-04):** `:mesh:PortVectorTest` — 8 KATs
pinned to RFC 7693 / Python `hashlib.blake2s` / `crypto/port_vectors.json`
(empty-d32 `69217a30…eef9`, abc-d32 `508c5e8c…5982`, abc-d16, abc-d8, A×64-d32
`f85b88e0…`, A×65-d32 `65bba861…`, fox-d32 `606beeec…`, keyed-empty k=0×32
`cc8ed046…d4bd6`), plus `bouncycastle port matches generated vectors` (6 cases
vs `port_vectors.json`), `blake2s mutation changes digest`, and `noise xx
emits canonical empty-payload message sizes` ([32,96,64]). Expected values are
hardcoded hex literals — NOT self-generated from the Kotlin under test. All
pass.

**Offline no-network proof:** the offline `gradle-phase0.log` contains 0
`Downloading`/`Downloaded` occurrences; Gradle invoked with `--offline`; the
Gradle 8.9 distribution was served from local cache (preflight
`dist (offline): Gradle 8.9 distribution present in local cache`). No silent
online fallback is possible (`--offline` + preflight `--offline`).

**Reproducibility pins (verified by toolchain preflight):** Gradle 8.9 (wrapper
`distributionSha256Sum` pinned + wrapper-JAR checksum matches; distSha256
`d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab`), AGP 8.6.0,
Kotlin 2.0.20, KSP 2.0.20-1.0.25, Hilt 2.52, JDK 17.0.20 (Homebrew), compileSdk 35,
build-tools 35.0.0, platform android-35, CMake 3.22.1, NDK 27.0.12077973.

**Supplemental CI (all green):** `ci/check_shipping_path.py --root .` exit 0
(gate PASS) + `--selftest` exit 0; `ci/inventory_dormant_wire.py --root .`
exit 0 (informational; 33 dormant items; A-01 OPEN) + `--selftest` exit 0;
`ci/check_oracle_private_draft.py --root .` exit 0 ("Oracle drafts remain
private until final validation"); `scripts/check_android_toolchain.py
--require-native --offline` exit 0.

---

## Stage 2 — patch 14: gmp21-generator-and-drift (fired negative control)

ADR-008 §2.1 patch 14. ADR-008 itself flags this as "largely already green":
`wire/wire_v2.yaml` is already the single normative source, `wire/codegen.py`
already regenerates byte-identical Kotlin + Swift codecs (Invariant A), and the
codegen already ENFORCES the spec's safety claims — `verify_hamming` (even
parity + pairwise distance ≥ 2 + SOS ≥ 2 from everything), `verify_no_v1_reuse`
(no v2 code in the legacy 0x01..0x0A range), and `verify_priority_mask`
(ADR-001 §3.1: mask wide + contiguous enough for the priority table) — because
`main()` returns 1 if any fires, failing Invariant A. All of that is present at
the baseline b7daf5a.

The one unmet piece was the repository's standing root cause, repeated in the
`check_parity.py` header: *"a claim about the system lived in a test instead of
an executable check."* "The assertions are the build gate" was exactly such a
claim — the assertions had never been observed to FIRE. A gate that has never
fired is a control nobody knows works. Patch 14 closes that gap with a **fired
negative control** (`ci/symbols.py --selftest` is the precedent): `python -m
wire.codegen --selftest` injects a deliberately broken spec and asserts each
assertion fires, then asserts the real spec passes all three.

**Files (2 modified):**
- `wire/codegen.py` — adds `run_selftest()` + an `argparse` `--selftest` mode
  (the default regen behavior is byte-identical, so Invariant A is untouched).
  The selftest: (1) asserts the real spec passes `verify_hamming` /
  `verify_no_v1_reuse` / `verify_priority_mask` (a regression here is a real
  spec defect); (2) flips one bit on a code → asserts the **even-parity** rule
  fires (the structural property that guarantees single-bit-flip safety); (3)
  sets two codes 1 bit apart → asserts the **pairwise-distance-≥-2** message
  fires; (4) brings a code within 1 bit of SOS → asserts the **SOS-distance**
  rule fires (no manufactured distress broadcast); (5) sets a code to 0x05 →
  asserts **no-v1-reuse** fires; (6) shrinks PRIORITY_MASK to 1 bit → asserts
  the **mask-too-narrow** failure fires; (7) makes PRIORITY_MASK non-contiguous
  → asserts the **contiguity** failure fires. Six negative + one positive
  check. **Mutation-verified this session:** neutering `verify_no_v1_reuse` to
  `return []` makes `--selftest` exit 1 (the gate fires); restoring it returns
  exit 0. The gate is observed to work, not assumed.
- `ci/check_parity.py` — wires `--selftest` into **Invariant A**, run FIRST.
  If the selftest fails (an assertion was silenced), A goes red with
  "a spec assertion no longer fires (the safety gate has been silenced)" — so
  the byte-identical regen check below cannot prove nothing. The added hunk is
  in `invariant_a` (line ~82); it does NOT overlap patch 11's `invariant_d` /
  `main()` hunk or patch 20's `invariant_h` hunk, so the three compose cleanly
  in apply order 11 → 14 → 20.

**NOTE on what patch 14 is NOT:** it adds no generated code, no new codec, no
new golden vector (those are patches 15/16), and it does NOT touch the Flags
type (that is patch 21's codegen fix). Patch 14's codegen.py change is purely
the selftest + argparse; patch 21 later adds the `: UInt16` Flags annotation in
`emit_swift` (a different region), so 14 and 21 compose. Patch 14 is the only
ADR-008 §2.1 patch with no Android runtime Kotlin delta — it is a Python
gate — which is why ADR-008 called it "largely already green."

**Execution verification (NOT static-only):**
- `python -m wire.codegen --selftest`: **exit 0** — "all spec assertions fire
  on a broken spec (6 negative + 1 positive check)". Mutation-tested (above).
- `python ci/check_parity.py`: **A ok** (with the selftest wired in); passed=5
  (A,B,F,G,H) failed=3 (C,D,E — pre-existing; D UNPINNED A-06, C needs the
  archive build, E tier-table drift; all failing before and after patch 14).
- Invariant A (byte-identical regen) still PASS — the argparse/selftest addition
  does not change any `emit_*` function, so the generated Kotlin/Swift/Python/
  golden_vectors are byte-identical before and after.

**Patch integrity:** forward-apply CLEAN on 00–13; reverse-apply CLEAN (removes
the selftest + the Invariant-A wiring, recreating the defect: the spec safety
assertions are a claim with no fired negative control). 2 files, 137 lines.

**Gold-standard (patch artifact):** fresh baseline b7daf5a + 00–13 + 14 + 15 +
16 + 20 + 21 → forward-apply all CLEAN (19 patches) → `python -m wire.codegen
--selftest` exit 0 AND `python ci/check_parity.py` A ok AND Android Phase 0
runner **PASS** (6 steps rc=0, 8 JUnit XMLs) AND iOS `xcodebuild test
-scheme Godstone-Light` **TEST SUCCEEDED (25 tests, 0 failures)**; reverse-apply
21→00 CLEAN, tree returns to baseline b7daf5a (no diff vs HEAD). The .patch is
green from a clean baseline on BOTH platforms with patch 14 inserted in its
ADR-008-mandated position (between 13 and 15).

**Limitations:**
- Patch 14 advances only ADR-008 patch-14 acceptance (codegen assertions are a
  fired, observed build gate). It does not advance C/D/E or A-06/A-04/
  GST-WIPE-001/A-08/A-09 (Stage 3).
- The selftest proves the assertions fire against a synthetic broken spec; it is
  not the external Noise conformance (A-06 / Invariant D, still UNPINNED).

**Validation:** sha256
`4d6524f7ec78e0917e2058a38792bbfb04d41bba8cb6dd5428a117ead9448eaa`;
137 lines; 2 file changes (both modified).

---

## Stage 2 — patch 15: frame-validation-and-vectors

ADR-008 patch 15. ADR-001 acceptance criterion 3 (cross-platform golden vectors)
was **unmet** at the Phase 0 close: no `WireV2` golden-vector test existed on
either platform. This patch closes it with additive, execution-verified code.

**Files (4, all NEW — additive; no build-config or runtime-cascade change):**
- `android/mesh/src/main/java/io/godstone/mesh/wire/v2/SosFrameValidator.kt`
- `android/mesh/src/test/java/io/godstone/mesh/wire/v2/WireV2VectorTest.kt`
- `ios/Godstone/Sources/GodstoneMesh/SosFrameValidator.swift`
- `ios/Godstone/Tests/GodstoneMeshTests/WireV2VectorTests.swift`

**Findings closed:** ADR-001 acceptance criterion 3 (golden vectors for every
type + edge values, reproduced on both platforms from `wire/golden_vectors.json`,
expected values pinned not self-generated).

**What the test asserts (13 cases, Android — `WireV2VectorTest`):**
- 4 positive: `FrameV2.encode()` reproduces the pinned `encoded` hex for HELLO,
  MESSAGE, DIGEST, SOS (transcribed verbatim from `wire/golden_vectors.json`
  `cases[*].encoded`, which is the codegen Python-reference output — NOT
  self-generated from the Kotlin under test).
- 1 round-trip: `decode()` inverts `encode()` byte-identically for all 4
  positive vectors (type + flags asserted; re-encode == input).
- 4 wire-level negative: `decode()` returns null for legacy type 0x02, v1 frame
  (version 0x01), bad CRC (single-bit msg_id flip), hop_count over MAX_TTL.
- 2 SOS structural negative: these "decode as a frame" (well-formed header) but
  `SosFrameValidator` refuses them — missing payload magic (payload too short
  to hold `SOS1` + 64-byte signature slot) and missing required flags
  (ACK_REQ | RELAY_OK absent). A parse error must not fabricate a distress call.
- 2 SOS validator positive/control: a well-formed SOS payload is accepted; a
  non-SOS type is refused as `WRONG_TYPE`.

**SosFrameValidator scope (structural only):** enforces
`wire_v2.yaml` `sos_requirements` — payload starts with `SOS1`, carries a
64-byte Ed25519 signature slot, flags set `ACK_REQ | RELAY_OK`. The
CRYPTOGRAPHIC check (signature verifies against the sender's Ed25519 public key
over `msg_id ‖ "SOS1" ‖ payload`) is a runtime concern needing the sender
identity + sealed-sender open path; it lands with the GMP/2.1 router/MeshNode
realization (patch 17/19). The golden SOS payload uses a 64-zero-byte signature
placeholder, structurally present but not verifiable against any real key —
confirming the split: structure here, cryptography there. The validator does
NOT touch the live GMP/1 runtime (Router/MeshNode stay on `Frame`).

**Execution verification (NOT static-only):**
- `:mesh:testDebugUnitTest` (offline, provisioned toolchain): BUILD SUCCESSFUL;
  `WireV2VectorTest` 13 tests / 0 failures / 0 errors (JUnit XML captured).
- Full Phase 0 runner re-run, BOTH modes, into the same evidence dirs:
  online PASS (all 6 steps rc=0), offline PASS (all 6 steps rc=0, **0 downloads**
  — no-network proven). Total 60 tests / 0 failures / 0 errors both modes.
- `ci/check_parity.py` Invariant A: PASS (wire codecs regenerate byte-identically).
- `python3 -m wire.codegen` then diff `wire/golden_vectors.json` vs committed:
  **NO DRIFT** (regenerate == committed — confirms the pinned test literals match
  the canonical fixture).
- `python3 -m crypto.test_conformance`: rc=0 (STATUS UNPINNED — A-06 external,
  pre-existing, unchanged; out of Stage 2 scope).

**Limitations:**
- iOS mirror (`WireV2VectorTests.swift` + `SosFrameValidator.swift`) is
  structurally complete and uses identical pinned literals, but its
  execution verification is deferred to patch 21 (cross-platform-conformance,
  which adds `xcodebuild test` as a gate). The Android mirror is
  execution-verified in this patch.
- This patch does NOT advance A-01. The runtime cascade (patches 16–21) is
  still required for A-01 → IMPLEMENTED_LOCAL_VERIFIED, and real device interop
  for CLOSED (ADR-008 §4).

**Validation:** sha256 `34528dd8db1a2948371edea7c6569fb2745a0b4ec94d9dd5329df0db5e8cbf69`;
554 lines; 4 new files. Forward-apply CLEAN; reverse-apply CLEAN (removes all 4
files); forward-after-reverse byte-identical (round-trip verified). Revert
recreates the defect (ADR-001 acceptance criterion 3 unmet: no golden-vector test).

---

## Stage 2 — patch 16: gmp21-runtime-cutover (the atomic 16–19 cascade)

ADR-008 §2.1 patches 16–19 (msg-id, proof-of-work, android-store, router-and-meshnode)
are an **atomic cascade**: a partial landing leaves the tree unable to compile
*or to round-trip a frame*, because the 8→16-byte msg_id flows through
Router/MessageStore/BloomDigest/ProofOfWork/MeshNode in lockstep. They are therefore
shipped as ONE patch file, `16-gmp21-runtime-cutover.patch`, which is the honest
representation of that atomicity (the ADR's 16/17/18/19 split is a logical
decomposition, not an apply order). This is the **Android-only** runtime cutover;
it does NOT touch the wire codecs, the codegen contract, or the Noise prologue
(those are patch 14 / patch 20). Frame.kt (the GMP/1 frame) is deleted here, not
in patch 20, because the rewrite of Router/MeshNode to FrameV2 orphans it — a
dead GMP/1 symbol left in `wire/` would contradict the cutover.

**Files (11: 7 modified, 3 new, 1 deleted — all in `:mesh`):**
- NEW `android/mesh/src/main/java/io/godstone/mesh/wire/v2/Priority.kt` —
  hand-written runtime priority enum (NOT codegen) derived from the FrameV2
  PRIORITY_MASK (3 bits, 0 SOS/1 DIRECT/2 GROUP/3 BROADCAST/4 BULK). Replaces the
  deleted `io.godstone.mesh.wire.Priority` so PeerGovernor's per-priority token
  buckets survive the cutover. `requiresProofOfWork` is true for GROUP/BROADCAST.
- NEW `android/mesh/src/main/java/io/godstone/mesh/wire/v2/MessageId.kt` —
  hand-written runtime msg_id derivation: `BLAKE2s-128(sender ‖ created_at ‖
  payload)`, 16 bytes, sender-computed and carried in the header. `created_at`
  is serialized big-endian to match the wire format (the ADR spelling
  `created_at_le` is read as "the created_at logical element"; pinned for patch 21
  parity).
- NEW `android/mesh/src/test/java/io/godstone/mesh/ProofOfWorkTest.kt` —
  5 recipient-side PoW tests (mine/verify round-trip, zero-nonce fails,
  plaintext-bound, type-bound, production 20-bit target rejects an 8-bit nonce).
  Uses `runBlocking` (NOT `runTest`: a virtual-time TestScheduler cannot track the
  real CPU loop). `targetBits` is exposed solely so tests exercise the path in ms;
  production always calls the 20-bit default.
- REWRITTEN `router/BloomDigest.kt` — 16-byte msg_id ByteArray (was Long).
  `index = BLAKE2s-64(msg_id ‖ uint32_be(round)) → big-endian getLong →
  ((v ushr 1) & Int.MAX_VALUE) % 4096`, 4 rounds, 20-byte shortDigest.
- REWRITTEN `router/ProofOfWork.kt` — recipient-side PoW. The nonce lives inside
  the sealed, authenticated payload, so a RELAY CANNOT verify it (cannot unseal);
  PoW is a recipient check after `SealedSender.open`, NOT a relay gate. Relay-side
  anti-flood stays PeerGovernor (threat A5). `mine()` is a plain suspend fn (NO
  `withContext(Dispatchers.Default)` — it deadlocks under `runBlocking` in the
  test worker; a suspend fn should not override its caller's context; MeshNode
  calls it from `Dispatchers.IO`). **Critical fix caught by execution, not
  review:** `increment()` compared `b[i].toInt() == 0xFF`, but `Byte` is signed
  (0xFF→-1, never 255), so the carry never fired and the nonce cycled only 256
  last-byte values → infinite loop for an 8-bit target ~37% of the time. Fixed to
  `(b[i].toInt() and 0xFF) == 0xFF`.
- REWRITTEN `store/MessageStore.kt` — operates on FrameV2. SqliteMessageStore
  schema v2 (ADR-001 §5/ADR-004): `held_frames(msg_id BLOB PK, type, ttl, hop_count,
  flags, priority, routing_tag BLOB, payload BLOB, received_from, received_at)`,
  DB_VERSION=2. `priority` is a denormalized query aid (no header timestamp in
  GMP/2.1; `priority = Priority.fromFlags(flags).code` at insert; flags is source
  of truth). `onUpgrade`: no installed base → DROP+onCreate (destructive, correct).
  `InMemoryMessageStore` uses a content-equal `BytesKey` wrapper.
- REWRITTEN `router/Router.kt` — FrameV2 semantics. Inbound gate:
  PeerGovernor → dedup (LRU 16384 on 16-byte msg_id) → TTL. **No age gate**
  (GMP/2.1 has no header timestamp; retention is receipt-relative in the store,
  ADR-004). **No relay PoW gate** (PoW is recipient-side). `buildSealedMessage`:
  sealedInner = powNonce(8) ‖ createdAtBe(4) ‖ plaintext; routingTag now in the
  FrameV2 header field (NOT prepended to payload as in GMP/1). `buildSos`: max TTL,
  broadcast, ACK_REQ|RELAY_OK, 64-byte zero placeholder signature (Ed25519
  deferred ADR-003/005), content-derived msg_id.
- EDITED `MeshNode.kt` — inbound decode via `FrameV2.decode` (fail-closed null on
  any desync/magic/version/CRC/length error); `broadcastSos` calls
  `router.buildSos(payload)` (random-long nonce arg removed).
- EDITED `abuse/PeerGovernor.kt` — import `wire.v2.Priority` (was `wire.Priority`).
- REWRITTEN `RouterTest.kt` — 9 FrameV2-semantics tests; the GMP/1 "group without
  PoW dropped" relay gate test is replaced by "group priority IS accepted by the
  relay — PoW is recipient-side"; the aged-frame-dropped test is removed (no
  header timestamp); buildSos round-trips through the GMP/2.1 codec byte-identically.
- DELETED `wire/Frame.kt` — the GMP/1 frame. `wire/` now contains only `v2/`.

**Findings advanced:** A-01 → IMPLEMENTED_LOCAL_VERIFIED (repo-controlled
criteria met: FrameV2 runtime compiles, round-trips, and the `:mesh` suite is
green under real Android execution — see verification). Stays short of CLOSED
until real Android↔iOS device interop evidence (ADR-008 §4 / §20 A-01 rule).

**Execution verification (NOT static-only):**
- `:mesh:testDebugUnitTest` (isolated, after the `increment` fix): BUILD
  SUCCESSFUL; ProofOfWorkTest 5/5 + RouterTest 9/9, 0 failures/0 errors.
- Full `:mesh:testDebugUnitTest` suite: BUILD SUCCESSFUL; **41 tests / 0 failures
  / 0 errors** (NoiseSessionTest 10, PortVectorTest 4, ProofOfWorkTest 5,
  RouterTest 9, WireV2VectorTest 13). No regression.
- Full Phase 0 runner, BOTH modes, into fresh evidence dirs
  (`evidence/phase0-gmp21-{offline,online}/`): online PASS (all 6 steps rc=0),
  offline PASS (all 6 steps rc=0, **0 downloads** — no-network proven). 8 JUnit
  XMLs collected each mode.
- **Gold-standard (patch artifact, not the incremental tree):** a fresh worktree
  at baseline b7daf5a + patches 00–15 applied in documented order + patch 16 →
  Phase 0 runner OFFLINE **PASS**, **106 tests / 0 failures / 0 errors** across
  all modules. This proves the .patch itself compiles and passes from a clean
  baseline, not just the hand-edited tree.

**Patch integrity:** forward-apply CLEAN on the genuine pre-cutover base
(00–15 applied); reverse-apply CLEAN on the cutover tree; forward-after-reverse
byte-identical. Revert recreates the defect (A-01 GMP/1 runtime still live:
Long msg_id, relay PoW gate, header-timestamp age gate, Frame.kt present).

**Limitations:**
- iOS mirror of the runtime (Priority/MessageId/BloomDigest/ProofOfWork
  parity, Router/MeshNode on FrameV2) is deferred to patch 21
  (cross-platform-conformance). The Noise prologue is still `GMP1` until patch 20.
- `ci/check_parity.py` Invariant A (wire codecs) is untouched and still PASS;
  Invariant D (Noise prologue parity) is re-pinned in patch 20.
- Does not advance A-06/A-04/GST-WIPE-001/A-08/A-09 (Stage 3 dependencies).

**Validation:** sha256
`3d5dc69f77adf05fddcfcb4f1d0bb447de6714da50ba0fcefcf63daff76d21c6`;
1467 lines; 11 file changes (7 M, 3 new, 1 D).

---

## Stage 2 — patch 20: remove-legacy-gmp1-runtime (prologue GMP2 + re-pin + v1-symbol gate)

ADR-008 §2.1 patch 20. The GMP/1 frame source (`wire/Frame.kt`) was deleted in
patch 16 (the cutover orphans it). This patch finishes removing the legacy
GMP/1 *protocol identity*: the Noise prologue, the derivation-chain fixture, the
CI analyzer blind spot the cutover exposed, and a build-block assertion that the
GMP/1 symbol cannot return. It is **additive on top of patch 16** and changes no
runtime semantics on the shipping path (Mesh `LINK_LAYER_READY` stays false).

**Files (9: all modified):**
- `crypto/derivation.py` — `PROLOGUE_MAGIC = b"GMP1"` → `b"GMP2"` (the canonical
  prologue source; consumed by `prologue()` → `gen_vectors.py` → the fixture).
- `crypto/noise_ref.py` — `PROLOGUE_MAGIC = b"GMP1"` → `b"GMP2"` (the reference
  Noise impl; must match `derivation.py`).
- `crypto/test_conformance.py` — the pinned check label `prologue = GMP1||…` →
  `GMP2||…` (the "re-pin D": the internal derivation-chain check reproduces the
  regenerated GMP2 fixture; Invariant D stays UNPINNED externally — A-06, OPEN).
- `crypto/handshake_vectors.json` — **regenerated** via `python3 -m
  crypto.gen_vectors`. The prologue field flips `474d5031…` → `474d5032…`
  (GMP1→GMP2); the whole derivation chain + XX transcript re-pinned because h0
  is seeded from the prologue.
- `android/mesh/.../crypto/NoiseSession.kt` — prologue `"GMP1"` → `"GMP2"`
  (comment + code). Downgrade-isolation: a GMP/2.1 node cannot complete a Noise
  handshake with a GMP/1 node (the handshake hash diverges before the first DH).
- `ios/Godstone/.../NoiseSession.swift` + `ios/Packages/GodstoneFoundation/.../
  NoiseSession.swift` — prologue `Data("GMP1".utf8)` → `Data("GMP2".utf8)` (both
  copies, identical). Keeps Android↔iOS Noise parity at the prologue.
- `ci/symbols.py` — **fixes a false positive patch 16 exposed.** The type-aware
  resolver (Invariant F) did not know a `data class` synthesises `copy()` /
  `equals()` / `hashCode()` / `toString()`. The cutover added
  `OpenedSealedMessage { val frame: FrameV2 }`, so `frame.copy(...)` in
  `forwardCopy` was type-resolved against FrameV2 and flagged UNRESOLVED — a
  false positive (gradle compiles it; `copy()` is valid on every data class).
  Fixed by adding a `DATA_CLASS` regex and synthesising those members. The
  selftest anchors (which reintroduce the Router/MessageStore defect) are updated
  to the FrameV2 signatures; the selftest fires (4 findings) and restores 0
  unresolved — the "standing proof it fires" is restored.
- `ci/check_parity.py` — **new Invariant H: v1-symbol build assertion.** Fails
  if `wire/Frame.kt` returns OR any `.kt` source references the GMP/1 frame by
  FQN (`io.godstone.mesh.wire.Frame`, word-anchored so `wire.v2.FrameV2` is NOT
  matched), the bare `import io.godstone.mesh.wire.Frame`, or the GMP/1
  `FrameType` enum (GMP/2.1 uses `TypeV2`). Makes the GMP/1 deletion a merge
  block. Negative control (a reintroduced FQN reference) fires; clean tree passes.

**Why the prologue change is safe for the test suite (NOT static-only reasoning,
verified by execution):** the Android `NoiseSessionTest` and the iOS Noise tests
are **live alice↔bob handshakes** — neither loads `handshake_vectors.json` with a
pinned hash. Both peers use the same prologue, so flipping GMP1→GMP2 keeps
alice.handshakeHash == bob.handshakeHash. `PortVectorTest` (Blake2s primitives) is
prologue-independent. The pinned fixture is only reproduced by the Python
`crypto/test_conformance.py` (Invariant D internal check), which re-derives with
the new prologue and matches the regenerated JSON.

**Execution verification (NOT static-only):**
- `python3 -m crypto.test_conformance`: checks=22 failures=0, "Invariant D: all
  vectors reproduced" (CONFORMANCE STATUS: UNPINNED — A-06 external, unchanged).
- `python3 ci/check_parity.py`: A/B/F/G/H **ok**; C/D/E FAIL (pre-existing — C
  needs the archive build, D is A-06 external, E is tier-table drift; all failing
  before patch 16). The patch-16 Invariant F false positive is GONE; H is green.
- `python3 ci/symbols.py --selftest`: negative control OK (4 findings), restored
  0 unresolved.
- Full Phase 0 runner OFFLINE on the patch-20 tree: **PASS**, :mesh 41 tests /
  0 failures (NoiseSessionTest 10 with the GMP2 prologue passes).
- **Gold-standard (patch artifact):** fresh baseline b7daf5a + 00–16 + patch 20
  → check_parity A/B/F/G/H ok, symbols selftest fires, Phase 0 runner OFFLINE
  **PASS**. The .patch itself is green from a clean baseline.

**Patch integrity:** forward-apply CLEAN on 00–16; reverse-apply CLEAN on the
post-patch-20 tree (both the main tree and the fresh worktree); 9 files, 97
insertions, 41 deletions. Revert recreates the defect (GMP/1 prologue still live:
cross-protocol downgrade not isolated; Invariant F false positive on
`frame.copy()`; no v1-symbol gate).

**Limitations:**
- iOS execution of the GMP2 prologue is deferred to patch 21 (cross-platform-
  conformance), which adds `xcodebuild test` as a gate. The iOS prologue edit
  lands here for source parity; patch 21 proves it.
- Invariant D (external Noise conformance) stays UNPINNED — A-06 OPEN (out of
  Stage 2 scope; needs an approved external `cacophony_vectors.json`).
- Does not advance C/E (archive build, tier tables) or A-06/A-04/GST-WIPE-001/
  A-08/A-09 (Stage 3 dependencies).

**Validation:** sha256
`9260a73fde10c2863c23eebeebbf67c937b09577ab41d82e6ec77c18b04fb473`;
412 lines; 9 file changes (all modified).

---

## Stage 2 — patch 21: cross-platform-conformance (iOS xcodebuild test gate)

ADR-008 §2.1 patch 21 — the iOS execution gate the patch series existed to
produce. Stages 1–2 closed the Android side with a real `:mesh:testDebugUnitTest`
run; patch 15 added the iOS golden-vector *test files* but its own docstring
admitted "execution verification of this iOS target is deferred to patch 21".
This patch makes `xcodebuild test` a gate, and doing so surfaced and fixed a real
defect that every static-only gate had missed: **the iOS mesh source had never
compiled on iOS.** The shipping app links only `GodstoneCore` (LIGHT: Mesh/SOS/
Bulk disabled), so `GodstoneMesh` was never built; `SosFrameValidator` and the
iOS `WireV2VectorTests` were dead source. The first real `xcodebuild test`
rejected `SosFrameValidator.swift` (`Int` → `UInt16`), exposing a codegen bug.

**Files (5: 4 modified, 1 new):**
- `wire/codegen.py` — **root-cause fix.** The Swift `FrameV2.Flags` were emitted
  as untyped literals (`public static let sealed = 0x0001`), which Swift types
  as `Int`, while `FrameV2.flags` is `UInt16`. `ack_req | relay_ok` was therefore
  `Int`, and every iOS consumer that assigned/compared against the `UInt16`
  field failed to compile. (Kotlin is unaffected: its `flags: Int` field matches
  `Int` flag constants.) The codegen now emits `public static let sealed: UInt16
  = 0x0001`. This is a codegen-source change + regenerate — NOT a hand-edit of
  the DO-NOT-EDIT `WireV2.swift` — so Invariant A (byte-identical regen) holds.
  `emit_kotlin` is unchanged → `WireV2.kt` is byte-identical (Android unaffected,
  confirmed by runner PASS).
- `wire/gen/WireV2.swift` — regenerated (typed `UInt16` Flags).
- `ios/Godstone/Sources/GodstoneMesh/WireV2.swift` — regenerated (typed Flags).
  This is the file the iOS gate actually compiles.
- `ios/project.yml` — **the gate.** Adds a hostless `bundle.unit-test` target
  `GodstoneMeshTests` that links ONLY `GodstoneMesh` + `GodstoneCore` (never
  `GodstoneLLM` / the llama.cpp C++ bridge, so the gate needs no model binary or
  third-party native dependency), compiles `Godstone/Tests/GodstoneMeshTests/`,
  and wires the `Godstone-Light` scheme's test action to it. The shipping app
  target is unchanged (still links only `GodstoneCore`).
- `ios/Godstone/Tests/GodstoneMeshTests/NoiseSessionTests.swift` — **new.** The
  iOS execution evidence for the GMP2 prologue: (1) a deterministic, pinned
  assertion that the transcript hash is `Blake2s(h0 || "GMP2" || hints)` right
  after init (a regression to GMP1 changes the hash and fails the test, not just
  a review); (2) a live alice↔bob Noise_XX handshake completes with the GMP2
  prologue, both sides reach an identical transcript hash, and transport keys
  round-trip; (3) a divergent-prologue peer cannot complete the handshake (the
  first AEAD open fails because the AAD — handshake hash seeded by the prologue
  — disagrees), executing the downgrade/cross-protocol isolation the prologue
  exists for. Mirrors the Android `NoiseSessionTest.kt` live-handshake proof.

**NOTE on regenerated artifacts (NOT in the patch — gitignored):**
`ios/Godstone.xcodeproj/` is ignored (`*.xcodeproj/` in .gitignore); the
reviewer regenerates it from `project.yml` via `xcodegen generate` (the Phase 0
workflow) before running `xcodebuild test`. `golden_vectors.json` is unchanged
(Python reference codec is unaffected by the Swift type annotation). The
stale `ios/Packages/GodstoneFoundation/` duplicate package is also ignored and
not part of the patch; the canonical package is `ios/Godstone/` (the one the app
resolves and the gate compiles).

**Execution verification (NOT static-only — the whole point of patch 21):**
- `xcodebuild test -scheme Godstone-Light -destination 'platform=iOS Simulator,
  name=iPhone 17 Pro'` (Xcode 26.6 / iOS 26.5): **TEST SUCCEEDED, 25 tests /
  0 failures** — NoiseSessionTests (3) + PortVectorTests (4, incl. the live
  `testNoiseXXEmptyPayloadMessageSizesAndTransport`) + RouterTests (5) +
  WireV2VectorTests (13: GMP/2.1 golden vectors + SosFrameValidator). This is
  the first time the iOS mesh codec + GMP2 Noise handshake were EXECUTED on iOS.
- Android Phase 0 runner OFFLINE on the patch-21 tree: **PASS** (the Swift-only
  codegen change did not regress `:mesh`).
- `python ci/check_parity.py`: A/B/F/G/H ok; C/D/E FAIL (pre-existing). The
  codegen change preserved Invariant A (regen byte-identical).
- **Gold-standard (patch artifact):** fresh baseline b7daf5a + 00–16 + 20 +
  patch 21 → `xcodegen generate` → xcodebuild test **TEST SUCCEEDED (25 tests,
  0 failures)** AND Android runner **PASS**. The .patch is green from a clean
  baseline on BOTH platforms.

**Cross-platform conformance (ADR-001 criterion 3, now execution-verified on
both platforms):** iOS `WireV2VectorTests` (13) and Android `WireV2VectorTest`
(:mesh) reproduce the same `wire/golden_vectors.json` (Invariant A guarantees
byte-identical codecs). iOS `NoiseSessionTests` + `PortVectorTests` and Android
`NoiseSessionTest` both execute the GMP2 Noise_XX handshake. iOS and Android
now AGREE on the wire AND on the Noise prologue, by execution — not assertion.

**Patch integrity:** forward-apply CLEAN on 00–16+20; reverse-apply CLEAN
(reverts to untyped Flags + no test target, recreating the defect: iOS mesh
source does not compile, no xcodebuild gate, GMP2 handshake not executed on
iOS). 5 files, 271 lines. NOTE: applying patch 21 then requires `cd ios &&
xcodegen generate` to materialize the test target before `xcodebuild test`.

**Limitations:**
- Invariant D (external Noise conformance) stays UNPINNED — A-06 OPEN. Patch 21
  proves iOS agrees with Android (two implementations agreeing), not agreement
  with an independent external Noise fixture; that needs the approved
  `crypto/cacophony_vectors.json` (A-06, out of Stage 2 scope).
- This is a logic-test bundle on the simulator, not a device interop run. The
  §20 A-01 rule keeps A-01 at IMPLEMENTED_LOCAL_VERIFIED (both platforms execute
  the GMP2 handshake locally); it stays short of CLOSED until real Android↔iOS
  device interop evidence.
- Does not advance C/E or A-06/A-04/GST-WIPE-001/A-08/A-09 (Stage 3).

**Validation:** sha256
`c78f0b32a1d577642f834a5344fe5ffe5fde42dc590a0e083a5d9e78a46de5e9`;
271 lines; 5 file changes (4 modified, 1 new).

---

## Evidence log SHA-256
```
1661ec3df12d9589df37a3e3c4f82fd8f51c1dff7e41d9cc25716f7ec831d5fc  logs/01-android-gradle-attempt.log
bda4fc6c4da309032d80ab8677c3b4d7d24a508635f3fe78c47bacccba567d4e  logs/02-bundle-inspection.log
9a0da8dddd39766abca471908a44203c0ca60042e9b618006c8fea7c7aa9bb7e  logs/02-drift-check.log
b20a22113c13a3e9e58a9f38818f38360ddfc6a269a610440f22ee2e2d3805c3  logs/02-foundation-tests.log
0b664ddb501489bb79ad3c632162ffec73d73347f3e3de623072c061c5b5849a  logs/02-no-legacy-selftest.log
e70cbb16e31c4b4132b9ce180e1730919a0f0a691a4e81a4f3c8a2b926790731  logs/02-xcodebuild-device.log
f289588fbec4b1e1af2654023a01e52252b31b6aa391304e83faa6989ac43532  logs/02-xcodebuild-simulator.log
d99265f1d411f9be8c23162ff0e07d299a2d523f3eac3b30c66a6b2c778971cb  logs/03-oracle-tripwire.log
f1a71b370f05c07089577b959a1f85373b49ce63ab1890b23e0f8b48be5b1214  logs/04-blake2s-reference.log
```

## Phase 0 execution-evidence SHA-256
```
b390fce3b3bda20e63333dc389783921de656ab3c4e36d2f766065f44af2c2f1  evidence/android-phase0-online/summary.json
fd7c90dbf10ce608cd12aa3e8cf1d742d67e89024ffddbbd88d8e59e3812887c  evidence/android-phase0-online/gradle-phase0.log
5b4ca88d59d7732fed6689f6a76887cf4816e8ba591670555098d7b534e2b0be  evidence/android-phase0-online/toolchain-preflight.log
d00ae79d49b8067aa1ccaf92a80a174293013c1c079be15e15396818fd8dbc3f  evidence/android-phase0-offline/summary.json
e3c243e7cefcf31ea8f9f8da741c524c70b838b5cf9cea4d4fd58650257d5aa4  evidence/android-phase0-offline/gradle-phase0.log
29e74aa6b2928a162a37fab5ca24c62e76ed3cb61441ad6f11ae92e2f5ec9f7d  evidence/android-phase0-offline/toolchain-preflight.log
5bcbe3da537773b88d8abeb29376c84d53a0f4f498bc8c0437c18ded2019add7  evidence/android-phase0-online/test-xml/android_mesh_build_test-results_testDebugUnitTest_TEST-io.godstone.mesh.wire.v2.WireV2VectorTest.xml
dc10aeeae9dd6c68ff2c231a35e0274a1e9ac10e6bb7bf44640cc2c43d5a4e92  patches/12-android-source-exclude-relocation.patch
0be233009b3e6a3913760cf438911afbf2fbed4c16bef1479daf3052799bf0f3  patches/13-android-phase0-build-fixes.patch
34528dd8db1a2948371edea7c6569fb2745a0b4ec94d9dd5329df0db5e8cbf69  patches/15-frame-validation-and-vectors.patch
3d5dc69f77adf05fddcfcb4f1d0bb447de6714da50ba0fcefcf63daff76d21c6  patches/16-gmp21-runtime-cutover.patch
9260a73fde10c2863c23eebeebbf67c937b09577ab41d82e6ec77c18b04fb473  patches/20-remove-legacy-gmp1-runtime.patch
c78f0b32a1d577642f834a5344fe5ffe5fde42dc590a0e083a5d9e78a46de5e9  patches/21-cross-platform-conformance.patch
4d6524f7ec78e0917e2058a38792bbfb04d41bba8cb6dd5428a117ead9448eaa  patches/14-gmp21-generator-and-drift.patch
```

## Phase 0 execution-evidence SHA-256 (Stage 2 patch 16 re-run)
```
25692fc543613dec291e0b812fa94fa12f4c273390a75c2ee55bd7163683738b  evidence/phase0-gmp21-offline/summary.json
64e5fd0ffa40a41815280dac0f5a226897e39b787b635cd8a12f9351d0a31576  evidence/phase0-gmp21-offline/gradle-phase0.log
ae97b3cf3265088924c334e0cdcf24e01bbcbde0521ad516f5437c307e55001d  evidence/phase0-gmp21-online/summary.json
fb82854d27c6606b94621800cb388158604ec80720cafedad203dc17b875c1e9  evidence/phase0-gmp21-online/gradle-phase0.log
```
Note: the `evidence/phase0-gmp21-{offline,online}` dirs are the patch 16 cutover
re-run (8 JUnit XMLs each, all 6 steps rc=0 both modes, 0 downloads offline).
Gold-standard forward-apply (fresh b7daf5a + 00–15 + 16) runner-offline PASS /
106 tests / 0 failures was verified in a throwaway worktree (since cleaned); it
is not persisted as an evidence dir to avoid duplicating the build artifacts,
but the steps are recorded above.
## Phase 0 execution-evidence SHA-256 (Stage 2 patch 20 re-run)
```
<patch 20 reuses the patch 16 evidence dirs — see note below>
25692fc543613dec291e0b812fa94fa12f4c273390a75c2ee55bd7163683738b  evidence/phase0-gmp21-offline/summary.json
64e5fd0ffa40a41815280dac0f5a226897e39b787b635cd8a12f9351d0a31576  evidence/phase0-gmp21-offline/gradle-phase0.log
ae97b3cf3265088924c334e0cdcf24e01bbcbde0521ad516f5437c307e55001d  evidence/phase0-gmp21-online/summary.json
fb82854d27c6606b94621800cb388158604ec80720cafedad203dc17b875c1e9  evidence/phase0-gmp21-online/gradle-phase0.log
```
Note: patch 20 (remove-legacy-gmp1-runtime) is additive on top of patch 16 and
changes only prologue magic + CI analyzer + a build-block invariant — it does
not alter any Android runtime Kotlin that the runner compiles, so the patch 16
evidence dirs (`evidence/phase0-gmp21-{offline,online}`) were re-run against the
patch-16+20 tree and reproduce green (verdict PASS, exit 0; :mesh 41 tests /
0 failures, NoiseSessionTest 10 with the GMP2 prologue). The gold-standard
fresh-baseline (b7daf5a + 00–16 + 20) runner-offline PASS was verified in a
throwaway worktree (since cleaned); it is not persisted as a separate evidence
dir to avoid duplicating build artifacts. Parity gate on the patch-20 tree:
`python ci/check_parity.py` → passed=5 (A,B,F,G,H) failed=3 (C,D,E — pre-existing
external/infra, failing before and after the cutover); `python ci/symbols.py
--selftest` fires (4 findings) and restores 0 unresolved.

Note: the `evidence/android-phase0-*` dirs were re-run for Stage 2 patch 15
(60 tests, a superset of the 47-test Phase 0 close). The supplemental-CI logs
(`evidence/supplemental-ci/*`) were not re-run; their SHAs are unchanged from
the Phase 0 close and remain in `logs/` + the prior record; the supplemental
gates (`check_shipping_path`, `inventory_dormant_wire`,
`check_oracle_private_draft`, `check_android_toolchain --offline`) all re-passed
as steps within the patch 15 runner (steps 1–2 green both modes).

## Phase 0 execution-evidence SHA-256 (Stage 2 patch 21 — iOS xcodebuild + Android)
```
c5d1cca15fb8df22305ad440c2b7d11a6e862d49e84ca1ea3fba8bba6a87a4db  evidence/phase0-gmp21-ios/summary.json
9575a5bf4c3cf94abd57c4107a63ab79acb50cfc9e6e0549c0520642a649426b  evidence/phase0-gmp21-ios/xcodebuild-test.log
aff2c2348c9b56ccb9999467c9fd069777a2da31bd6fb5e8b03ef198bcb2a197  evidence/phase0-gmp21-p21-android/summary.json
18423bf620e5d1c2480430f31127fb68782c373273eafcc4a42e3bd2a9a624d2  evidence/phase0-gmp21-p21-android/test-xml.log
ee46753928d6330416ece38a972cda896aeb66602c8d76cd51cce1b4581e7acc  evidence/phase0-gmp21-p21-android/gradle-phase0.log
997edbcd4f469fd02710495f736f5d05c2ab026acf4e00c4257a4117cae83f16  evidence/phase0-gmp21-p21-android/gradle-oracle-vm.log
a9095dd05dec9aa03da4ff574406866aade3b9f07d787f80534c5c28722f39bb  evidence/phase0-gmp21-p21-android/steps.tsv
```
Note: patch 21 is the iOS execution gate. `evidence/phase0-gmp21-ios/` holds the
first-ever `xcodebuild test` of the iOS mesh codec + GMP2 Noise handshake
(gate `ios-xcodebuild-test`, verdict PASS, **25 tests / 0 failures**:
NoiseSessionTests 3, PortVectorTests 4, RouterTests 5, WireV2VectorTests 13).
`evidence/phase0-gmp21-p21-android/` is the same Phase 0 runner re-run on the
patch-21 tree (verdict PASS, summary.json SHA `aff2c234…`) confirming the
Swift-only codegen change (typed `UInt16` Flags) did not regress the Android
`:mesh` build/test. The gold-standard fresh-baseline (b7daf5a + 00–16 + 20 + 21)
was verified in a throwaway worktree: forward-apply CLEAN → `xcodegen generate`
→ `xcodebuild test` TEST SUCCEEDED (25/0) AND Android runner PASS; reverse-apply
CLEAN (reverts to the untyped-Flags defect + no iOS gate). Worktree since cleaned
(it is not persisted as a separate evidence dir to avoid duplicating build
artifacts). Parity gate on the patch-21 tree: `python ci/check_parity.py` →
passed=5 (A,B,F,G,H) failed=3 (C,D,E — pre-existing; D stays UNPINNED / A-06
OPEN, patch 21 proves iOS↔Android agreement, not external-conformance).

## Phase 0 execution-evidence SHA-256 (Stage 2 patch 14 — gold-standard full chain)
```
f49596e22e6972b28b6ee150a6eb76cf35464471419ff529fb14a3596767efb4  evidence/phase0-gmp21-p14-android/summary.json
cd534915c758b2de7c6bcdbc778856528db071aa61ca0d442e603923d0e8be1a  evidence/phase0-gmp21-p14-android/gradle-phase0.log
18423bf620e5d1c2480430f31127fb68782c373273eafcc4a42e3bd2a9a624d2  evidence/phase0-gmp21-p14-android/test-xml.log
598d11c6b4dcecf993aa7c3a70f30315ed845d1d7d41e448340f9ad38dcd6032  evidence/phase0-gmp21-p14-ios/summary.json
```
Note: patch 14 is a Python gate (no Android/iOS runtime delta), so its
execution evidence is the gold-standard full-chain re-run with patch 14
inserted in its ADR-008 position (00–13 + 14 + 15 + 16 + 20 + 21) on a fresh
b7daf5a worktree (since cleaned). `evidence/phase0-gmp21-p14-android/` is the
Android Phase 0 runner on that tree (verdict PASS, summary.json SHA `f49596e2…`,
6 steps rc=0, 8 JUnit XMLs). `evidence/phase0-gmp21-p14-ios/summary.json`
records the iOS `xcodebuild test` gate on the same tree (TEST SUCCEEDED, 25
tests / 0 failures: NoiseSessionTests 3 / PortVectorTests 4 / RouterTests 5 /
WireV2VectorTests 13). Plus `python -m wire.codegen --selftest` exit 0 (the
patch 14 gate itself) and `python ci/check_parity.py` A ok (selftest wired into
Invariant A). Reverse-apply 21→00 CLEAN, tree back to baseline. The
mutation test (neuter `verify_no_v1_reuse` → `--selftest` exits 1) was run
in-line and is recorded in the patch 14 section above, not as a persisted dir.

## How to apply (review only)
```
cd <repo root at baseline b7daf5a>
# Phase 0 (00 → 13): 05–11 are present as artifacts; 12 depends on 07's ci/ files;
# 13 applies independently on top of 12.
# Stage 2: patch 14 (gmp21-generator-and-drift) is the fired negative control —
# it adds `wire/codegen --selftest` + wires it into Invariant A. It applies on
# top of 13 (its codegen.py/check_parity.py hunks do not overlap patch 11's or
# patch 20's). Patch 15 (frame-validation-and-vectors) is additive on top of 14.
# Patch 16 (gmp21-runtime-cutover) is the atomic 16–19 cascade on top of 15.
# Patch 20 (remove-legacy-gmp1-runtime) is additive on top of 16. Patch 21
# (cross-platform-conformance with iOS/xcodebuild) is additive on top of 20 — it
# adds the iOS `xcodebuild test` gate; applying it then requires `cd ios &&
# xcodegen generate` to materialize the test target before running
# `xcodebuild test`.
for p in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 20 21; do
  git apply --check /tmp/gs-remediate/patches/${p}-*.patch
  git apply       /tmp/gs-remediate/patches/${p}-*.patch
done
```
Reverse (recreates the original defect state; 21 → 00):
```
git apply --reverse --check /tmp/gs-remediate/patches/21-cross-platform-conformance.patch
git apply --reverse       /tmp/gs-remediate/patches/21-cross-platform-conformance.patch
git apply --reverse --check /tmp/gs-remediate/patches/20-remove-legacy-gmp1-runtime.patch
git apply --reverse       /tmp/gs-remediate/patches/20-remove-legacy-gmp1-runtime.patch
git apply --reverse --check /tmp/gs-remediate/patches/16-gmp21-runtime-cutover.patch
git apply --reverse       /tmp/gs-remediate/patches/16-gmp21-runtime-cutover.patch
git apply --reverse --check /tmp/gs-remediate/patches/15-frame-validation-and-vectors.patch
git apply --reverse       /tmp/gs-remediate/patches/15-frame-validation-and-vectors.patch
git apply --reverse --check /tmp/gs-remediate/patches/14-gmp21-generator-and-drift.patch
git apply --reverse       /tmp/gs-remediate/patches/14-gmp21-generator-and-drift.patch
git apply --reverse --check /tmp/gs-remediate/patches/13-android-phase0-build-fixes.patch
git apply --reverse       /tmp/gs-remediate/patches/13-android-phase0-build-fixes.patch
# ... 12, 11, ..., 00 in reverse order
```