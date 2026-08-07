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

## Stage 3 — durability (branch `remediation/stage-3-durability`, from Stage-2 tip `b7bac64`)

The "unavailable" platform caveats above were the Stage 0/2 Linux-container
state. Stage 3 makes the pushed GitHub repository authoritative and moves
platform execution into repository-owned CI (`repository-verification.yml`),
so the Android Gradle source compile + unit tests and the Xcode LightRelease
build + 25 GodstoneMeshTests now actually run on every push (provenance-bound
to a clean commit). The GMP/2.1 runtime inventory's pre-Stage-2 "current =
GMP/1 on `wire/Frame.kt`" framing is reconciled: `Frame.kt` is deleted
(patch 20), the runtime routes on `FrameV2`, and the Noise prologue is
`"GMP2"`. Phase B reconciled the stale evidence docs
(`VERIFICATION_MATRIX.md`, `PLATFORM_VERIFICATION_MATRIX.md`,
`FINAL_STATUS.md`, `PRODUCTION_READINESS_REPORT.md`, `RELEASE_MANIFEST.json`,
`patches/MANIFEST.md`) to derive from the committed branch state rather than
stale bundle logs, and emitted a machine-readable `FINDINGS_STATUS.json`.

Still open after Stage 3 Phase B: Invariant E (tier tables — Phase D); GMP/2.1
msg-id/Bloom/PoW cross-platform byte parity (Phase C); durable encrypted stores
+ bounded capacity (Phase E/G); coordinated resumable panic wipe (Phase F);
authenticated ACK (Phase H); Archive-only Android release artifact with `:llm`
out of the LIGHT graph (Phase I); and the external release gates (independent
Noise vectors/A-06, production corpus, model/native stack, device
interoperability, accessibility, battery/thermal, signing). Full APK/AAB
assembly and on-device evidence remain fail-closed release gates, not
repo-owned greens.
