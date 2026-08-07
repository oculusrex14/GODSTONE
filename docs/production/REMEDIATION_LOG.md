# Remediation log

## Baseline and build stability

- Recorded commit `b7daf5aceb642277807e9bfbe3bbb486112a64ec`; confirmed no intervening commits.
- Corrected `Ed25519Keys.kt` and `X25519Keys.kt` to use concrete Bouncy Castle key parameter types.
- Added `android/gradle.properties` and pinned wrapper distribution metadata.
- Added `ios/Packages/GodstoneFoundation` plus deterministic source synchronization.
- Removed iOS inference `-ffast-math`.
- Blocker retained: verified `gradle-wrapper.jar` cannot be retrieved through the connector and must not be fabricated.

## Oracle and content safety

- Android and iOS generation drafts remain coroutine/task-local until final validation.
- Failure, cancellation, invalid citation, unsupported quantity, omitted qualifier, warning omission, and partial generation expose no draft.
- Removed bare-number fallback from both legacy numeric-provenance functions through exact-baseline transforms.
- Added machine-verifiable document approval manifests and signed Archive manifests.
- Production manifest directory is intentionally empty; examples are mechanically nonreleasable.

## Packaging and truthfulness

- Selected one application identity, `io.godstone.app`, and LIGHT as the only initial tier.
- Android and iOS production navigation expose Archive only.
- Android production app no longer depends on `:mesh`; iOS app target depends only on `GodstoneCore`.
- Removed disabled radio/SOS/media permissions, services, entitlements, background modes, and claims.
- Added an Apple privacy manifest starter derived from the Archive-only target.

## Verification performed

- Kotlin answer-validator harness: 4 passed, 0 failed.
- Swift answer-validator harness: 4 passed, 0 failed.
- Python content/archive tests: 10 passed, 0 failed.
- Overlay transformation tests: 2 passed, 0 failed.
- Static release-surface, private-draft, action-pinning, and shipping Mesh guard checks: passed.

## Known incomplete work

The private checkout could not be mounted into the build container, Android SDK/Gradle were unavailable, and macOS/Xcode/physical devices were unavailable. Durable messaging, canonical future Mesh, key/trust lifecycle, panic-wipe integration, model/native reproducibility, independent Noise vectors, and external approvals remain open.
