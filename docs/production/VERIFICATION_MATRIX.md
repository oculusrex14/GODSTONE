# Verification matrix

| Gate | Command | Environment | Result | Evidence | Limitation |
|---|---|---|---|---|---|
| Android Oracle validation | Kotlin harness compiling `AnswerValidator.kt` | Linux x86_64, Kotlin 1.9.0/JRE 21 | PASS, 4/4 | `artifacts/android/logs/kotlin-validator-*.log` | Not an Android Gradle/instrumentation build |
| iOS Oracle validation | Swift harness for `OracleAnswerValidator.swift` | Linux x86_64, Swift 6.2.1 | PASS, 4/4 | `artifacts/ios/logs/swift-validator-test.log` | Not Xcode/iOS UI execution |
| Content release gate | `python3 -m unittest discover -s content/tests -v` | Linux, Python 3.13.5 | PASS, 10/10 | `artifacts/reports/logs/content-release-gates-test.log` | Uses test-only signing key in temporary directory |
| Overlay mutations | `python3 -m unittest discover -s overlay/tests -v` | Linux, Python 3.13.5 | PASS, 2/2 | `artifacts/reports/logs/overlay-transform-tests.log` | Full private checkout unavailable |
| Oracle draft isolation | `python3 ci/check_oracle_private_draft.py` | Linux | PASS | `repository-static-checks.log` | Static supporting evidence only |
| Release surface | `python3 ci/check_release_surface.py` | Linux | PASS | `repository-static-checks.log` | Merged/binary manifests require build |
| Action/bypass policy | `python3 ci/no_release_bypasses.py` | Linux | PASS | `repository-static-checks.log` | Python wheel hashes remain incomplete |
| Shipping Mesh isolation | `python3 ci/no_legacy_wire.py` | Linux | PASS | local output and negative control | Legacy Mesh module remains nonshipping |
| Android clean build | `./gradlew clean test lint assembleLightRelease bundleLightRelease` | Required Android SDK/Gradle/full checkout | BLOCKED | none | SDK, wrapper JAR, complete checkout unavailable |
| iOS release build | `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` | Required macOS/Xcode/full checkout | BLOCKED | none | Linux environment |
| Device/hardware | report matrix | Physical devices | BLOCKED | none | No devices/BLE/battery lab |
