# Godstone

Offline survival archive and local-only disaster communications for Android and iOS.

> **Status: V4 pre-alpha repair baseline — not a release.**
> The Archive and grounding controls are executable. Mobile mesh transmission,
> semantic embeddings, bulk transfer, and release packaging remain disabled or
> incomplete until their acceptance gates pass. Read `BUILD_REPORT.md`,
> `docs/AUDIT.md`, and `docs/adr/README.md` before changing a feature flag.

## Product boundaries

Godstone is three isolated subsystems:

- **Archive:** immutable SQLite/FTS5 reference material that remains usable when
  every model and radio is unavailable.
- **Oracle:** an on-device RAG assistant that may answer only when the shipping
  safety gate accepts the retrieved evidence.
- **Mesh:** a planned infrastructure-free encrypted DTN. In V4 it is
  mechanically **fail-closed** because the canonical GMP/2.1 migration and BLE
  record/handshake driver are accepted designs but not implemented end to end.

The Oracle may read the Archive. The Mesh owns a separate encrypted message
store. Neither subsystem may silently fall back to the internet, telemetry, or
plaintext transport.

## V4 guarantees

V4 makes the following claims, and no broader ones:

1. The V4 markdown change-set applies complete files and deletions; it contains
   no inert `*.patch` pseudo-files.
2. Android uses one injected `MeshNode` composition root.
3. Known Android/iOS compile blockers from the V3 reviews are repaired in source.
4. iOS Noise XX has canonical empty-payload message sizes `[32, 96, 64]`, and
   both platform ports own vector tests.
5. The Android and iOS safety-gate formulas agree.
6. Generated GMP/2.1 codecs regenerate deterministically from
   `wire/wire_v2.yaml`.
7. Unfinished radio and bulk paths remain disabled and return truthful UI states.
8. The Archive browser reads real bundled documents instead of placeholder rows.

These are **not** claims that the mobile apps compile in every toolchain, that
Android and iOS currently interoperate, that an SOS was delivered, or that the
content corpus is clinically ready.

## Non-negotiable constraints

`C1` no runtime internet · `C2` no telemetry/accounts · `C3` grounded answers
only · `C4` battery is life · `C5` degrade honestly · `C6` compose audited
cryptography · `C7` accessible under stress.

## Verification

From the repository root:

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r content/requirements.txt cryptography

python scripts/check_tiers.py --require-swift
python -m content.ingest.build_archive \
  --tier MEDIUM --out /tmp/godstone_archive_medium.db --no-embed
python -m wire.codegen
python -m crypto.port_vectors
python -m crypto.gen_vectors
python -m crypto.test_conformance
python -m crypto.cacophony --selftest
python ci/symbols.py --selftest
python ci/integration.py --selftest
python -m safety.probes --db /tmp/godstone_archive_medium.db
python -m content.eval.grounding \
  --db /tmp/godstone_archive_medium.db --strict
python ci/check_parity.py \
  --db /tmp/godstone_archive_medium.db
python -m meshsim.run --nodes 200 --scenario city_blackout \
  --ticks 600 --assert-regression
```

The parity gate is FAIL-CLOSED on the Noise vector lock: Invariant D fails
with "independent vectors unavailable or unapproved" while
`crypto/cacophony_vectors.json` holds no approved EXTERNAL fixture. There is
no permissive escape hatch -- the gate stays red until an independent vector
file is pinned, reviewed and consumed by both platform tests (A-06).

## Mobile proof still required

A releasable build requires all of the following on a clean checkout:

- Android Gradle/JDK/SDK/NDK compile and tests.
- macOS/Xcode/Swift tests and app build.
- a pinned, reproducible llama.cpp dependency and verified model lockfile.
- Hardware Case 0: Android↔iOS BLE discovery, record reassembly, Noise XX,
  canonical frame exchange, reconnect, tamper, replay, and timeout behavior.
- clinician/editorial approval for every shipped chunk.
- permissions, accessibility, battery, migration, panic-wipe, and data-loss tests.

## Layout

```text
android/       native app, mesh, archive/RAG and tests
ios/           SwiftUI app, core, mesh, LLM bridge and tests
content/       corpus ingestion, schema, examples and evaluation
safety/        canonical grounding gate and probes
wire/          GMP/2.1 schema, code generator and golden vectors
crypto/        reference vectors and cross-port fixtures
ci/            invariants, symbol checks and mutation controls
meshsim/       routing simulator
transport/     hardware role matrix
docs/adr/      accepted decisions and unresolved architecture
```
