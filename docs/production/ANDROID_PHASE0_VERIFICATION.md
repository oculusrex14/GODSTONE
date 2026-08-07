# Android Phase 0 Verification (Portable Runner)

`scripts/verify_android_phase0.sh` is the portable, self-contained Android
Phase 0 evidence runner. It runs the toolchain preflight, the shipping-path
gate, the Gradle wrapper/distribution verification, the core/mesh/llm host
unit tests, the LIGHT Kotlin compile, and the Android Oracle ViewModel
runtime-state tests; records every command's log and SHA-256; collects the
JUnit XML; and emits a machine-readable `summary.json`. It returns nonzero if
any required step fails or is skipped.

It does **not** build the full APK (that remains a release gate: llama.cpp,
model weights and the archive must be pinned and restored first). Run it on a
correctly provisioned machine (see `scripts/check_android_toolchain.py` and
`docs/production/ANDROID_TOOLCHAIN_CONTRACT.md`); the preflight fails fast with
a distinct exit code if the toolchain is missing or the NDK version is wrong.

## Prerequisites

The exact toolchain is defined in
[`ANDROID_TOOLCHAIN_CONTRACT.md`](./ANDROID_TOOLCHAIN_CONTRACT.md): Gradle 8.9
(pinned `distributionSha256Sum`), AGP 8.6.0, Kotlin 2.0.20, JDK 17, compileSdk
35, build-tools 35.0.0, CMake 3.22.1, NDK 27.0.12077973 (both pinned and asserted
by the preflight). Required environment:

- `JAVA_HOME` — JDK 17
- `ANDROID_HOME` (or `ANDROID_SDK_ROOT`) — Android SDK with
  `platforms;android-35`, `build-tools;35.0.0`, `cmake;3.22.1`,
  `ndk;27.0.12077973`
- `GRADLE_USER_HOME` — optional (defaults to `~/.gradle`)

The runner verifies all of this up front via the fail-fast preflight, run with
`--require-native` so the pinned NDK version is asserted (a wrong or missing NDK
is an environment failure, exit 3, reported before Gradle).

## Two modes

### `online-bootstrap`

Use on a clean, online machine. The Gradle 8.9 distribution may be downloaded
on first wrapper invocation; the wrapper verifies it against
`distributionSha256Sum` before use, so a tampered distribution fails the build
rather than silently executing.

```
scripts/verify_android_phase0.sh online-bootstrap
```

### `offline-preprovisioned`

Use on an air-gapped or pre-provisioned machine. No network is used. The Gradle
8.9 distribution **and** the SDK packages must already be cached locally. The
preflight is run with `--offline` and **fails clearly** (exit 3) if the
distribution is not in the local cache; Gradle is invoked with `--offline` so it
can **never silently switch to online** to download a missing distribution.

```
scripts/verify_android_phase0.sh offline-preprovisioned
```

Provision the offline cache beforehand by running once online (which populates
`GRADLE_USER_HOME/wrapper/dists/gradle-8.9-bin/...`), then copy that cache and
the SDK packages to the offline machine.

## What it runs (required steps)

| Step | Command | What it proves |
|---|---|---|
| 1. toolchain preflight | `python3 scripts/check_android_toolchain.py --require-native [--offline]` | JDK 17, SDK, platform/build-tools, wrapper JAR SHA-256, pinned distribution checksum, CMake 3.22.1, NDK 27.0.12077973 (exact version pin); (offline) distribution cached. Environment failure, not a source failure. |
| 2. shipping-path gate | `python3 ci/check_shipping_path.py --root .` | LIGHT shipping path has no Mesh/GMP-1 dependency edge (build-config evidence). A-01 stays OPEN. |
| 3. wrapper + dist verify | `./gradlew [--offline] --version` | The pinned wrapper + distribution actually run. |
| 4. gradle Phase 0 | `./gradlew --no-daemon --stacktrace --warning-mode=all [--offline] clean :core:testDebugUnitTest :mesh:testDebugUnitTest :llm:testDebugUnitTest :app:compileLightDebugKotlin` | core (Blake2s conformance), mesh (port-vector + Noise session), llm (Android Oracle AnswerValidator), LIGHT Kotlin compile. |
| 5. Oracle VM tests | `./gradlew ... :app:testLightDebugUnitTest --tests '*OracleViewModelTest*'` | Android Oracle ViewModel runtime-state tests (no native model). |
| 6. collect test XML | (internal) | JUnit XML gathered + SHA-256'd. |
| 7. summary | (internal) | `summary.json` written. |

If step 1 fails, the runner stops before Gradle (exit 3) so an environment
failure is never mislabelled as a source-code test failure.

## Evidence

All evidence is written under `evidence/android-phase0-<UTC-timestamp>/`
(override with `--evidence-dir DIR`):

- `environment.txt` — host, tool versions (`java -version`, `python3 --version`,
  `adb version`), `ANDROID_HOME`/`JAVA_HOME`/`GRADLE_USER_HOME`.
- `git.txt` — `git rev-parse HEAD`, branch, `git status --porcelain`, worktree
  list (or `is_git_repo=no`).
- `<step>.log` — full stdout+stderr of each step, with a `.sha256` sidecar
  where applicable (every log is hashed).
- `test-xml/` — collected JUnit XML, with `<step>.log` listing each XML file
  and its SHA-256.
- `steps.tsv` — per-step `rc`, log SHA-256, and XML counts.
- `summary.json` — machine-readable verdict:
  ```json
  {
    "verdict": "PASS | FAIL",
    "mode": "online-bootstrap | offline-preprovisioned",
    "timestamp": "...",
    "overall_exit_code": 0 | 1,
    "required_steps": ["toolchain-preflight", "shipping-path-gate", ...],
    "steps": [{"name": "...", "rc": "...", "sha256": "...", "passed": true}],
    "evidence_files": [{"file": "...", "sha256": "..."}]
  }
  ```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every required step passed |
| 1 | at least one required step failed (after the preflight passed) |
| 2 | bad usage / unknown mode |
| 3 | toolchain preflight failed (environment failure) — Gradle was not invoked |

## Reading a run

```
jq '.verdict, .steps[] | {name, passed}' evidence/android-phase0-<ts>/summary.json
```

A `PASS` verdict with every step `passed: true` is the Phase 0 green signal for
Android. Anything else is a regression or an environment gap; consult the
per-step `.log` (and its SHA-256) for the detail.