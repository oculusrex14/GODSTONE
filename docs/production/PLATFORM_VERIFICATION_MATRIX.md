# Platform verification matrix

> **Stage 3 reconciliation.** Derived from the repository-owned CI on
> `remediation/stage-3-durability` (`repository-verification.yml`), not from the
> stale Stage 0/2 Linux-container overlay where Android/Xcode were unavailable.
> The authoritative source is the pushed GitHub repository.

| Platform | Source validation | Unit tests | Static analysis | Release build | Artifact inspection | Device evidence |
|---|---|---|---|---|---|---|
| Android | `:core:assembleDebug` + `:app:compileLightDebugKotlin` in CI (committed Gradle 8.9 wrapper, jar SHA + distributionSha256Sum verified) | `:mesh:testDebugUnitTest`, `:llm:testDebugUnitTest`, `:app:testLightDebugUnitTest --tests '*OracleViewModelTest*'` PASS in CI | C1/C2 + `check_repository.py` + `check_shipping_path.py` PASS in CI | LightRelease APK/AAB = release gate (fail-closed; native stack unpinned) | `inspect_android_artifacts.py` runs in the release-gates job | Unavailable (A-02 device — Phase L) |
| iOS | `xcodegen generate` + `xcodebuild ... LightRelease build` PASS in CI; `sync_ios_foundation_package.py --check` (mirror drift) PASS | `xcodebuild test` GodstoneMeshTests 25/25 PASS in CI; `swift test` mirror 38/38 PASS | `check_release_surface.py` plist/project checks PASS | LightRelease Archive-only build PASS in CI (unsigned; truthful "Archive unavailable") | Not generated (unsigned build) | Unavailable (A-01/A-02 device — Phase L) |
| Content/Python | Full overlay modules executable | 10 tests PASS in CI | compile/static checks PASS | Signed fixture manifest PASS | SQLite/tier/hash/signature faults PASS | N/A |

A simulator, Linux Swift compiler, or software BLE model does not close any physical-device requirement. Full APK/AAB assembly, signing, and on-device evidence remain fail-closed release gates (`RELEASE_GATES_STATUS.json`).