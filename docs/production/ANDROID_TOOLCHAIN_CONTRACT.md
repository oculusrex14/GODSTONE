# Android Reproducible Toolchain Contract

The single source of truth for the exact toolchain that builds the Android
LIGHT shipping variant. A machine that does not match this contract is reported
as an *environment* failure by `scripts/check_android_toolchain.py` — it is never
mislabelled as a source-code test failure.

## Wrapper

| Item | Value |
|---|---|
| Gradle version | **8.9** |
| Distribution URL | `https://services.gradle.org/distributions/gradle-8.9-bin.zip` |
| `distributionSha256Sum` | `d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab` |
| Checksum source of truth | `https://services.gradle.org/distributions/gradle-8.9-bin.zip.sha256` (services.gradle.org, the authoritative Gradle host) |
| `validateDistributionUrl` | `true` |
| `networkTimeout` | `10000` (ms, explicit) |
| Wrapper JAR | `android/gradle/wrapper/gradle-wrapper.jar` |
| Wrapper JAR SHA-256 | `498495120a03b9a6ab5d155f5de3c8f0d986a449153702fb80fc80e134484f17` |

The wrapper verifies the downloaded Gradle distribution against
`distributionSha256Sum` before use, so a tampered or replaced distribution fails
the build rather than silently executing. The wrapper JAR checksum is verified by
`scripts/check_android_toolchain.py` and by `scripts/verify_android_phase0.sh`.

## Build tools (root `android/build.gradle.kts`)

| Item | Value |
|---|---|
| Android Gradle Plugin (AGP) | **8.6.0** (`com.android.application` / `com.android.library`) |
| Kotlin | **2.0.20** (`org.jetbrains.kotlin.android`, `org.jetbrains.kotlin.plugin.compose`) |
| Hilt | **2.52** (`com.google.dagger.hilt.android`) |
| KSP | **2.0.20-1.0.25** (`com.google.devtools.ksp`) |

## JDK

| Item | Value |
|---|---|
| Java / JDK | **17** |
| Evidence | `sourceCompatibility`/`targetCompatibility = JavaVersion.VERSION_17`, `kotlinOptions.jvmTarget = "17"` in every module |
| Vendor | Any JDK 17 (Eclipse Temurin / OpenJDK 17 recommended). Vendor is not pinned; the contract pins the major version only. |

## SDK / compile target

| Item | Value |
|---|---|
| `compileSdk` | **35** (all modules: app, core, llm, mesh) |
| `minSdk` | **26** (all modules) |
| `targetSdk` | **35** (app) |
| Build-tools | **35.0.0** (AGP default for `compileSdk` 35; no explicit `buildToolsVersion` is set) |

### Required `sdkmanager` packages

```
platform-tools
platforms;android-35
build-tools;35.0.0
cmake;3.22.1
ndk;27.0.12077973
```

The NDK version `27.0.12077973` is pinned in `:llm` via `ndkVersion` and asserted
by the preflight (`scripts/check_android_toolchain.py`, `EXPECTED_NDK`). A
present-but-wrong NDK version is a pin mismatch, reported as an environment
failure (`missing_native_tools`), never silently accepted.

## Native build (llm module — llama.cpp/ggml bridge)

| Item | Value |
|---|---|
| Module | `:llm` (`android/llm/build.gradle.kts`) |
| CMake | **3.22.1** (pinned via `externalNativeBuild.cmake.version`) |
| CMakeLists | `android/llm/src/main/cpp/CMakeLists.txt` |
| NDK | **27.0.12077973** (pinned via `ndkVersion` in `:llm`; asserted by preflight `EXPECTED_NDK`) |
| ABI | `arm64-v8a` only (`ndk.abiFilters`) |
| cppFlags | `-O3 -fno-exceptions -fno-rtti` |
| CMake args | `-DGGML_LLAMAFILE=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF` |

### NDK pin

`ndkVersion = "27.0.12077973"` is declared in `:llm` (the only native module).
This is the exact version AGP 8.6.0 selects as its bundled default on the
provisioned host; pinning it makes the native build reproducible across local
and CI machines. The preflight asserts this exact version is installed under
`$ANDROID_HOME/ndk/27.0.12077973`; any other NDK version present is reported as
a pin mismatch (environment failure), not accepted. Any future native module
must declare the same `ndkVersion`.

## Accepted environment variables

| Variable | Required | Purpose |
|---|---|---|
| `ANDROID_HOME` (or `ANDROID_SDK_ROOT`) | **yes** (one of) | SDK root; the wrapper/AGP locate `platforms`, `build-tools`, `cmake`, `ndk` here |
| `JAVA_HOME` | **yes** | JDK 17 used by Gradle and `kotlinOptions.jvmTarget` |
| `GRADLE_USER_HOME` | no | Override the Gradle cache/distribution store (defaults to `~/.gradle`) |
| `ANDROID_NDK_HOME` | no | Override the NDK path (otherwise the pinned `ndkVersion = 27.0.12077973`) |
| `ORG_GRADLE_PROJECT_*` | no | Optional Gradle project properties |

## Verification

- Preflight (fail-fast, distinguishes environment from source failure):
  `python3 scripts/check_android_toolchain.py`
- Full Phase 0 runner: `scripts/verify_android_phase0.sh` (see
  `docs/production/ANDROID_PHASE0_VERIFICATION.md`).