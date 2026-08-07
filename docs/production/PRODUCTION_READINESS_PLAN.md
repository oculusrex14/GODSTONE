# Production readiness implementation plan

## Executed in this bundle

1. Locked the audited baseline and recorded exact Git blob preconditions.
2. Corrected Bouncy Castle key parameter typing and added deterministic Android properties.
3. Isolated host-testable iOS Core/Mesh package generation and removed `-ffast-math` from the iOS inference package.
4. Replaced pre-validation Oracle streaming with private draft buffering on Android and iOS.
5. Added citation-bound answer validation and exact quantity/unit/dimension/qualifier checks with no bare-number fallback.
6. Added fail-closed content provenance, rights, reviewer, expiry, warning, contraindication, and chunk-approval validation.
7. Added signed Ed25519 Archive release manifests and corruption/tier/schema/count verification.
8. Reduced both production applications to one LIGHT identity and an Archive-only user surface.
9. Removed production radio/SOS/media permissions, services, entitlements, background modes, and claims.
10. Added immutable-action CI scaffolding, release-surface checks, Oracle draft checks, and shipping Mesh/GMP guards.
11. Added deterministic evidence, SBOM stubs, release documentation, and exact-commit application tooling.

## Remaining dependency order

1. Materialize a complete private checkout and add a verified Gradle wrapper JAR.
2. Run/fix the full Android build, unit tests, lint, release APK/AAB, and artifact inspections.
3. Run/fix the isolated Swift package and Xcode project on macOS/Xcode.
4. Complete GMP/2.1 migration and durable encrypted Android/iOS message stores before reintroducing any Mesh dependency.
5. Pin independent Noise vectors, llama.cpp, models, compilers, native outputs, and Python distribution hashes.
6. Integrate resumable panic wipe with every sensitive key/store/cache component.
7. Supply genuinely approved and licensed production content and release signing keys.
8. Perform physical-device accessibility, BLE, battery, thermal, migration, recovery, and airplane-mode evidence.
9. Complete legal, privacy, clinical, export, signing, support, and store approvals.

No later phase may enable Oracle, Mesh, bulk transfer, or SOS merely because source scaffolding exists.
