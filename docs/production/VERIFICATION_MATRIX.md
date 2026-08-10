# Verification matrix

> **Stage 3 reconciliation.** The earlier rows recorded a Stage 0/2
> "exact-commit remediation overlay" executed in a Linux container where the
> Android SDK/Gradle runtime and macOS/Xcode were unavailable, so most
> platform rows were BLOCKED and evidence pointed at `artifacts/...` bundle
> logs that are not in the repository. The authoritative source is now the
> pushed GitHub repository (`oculusrex14/GODSTONE`), and the repository-owned
> CI on `remediation/stage-3-durability` (`.github/workflows/repository-
> verification.yml`) executes the platform source compile, unit tests, and the
> Xcode LightRelease build + 25 GodstoneMeshTests on every push. Rows below
> derive from that committed CI, not from stale bundle logs. Full APK/AAB
> assembly, device, accessibility, battery/thermal, and signing evidence
remain fail-closed release gates (see `RELEASE_GATES_STATUS.json` and
`EXTERNAL_RELEASE_GATES.md`).

| Gate | Command | Environment | Result | Evidence | Limitation |
|---|---|---|---|---|---|
| Android source compile + unit tests | `./gradlew :core:assembleDebug :mesh:testDebugUnitTest :llm:testDebugUnitTest :app:compileLightDebugKotlin` (committed wrapper, jar SHA + distributionSha256Sum verified) | CI ubuntu-latest, JDK 17, Gradle 8.9 (pinned wrapper) | PASS (repo-owned job `android`) | repository-verification run on the branch tip; provenance artifact `provenance-android` | Not a full APK/AAB assembly (release gate — native stack unpinned) |
| Android Oracle ViewModel runtime tests | `./gradlew :app:testLightDebugUnitTest --tests '*OracleViewModelTest*'` | CI ubuntu-latest, JDK 17, Gradle 8.9 | PASS, 12/12 (OracleViewModelTest) | repository-verification run on the branch tip | No on-device instrumentation |
| iOS mesh tests (xcodebuild) | `xcodebuild -scheme Godstone-Light -configuration LightDebug -destination 'platform=iOS Simulator,name=…' test` | CI macos-15, Xcode | PASS, 25/25 (GodstoneMeshTests: 13 WireV2 + 5 Router + 4 PortVector + 3 NoiseSession) | repository-verification run on the branch tip; asserts "Executed 25 tests, with 0 failures" | Simulator logic tests; no device/BLE |
| iOS host mirror (SwiftPM) | `swift test --package-path ios/Packages/GodstoneFoundation` | CI macos-15 | PASS, 38/38 (Core+Mesh mirror; drift-gated by `sync_ios_foundation_package.py --check`) | repository-verification run on the branch tip | Mirror of canonical `ios/Godstone` |
| iOS Archive-only release build | `xcodebuild -scheme Godstone-Light -configuration LightRelease -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | CI macos-15, Xcode | PASS (app starts truthful "Archive unavailable") | repository-verification run on the branch tip | Unsigned; no model/native stack; not a signed archive |
| Repo-owned parity invariants | `python ci/check_parity.py --scope repo` (A,B,C,E,F,G,H; D reported OPEN) | CI ubuntu-latest | A,B,C,F,G,H PASS; **E FAIL** (tier tables — Phase D); D OPEN (external A-06) | repository-verification run on the branch tip | Invariant E is repo-controlled and is being fixed in Phase D |
| Constraint audit | C1/C2 + `check_tiers.py` + `check_release_gates_status.py` | CI ubuntu-latest | C1/C2/release-gate-status PASS; **`check_tiers.py` FAIL** (no MEDIUM/LARGE flavours — Phase D) | repository-verification run on the branch tip | Tier invariant closed by Phase D |
| Content release gate | `python -m unittest discover -s content/tests -v` | CI ubuntu-latest, Python 3.12 | PASS, 10/10 | repository-verification run on the branch tip | Test-only signing key in temporary directory |
| Mesh simulation regression | `python -m meshsim.run --nodes 200 --scenario city_blackout --ticks 600 --assert-regression` (+ 4 scenarios) | CI ubuntu-latest | PASS | repository-verification run on the branch tip | Simulation, not device |
| Oracle draft isolation / release surface / shipping path / no-release-bypass / no-legacy-wire | `ci/check_repository.py`, `ci/no_legacy_wire.py --selftest` | CI ubuntu-latest | PASS (incl. mutation selftests) | repository-verification run on the branch tip | Static + negative-control evidence |
| Android Archive-only LIGHT release (APK/AAB) | `:app:lintLightRelease :app:assembleLightRelease :app:bundleLightRelease` (scoped to :app) + `lightRelease{Runtime,Compile}Classpath` forbidden-edge check + `inspect_android_artifacts.py` + merged-manifest permission check | release-gates.yml `android-archive-only-release` (repo-owned) | PASS (run 31384944062 @ 3ddb6f6; Archive-only binary does not need llama.cpp/model/Oracle; :app ships `implementation(:core)` only, :llm is testImplementation; `ignoreTestSources=true` keeps full lint off the test component so it never reaches :llm's CMake) | `RELEASE_GATES_STATUS.json` `android-archive-only-release` CLOSED evidence_commit 3ddb6f6; APK SHA-256 e1b8211714bcbbbddee2f70c3be3b703ebe1dc4c3906375a4e40c2e0dcc107ae (2,381,429 B); AAB SHA-256 b77411487af3b672aeff10755db87231b7a2bff7cad0323fed700fb6acc2bb97 (4,045,846 B); lightRelease classpath has no :llm/:mesh/llama/ggml/godstone_llm edge; merged manifest grants no INTERNET/BLE/radio/location permission; APK/AAB namelist clean; uploaded as workflow artifact `android-archive-only-inspection` | Unsigned; no on-device/signing evidence (separate external gates) |
| Android native stack (:llm release) | `:llm:assembleRelease` | release-gates.yml `llm-native-stack` (fail-closed) | BLOCKED — pinned llama.cpp native stack not restored | release-gates run; `RELEASE_GATES_STATUS.json` `model-native-stack` | Future Oracle capability; must not block the Archive-only binary |
| Device/hardware (Case 0) | report matrix | Physical devices | BLOCKED | `RELEASE_GATES_STATUS.json` | A-01/A-02 device closure (Stage 3 Phase L) |