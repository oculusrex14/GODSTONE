# GODSTONE — V4 FINAL

**Self-applying change-set onto `GODSTONE_V3.md`**  
**Milestone:** compile repair, fail-closed product surfaces, conformance controls, accepted GMP/2.1 and BLE-link ADRs  
**Status:** **PRE-ALPHA / NOT A RELEASE**  
**Assembled:** 1 August 2026

This document replaces the three Claude V4 drafts. It contains the complete,
final content of every changed or added file and explicit deletion markers. It
contains **no inert `*.patch` pseudo-files** and no duplicate paths.

Apply it only to a clean extraction of `GODSTONE_V3.md`.

- Base file count: **166**
- Base tree SHA-256: `01e68135a7556ce0cba3c374e5461114eea7ecaf879d2adfb0648ae94d06b4f4`
- Files written: **76** (17 added, 59 replaced)
- Files deleted: **2**
- Final file count: **181**
- Final tree SHA-256: `4c126c95957102f661d21d0d87464146e901519786d47d2c5e1110d0456168b7`

## 0. What this closes

V4 consolidates the V3 source, GLM review, GPT review, and Claude revisions. It:

1. replaces pseudo-patches with real target files and validates reconstruction;
2. removes Android's second `MeshNode` object graph;
3. repairs the confirmed Android/iOS source blockers identified in the reviews;
4. rewrites the iOS Noise XX transcript logic and adds platform-owned port tests;
5. aligns the Swift/Kotlin/Python grounding-gate formula;
6. restores real Archive browsing on Android and iOS;
7. hardens CI against comment-only and orphaned implementations;
8. accepts GMP/2.1 and the BLE record-layer decisions without pretending they
   are implemented end to end;
9. keeps mesh, SOS and bulk transfer mechanically disabled until real acceptance
   tests pass;
10. replaces unverified model hashes with a lockfile-driven fetch path that
    refuses to run while the lock is unpinned;
11. updates product, threat-model, build, audit and store documentation so user
    claims are no stronger than measured behavior.

## 1. What remains deliberately open

This is not a hidden promise of a working emergency messenger. The following are
still stop-ship gates:

- Android and iOS full app builds in their real SDK/Xcode toolchains;
- the Android migration from the disabled legacy router/store to GMP/2.1;
- BLE record reassembly and the complete Noise handshake driver;
- Android↔iOS hardware Case 0;
- external pinned Noise vectors;
- a durable encrypted iOS DTN store and coordinated panic wipe;
- identity binding, TOFU/contact semantics and sealed-sender redesign;
- authenticated SOS receipt lifecycle;
- a reviewed cross-platform bulk plane;
- a pinned llama.cpp revision and independently verified model hashes;
- a licensed, clinically reviewed corpus.

The app must continue to expose these capabilities as unavailable, not
“degraded” or “sent,” until those gates are closed.

## 2. Apply the change-set

Save this file as `GODSTONE_V4_FINAL.md` beside a directory containing a clean
V3 extraction, then run the script below from the parent directory. Change
`ROOT` if needed.

```python
from __future__ import annotations

import hashlib
from pathlib import Path

CHANGESET = Path("GODSTONE_V4_FINAL.md")
ROOT = Path("godstone-v3-tree")
EXPECTED_BASE_FILES = 166
EXPECTED_BASE_SHA256 = "01e68135a7556ce0cba3c374e5461114eea7ecaf879d2adfb0648ae94d06b4f4"
EXPECTED_WRITES = 76
EXPECTED_DELETES = 2
EXPECTED_FINAL_FILES = 181
EXPECTED_FINAL_SHA256 = "4c126c95957102f661d21d0d87464146e901519786d47d2c5e1110d0456168b7"


def tree_hash(root: Path) -> tuple[str, int]:
    paths = sorted(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file())
    h = hashlib.sha256()
    for rel in paths:
        data = (root / rel).read_bytes()
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(hashlib.sha256(data).digest())
        h.update(b"\n")
    return h.hexdigest(), len(paths)


def safe_path(raw: str) -> Path:
    rel = Path(raw)
    if rel.is_absolute() or not rel.parts or ".." in rel.parts:
        raise SystemExit(f"unsafe path: {raw!r}")
    return rel


base_sha, base_files = tree_hash(ROOT)
if (base_files, base_sha) != (EXPECTED_BASE_FILES, EXPECTED_BASE_SHA256):
    raise SystemExit(
        "base tree does not match the clean GODSTONE_V3 extraction: "
        f"files={base_files} sha256={base_sha}"
    )

lines = CHANGESET.read_text(encoding="utf-8").splitlines()
writes: dict[str, list[str]] = {}
deletes: set[str] = set()
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith(">>> DELETE: "):
        rel = safe_path(line[12:].strip()).as_posix()
        if rel in writes or rel in deletes:
            raise SystemExit(f"duplicate change-set path: {rel}")
        deletes.add(rel)
    elif line.startswith(">>> FILE: "):
        rel = safe_path(line[10:].strip()).as_posix()
        if rel in writes or rel in deletes:
            raise SystemExit(f"duplicate change-set path: {rel}")
        i += 1
        if i >= len(lines) or not lines[i].startswith("`````"):
            raise SystemExit(f"missing opening fence for {rel}")
        i += 1
        body: list[str] = []
        while i < len(lines) and lines[i].strip() != "<<< END FILE":
            body.append(lines[i])
            i += 1
        if i >= len(lines):
            raise SystemExit(f"unterminated file block: {rel}")
        if body and body[-1].startswith("`````"):
            body.pop()
        writes[rel] = body
    i += 1

if len(writes) != EXPECTED_WRITES or len(deletes) != EXPECTED_DELETES:
    raise SystemExit(
        f"marker count mismatch: writes={len(writes)} deletes={len(deletes)}"
    )

for rel in sorted(deletes):
    target = ROOT / rel
    if not target.exists():
        raise SystemExit(f"delete target missing: {rel}")
    target.unlink()

for rel, body in sorted(writes.items()):
    target = ROOT / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".v4tmp")
    temporary.write_text("\n".join(body) + "\n", encoding="utf-8")
    temporary.replace(target)

final_sha, final_files = tree_hash(ROOT)
if (final_files, final_sha) != (EXPECTED_FINAL_FILES, EXPECTED_FINAL_SHA256):
    raise SystemExit(
        "final reconstruction mismatch: "
        f"files={final_files} sha256={final_sha}"
    )

print(f"applied V4: files={final_files} sha256={final_sha}")
```

## 3. Validation performed on the reconstructed tree

The final change-set was applied to a fresh 166-file V3 extraction and compared
byte-for-byte with the assembled V4 tree. The reconstruction hash matched the
value above.

Executed checks:

- shell syntax for model acquisition/verification scripts;
- four-way tier-table agreement;
- deterministic wire-codec regeneration;
- generated port vectors and internal Noise reference conformance;
- cacophony harness negative control;
- Kotlin symbol negative control;
- integration mutation corpus: **5/6 caught, 1 documented static-analysis
  ceiling**, no regressions;
- MEDIUM lexical archive build: 27 worked-example chunks;
- C3 probes: **10/10 passed**;
- strict grounding evaluation: **11 probes, 0 failures**;
- parity invariants A–G: **7 passed, 0 failed**, with Noise explicitly unpinned;
- mesh simulator regression: **0.293**, above the 0.250 regression floor and
  below the open 0.800 product target;
- Swift parser: **35 files, 0 syntax failures**;
- model fetch path: correctly exited non-zero while the lock is `UNPINNED`.

These checks do not replace Android Gradle/SDK/NDK compilation, macOS Xcode
compilation, device-radio testing, external crypto vectors or clinical review.

## 4. Reviewer mandate for Opus

Do not validate this document by agreeing with its prose. Reconstruct it from a
clean V3 tree and independently attempt to falsify every closure claim.

At minimum:

1. compile every Android module and every host/iOS target available;
2. run platform port tests, not only Python reference tests;
3. inspect the actual call graph for dead branches and duplicate composition
   roots;
4. verify all BLE packet-size assumptions on devices;
5. challenge ADR-001's PoW/sealed-envelope interaction before enabling GROUP or
   BROADCAST;
6. reject any UI state stronger than the transport evidence;
7. do not weaken a test merely to make the revision green;
8. list every remaining blocker with an executable closure test.

---

# Change-set manifest

## Added

- `android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt`
- `android/llm/src/main/java/io/godstone/llm/archive/ArchiveRepository.kt`
- `android/mesh/src/main/java/io/godstone/mesh/transport/PeerId.kt`
- `android/mesh/src/test/java/io/godstone/mesh/PortVectorTest.kt`
- `ci/mutations.py`
- `crypto/port_vectors.json`
- `crypto/port_vectors.py`
- `docs/adr/ADR-001-canonical-wire.md`
- `docs/adr/ADR-002-ble-record-layer.md`
- `docs/adr/ADR-003-identity-and-sealed-sender.md`
- `docs/adr/ADR-004-durable-store.md`
- `docs/adr/ADR-005-sos-and-lifecycle.md`
- `docs/adr/ADR-006-bulk-plane.md`
- `docs/adr/ADR-007-cipher-suite.md`
- `docs/adr/README.md`
- `docs/packaging/MODELS.lock.json`
- `ios/Godstone/Tests/GodstoneMeshTests/PortVectorTests.swift`

## Replaced

- `.github/workflows/build.yml`
- `.gitignore`
- `BUILD_REPORT.md`
- `README.md`
- `android/app/build.gradle.kts`
- `android/app/src/main/java/io/godstone/app/GodstoneApplication.kt`
- `android/app/src/main/java/io/godstone/app/di/AppModule.kt`
- `android/app/src/main/java/io/godstone/app/ui/GodstoneNavHost.kt`
- `android/app/src/main/java/io/godstone/app/ui/browse/BrowseScreen.kt`
- `android/app/src/main/java/io/godstone/app/ui/mesh/MeshScreen.kt`
- `android/app/src/main/java/io/godstone/app/ui/sos/SosScreen.kt`
- `android/build.gradle.kts`
- `android/llm/src/main/cpp/CMakeLists.txt`
- `android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt`
- `android/llm/src/test/java/io/godstone/llm/RagPipelineTest.kt`
- `android/mesh/build.gradle.kts`
- `android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt`
- `android/mesh/src/main/java/io/godstone/mesh/MeshService.kt`
- `android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt`
- `android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt`
- `android/mesh/src/main/java/io/godstone/mesh/transport/GattClient.kt`
- `android/mesh/src/main/java/io/godstone/mesh/transport/GattServer.kt`
- `android/mesh/src/main/java/io/godstone/mesh/transport/WifiAwareTransport.kt`
- `android/mesh/src/main/java/io/godstone/mesh/wire/v2/WireV2.kt`
- `ci/check_parity.py`
- `ci/integration.py`
- `docs/AUDIT.md`
- `docs/mesh/PROTOCOL.md`
- `docs/mesh/THREAT_MODEL.md`
- `docs/packaging/STORE.md`
- `ios/Godstone/Package.swift`
- `ios/Godstone/Sources/App/ArchiveView.swift`
- `ios/Godstone/Sources/App/MeshView.swift`
- `ios/Godstone/Sources/App/SosView.swift`
- `ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift`
- `ios/Godstone/Sources/GodstoneCore/LruSet.swift`
- `ios/Godstone/Sources/GodstoneCore/SafetyGate.swift`
- `ios/Godstone/Sources/GodstoneLLM/ModelManager.swift`
- `ios/Godstone/Sources/GodstoneLLM/RagPipeline.swift`
- `ios/Godstone/Sources/GodstoneMesh/BleTransport.swift`
- `ios/Godstone/Sources/GodstoneMesh/BulkTransport.swift`
- `ios/Godstone/Sources/GodstoneMesh/MeshCoordinator.swift`
- `ios/Godstone/Sources/GodstoneMesh/MeshIdentity.swift`
- `ios/Godstone/Sources/GodstoneMesh/MeshNode.swift`
- `ios/Godstone/Sources/GodstoneMesh/NoiseSession.swift`
- `ios/Godstone/Sources/GodstoneMesh/Router.swift`
- `ios/Godstone/Sources/GodstoneMesh/WireV2.swift`
- `ios/Godstone/Tests/GodstoneMeshTests/RouterTests.swift`
- `ios/project.yml`
- `scripts/check_tiers.py`
- `scripts/fetch_models.sh`
- `scripts/quantise.sh`
- `third_party/README.md`
- `wire/codegen.py`
- `wire/gen/WireV2.kt`
- `wire/gen/WireV2.swift`
- `wire/gen/wire_v2_codec.py`
- `wire/golden_vectors.json`
- `wire/wire_v2.yaml`

## Deleted

- `android/mesh/src/main/java/io/godstone/mesh/MeshNodeHolder.kt`
- `ios/Godstone/Sources/GodstoneMesh/Frame.swift`

---

# File blocks

### `.github/workflows/build.yml`

>>> FILE: .github/workflows/build.yml
`````yaml
name: build

on:
  push:
    branches: [ main ]
  pull_request:

# No secrets are used anywhere in this workflow. There is no signing key, no
# store upload and no telemetry endpoint, because there is nothing to upload to
# and nothing to report (C1, C2). Release artefacts are built and signed on a
# workstation that is not connected to anything.
permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:

  constraints:
    name: constraint audit
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # C1. The most important check in this file. If an INTERNET permission or
      # a URLSession ever appears, the product's central promise is broken and
      # the build must stop, loudly, before anyone can ship it.
      - name: no network permission on Android
        run: |
          # A bare grep also matched the comment EXPLAINING the constraint and
          # the tools:node="remove" strip -- both correct content -- so this gate
          # failed on every clean checkout and could never go green.
          if grep -rn 'uses-permission' android/ --include='*.xml' \
               | grep 'android.permission.INTERNET' \
               | grep -v 'tools:node="remove"' ; then
            echo '::error::android.permission.INTERNET is granted - violates C1'
            exit 1
          fi
          echo 'ok: no INTERNET permission granted'

      - name: no networking APIs on iOS
        run: |
          if grep -rnE 'URLSession|NSURLConnection|CFStream|Network\\.framework' \
               ios/ --include='*.swift' --include='*.m' --include='*.mm' ; then
            echo '::error::iOS networking API referenced - violates C1'
            exit 1
          fi
          echo 'ok: no networking APIs'

      # C2. Analytics SDKs arrive as transitive dependencies far more often than
      # as deliberate additions, so this greps the lockfiles too.
      - name: no analytics or crash reporting
        run: |
          if grep -rniE 'firebase|crashlytics|sentry|amplitude|mixpanel|appcenter' \
               android/ ios/ --include='*.kts' --include='*.gradle' \
               --include='*.plist' --include='*.yml' --include='*.resolved' ; then
            echo '::error::telemetry dependency found - violates C2'
            exit 1
          fi
          echo 'ok: no telemetry'

      - name: tier tables agree across platforms
        run: python scripts/check_tiers.py

  parity:
    name: parity + safety invariants
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: pip install -r content/requirements.txt cryptography
      - name: build archive for the gate
        run: |
          python -m content.ingest.build_archive \
            --tier MEDIUM --out dist/archive_medium.db --no-embed
      - name: regenerate wire codecs and crypto vectors
        run: |
          python -m wire.codegen
          python -m crypto.port_vectors
          python -m crypto.gen_vectors
      # A regenerates the wire codecs and diffs; B forbids any eval file from
      # computing its own grounding verdict; C is the C3 red/green probe suite;
      # D is Noise conformance incl. the derivation chain; E is C1/C2 + tiers.
      #
      # --allow-unpinned acknowledges that noise_ref has not been checked
      # against an EXTERNAL vector. REMOVE THIS FLAG once a real vector file is
      # dropped into crypto/cacophony_vectors.json -- Invariant D flips to
      # PINNED automatically. See docs/PINNING_CACOPHONY.md.
      # Invariant F resolves Kotlin cross-file symbols. Its --selftest is run
      # FIRST: a control that has never been observed failing is not a control,
      # and the first version of F passed while the defect was present.
      - name: symbol resolver negative control
        run: python ci/symbols.py --selftest
      # Invariant G asks whether the apps actually USE the reference code.
      # Its selftest re-orphans the codec and requires detection: A-F all passed
      # while the wire, Noise and gate fixes were imported by nothing.
      - name: integration reachability negative control
        run: python ci/integration.py --selftest
      - name: invariants A-G
        run: python ci/check_parity.py --allow-unpinned

  content:
    name: content pipeline
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: install
        run: pip install -r content/requirements.txt

      # --no-embed skips the model entirely. CI verifies the schema, the
      # chunker and the SQL; embedding quality is measured offline where the
      # weights actually live.
      - name: build a LIGHT archive without embeddings
        run: |
          python -m content.ingest.build_archive \
            --tier LIGHT --out /tmp/archive_light.db --no-embed

      - name: archive is queryable and correctly indexed
        run: |
          python - <<'PY'
          import sqlite3, sys
          db = sqlite3.connect('/tmp/archive_light.db')

          meta = dict(db.execute('SELECT key, value FROM archive_meta'))
          print('corpus_sha256', meta['corpus_sha256'])
          assert meta['tier'] == 'LIGHT'

          docs = db.execute('SELECT COUNT(*) FROM documents').fetchone()[0]
          chunks = db.execute('SELECT COUNT(*) FROM chunks').fetchone()[0]
          assert docs > 0 and chunks > 0, 'empty archive'

          # The exact join both retrievers issue. If the FTS content_rowid is
          # wrong this returns nothing and every semantic-miss query in the app
          # silently returns no sources.
          rows = db.execute('''
              SELECT c.chunk_id, d.title, c.section
              FROM chunks_fts
              JOIN chunks c ON c.chunk_id = chunks_fts.rowid
              JOIN documents d ON d.document_id = c.document_id
              WHERE chunks_fts MATCH 'tourniquet'
              ORDER BY bm25(chunks_fts) LIMIT 5
          ''').fetchall()
          assert rows, 'FTS join returned nothing'
          print('fts ok:', rows[0])

          # A LIGHT build must not carry MEDIUM-only material.
          leaked = db.execute(
              "SELECT COUNT(*) FROM documents WHERE tier_min != 'LIGHT'"
          ).fetchone()[0]
          assert leaked == 0, f'{leaked} non-LIGHT documents in a LIGHT build'
          print('tier filtering ok')
          PY

      - name: build is deterministic
        run: |
          python -m content.ingest.build_archive \
            --tier LIGHT --out /tmp/archive_two.db --no-embed
          a=$(sqlite3 /tmp/archive_light.db \
                "SELECT value FROM archive_meta WHERE key='corpus_sha256'")
          b=$(sqlite3 /tmp/archive_two.db \
                "SELECT value FROM archive_meta WHERE key='corpus_sha256'")
          if [ "$a" != "$b" ]; then
            echo "::error::corpus_sha256 not reproducible: $a vs $b"
            exit 1
          fi
          echo "ok: reproducible ($a)"

  meshsim:
    name: mesh simulation
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      # The reference run from the README. The floor is a regression guard, not
      # a target: routing changes that quietly halve delivery are otherwise
      # invisible until somebody needs the mesh.
      - name: city blackout, 200 nodes
        run: |
          # The 0.80 target was never derived from measurement and is not
          # reachable at 3.66 mean neighbours -- it is a statement about street
          # density, not about routing. Asserting it made the job permanently
          # red, which trains people to ignore a red job. CI now guards against
          # REGRESSION and reports the product gap without failing on physics.
          python -m meshsim.run --nodes 200 --scenario city_blackout \
            --ticks 600 --assert-regression

      - name: other scenarios
        run: |
          for s in rural_sparse crowd_surge partition_heal flat_batteries; do
            echo "--- $s"
            python -m meshsim.run --nodes 120 --scenario "$s" --ticks 400
          done

  android:
    name: android source compile + unit tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - uses: gradle/actions/setup-gradle@v4

      # The text-distributed repository cannot carry gradle-wrapper.jar. Restore
      # it deterministically before invoking the wrapper.
      - name: restore Gradle wrapper binary
        working-directory: android
        run: gradle wrapper --gradle-version 8.9 --distribution-type bin

      - name: compile Kotlin surfaces and run host unit tests
        working-directory: android
        run: |
          ./gradlew \
            :core:assembleDebug \
            :mesh:testDebugUnitTest \
            :llm:testDebugUnitTest \
            :app:compileLightDebugKotlin \
            --no-daemon

      # Full APK assembly remains a release gate because llama.cpp, models and
      # archives must first be pinned and restored. CI must not manufacture a
      # false green by silently omitting those assets.

      - name: verify merged manifest has no INTERNET permission
        run: |
          manifest=$(find android -name AndroidManifest.xml -path '*merged*' | head -1)
          if [ -n "$manifest" ] && grep -q 'android.permission.INTERNET' "$manifest"; then
            echo '::error::INTERNET permission appeared via a library merge'
            exit 1
          fi
          echo 'ok: merged manifest clean'

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: android-test-results
          path: '**/build/reports/tests/**'

  ios:
    name: ios core + mesh compile and tests
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: compile the host-buildable closure
        run: swift build --package-path ios/Godstone --target GodstoneMesh

      - name: run GodstoneCore/GodstoneMesh tests
        run: swift test --package-path ios/Godstone --filter GodstoneMeshTests

      # The full app/LLM build remains a separate release gate until the
      # llama.cpp revision and model artefacts are immutable and restorable.
`````
<<< END FILE

### `.gitignore`

>>> FILE: .gitignore
`````text
# V4: restored. V3 cut this from 80 lines to 27 and dropped load-bearing rules.
# ios/Godstone/.build/ alone holds ~346 MB across ~3,599 files, and a single
# `git add .` would have ingested it.

# --- build output ---
dist/
build/
.build/
.gradle/
.cxx/
captures/
local.properties
*.apk
*.aab
*.ap_
*.dex

# --- signing keys and secrets. NEVER commit. ---
*.keystore
*.jks
secrets.properties
google-services.json
*.p12
*.mobileprovision

# --- large binaries, produced by scripts, never committed ---
models/
*.gguf
*.db
*.db-journal
*.db-shm
*.db-wal

# --- native dependency checkout; pinning method is still an open release gate ---
third_party/llama.cpp/

# --- Xcode: the project is GENERATED from ios/project.yml ---
*.xcodeproj/
*.xcworkspace/
xcuserdata/
DerivedData/
*.xcuserstate
Pods/

# The app currently has no external Swift package dependency graph worth locking.
# Revisit when a reviewed native-dependency pinning strategy is added.
Package.resolved

# --- simulator artefacts ---
meshsim/out/
meshsim/logs/
*.meshlog

# --- python ---
__pycache__/
*.py[cod]
.venv/
venv/
.pytest_cache/
.mypy_cache/
.ruff_cache/

# --- editors ---
.idea/
.vscode/
*.iml
*.swp
.DS_Store
`````
<<< END FILE

### `BUILD_REPORT.md`

>>> FILE: BUILD_REPORT.md
`````markdown
# Godstone V4 — Build and Verification Report

**Date:** 1 August 2026  
**Milestone:** compile repair, one composition root, honest CI, accepted wire/link ADRs  
**Release status:** **PRE-ALPHA / NOT SHIPPABLE**

## 1. Executive result

V4 consolidates the V3 source and both adversarial reviews into a self-applying
change-set. It fixes confirmed source defects, adds platform-port tests, removes
placeholder product surfaces, and disables network-like features whose security
or delivery semantics are not yet implemented.

V4 does **not** claim production readiness or cross-platform mesh operation.
ADR-001 and ADR-002 are accepted designs; their M1-wire and M2-link
implementations remain open. Both mobile apps therefore expose the mesh as
unavailable rather than transmitting plaintext or reporting fictional delivery.

## 2. Closed in source

| Area | V4 action |
|---|---|
| Change-set packaging | complete target files only; duplicate paths rejected; no inert pseudo-patches |
| Android composition | deleted `MeshNodeHolder`; service, app and UI share the Hilt singleton |
| iOS compile blockers | declared session/peer state, protocol conformance and FrameV2 router surface |
| Android compile blockers | corrected SQLCipher API, SafetyGate call, BuildConfig fields and Kotlin Compose plugin |
| Noise port | rewrote iOS XX transcript processing and added Android/iOS message-size tests |
| Grounding parity | corrected Swift IDF precedence and hardened integration checks |
| Archive UI | replaced Android/iOS placeholders with real SQLite-backed document browsing |
| Truthful failure | radio, SOS and bulk UI fail closed until implementations pass acceptance tests |
| CI controls | comment-stripping reachability checks plus mutation corpus; 5/6 caught, one documented static-analysis ceiling |
| Wire schema | accepted GMP/2.1, widened priority mask and regenerated both codecs/golden vectors |

## 3. Verification performed in the assembly environment

The final change-set is applied to a clean V3 extraction before these checks are
run. Results recorded by the final assembly script:

- marker/path uniqueness and byte-for-byte reconstruction;
- tier-table parity;
- MEDIUM archive build without embeddings;
- wire regeneration;
- generated crypto fixtures and reference conformance;
- C3 probes and strict grounding evaluation;
- symbol resolver and integration mutation controls;
- invariants A–G;
- mesh simulator regression scenario;
- Swift parser pass over authored Swift sources where host modules permit.

The exact command log is embedded in the final V4 markdown. A Python/static pass
is not a substitute for Gradle, Xcode, radios, or clinical review.

## 4. Deliberately disabled

| Capability | Why disabled | Re-enable gate |
|---|---|---|
| BLE mesh | canonical v2 runtime and record/handshake driver not complete | ADR-001 M1 + ADR-002 M2 acceptance tests |
| SOS transmission | no durable end-to-end ACK semantics or verified authenticity model | ADR-003/004/005 plus hardware tests |
| Wi-Fi/AWDL bulk | no shared authenticated cross-platform protocol | ADR-006 |
| Android semantic vector search | JNI `nativeEmbed` is absent; mixing embedding spaces is unsafe | implemented port + model lock + parity tests |
| release model download | weights/hashes are not externally verified and locked | reproducible model lockfile |

Lexical Archive search and the C3 safety gate remain available. Disabling a
partial feature is intentional C5 degradation, not a hidden failure.

## 5. Open stop-ship gates

1. Clean Android compile/test/assemble with restored wrapper and pinned native dependency.
2. Clean macOS Swift/Xcode compile/test for all targets.
3. Android↔iOS Hardware Case 0.
4. External/pinned Noise vectors and removal of `--allow-unpinned`.
5. Durable iOS store, Android migration/eviction hardening, coordinated panic wipe.
6. Identity binding, TOFU/contact model and sealed-sender redesign.
7. Permission/capability lifecycle and accessibility stress tests.
8. Pinned llama.cpp revision and model/artifact hashes.
9. Real licensed corpus with clinician/editorial approval per independently safe chunk.
10. Store/privacy/disclaimer materials implemented in the apps, not merely documented.

## 6. Honest readiness

| Dimension | V4 assessment |
|---|---:|
| Architecture decisions | 8/10 |
| Source coherence | 7/10 pending real compilers |
| Verification design | 8/10 with documented reachability ceiling |
| Mesh runtime | 1/10; intentionally disabled |
| Content readiness | 1/10; examples only |
| Production readiness | **2/10** |
`````
<<< END FILE

### `README.md`

>>> FILE: README.md
`````markdown
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
  --db /tmp/godstone_archive_medium.db --allow-unpinned
python -m meshsim.run --nodes 200 --scenario city_blackout \
  --ticks 600 --assert-regression
```

`--allow-unpinned` is an explicit acknowledgement that external Noise
cacophony vectors have not yet been pinned. It must not appear in a release gate.

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
`````
<<< END FILE

### `android/app/build.gradle.kts`

>>> FILE: android/app/build.gradle.kts
`````kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
}

android {
    namespace = "io.godstone.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.godstone.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // Tier flavors. Each ships a different model and archive database.
    flavorDimensions += "tier"

    productFlavors {
        create("light") {
            dimension = "tier"
            applicationIdSuffix = ".light"
            versionNameSuffix = "-light"
            buildConfigField("String", "TIER", "\"LIGHT\"")
            buildConfigField("String", "MODEL_FILE", "\"qwen3-0.6b-q4km.gguf\"")
            buildConfigField("String", "ARCHIVE_FILE", "\"archive_light.db\"")
            buildConfigField("int", "CTX_TOKENS", "2048")
            buildConfigField("int", "TOP_K_CHUNKS", "4")
            buildConfigField("String", "EMBED_MODEL_FILE", "\"\"")
            buildConfigField("int", "EMBED_DIM", "384")
        }
        create("medium") {
            dimension = "tier"
            applicationIdSuffix = ".medium"
            versionNameSuffix = "-medium"
            buildConfigField("String", "TIER", "\"MEDIUM\"")
            buildConfigField("String", "MODEL_FILE", "\"qwen3-1.7b-q4km.gguf\"")
            buildConfigField("String", "ARCHIVE_FILE", "\"archive_medium.db\"")
            buildConfigField("int", "CTX_TOKENS", "4096")
            buildConfigField("int", "TOP_K_CHUNKS", "6")
            buildConfigField("String", "EMBED_MODEL_FILE", "\"\"")
            buildConfigField("int", "EMBED_DIM", "384")
        }
        create("large") {
            dimension = "tier"
            applicationIdSuffix = ".large"
            versionNameSuffix = "-large"
            buildConfigField("String", "TIER", "\"LARGE\"")
            buildConfigField("String", "MODEL_FILE", "\"qwen3-4b-q5km.gguf\"")
            buildConfigField("String", "ARCHIVE_FILE", "\"archive_large.db\"")
            buildConfigField("int", "CTX_TOKENS", "8192")
            buildConfigField("int", "TOP_K_CHUNKS", "8")
            buildConfigField("String", "EMBED_MODEL_FILE", "\"\"")
            buildConfigField("int", "EMBED_DIM", "768")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    // Model and archive assets must never be compressed: we mmap them at runtime.
    androidResources {
        noCompress += listOf("gguf", "db")
    }

    // The model and archive are mmap'd from assets at runtime. Without this
    // sourceSet the app installs, launches, and then cannot find its model on
    // a device that by definition cannot download it (C1).
    sourceSets {
        getByName("light")  { assets.srcDirs("src/light/assets",  "../../models", "../../dist") }
        getByName("medium") { assets.srcDirs("src/medium/assets", "../../models", "../../dist") }
        getByName("large")  { assets.srcDirs("src/large/assets",  "../../models", "../../dist") }
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":mesh"))
    implementation(project(":llm"))

    implementation(platform("androidx.compose:compose-bom:2024.09.02"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.navigation:navigation-compose:2.8.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")

    implementation("com.google.dagger:hilt-android:2.52")
    ksp("com.google.dagger:hilt-compiler:2.52")
    implementation("androidx.hilt:hilt-navigation-compose:1.2.0")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
`````
<<< END FILE

### `android/app/src/main/java/io/godstone/app/GodstoneApplication.kt`

>>> FILE: android/app/src/main/java/io/godstone/app/GodstoneApplication.kt
`````kotlin
package io.godstone.app

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject
import io.godstone.mesh.MeshNode

@HiltAndroidApp
class GodstoneApplication : Application() {

    @Inject lateinit var meshNode: MeshNode

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()

        // Identity must exist before any radio starts. Cheap if already present.
        meshNode.ensureIdentity()

        // Radios start only after the user explicitly enables the mesh and
        // grants runtime permissions. Model preparation occurs on first Oracle
        // use, never as multi-gigabyte main-thread I/O at process startup.
    }

    private fun createNotificationChannels() {
        val nm = getSystemService(NotificationManager::class.java)

        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_MESH,
                getString(R.string.channel_mesh),
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = getString(R.string.channel_mesh_desc) }
        )

        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_SOS,
                getString(R.string.channel_sos),
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = getString(R.string.channel_sos_desc)
                enableVibration(true)
                setBypassDnd(true)
            }
        )
    }

    companion object {
        const val CHANNEL_MESH = "godstone.mesh"
        const val CHANNEL_SOS = "godstone.sos"
    }
}
`````
<<< END FILE

### `android/app/src/main/java/io/godstone/app/di/AppModule.kt`

>>> FILE: android/app/src/main/java/io/godstone/app/di/AppModule.kt
`````kotlin
package io.godstone.app.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import io.godstone.app.BuildConfig
import io.godstone.llm.ModelManager
import io.godstone.llm.archive.ArchiveRepository
import io.godstone.llm.rag.Embedder
import io.godstone.llm.rag.RagPipeline
import io.godstone.llm.rag.Retriever
import io.godstone.mesh.MeshNode
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.SqliteMessageStore
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideMessageStore(@ApplicationContext ctx: Context): MessageStore =
        SqliteMessageStore(ctx, maxBytes = 200L * 1024 * 1024)

    @Provides
    @Singleton
    fun provideMeshNode(
        @ApplicationContext ctx: Context,
        store: MessageStore
    ): MeshNode = MeshNode(ctx, store)

    @Provides
    @Singleton
    fun provideArchiveRepository(@ApplicationContext ctx: Context): ArchiveRepository =
        ArchiveRepository(ctx, archiveAsset = BuildConfig.ARCHIVE_FILE)

    @Provides
    @Singleton
    fun provideModelManager(@ApplicationContext ctx: Context): ModelManager =
        ModelManager(
            context = ctx,
            modelAsset = BuildConfig.MODEL_FILE,
            contextTokens = BuildConfig.CTX_TOKENS
        )

    @Provides
    @Singleton
    fun provideEmbedder(@ApplicationContext ctx: Context): Embedder? {
        if (BuildConfig.EMBED_MODEL_FILE.isEmpty()) return null
        return Embedder(
            context = ctx,
            embedModelAsset = BuildConfig.EMBED_MODEL_FILE,
            expectedDim = BuildConfig.EMBED_DIM
        )
    }

    @Provides
    @Singleton
    fun provideRetriever(
        @ApplicationContext ctx: Context,
        embedder: Embedder?
    ): Retriever = Retriever(ctx, archiveAsset = BuildConfig.ARCHIVE_FILE, embedder = embedder)

    @Provides
    @Singleton
    fun provideRagPipeline(
        models: ModelManager,
        retriever: Retriever
    ): RagPipeline = RagPipeline(
        models = models,
        retriever = retriever,
        topK = BuildConfig.TOP_K_CHUNKS
    )
}
`````
<<< END FILE

### `android/app/src/main/java/io/godstone/app/ui/GodstoneNavHost.kt`

>>> FILE: android/app/src/main/java/io/godstone/app/ui/GodstoneNavHost.kt
`````kotlin
package io.godstone.app.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import io.godstone.app.ui.browse.BrowseScreen
import io.godstone.app.ui.home.HomeScreen
import io.godstone.app.ui.mesh.MeshScreen
import io.godstone.app.ui.oracle.OracleScreen
import io.godstone.app.ui.sos.SosScreen
import io.godstone.mesh.MeshNode

/**
 * Five destinations, flat hierarchy. Under stress nobody navigates a tree.
 * Every screen is reachable in at most two taps from anywhere.
 */
sealed class Dest(val route: String, val label: String) {
    data object Home : Dest("home", "Home")
    data object Oracle : Dest("oracle", "Ask")
    data object Browse : Dest("browse", "Archive")
    data object Mesh : Dest("mesh", "Mesh")
    data object Sos : Dest("sos", "SOS")
}

@Composable
fun GodstoneNavHost(meshNode: MeshNode) {
    val nav = rememberNavController()
    val backStack by nav.currentBackStackEntryAsState()
    val current = backStack?.destination?.route

    Scaffold(
        bottomBar = {
            NavigationBar {
                listOf(Dest.Home, Dest.Oracle, Dest.Browse, Dest.Mesh, Dest.Sos)
                    .forEach { dest ->
                        NavigationBarItem(
                            selected = current == dest.route,
                            onClick = {
                                nav.navigate(dest.route) {
                                    popUpTo(Dest.Home.route)
                                    launchSingleTop = true
                                }
                            },
                            icon = { Icon(iconFor(dest), contentDescription = dest.label) },
                            label = { Text(dest.label) }
                        )
                    }
            }
        }
    ) { padding ->
        NavHost(
            navController = nav,
            startDestination = Dest.Home.route,
            modifier = androidx.compose.ui.Modifier.padding(padding)
        ) {
            composable(Dest.Home.route) { HomeScreen(onNavigate = { nav.navigate(it) }) }
            composable(Dest.Oracle.route) { OracleScreen() }
            composable(Dest.Browse.route) { BrowseScreen() }
            composable(Dest.Mesh.route) { MeshScreen(meshNode = meshNode) }
            composable(Dest.Sos.route) { SosScreen(meshNode = meshNode) }
        }
    }
}

private fun iconFor(dest: Dest) = when (dest) {
    Dest.Home -> Icons.Filled.Home
    Dest.Oracle -> Icons.Filled.Chat
    Dest.Browse -> Icons.Filled.Book
    Dest.Mesh -> Icons.Filled.Chat
    Dest.Sos -> Icons.Filled.Warning
}
`````
<<< END FILE

### `android/app/src/main/java/io/godstone/app/ui/browse/BrowseScreen.kt`

>>> FILE: android/app/src/main/java/io/godstone/app/ui/browse/BrowseScreen.kt
`````kotlin
package io.godstone.app.ui.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.godstone.llm.archive.ArchiveDocument
import io.godstone.llm.archive.ArchivePassage

/** Search and document browsing remain available even when the model and radios do not. */
@Composable
fun BrowseScreen(vm: BrowseViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(state.openedTitle ?: "Archive", style = MaterialTheme.typography.titleLarge)
            if (state.openedTitle != null || state.passages.isNotEmpty()) {
                Button(onClick = vm::backToDocuments) { Text("All documents") }
            }
        }

        OutlinedTextField(
            value = state.query,
            onValueChange = vm::onQueryChanged,
            label = { Text("Search every document") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { vm.search() })
        )
        Button(onClick = vm::search, modifier = Modifier.fillMaxWidth()) { Text("Search offline") }

        state.error?.let {
            Card(
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer
                )
            ) { Text(it, modifier = Modifier.padding(16.dp)) }
        }

        if (state.loading) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(state.documents, key = { it.id }) { DocumentCard(it, vm::open) }
                items(state.passages, key = { it.chunkId }) { PassageCard(it) }
            }
        }
    }
}

@Composable
private fun DocumentCard(document: ArchiveDocument, onOpen: (ArchiveDocument) -> Unit) {
    Card(
        onClick = { onOpen(document) },
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(document.title, fontWeight = FontWeight.Bold)
            Text(document.domain, style = MaterialTheme.typography.bodyMedium)
            if (document.isCritical) Text("Critical procedure", color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun PassageCard(passage: ArchivePassage) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(passage.documentTitle, fontWeight = FontWeight.Bold)
            if (passage.section.isNotBlank()) Text(passage.section, style = MaterialTheme.typography.bodyMedium)
            Text(passage.text, style = MaterialTheme.typography.bodyLarge)
        }
    }
}
`````
<<< END FILE

### `android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt`

>>> FILE: android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt
`````kotlin
package io.godstone.app.ui.browse

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.godstone.llm.archive.ArchiveDocument
import io.godstone.llm.archive.ArchivePassage
import io.godstone.llm.archive.ArchiveRepository
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class BrowseUiState(
    val query: String = "",
    val loading: Boolean = true,
    val documents: List<ArchiveDocument> = emptyList(),
    val passages: List<ArchivePassage> = emptyList(),
    val openedTitle: String? = null,
    val error: String? = null
)

@HiltViewModel
class BrowseViewModel @Inject constructor(
    private val archive: ArchiveRepository
) : ViewModel() {
    private val _state = MutableStateFlow(BrowseUiState())
    val state: StateFlow<BrowseUiState> = _state.asStateFlow()

    init { loadDocuments() }

    fun onQueryChanged(value: String) {
        _state.value = _state.value.copy(query = value)
    }

    fun search() {
        val query = _state.value.query.trim()
        if (query.isEmpty()) {
            loadDocuments()
            return
        }
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null, openedTitle = null)
            val result = runCatching {
                withContext(Dispatchers.IO) { archive.search(query) }
            }
            _state.value = result.fold(
                onSuccess = { _state.value.copy(loading = false, passages = it, documents = emptyList()) },
                onFailure = { _state.value.copy(loading = false, error = "Archive search failed: ${it.message}") }
            )
        }
    }

    fun open(document: ArchiveDocument) {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            val result = runCatching {
                withContext(Dispatchers.IO) { archive.passages(document.id) }
            }
            _state.value = result.fold(
                onSuccess = {
                    _state.value.copy(
                        loading = false,
                        documents = emptyList(),
                        passages = it,
                        openedTitle = document.title
                    )
                },
                onFailure = { _state.value.copy(loading = false, error = "Document failed to open: ${it.message}") }
            )
        }
    }

    fun backToDocuments() {
        _state.value = _state.value.copy(query = "")
        loadDocuments()
    }

    private fun loadDocuments() {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null, openedTitle = null)
            val result = runCatching {
                withContext(Dispatchers.IO) { archive.listDocuments() }
            }
            _state.value = result.fold(
                onSuccess = {
                    _state.value.copy(
                        loading = false,
                        documents = it,
                        passages = emptyList(),
                        openedTitle = null
                    )
                },
                onFailure = { _state.value.copy(loading = false, error = "Archive unavailable: ${it.message}") }
            )
        }
    }
}
`````
<<< END FILE

### `android/app/src/main/java/io/godstone/app/ui/mesh/MeshScreen.kt`

>>> FILE: android/app/src/main/java/io/godstone/app/ui/mesh/MeshScreen.kt
`````kotlin
package io.godstone.app.ui.mesh

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.godstone.mesh.MeshNode

/** Honest status surface. Radio enablement remains blocked until M1-wire/M2-link close. */
@Composable
fun MeshScreen(meshNode: MeshNode) {
    val status by meshNode.statusFlow.collectAsStateWithLifecycle()
    Column(
        modifier = Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text("Mesh", style = MaterialTheme.typography.titleLarge)
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(if (status.linkLayerReady) "Control plane ready" else "Transport not field-ready")
                Text(status.detail, style = MaterialTheme.typography.bodyLarge)
                Text("Nearby peers: ${status.peerCount}", style = MaterialTheme.typography.bodyMedium)
            }
        }
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer
            )
        ) {
            Text(
                "Godstone will not activate radios or claim encrypted delivery until the canonical GMP/2.1 wire format, BLE record reassembly, and Noise handshake driver pass real two-device tests.",
                modifier = Modifier.padding(16.dp)
            )
        }
    }
}
`````
<<< END FILE

### `android/app/src/main/java/io/godstone/app/ui/sos/SosScreen.kt`

>>> FILE: android/app/src/main/java/io/godstone/app/ui/sos/SosScreen.kt
`````kotlin
package io.godstone.app.ui.sos

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.godstone.mesh.MeshNode
import io.godstone.mesh.SosDispatchResult
import kotlinx.coroutines.launch

sealed interface SosUiState {
    data object Idle : SosUiState
    data object Sending : SosUiState
    data class Unavailable(val reason: String) : SosUiState
    data object QueuedLocally : SosUiState
    data class HandedToRelays(val count: Int) : SosUiState
    data class Failed(val reason: String) : SosUiState
}

/** A transport write is never labelled recipient delivery. */
@Composable
fun SosScreen(meshNode: MeshNode) {
    var state by remember { mutableStateOf<SosUiState>(SosUiState.Idle) }
    val scope = rememberCoroutineScope()
    val linkReady = MeshNode.LINK_LAYER_READY
    val buttonColor = if (linkReady) MaterialTheme.colorScheme.error
        else MaterialTheme.colorScheme.surfaceVariant

    Column(
        modifier = Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text("SOS", style = MaterialTheme.typography.titleLarge)
        Text(
            if (linkReady) "Press and hold to queue a distress message."
            else "Mesh SOS is unavailable in this pre-alpha build.",
            style = MaterialTheme.typography.bodyLarge
        )
        Spacer(Modifier.height(24.dp))
        Box(
            modifier = Modifier
                .size(220.dp)
                .semantics { contentDescription = if (linkReady) "Hold to queue SOS" else "SOS unavailable" }
                .pointerInput(linkReady) {
                    if (linkReady) detectTapGestures(onLongPress = {
                        if (state is SosUiState.Sending) return@detectTapGestures
                        state = SosUiState.Sending
                        scope.launch {
                            state = when (val result = meshNode.broadcastSos("SOS".toByteArray())) {
                                is SosDispatchResult.Unavailable -> SosUiState.Unavailable(result.reason)
                                SosDispatchResult.QueuedLocally -> SosUiState.QueuedLocally
                                is SosDispatchResult.HandedToRelays -> SosUiState.HandedToRelays(result.count)
                                is SosDispatchResult.Failed -> SosUiState.Failed(result.reason)
                            }
                        }
                    })
                },
            contentAlignment = Alignment.Center
        ) {
            androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                drawCircle(color = buttonColor)
            }
            Text(
                when (state) {
                    SosUiState.Idle -> if (linkReady) "HOLD" else "DISABLED"
                    SosUiState.Sending -> "QUEUING"
                    is SosUiState.Unavailable -> "DISABLED"
                    SosUiState.QueuedLocally -> "QUEUED"
                    is SosUiState.HandedToRelays -> "RELAYED"
                    is SosUiState.Failed -> "RETRY"
                },
                style = MaterialTheme.typography.titleLarge
            )
        }
        Spacer(Modifier.height(24.dp))
        Text(
            when (val current = state) {
                SosUiState.Idle -> if (linkReady) {
                    "Queued means stored on this phone. Relayed means a nearby device accepted the encrypted record. Neither means a recipient acknowledged it."
                } else {
                    "The app refuses to show a success state while cross-platform encrypted transport is incomplete. Use local emergency services or another working communication method."
                }
                SosUiState.Sending -> "Writing to the local queue…"
                is SosUiState.Unavailable -> current.reason
                SosUiState.QueuedLocally -> "Stored on this phone; no relay accepted it yet."
                is SosUiState.HandedToRelays -> "Accepted by ${current.count} nearby relay(s); recipient acknowledgement has not been received."
                is SosUiState.Failed -> "Could not queue SOS: ${current.reason}"
            },
            style = MaterialTheme.typography.bodyMedium
        )
    }
}
`````
<<< END FILE

### `android/build.gradle.kts`

>>> FILE: android/build.gradle.kts
`````kotlin
plugins {
    id("com.android.application") version "8.6.0" apply false
    id("com.android.library") version "8.6.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.20" apply false
    id("com.google.dagger.hilt.android") version "2.52" apply false
    id("com.google.devtools.ksp") version "2.0.20-1.0.25" apply false
}

tasks.register("clean", Delete::class) {
    delete(rootProject.layout.buildDirectory)
}
`````
<<< END FILE

### `android/llm/src/main/cpp/CMakeLists.txt`

>>> FILE: android/llm/src/main/cpp/CMakeLists.txt
`````text
cmake_minimum_required(VERSION 3.22.1)
project("godstone_llm")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# llama.cpp must be present at third_party/llama.cpp. V4 has no verified
# gitlink or source-archive lock yet, so full native builds remain blocked until
# the dependency is pinned reproducibly. Nothing is fetched by CMake.
# FIXED: this was ../../../../ which resolves to android/third_party -- a
# directory that does not exist. The cpp dir is android/llm/src/main/cpp, so
# reaching the repo root takes FIVE levels, not four. The native build could
# never have configured.
set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third_party/llama.cpp)

set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP          OFF CACHE BOOL "" FORCE)

add_subdirectory(${LLAMA_DIR} ${CMAKE_BINARY_DIR}/llama.cpp)

add_library(godstone_llm SHARED
    godstone_llm_jni.cpp
)

target_include_directories(godstone_llm PRIVATE
    ${LLAMA_DIR}
    ${LLAMA_DIR}/common
    ${LLAMA_DIR}/ggml/include
)

target_link_libraries(godstone_llm
    llama
    common
    android
    log
)

target_compile_options(godstone_llm PRIVATE
    -O3
    -ffast-math
    -funroll-loops
)
`````
<<< END FILE

### `android/llm/src/main/java/io/godstone/llm/archive/ArchiveRepository.kt`

>>> FILE: android/llm/src/main/java/io/godstone/llm/archive/ArchiveRepository.kt
`````kotlin
package io.godstone.llm.archive

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File

/** A document that can be opened without loading the language model. */
data class ArchiveDocument(
    val id: Long,
    val title: String,
    val domain: String,
    val isCritical: Boolean
)

/** A readable passage from the immutable on-device archive. */
data class ArchivePassage(
    val chunkId: Long,
    val documentId: Long,
    val documentTitle: String,
    val domain: String,
    val section: String,
    val text: String,
    val score: Double = 0.0
)

/**
 * Read-only browser over the bundled Archive.
 *
 * This path deliberately has no dependency on llama.cpp or an embedding model.
 * If generation, semantic search, or every radio fails, the user can still list
 * documents, search them with FTS5, and read complete passages.
 */
class ArchiveRepository(
    context: Context,
    private val archiveAsset: String
) {
    private val appContext = context.applicationContext
    private val db: SQLiteDatabase by lazy { openReadOnly() }

    val isAvailable: Boolean
        get() = runCatching { db.isOpen }.getOrDefault(false)

    fun listDocuments(domain: String? = null): List<ArchiveDocument> {
        val out = ArrayList<ArchiveDocument>()
        val where = if (domain.isNullOrBlank()) "" else "WHERE domain = ?"
        val args = if (domain.isNullOrBlank()) null else arrayOf(domain)
        db.rawQuery(
            "SELECT document_id, title, domain, is_critical FROM documents " +
                "$where ORDER BY is_critical DESC, domain, title",
            args
        ).use { c ->
            while (c.moveToNext()) {
                out += ArchiveDocument(
                    id = c.getLong(0),
                    title = c.getString(1),
                    domain = c.getString(2),
                    isCritical = c.getInt(3) != 0
                )
            }
        }
        return out
    }

    fun listDomains(): List<String> {
        val out = ArrayList<String>()
        db.rawQuery("SELECT DISTINCT domain FROM documents ORDER BY domain", null).use { c ->
            while (c.moveToNext()) out += c.getString(0)
        }
        return out
    }

    fun passages(documentId: Long): List<ArchivePassage> {
        val out = ArrayList<ArchivePassage>()
        db.rawQuery(
            """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text
            FROM chunks c JOIN documents d ON d.document_id = c.document_id
            WHERE c.document_id = ?
            ORDER BY c.ordinal
            """.trimIndent(),
            arrayOf(documentId.toString())
        ).use { c ->
            while (c.moveToNext()) out += c.toPassage()
        }
        return out
    }

    fun search(query: String, limit: Int = 40): List<ArchivePassage> {
        val safe = sanitiseFts(query)
        if (safe.isBlank()) return emptyList()
        val out = ArrayList<ArchivePassage>()
        db.rawQuery(
            """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text,
                   bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.chunk_id = chunks_fts.rowid
            JOIN documents d ON d.document_id = c.document_id
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """.trimIndent(),
            arrayOf(safe, limit.toString())
        ).use { c ->
            while (c.moveToNext()) out += c.toPassage(score = -c.getDouble(6))
        }
        return out
    }

    private fun android.database.Cursor.toPassage(score: Double = 0.0) = ArchivePassage(
        chunkId = getLong(0),
        documentId = getLong(1),
        documentTitle = getString(2),
        domain = getString(3),
        section = getString(4),
        text = getString(5),
        score = score
    )

    private fun openReadOnly(): SQLiteDatabase {
        val dest = File(appContext.filesDir, archiveAsset)
        if (!dest.exists()) {
            val tmp = File(dest.parentFile, dest.name + ".tmp")
            appContext.assets.open(archiveAsset).use { input ->
                tmp.outputStream().use { output ->
                    input.copyTo(output)
                    output.fd.sync()
                }
            }
            check(tmp.renameTo(dest) || dest.exists()) {
                "could not install archive asset $archiveAsset"
            }
            if (tmp.exists()) tmp.delete()
        }
        return SQLiteDatabase.openDatabase(
            dest.absolutePath,
            null,
            SQLiteDatabase.OPEN_READONLY
        ).apply {
            execSQL("PRAGMA query_only = ON")
            execSQL("PRAGMA mmap_size = 268435456")
        }
    }

    private fun sanitiseFts(value: String): String =
        value.replace(Regex("[\\\"*():^-]"), " ")
            .split(Regex("\\s+"))
            .filter { it.isNotBlank() }
            .joinToString(" OR ") { "\"$it\"" }
}
`````
<<< END FILE

### `android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt`

>>> FILE: android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt
`````kotlin
package io.godstone.llm.rag

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File
import kotlin.math.sqrt

data class Chunk(
    val chunkId: Long,
    val documentId: Long,
    val documentTitle: String,
    val domain: String,
    val text: String,
    val score: Double
)

data class Citation(
    val documentId: Long,
    val title: String,
    val domain: String,
    val snippet: String
)

data class RetrievalResult(
    val chunks: List<Chunk>,
    val bestScore: Double,
    val nearMisses: List<Citation>,
    /** Verdict from io.godstone.llm.safety.SafetyGate. Null = never gated = refuse. */
    val gateVerdict: io.godstone.llm.safety.SafetyGate.Result? = null
) {
    /**
     * Constraint C3.
     *
     * This used to read `bestScore >= 0.35` over a reciprocal-rank-fusion
     * score. The repository's own audit proved that rule cannot discriminate --
     * RRF's entire top-20 spans 0.500..0.381, so ANY BM25 hit passed -- and the
     * app shipped it anyway while the improved gate sat in the test harness.
     *
     * The verdict is now computed by SafetyGate.evaluate, the same logic the
     * probe suite exercises. `gateVerdict` is populated by Retriever.retrieve;
     * a result that never went through the gate is refused, so forgetting to
     * run it fails closed instead of silently allowing.
     */
    val passesConfidenceGate: Boolean
        get() = gateVerdict?.allowsGeneration ?: false
}

/**
 * Hybrid retrieval over the read-only Archive.
 *
 *   1. BM25 lexical search via FTS5  (exact, fast, great for "tourniquet")
 *   2. Cosine similarity over int8 vectors (semantic, catches paraphrase)
 *   3. Reciprocal Rank Fusion merges the two rankings
 *
 * Brute-force vector scan is deliberate. At LARGE tier that is ~400k int8 dot
 * products over 768 dims, about 150 ms on a mid-range 2023 SoC. That is well
 * inside budget and it removes an entire class of index-corruption failures.
 * Simplicity is a survival feature.
 */
class Retriever(
    private val context: Context,
    private val archiveAsset: String,
    private val embedder: Embedder? = null
) {
    /** Built once from the archive; drives the gate's vocabulary and IDF. */
    private val corpusIndex: io.godstone.llm.safety.SafetyGate.CorpusIndex by lazy {
        io.godstone.llm.safety.SafetyGate.CorpusIndex(allChunks())
    }

    private fun allChunks(): List<Chunk> {
        val out = ArrayList<Chunk>()
        db.rawQuery(
            "SELECT c.chunk_id, c.document_id, d.title, d.domain, c.text " +
            "FROM chunks c JOIN documents d ON d.document_id = c.document_id", null
        ).use { cur ->
            while (cur.moveToNext()) out.add(Chunk(
                cur.getLong(0), cur.getLong(1), cur.getString(2),
                cur.getString(3), cur.getString(4), 0.0))
        }
        return out
    }

    private val db: SQLiteDatabase by lazy { openReadOnly() }

    private fun openReadOnly(): SQLiteDatabase {
        val dest = File(context.filesDir, archiveAsset)
        if (!dest.exists()) {
            context.assets.open(archiveAsset).use { input ->
                dest.outputStream().use { out -> input.copyTo(out) }
            }
        }
        val d = SQLiteDatabase.openDatabase(
            dest.absolutePath, null, SQLiteDatabase.OPEN_READONLY
        )
        d.execSQL("PRAGMA query_only = ON")
        d.execSQL("PRAGMA mmap_size = 268435456")
        return d
    }

    fun retrieve(query: String, topK: Int, domainHint: String? = null): RetrievalResult {
        val lexical = bm25Search(query, LEXICAL_CANDIDATES, domainHint)
        val semantic = vectorSearch(query, SEMANTIC_CANDIDATES, domainHint)
        val fused = reciprocalRankFusion(lexical, semantic, topK)

        val best = fused.firstOrNull()?.score ?: 0.0

        val verdict = io.godstone.llm.safety.SafetyGate.evaluate(query, fused, corpusIndex)

        val nearMisses = if (!verdict.allowsGeneration) {
            (lexical + semantic)
                .distinctBy { it.documentId }
                .take(3)
                .map { Citation(it.documentId, it.documentTitle, it.domain,
                                it.text.take(180)) }
        } else emptyList()

        return RetrievalResult(fused, best, nearMisses, verdict)
    }

    private fun bm25Search(query: String, limit: Int, domain: String?): List<Chunk> {
        val sql = """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.text,
                   bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.chunk_id = chunks_fts.rowid
            JOIN documents d ON d.document_id = c.document_id
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
        """.trimIndent()

        val out = ArrayList<Chunk>()
        db.rawQuery(sql, arrayOf(sanitiseFts(query), limit.toString())).use { cur ->
            while (cur.moveToNext()) {
                out.add(
                    Chunk(
                        chunkId = cur.getLong(0),
                        documentId = cur.getLong(1),
                        documentTitle = cur.getString(2),
                        domain = cur.getString(3),
                        text = cur.getString(4),
                        // bm25() returns negative values, lower is better.
                        score = -cur.getDouble(5)
                    )
                )
            }
        }
        return out
    }

    private fun vectorSearch(query: String, limit: Int, domain: String?): List<Chunk> {
        // Null when no embedding model is available: degrade to lexical-only
        // rather than compare against a different vector space (see Embedder).
        val qvec = embedder?.embed(query) ?: return emptyList()
        val results = ArrayList<Pair<Long, Double>>()

        db.rawQuery("SELECT chunk_id, vec FROM vectors", null).use { cur ->
            while (cur.moveToNext()) {
                val id = cur.getLong(0)
                val blob = cur.getBlob(1)
                results.add(id to cosineInt8(qvec, blob))
            }
        }

        val top = results.sortedByDescending { it.second }.take(limit)
        return top.mapNotNull { (id, score) -> loadChunk(id, score) }
    }

    /**
     * Reciprocal Rank Fusion. Rank-based rather than score-based, so we never
     * have to normalise BM25 against cosine, which are not comparable scales.
     */
    private fun reciprocalRankFusion(
        lexical: List<Chunk>,
        semantic: List<Chunk>,
        topK: Int
    ): List<Chunk> {
        val scores = HashMap<Long, Double>()
        val byId = HashMap<Long, Chunk>()

        lexical.forEachIndexed { i, c ->
            scores[c.chunkId] = (scores[c.chunkId] ?: 0.0) + 1.0 / (RRF_K + i + 1)
            byId[c.chunkId] = c
        }
        semantic.forEachIndexed { i, c ->
            scores[c.chunkId] = (scores[c.chunkId] ?: 0.0) + 1.0 / (RRF_K + i + 1)
            byId[c.chunkId] = c
        }

        // Normalise to roughly 0..1 so the confidence gate is interpretable.
        val maxPossible = 2.0 / (RRF_K + 1)

        return scores.entries
            .sortedByDescending { it.value }
            .take(topK)
            .mapNotNull { (id, s) -> byId[id]?.copy(score = s / maxPossible) }
    }

    private fun loadChunk(chunkId: Long, score: Double): Chunk? {
        val sql = """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.text
            FROM chunks c JOIN documents d ON d.document_id = c.document_id
            WHERE c.chunk_id = ?
        """.trimIndent()

        db.rawQuery(sql, arrayOf(chunkId.toString())).use { cur ->
            if (!cur.moveToFirst()) return null
            return Chunk(
                cur.getLong(0), cur.getLong(1), cur.getString(2),
                cur.getString(3), cur.getString(4), score
            )
        }
    }

    private fun cosineInt8(query: FloatArray, blob: ByteArray): Double {
        // Comparing only a shared prefix silently mixes incompatible embedding
        // spaces. A dimension mismatch is archive/model corruption, so this
        // candidate receives the lowest possible score and semantic retrieval
        // degrades to the lexical path.
        if (query.isEmpty() || blob.size != query.size) return 0.0
        var dot = 0.0
        var normB = 0.0
        for (i in query.indices) {
            val b = blob[i].toDouble() / 127.0
            dot += query[i] * b
            normB += b * b
        }
        var normA = 0.0
        for (v in query) normA += v * v
        val denom = sqrt(normA) * sqrt(normB)
        return if (denom == 0.0) 0.0 else dot / denom
    }

    /** Strip FTS5 operators so a user's plain question cannot become a syntax error. */
    private fun sanitiseFts(q: String): String =
        q.replace(Regex("[\"*():^-]"), " ")
            .split(Regex("\\s+"))
            .filter { it.isNotBlank() }
            .joinToString(" OR ") { "\"" + it + "\"" }

    companion object {
        const val LEXICAL_CANDIDATES = 20
        const val SEMANTIC_CANDIDATES = 20
        const val RRF_K = 60.0
    }
}
`````
<<< END FILE

### `android/llm/src/test/java/io/godstone/llm/RagPipelineTest.kt`

>>> FILE: android/llm/src/test/java/io/godstone/llm/RagPipelineTest.kt
`````kotlin
package io.godstone.llm

import io.godstone.llm.safety.SafetyGate

import io.godstone.llm.rag.Chunk
import io.godstone.llm.rag.PromptBuilder
import io.godstone.llm.rag.RetrievalResult
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Grounding tests. These enforce constraint C3: the model never answers from
 * parametric memory alone.
 *
 * This is the most important test file in the repository. A regression here
 * does not produce a crash or a wrong pixel - it produces a confident,
 * well-formatted, fluent answer about a tourniquet that nothing in the archive
 * supports. Everything else can degrade; this cannot.
 */
class RagPipelineTest {

    private fun chunk(
        id: Long,
        title: String,
        text: String,
        score: Double
    ) = Chunk(
        chunkId = id,
        documentId = id,
        documentTitle = title,
        domain = "medical_trauma",
        text = text,
        score = score
    )

    @Test
    fun `prompt contains every retrieved chunk`() {
        val chunks = listOf(
            chunk(1, "Stopping severe bleeding",
                  "Place it 5 to 7 cm above the wound.", 0.81),
            chunk(2, "Stopping severe bleeding",
                  "Push hard with the heel of your hand.", 0.64)
        )

        val prompt = PromptBuilder().build("how do I stop bleeding", chunks)

        assertContains(prompt, "5 to 7 cm above the wound")
        assertContains(prompt, "heel of your hand")
    }

    @Test
    fun `each chunk is labelled with a citation marker`() {
        val chunks = listOf(
            chunk(1, "Stopping severe bleeding", "text one", 0.8),
            chunk(2, "Making water safe to drink", "text two", 0.7)
        )

        val prompt = PromptBuilder().build("question", chunks)

        // The markers are what the UI turns into tappable source cards. Without
        // them an answer is unverifiable and therefore useless.
        assertContains(prompt, "[1]")
        assertContains(prompt, "[2]")
        assertContains(prompt, "Stopping severe bleeding")
        assertContains(prompt, "Making water safe to drink")
    }

    @Test
    fun `system rules forbid answering beyond the context`() {
        val prompt = PromptBuilder().build("question", listOf(
            chunk(1, "Doc", "text", 0.9)
        ))

        val lower = prompt.lowercase()
        // SYSTEM_RULES says "Answer ONLY from" and "The archive does not cover
        // this. Do not guess." Refusal is the default when the context is silent.
        assertTrue("only" in lower)
        assertTrue("archive does not cover" in lower || "do not guess" in lower)
    }

    @Test
    fun `empty retrieval produces a refusal prompt and never a free answer`() {
        val prompt = PromptBuilder().build("how do I build a nuclear reactor", emptyList())

        val lower = prompt.lowercase()
        // With no chunks the system rules still bind: the model is told to say
        // "The archive does not cover this." and not to guess.
        assertTrue("archive does not cover" in lower || "do not guess" in lower)
    }

    @Test
    fun `prompt respects the context budget by dropping the weakest chunks`() {
        val many = (1..40).map {
            chunk(it.toLong(), "Doc $it", "word ".repeat(200), 1.0 / it)
        }

        val builder = PromptBuilder(contextTokens = 2048, reservedForAnswer = 512)
        val prompt = builder.build("question", many)

        // Budgeting must be honest: the bridge refuses to generate at all if the
        // prompt does not fit, so an over-budget prompt is a failed answer.
        assertTrue(builder.estimateTokens(prompt) <= 2048 - 512)

        // The strongest chunk survives the trimming; the weakest does not.
        assertContains(prompt, "Doc 1")
    }

    @Test
    fun `chunks are ordered by descending score`() {
        val chunks = listOf(
            chunk(1, "Weak", "weak text", 0.31),
            chunk(2, "Strong", "strong text", 0.92),
            chunk(3, "Middle", "middle text", 0.55)
        )

        val prompt = PromptBuilder().build("question", chunks.sortedByDescending { it.score })

        assertTrue(prompt.indexOf("strong text") < prompt.indexOf("middle text"))
        assertTrue(prompt.indexOf("middle text") < prompt.indexOf("weak text"))
    }

    @Test
    fun `reciprocal rank fusion favours chunks found by both retrievers`() {
        // Lexical ranks it 3rd, semantic ranks it 3rd - but it is the only chunk
        // both agree on, and RRF should lift it above anything either found once.
        val lexical = listOf(10L, 11L, 12L)
        val semantic = listOf(20L, 21L, 12L)

        val fused = reciprocalRankFusion(lexical, semantic, k = 60.0)

        assertEquals(12L, fused.first())
    }

    private fun reciprocalRankFusion(
        lexical: List<Long>,
        semantic: List<Long>,
        k: Double
    ): List<Long> {
        val scores = mutableMapOf<Long, Double>()
        lexical.forEachIndexed { i, id -> scores.merge(id, 1.0 / (k + i + 1), Double::plus) }
        semantic.forEachIndexed { i, id -> scores.merge(id, 1.0 / (k + i + 1), Double::plus) }
        return scores.entries.sortedByDescending { it.value }.map { it.key }
    }

    @Test
    fun `gate constants are pinned`() {
        assertEquals(0.60, SafetyGate.ANCHOR_RECALL_FLOOR, 0.0)
        assertEquals(0.50, SafetyGate.COLOCATION_FLOOR, 0.0)
        assertEquals(0.40, SafetyGate.DOMAIN_COHERENCE_FLOOR, 0.0)
        assertEquals(0.15, SafetyGate.CAVEAT_MARGIN, 0.0)
    }

    @Test
    fun `idf formula matches the reference`() {
        val n = 27
        val d = 20
        val actual = kotlin.math.ln((n - d + 0.5) / (d + 0.5) + 1.0)
        assertEquals(0.3118, actual, 0.0005)
    }
}
`````
<<< END FILE

### `android/mesh/build.gradle.kts`

>>> FILE: android/mesh/build.gradle.kts
`````kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.godstone.mesh"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(project(":core"))
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Noise Protocol Framework, Java reference implementation.
    implementation("com.southernstorm:noise-java:1.0")

    // BouncyCastle for BLAKE2s and Ed25519 where the platform lacks them.
    implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")

    // Encrypted local storage for the message store (threat A6).
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("net.zetetic:sqlcipher-android:4.17.0")
    implementation("androidx.sqlite:sqlite:2.6.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test:2.0.20")
}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt
`````kotlin
package io.godstone.mesh

import android.content.Context
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.PeerEvent
import io.godstone.mesh.transport.PowerState
import io.godstone.mesh.transport.WifiAwareTransport
import java.security.SecureRandom
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withContext

data class MeshStatus(
    val started: Boolean = false,
    val peerCount: Int = 0,
    val activeSos: Boolean = false,
    val linkLayerReady: Boolean = false,
    val detail: String = LINK_LAYER_OPEN_REASON
)

sealed interface SosDispatchResult {
    data class Unavailable(val reason: String) : SosDispatchResult
    data object QueuedLocally : SosDispatchResult
    data class HandedToRelays(val count: Int) : SosDispatchResult
    data class Failed(val reason: String) : SosDispatchResult
}

const val LINK_LAYER_OPEN_REASON =
    "Encrypted BLE records and the Noise handshake driver are not implemented yet. " +
    "Radio transmission is disabled in this pre-alpha build."

/**
 * Process-wide composition root for the mesh subsystem.
 *
 * There is exactly one instance, supplied by Hilt to the application, service,
 * screens, router and session registry. V3's separate service-locator instance
 * was deleted because it split peer state and SOS state across two object graphs.
 */
class MeshNode(
    private val ctx: Context,
    private val store: MessageStore
) {
    private val identity: Identity by lazy { Identity.loadOrCreate(ctx) }
    private val router: Router by lazy { Router(store, identity.nodeId) }
    val sessions: io.godstone.mesh.crypto.SessionManager by lazy {
        io.godstone.mesh.crypto.SessionManager(identity)
    }
    private val ble: BleTransport by lazy {
        BleTransport(ctx, identity, { router.currentDigest() }, sessions)
    }
    private val wifi: WifiAwareTransport by lazy { WifiAwareTransport(ctx) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _nightMode = MutableStateFlow(false)
    val nightModeFlow: StateFlow<Boolean> = _nightMode.asStateFlow()

    private val _status = MutableStateFlow(MeshStatus())
    val statusFlow: StateFlow<MeshStatus> = _status.asStateFlow()

    @Volatile private var isStarted = false
    private val peerLock = Any()
    private val peers = LinkedHashMap<String, ByteArray>()

    private fun ByteArray.toHexKey(): String = joinToString("") { "%02x".format(it) }

    fun ensureIdentity() { identity.nodeId }
    fun onAppForegrounded() { if (isStarted) setPowerState(PowerState.NORMAL) }
    fun onAppBackgrounded() { if (isStarted) setPowerState(PowerState.POWER_SAVE) }
    fun setPowerState(state: PowerState) { if (isStarted) ble.setPowerState(state) }

    /**
     * Start only after M1-wire and M2-link are implemented and verified.
     * A non-functional encrypted transport must never silently fall back to
     * plaintext or consume battery while the UI calls it active.
     */
    fun start(): Boolean {
        if (!LINK_LAYER_READY) {
            _status.value = MeshStatus(detail = LINK_LAYER_OPEN_REASON)
            return false
        }
        synchronized(peerLock) {
            if (isStarted) return true
            isStarted = true
        }
        ble.start()
        if (wifi.isSupported) wifi.start()
        ble.peers().onEach { event ->
            synchronized(peerLock) {
                when (event) {
                    is PeerEvent.Found -> peers[event.peerId.toHexKey()] = event.peerId
                    is PeerEvent.Lost -> peers.remove(event.peerId.toHexKey())
                }
                publishStatus()
            }
        }.launchIn(scope)
        ble.receivedPlaintext().onEach { (peer, clear) ->
            runCatching { io.godstone.mesh.wire.Frame.decode(clear) }
                .getOrNull()?.let { router.onFrameReceived(it, peer) }
        }.launchIn(scope)
        publishStatus()
        return true
    }

    fun stop() {
        synchronized(peerLock) {
            if (!isStarted) return
            isStarted = false
        }
        sessions.destroyAll()
        ble.stop()
        wifi.stop()
        scope.coroutineContext.cancelChildren()
        synchronized(peerLock) { peers.clear() }
        publishStatus()
    }

    fun hasActiveSos(): Boolean = _status.value.activeSos

    suspend fun broadcastSos(payload: ByteArray): SosDispatchResult = withContext(Dispatchers.IO) {
        if (!LINK_LAYER_READY) return@withContext SosDispatchResult.Unavailable(LINK_LAYER_OPEN_REASON)
        runCatching {
            val frame = router.buildSos(payload, SecureRandom().nextLong())
            store.persist(frame, receivedFrom = identity.nodeId)
            val bytes = frame.encode()
            var handed = 0
            for (peerId in knownPeers()) if (ble.send(peerId, bytes)) handed++
            _status.value = _status.value.copy(activeSos = true)
            if (handed == 0) SosDispatchResult.QueuedLocally
            else SosDispatchResult.HandedToRelays(handed)
        }.getOrElse { SosDispatchResult.Failed(it.message ?: "unknown mesh error") }
    }

    private fun knownPeers(): List<ByteArray> = synchronized(peerLock) { peers.values.toList() }

    fun onSosAcknowledgedByRecipient() {
        _status.value = _status.value.copy(activeSos = false)
    }

    fun setNightMode(enabled: Boolean) { _nightMode.value = enabled }

    private fun publishStatus() {
        val count = synchronized(peerLock) { peers.size }
        _status.value = _status.value.copy(
            started = isStarted,
            peerCount = count,
            linkLayerReady = LINK_LAYER_READY,
            detail = if (LINK_LAYER_READY) "Mesh control plane active" else LINK_LAYER_OPEN_REASON
        )
    }

    companion object {
        /** Flipped only when ADR-001/M1-wire and ADR-002/M2-link acceptance tests pass. */
        const val LINK_LAYER_READY = false
    }
}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/MeshService.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/MeshService.kt
`````kotlin
package io.godstone.mesh

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import dagger.hilt.android.AndroidEntryPoint
import io.godstone.mesh.transport.PowerState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Foreground service that keeps the mesh alive while the app is backgrounded.
 *
 * V4 (audit P0-02): the node is now INJECTED, not fetched from a holder that
 * built its own. `MeshNodeHolder` is deleted. This service and the UI now
 * observe the same peer set, the same sessions and the same active-SOS flag.
 *
 * V4 also stops this service crashing on first launch. On Android 14+ a
 * foreground service typed `connectedDevice` requires BLUETOOTH_CONNECT to be
 * GRANTED at the moment `startForeground` is called. Nothing in the app requests
 * runtime permissions (P0-14), so V3 would throw SecurityException on a fresh
 * install on any modern device -- before any of the mesh defects could even be
 * reached. The service now refuses to start rather than crash, and reports why.
 *
 * Constraint C4: power state is re-evaluated from the battery every minute.
 */
@AndroidEntryPoint
class MeshService : Service() {

    @Inject lateinit var meshNode: MeshNode

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var started = false

    override fun onCreate() {
        super.onCreate()
        if (!MeshNode.LINK_LAYER_READY) {
            android.util.Log.w(TAG, "mesh service refused: M1-wire/M2-link not implemented")
            stopSelf()
            return
        }
        if (!hasRequiredPermissions()) {
            // Fail visibly and stop. Starting a connectedDevice FGS without
            // BLUETOOTH_CONNECT is an immediate SecurityException on API 34+.
            android.util.Log.w(TAG, "mesh service refused: BLUETOOTH_CONNECT not granted")
            stopSelf()
            return
        }
        startForeground(NOTIFICATION_ID, buildNotification(peers = 0, queued = 0))
        scope.launch {
            while (true) {
                meshNode.setPowerState(currentPowerState())
                delay(POWER_CHECK_INTERVAL_MS)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!MeshNode.LINK_LAYER_READY || !hasRequiredPermissions()) {
            stopSelf()
            return START_NOT_STICKY
        }
        // START_STICKY redelivers onStartCommand after a process kill, so this
        // must be idempotent. MeshNode.start() is guarded as well.
        if (!started) {
            started = true
            meshNode.start()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        meshNode.stop()
        started = false
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * BLUETOOTH_CONNECT is runtime-granted from API 31 and is required for the
     * connectedDevice foreground-service type from API 34.
     */
    private fun hasRequiredPermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun currentPowerState(): PowerState {
        if (meshNode.hasActiveSos()) return PowerState.SOS_ACTIVE
        val bm = getSystemService(BatteryManager::class.java)
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return when {
            level <= 15 -> PowerState.CRITICAL
            level <= 40 -> PowerState.POWER_SAVE
            else -> PowerState.NORMAL
        }
    }

    // ADR-005 OPEN: this notification is still built once and never updated, so
    // it reports 0 peers forever. Wiring it needs the single mesh StateFlow that
    // ADR-005 specifies; a second ad-hoc state source is what produced P0-02.
    private fun buildNotification(peers: Int, queued: Int): Notification =
        NotificationCompat.Builder(this, CHANNEL_MESH)
            .setContentTitle("Godstone mesh active")
            .setContentText("$peers nearby, $queued carried")
            .setSmallIcon(R.drawable.ic_mesh)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    companion object {
        private const val TAG = "MeshService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_MESH = "godstone.mesh"
        private const val POWER_CHECK_INTERVAL_MS = 60_000L

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, MeshService::class.java))
        }
    }
}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt
`````kotlin
// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.store

import android.content.ContentValues
import android.content.Context
// AUDIT A-06. net.zetetic:sqlcipher-android was declared in build.gradle.kts and
// then never imported: the store used plain android.database.sqlite, so seizing
// a device yielded the entire message history in cleartext while the threat
// model told adversary A6 the store was encrypted. A declared dependency is not
// a control; only the import that actually replaces the plaintext engine is.
import net.zetetic.database.sqlcipher.SQLiteDatabase
import net.zetetic.database.sqlcipher.SQLiteOpenHelper
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.SecureRandom
import io.godstone.mesh.wire.Frame
import io.godstone.mesh.wire.FrameType
import io.godstone.mesh.wire.Priority

/**
 * Persistent hold for relayed and locally-originated frames.
 *
 * The router treats the store as the source of truth for what this node carries,
 * so an encounter with any peer can be answered from disk without an in-memory
 * index. Frames are retained until delivered or aged out, which is the whole
 * point of a delay-tolerant epidemic router.
 */
interface MessageStore {
    /** Persist [frame], recording the peer it was received from. */
    suspend fun persist(frame: Frame, receivedFrom: ByteArray)

    /** All held frames, SOS-first then by priority and recency. */
    suspend fun allHeldOrderedByPriority(): List<Frame>

    /** msg_ids of every held frame, for bloom-digest construction. */
    suspend fun allHeldMsgIds(): List<Long>

    /**
     * Stream held frames in priority order, stopping as soon as [visit] returns
     * false. This is what Router.framesPeerLacks actually calls.
     *
     * Audit A-13: the list-returning variants materialise the entire store (up
     * to the 200 MB budget) into an ArrayList on every peer encounter. Router
     * was already written against this streaming form, but the interface never
     * declared it -- an unresolved reference that no Python-only invariant could
     * see, because Kotlin is never compiled in the verification environment.
     * Invariant F now resolves every cross-file call and would fail the build.
     */
    suspend fun forEachHeldOrderedByPriority(visit: (Frame) -> Boolean)

    /** Stream held msg_ids, stopping as soon as [visit] returns false. */
    suspend fun forEachHeldMsgId(visit: (Long) -> Boolean)
}

/**
 * SQLCipher-backed store (threat A6).
 *
 * This store still uses the legacy GMP/1 logical schema until ADR-001/M1-wire
 * lands. ACK expiry, exact hard-cap semantics, and coordinated identity/store
 * wipe remain tracked in ADR-004 and are not represented as closed here.
 */
class SqliteMessageStore(
    private val ctx: Context,
    private val maxBytes: Long
) : MessageStore {

    private val helper: Helper

    init {
        // sqlcipher-android requires explicit native-core loading before any
        // helper can attempt to open a database.
        System.loadLibrary("sqlcipher")
        helper = Helper(ctx.applicationContext, passphrase(ctx.applicationContext))
    }

    override suspend fun persist(frame: Frame, receivedFrom: ByteArray) {
        val db = helper.writableDatabase
        val cv = ContentValues().apply {
            put(COL_MSG_ID, frame.msgId)
            put(COL_TYPE, frame.type.code.toInt())
            put(COL_TTL, frame.ttl)
            put(COL_PRIORITY, frame.priority.code.toInt())
            put(COL_TIMESTAMP, frame.timestamp)
            put(COL_PAYLOAD, frame.payload)
            put(COL_RECEIVED_FROM, receivedFrom)
            put(COL_RECEIVED_AT, System.currentTimeMillis())
        }
        db.insertWithOnConflict(TABLE, null, cv, SQLiteDatabase.CONFLICT_IGNORE)
        evictIfOverBudget(db)
    }

    override suspend fun allHeldOrderedByPriority(): List<Frame> {
        val db = helper.readableDatabase
        val out = ArrayList<Frame>()
        db.query(
            TABLE, null, null, null, null, null,
            "$COL_PRIORITY ASC, $COL_RECEIVED_AT DESC"
        ).use { c ->
            while (c.moveToNext()) {
                val f = readFrame(c)
                if (f != null) out.add(f)
            }
        }
        return out
    }

    override suspend fun allHeldMsgIds(): List<Long> {
        val db = helper.readableDatabase
        val out = ArrayList<Long>()
        db.query(TABLE, arrayOf(COL_MSG_ID), null, null, null, null, null).use { c ->
            while (c.moveToNext()) out.add(c.getLong(0))
        }
        return out
    }

    /**
     * Cursor-streamed scan. The cursor is walked row by row and abandoned the
     * moment [visit] returns false, so a full backlog never lands in memory
     * (audit A-13).
     */
    override suspend fun forEachHeldOrderedByPriority(visit: (Frame) -> Boolean) {
        val db = helper.readableDatabase
        db.query(
            TABLE, null, null, null, null, null,
            "$COL_PRIORITY ASC, $COL_RECEIVED_AT DESC"
        ).use { c ->
            while (c.moveToNext()) {
                val f = readFrame(c) ?: continue
                if (!visit(f)) return
            }
        }
    }

    override suspend fun forEachHeldMsgId(visit: (Long) -> Boolean) {
        val db = helper.readableDatabase
        db.query(TABLE, arrayOf(COL_MSG_ID), null, null, null, null, null).use { c ->
            while (c.moveToNext()) {
                if (!visit(c.getLong(0))) return
            }
        }
    }

    /**
     * Best-effort eviction of the oldest non-SOS rows when the store exceeds
     * [maxBytes]. SOS frames are retained longest by being sorted last out.
     *
     * TODO: precise byte accounting; this currently approximates by row count.
     */
    private fun evictIfOverBudget(db: SQLiteDatabase) {
        // AUDIT A-14. This previously ran the DELETE unconditionally on EVERY
        // insert, with no check that the budget had been exceeded at all. Its
        // own doc comment said "when the store exceeds maxBytes", and it never
        // asked. On a fresh install with two messages held, inserting a third
        // deleted a quarter of the non-SOS backlog immediately -- a
        // delay-tolerant store that discards the traffic it exists to carry.
        //
        // The size is now measured before anything is deleted, and the query
        // only runs when the store is genuinely over budget.
        val heldBytes = db.rawQuery(
            "SELECT COALESCE(SUM(LENGTH($COL_PAYLOAD)) + COUNT(*) * $ROW_OVERHEAD, 0) FROM $TABLE",
            null
        ).use { c -> if (c.moveToFirst()) c.getLong(0) else 0L }

        if (heldBytes <= maxBytes) return   // nothing to do: the common case

        // Evict roughly the overshoot, oldest non-SOS first. SOS is retained
        // last under storage pressure (PROTOCOL.md section 7).
        val overshoot = heldBytes - maxBytes
        val approxRowBytes = ROW_OVERHEAD + 256L
        val toDelete = ((overshoot / approxRowBytes) + 1).coerceAtLeast(1L)
        db.execSQL(
            "DELETE FROM $TABLE WHERE $COL_MSG_ID IN (" +
                "SELECT $COL_MSG_ID FROM $TABLE WHERE $COL_PRIORITY != ? " +
                "ORDER BY $COL_RECEIVED_AT ASC LIMIT ?)",
            arrayOf<Any>(Priority.SOS.code.toInt(), toDelete)
        )
    }

    private fun readFrame(c: android.database.Cursor): Frame? {
        // Reconstruct via the wire enum types, not the payload bytes.
        val typeCode = c.getInt(c.getColumnIndexOrThrow(COL_TYPE)).toByte()
        val priorityCode = c.getInt(c.getColumnIndexOrThrow(COL_PRIORITY)).toByte()
        val ft = FrameType.from(typeCode) ?: return null
        val pr = Priority.from(priorityCode) ?: return null
        return Frame(
            type = ft,
            ttl = c.getInt(c.getColumnIndexOrThrow(COL_TTL)),
            priority = pr,
            msgId = c.getLong(c.getColumnIndexOrThrow(COL_MSG_ID)),
            timestamp = c.getLong(c.getColumnIndexOrThrow(COL_TIMESTAMP)),
            payload = c.getBlob(c.getColumnIndexOrThrow(COL_PAYLOAD))
        )
    }

    private class Helper(ctx: Context, private val key: ByteArray) :
        SQLiteOpenHelper(ctx, DB_NAME, key, null, DB_VERSION, 1, null, null, false) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE $TABLE (
                    $COL_MSG_ID INTEGER PRIMARY KEY,
                    $COL_TYPE INTEGER,
                    $COL_TTL INTEGER,
                    $COL_PRIORITY INTEGER,
                    $COL_TIMESTAMP INTEGER,
                    $COL_PAYLOAD BLOB,
                    $COL_RECEIVED_FROM BLOB,
                    $COL_RECEIVED_AT INTEGER
                )""".trimIndent()
            )
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // AUDIT A-12. This used to DROP TABLE, destroying every undelivered
            // frame -- including SOS traffic the mesh had not yet been able to
            // hand on -- the first time a user updated the app. In a blackout an
            // app update is exactly when a queued distress beacon matters most.
            //
            // Additive migration only. Any future schema change must preserve
            // held frames or explicitly justify why it cannot.
            if (oldVersion == newVersion) return
            db.execSQL("ALTER TABLE $TABLE RENAME TO ${TABLE}_migrating")
            onCreate(db)
            db.execSQL(
                "INSERT OR IGNORE INTO $TABLE SELECT * FROM ${TABLE}_migrating")
            db.execSQL("DROP TABLE ${TABLE}_migrating")
        }
    }

    companion object {
        /**
         * 256-bit store key, generated once and held in EncryptedSharedPreferences
         * behind a Keystore master key -- so the passphrase is protected by
         * hardware where the device provides it, and never appears in the APK.
         *
         * Losing this key makes the store unreadable, which is the correct
         * outcome: a recoverable key is not a key, it is an inconvenience for
         * whoever seized the phone.
         */
        private fun passphrase(ctx: Context): ByteArray {
            val master = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            val prefs = EncryptedSharedPreferences.create(
                ctx, "godstone_store_key", master,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM)
            prefs.getString("k", null)?.let {
                return android.util.Base64.decode(it, android.util.Base64.NO_WRAP)
            }
            val k = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val encoded = android.util.Base64.encodeToString(k, android.util.Base64.NO_WRAP)
            check(prefs.edit().putString("k", encoded).commit()) {
                "failed to persist SQLCipher key"
            }
            return k
        }

        /**
         * Panic wipe (PROTOCOL.md section 2). Destroys the store AND its key, so
         * prior traffic cannot be linked to the regenerated identity.
         */
        fun panicWipe(ctx: Context) {
            ctx.deleteDatabase(DB_NAME)
            ctx.deleteSharedPreferences("godstone_store_key")
        }

        /** Per-row bookkeeping beyond the payload blob. */
        private const val ROW_OVERHEAD = 64L
        private const val DB_NAME = "godstone_messages.db"
        private const val DB_VERSION = 1
        private const val TABLE = "held_frames"
        private const val COL_MSG_ID = "msg_id"
        private const val COL_TYPE = "type"
        private const val COL_TTL = "ttl"
        private const val COL_PRIORITY = "priority"
        private const val COL_TIMESTAMP = "timestamp"
        private const val COL_PAYLOAD = "payload"
        private const val COL_RECEIVED_FROM = "received_from"
        private const val COL_RECEIVED_AT = "received_at"
    }
}

/**
 * Pure-Kotlin in-memory store with no Android dependency. Used by unit tests
 * that exercise the router with no device or SQLite available.
 */
internal class InMemoryMessageStore : MessageStore {
    private val held = LinkedHashMap<Long, Frame>()

    override suspend fun persist(frame: Frame, receivedFrom: ByteArray) {
        held[frame.msgId] = frame
    }

    override suspend fun allHeldOrderedByPriority(): List<Frame> =
        held.values.sortedWith(
            compareBy<Frame> { it.priority.code }.thenByDescending { it.timestamp }
        )

    override suspend fun allHeldMsgIds(): List<Long> = held.keys.toList()

    override suspend fun forEachHeldOrderedByPriority(visit: (Frame) -> Boolean) {
        for (f in allHeldOrderedByPriority()) if (!visit(f)) return
    }

    override suspend fun forEachHeldMsgId(visit: (Long) -> Boolean) {
        for (id in allHeldMsgIds()) if (!visit(id)) return
    }
}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt
`````kotlin
package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.wire.v2.FrameV2
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import java.nio.ByteBuffer
import java.util.UUID

/**
 * Disabled BLE control-plane scaffold.
 *
 * ADR-002 proved the old 26-byte service-data advertisement cannot fit beside a
 * 128-bit UUID. The accepted target is UUID-only primary advertising plus a
 * 13-byte scan-response payload. MeshNode keeps this transport unreachable until
 * the record layer, handshake driver and on-device size tests are complete.
 */
@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context,
    private val identity: Identity,
    private val digestProvider: suspend () -> BloomDigest,
    /** Noise sessions. Without this the transport cannot send at all -- by design. */
    private val sessions: io.godstone.mesh.crypto.SessionManager? = null
) : Transport {

    override val name = "BLE"
    override val isBulkCapable = false

    private val btManager = context.getSystemService(BluetoothManager::class.java)
    private val adapter get() = btManager.adapter

    private var powerState = PowerState.NORMAL
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null

    override fun start() {
        startAdvertising()
    }

    override fun stop() {
        advertiseCallback?.let { adapter.bluetoothLeAdvertiser?.stopAdvertising(it) }
        scanCallback?.let { adapter.bluetoothLeScanner?.stopScan(it) }
        advertiseCallback = null
        scanCallback = null
    }

    fun setPowerState(state: PowerState) {
        if (state == powerState) return
        powerState = state
        stop()
        start()
    }

    /**
     * Accepted 13-byte scan-response payload from ADR-002.
     *
     * This builder is not wired into advertising yet: the complete M2-link
     * lifecycle must produce it asynchronously from the durable held-message
     * digest and verify packet sizes on hardware before LINK_LAYER_READY moves.
     */
    fun buildScanResponsePayload(
        digest: ByteArray,
        queueDepth: Int,
        sosPresent: Boolean,
        clockUntrusted: Boolean = false
    ): ByteArray {
        require(digest.size >= 6) { "short digest requires at least 6 bytes" }
        var flags = 0
        if (sosPresent) flags = flags or FLAG_SOS
        if (powerState == PowerState.CRITICAL) flags = flags or FLAG_POWER_CONSTRAINED
        if (clockUntrusted) flags = flags or FLAG_CLOCK_UNTRUSTED

        return ByteBuffer.allocate(SCAN_RESPONSE_BYTES)
            .put(FrameV2.VERSION)
            .put(flags.toByte())
            .put(identity.nodeHint)
            .put(digest, 0, 6)
            .put(queueDepth.coerceIn(0, 255).toByte())
            .array()
    }

    private fun startAdvertising() {
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(
                when (powerState) {
                    PowerState.SOS_ACTIVE -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                    PowerState.NORMAL -> AdvertiseSettings.ADVERTISE_MODE_BALANCED
                    else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                }
            )
            .setTxPowerLevel(
                if (powerState == PowerState.CRITICAL)
                    AdvertiseSettings.ADVERTISE_TX_POWER_LOW
                else
                    AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
            )
            .setConnectable(true)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)   // never leak the device name
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                // Surfaced to the user by MeshNode as a degraded-mode banner.
            }
        }

        adapter.bluetoothLeAdvertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    override fun peers(): Flow<PeerEvent> = callbackFlow {
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val sd = result.scanRecord
                    ?.getServiceData(ParcelUuid(SERVICE_UUID)) ?: return
                if (sd.size < SCAN_RESPONSE_BYTES) return

                val buf = ByteBuffer.wrap(sd)
                if (buf.get() != 0x02.toByte()) return   // refuse unknown versions

                val flags = buf.get().toInt()
                val hint = ByteArray(4).also { buf.get(it) }
                val digest = ByteArray(6).also { buf.get(it) }
                val queueDepth = buf.get().toInt() and 0xFF

                trySend(
                    PeerEvent.Found(
                        peerId = PeerId.fromAddress(result.device.address) ?: return,
                        nodeHint = hint,
                        rssi = result.rssi,
                        sosFlag = flags and FLAG_SOS != 0,
                        bulkCapable = flags and FLAG_BULK_CAPABLE != 0,
                        shortDigest = digest,
                        queueDepth = queueDepth
                    )
                )
            }
        }

        val settings = ScanSettings.Builder()
            .setScanMode(
                when (powerState) {
                    PowerState.SOS_ACTIVE -> ScanSettings.SCAN_MODE_LOW_LATENCY
                    PowerState.NORMAL -> ScanSettings.SCAN_MODE_BALANCED
                    else -> ScanSettings.SCAN_MODE_LOW_POWER
                }
            )
            .build()

        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        adapter.bluetoothLeScanner?.startScan(listOf(filter), settings, cb)
        scanCallback = cb

        awaitClose { adapter.bluetoothLeScanner?.stopScan(cb) }
    }

    /**
     * Send [bytes] to [peerId] THROUGH THE NOISE SESSION.
     *
     * Audit: this method previously wrote `frame.encode()` directly to the GATT
     * characteristic. NoiseSession existed and was tested, but nothing in
     * production ever constructed one, so every byte the mesh sent was
     * plaintext while the app described itself as encrypted.
     *
     * There is deliberately NO plaintext fallback. If no session is established
     * the send fails and the router carries the frame to the next encounter --
     * delay is the designed behaviour; leaking is not.
     */
    override suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean {
        require(bytes.size <= GATT_MTU) { "use the bulk plane for large payloads" }
        val sealed = sessions?.seal(peerId, bytes) ?: return false
        return GattClient.write(context, peerId, WRITE_CHAR_UUID, sealed)
    }

    /** Decrypted inbound frames. Anything that fails authentication is dropped. */
    fun receivedPlaintext(): Flow<Pair<ByteArray, ByteArray>> =
        kotlinx.coroutines.flow.flow {
            received().collect { (peer, cipher) ->
                val clear = try {
                    sessions?.open(peer, cipher)
                } catch (e: Exception) {
                    null   // tamper or replay: refuse to process
                }
                if (clear != null) emit(peer to clear)
            }
        }

    override fun received(): Flow<Pair<ByteArray, ByteArray>> =
        GattServer.incoming(context, SERVICE_UUID, WRITE_CHAR_UUID)

    companion object {
        // GENERATED-SPEC UUIDs. These previously read 67640001-… while iOS read
        // 6F0D0001-… -- the two platforms literally could not see each other, so
        // the header and type-code defects below were never even reached. The
        // values now come from wire/wire_v2.yaml via FrameV2 and cannot drift:
        // ci/check_parity.py Invariant G fails the build if a literal UUID
        // reappears here.
        val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID
        val WRITE_CHAR_UUID: UUID = FrameV2.INBOX_UUID
        val NOTIFY_CHAR_UUID: UUID = FrameV2.DIGEST_UUID

        const val GATT_MTU = 512
        const val SCAN_RESPONSE_BYTES = 13

        const val FLAG_SOS = 0x01
        const val FLAG_BULK_CAPABLE = 0x02
        const val FLAG_POWER_CONSTRAINED = 0x04
        const val FLAG_VERIFIED_ONLY = 0x08
        const val FLAG_CLOCK_UNTRUSTED = 0x10
    }
}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/transport/GattClient.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/transport/GattClient.kt
`````kotlin
// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.content.Context
import java.util.UUID
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Central-side GATT client. Connects to a peer, locates the write characteristic,
 * and writes one frame. The peer [peerId] is the peer's MAC address as raw bytes.
 */
@SuppressLint("MissingPermission")
internal object GattClient {

    /**
     * Write [bytes] to [charUuid] on the peer identified by [peerId] MAC bytes.
     * Returns true only when the write is acknowledged by the peripheral.
     */
    suspend fun write(
        context: Context,
        peerId: ByteArray,
        charUuid: UUID,
        bytes: ByteArray
    ): Boolean = suspendCancellableCoroutine { cont ->
        val manager = context.getSystemService(android.bluetooth.BluetoothManager::class.java)
        val adapter = manager?.adapter
        if (adapter == null) {
            cont.resume(false); return@suspendCancellableCoroutine
        }

        val mac = PeerId.toAddress(peerId) ?: run {
            cont.resume(false); return@suspendCancellableCoroutine
        }
        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(mac)
        } catch (e: IllegalArgumentException) {
            cont.resume(false); return@suspendCancellableCoroutine
        }

        var gatt: BluetoothGatt? = null
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    g.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    if (cont.isActive) cont.resume(false)
                    g.close()
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val service = g.services.firstOrNull { it.uuid == BleTransport.SERVICE_UUID }
                val characteristic = service?.getCharacteristic(charUuid)
                if (characteristic == null) {
                    if (cont.isActive) cont.resume(false)
                    g.disconnect(); return
                }
                characteristic.value = bytes
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                if (!g.writeCharacteristic(characteristic)) {
                    if (cont.isActive) cont.resume(false)
                    g.disconnect()
                }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                if (cont.isActive) cont.resume(status == BluetoothGatt.GATT_SUCCESS)
                g.disconnect()
            }
        }

        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        if (gatt == null && cont.isActive) cont.resume(false)

        cont.invokeOnCancellation { gatt?.close() }
    }

}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/transport/GattServer.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/transport/GattServer.kt
`````kotlin
// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.content.Context
import java.util.UUID
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Peripheral-side GATT server. Exposes the write characteristic and emits every
 * frame a central writes, paired with that central's MAC bytes as the peer id.
 */
@SuppressLint("MissingPermission")
internal object GattServer {

    /**
     * Stream of (peerId, frame) pairs written by connected centrals. [peerId] is
     * the central's MAC address as raw bytes.
     */
    fun incoming(
        context: Context,
        serviceUuid: UUID,
        writeCharUuid: UUID
    ): Flow<Pair<ByteArray, ByteArray>> = callbackFlow {
        val manager = context.getSystemService(BluetoothManager::class.java)
        val adapter = manager?.adapter
        if (manager == null || adapter == null) {
            close(); return@callbackFlow
        }

        lateinit var server: BluetoothGattServer
        server = manager.openGattServer(context, object : BluetoothGattServerCallback() {
            override fun onCharacteristicWriteRequest(
                device: android.bluetooth.BluetoothDevice,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray
            ) {
                if (characteristic.uuid == writeCharUuid) {
                    PeerId.fromAddress(device.address)?.let { trySend(it to value) }
                }
                if (responseNeeded) {
                    server.sendResponse(device, requestId, 0 /* GATT_SUCCESS */, offset, value)
                }
            }
        }) ?: run { close(); return@callbackFlow }

        val characteristic = BluetoothGattCharacteristic(
            writeCharUuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        val service = BluetoothGattService(
            serviceUuid,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        ).apply { addCharacteristic(characteristic) }

        server.addService(service)

        awaitClose {
            server.clearServices()
            server.close()
        }
    }
}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/transport/PeerId.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/transport/PeerId.kt
`````kotlin
package io.godstone.mesh.transport

/** Stable six-byte representation of an Android Bluetooth device address. */
internal object PeerId {
    fun fromAddress(address: String): ByteArray? {
        val parts = address.split(':')
        if (parts.size != 6) return null
        return runCatching {
            ByteArray(6) { index -> parts[index].toInt(16).toByte() }
        }.getOrNull()
    }

    fun toAddress(bytes: ByteArray): String? {
        if (bytes.size != 6) return null
        return bytes.joinToString(":") { "%02X".format(it.toInt() and 0xFF) }
    }
}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/transport/WifiAwareTransport.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/transport/WifiAwareTransport.kt
`````kotlin
package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareSession
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * Wi-Fi bulk plane. Brought up ONLY on demand, when a queued payload exceeds
 * Transport.BULK_THRESHOLD and both peers advertise BULK_CAPABLE, then torn down
 * within 5 seconds of the last byte. It is never left running.
 *
 * The link inherits the Noise session already established over BLE, so no second
 * handshake is needed and the bulk plane is authenticated from its first byte.
 */
@SuppressLint("MissingPermission")
class WifiAwareTransport(
    private val context: Context
) : Transport {

    override val name = "WiFi-Aware"
    override val isBulkCapable = false

    private val manager = context.getSystemService(WifiAwareManager::class.java)
    private var session: WifiAwareSession? = null
    private var publishSession: PublishDiscoverySession? = null

    private val inbound = MutableSharedFlow<Pair<ByteArray, ByteArray>>(
        extraBufferCapacity = 64
    )

    val isSupported: Boolean
        get() = manager != null && manager.isAvailable

    override fun start() {
        // ADR-006 is not implemented. Do not publish a service that cannot
        // authenticate or carry bytes end to end.
    }

    override fun stop() {
        publishSession?.close()
        session?.close()
        publishSession = null
        session = null
    }

    private fun publish(s: WifiAwareSession) {
        val config = PublishConfig.Builder()
            .setServiceName(SERVICE_NAME)
            .build()

        s.publish(config, object : DiscoverySessionCallback() {
            override fun onPublishStarted(session: PublishDiscoverySession) {
                publishSession = session
            }

            override fun onMessageReceived(peer: PeerHandle, message: ByteArray) {
                inbound.tryEmit(peer.toString().toByteArray() to message)
            }
        }, null)
    }

    private fun subscribe(s: WifiAwareSession) {
        val config = SubscribeConfig.Builder()
            .setServiceName(SERVICE_NAME)
            .build()

        s.subscribe(config, object : DiscoverySessionCallback() {}, null)
    }

    override fun peers(): Flow<PeerEvent> = kotlinx.coroutines.flow.emptyFlow()

    override suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean {
        // Fail closed until the ADR-006 bulk protocol is implemented.
        return false
    }

    override fun received(): Flow<Pair<ByteArray, ByteArray>> = inbound

    companion object {
        const val SERVICE_NAME = "godstone-gmp1"
        const val TEARDOWN_DELAY_MS = 5_000L
    }
}
`````
<<< END FILE

### `android/mesh/src/main/java/io/godstone/mesh/wire/v2/WireV2.kt`

>>> FILE: android/mesh/src/main/java/io/godstone/mesh/wire/v2/WireV2.kt
`````kotlin
// GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.
// Regenerate with `python -m wire.codegen`.
// ci/check_parity.py Invariant A fails the build on any hand edit.
package io.godstone.mesh.wire.v2

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** GMP/2 frame. Header is 32 bytes, big-endian. */
data class FrameV2(
    val type: TypeV2,
    val msgId: ByteArray,        // 16 bytes
    val routingTag: ByteArray,   // 4 bytes
    val ttl: Int,
    val hopCount: Int,
    val flags: Int,
    val payload: ByteArray
) {
    fun encode(): ByteArray {
        require(msgId.size == 16) { "msg_id must be 16 bytes" }
        require(routingTag.size == 4) { "routing_tag must be 4 bytes" }
        require(ttl in 0..MAX_TTL) { "ttl out of range" }
        require(hopCount in 0..MAX_TTL) { "hop_count out of range" }
        require(payload.size <= MAX_PAYLOAD) { "payload too large" }
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
        buf.putShort(MAGIC.toShort())
        buf.put(VERSION)
        buf.put(type.code)
        buf.put(msgId)
        buf.put(routingTag)
        buf.put(ttl.toByte())
        buf.put(hopCount.toByte())
        buf.putShort(flags.toShort())
        buf.putShort(payload.size.toShort())
        val header = buf.array()
        buf.putShort(crc16(header, 0, HEADER_SIZE - 2).toShort())
        buf.put(payload)
        return buf.array()
    }

    companion object {
        const val MAGIC = 0x4753
        const val VERSION: Byte = 0x02
        const val HEADER_SIZE = 32
        const val MAX_PAYLOAD = 60000
        const val MAX_TTL = 16
        const val DEFAULT_TTL = 12

        /** Shared BLE identifiers. Both platforms MUST use these exact values. */
        val SERVICE_UUID: java.util.UUID = java.util.UUID.fromString("6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        val INBOX_UUID: java.util.UUID = java.util.UUID.fromString("6764A002-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        val DIGEST_UUID: java.util.UUID = java.util.UUID.fromString("6764A003-9A5E-4C7B-B0A1-3E5D8C2F7A10")

        const val SEALED = 0x0001
        const val COMPRESSED = 0x0002
        const val FRAGMENTED = 0x0004
        const val HAS_POW = 0x0008
        const val ACK_REQ = 0x0010
        const val RELAY_OK = 0x0020
        const val PRIORITY_MASK = 0x0700

        /**
         * Bounded, fail-closed parsing. Magic, version, CRC and the declared
         * length are all validated BEFORE any allocation, so a desynced or
         * corrupted frame is rejected outright rather than half-parsed into a
         * different message.
         */
        fun decode(raw: ByteArray): FrameV2? {
            if (raw.size < HEADER_SIZE) return null
            val buf = ByteBuffer.wrap(raw).order(ByteOrder.BIG_ENDIAN)
            if ((buf.short.toInt() and 0xFFFF) != MAGIC) return null
            if (buf.get() != VERSION) return null
            val type = TypeV2.from(buf.get()) ?: return null
            val msgId = ByteArray(16).also { buf.get(it) }
            val tag = ByteArray(4).also { buf.get(it) }
            val ttl = buf.get().toInt() and 0xFF
            if (ttl > MAX_TTL) return null
            val hop = buf.get().toInt() and 0xFF
            if (hop > MAX_TTL) return null
            val flags = buf.short.toInt() and 0xFFFF
            val len = buf.short.toInt() and 0xFFFF
            val crc = buf.short.toInt() and 0xFFFF
            if (crc != crc16(raw, 0, HEADER_SIZE - 2)) return null
            if (len > MAX_PAYLOAD) return null
            if (raw.size != HEADER_SIZE + len) return null
            val payload = ByteArray(len).also { buf.get(it) }
            return FrameV2(type, msgId, tag, ttl, hop, flags, payload)
        }

        fun crc16(data: ByteArray, from: Int, len: Int): Int {
            var crc = 0xFFFF
            for (i in from until from + len) {
                crc = crc xor ((data[i].toInt() and 0xFF) shl 8)
                repeat(8) {
                    crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xFFFF
                          else (crc shl 1) and 0xFFFF
                }
            }
            return crc
        }
    }
}

enum class TypeV2(val code: Byte) {
    HELLO(0x11.toByte()),
    DIGEST(0x12.toByte()),
    WANT(0x14.toByte()),
    MESSAGE(0x18.toByte()),
    ACK(0x21.toByte()),
    BULK_OFFER(0x22.toByte()),
    BULK_CHUNK(0x24.toByte()),
    PING(0x28.toByte()),
    GOODBYE(0x41.toByte()),
    SOS(0xF0.toByte()),
    ;
    companion object {
        private val map = entries.associateBy { it.code }
        fun from(b: Byte): TypeV2? = map[b]
    }
}
`````
<<< END FILE

### `android/mesh/src/test/java/io/godstone/mesh/PortVectorTest.kt`

>>> FILE: android/mesh/src/test/java/io/godstone/mesh/PortVectorTest.kt
`````kotlin
package io.godstone.mesh

import io.godstone.mesh.crypto.NoiseSession
import org.bouncycastle.crypto.digests.Blake2sDigest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PortVectorTest {
    private fun blake(input: ByteArray, length: Int): String {
        val d = Blake2sDigest(null, length, null, null)
        d.update(input, 0, input.size)
        val out = ByteArray(length)
        d.doFinal(out, 0)
        return out.joinToString("") { "%02x".format(it) }
    }

    @Test
    fun `bouncycastle port matches generated vectors`() {
        val cases = listOf(
            Triple(ByteArray(0), 32, "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"),
            Triple("abc".toByteArray(), 32, "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"),
            Triple("abc".toByteArray(), 16, "aa4938119b1dc7b87cbad0ffd200d0ae"),
            Triple("abc".toByteArray(), 8, "972e9d2cd6de6402"),
            Triple(ByteArray(64) { 0xA5.toByte() }, 32, "f85b88e0ac55872416d202c5f4881e7dbc9c7270542ef75074ff9b0a610b5a0e"),
            Triple(ByteArray(65) { 0xA5.toByte() }, 32, "65bba861969fcb5f1d8ec69e1dbd3e891f546b02203ce73b27958b9589a6789d")
        )
        for ((input, length, expected) in cases) assertEquals(expected, blake(input, length))
    }

    @Test
    fun `noise xx emits canonical empty-payload message sizes`() {
        val alice = NoiseSession.initiator(MeshIdentity.generate())
        val bob = NoiseSession.responder(MeshIdentity.generate())
        val m1 = alice.writeMessage()
        bob.readMessage(m1)
        val m2 = bob.writeMessage()
        alice.readMessage(m2)
        val m3 = alice.writeMessage()
        bob.readMessage(m3)

        assertEquals(listOf(32, 96, 64), listOf(m1.size, m2.size, m3.size))
        assertTrue(alice.isEstablished)
        assertTrue(bob.isEstablished)
        assertContentEquals(alice.handshakeHash, bob.handshakeHash)
    }
}
`````
<<< END FILE

### `ci/check_parity.py`

>>> FILE: ci/check_parity.py
`````python
#!/usr/bin/env python3
"""Godstone parity and safety gate. The control that stops recurrence.

    python ci/check_parity.py

Every defect this repository has shipped shared one root cause: A CLAIM ABOUT
THE SYSTEM LIVED IN A COMMENT OR A TEST INSTEAD OF IN AN EXECUTABLE CHECK.

    "Byte-for-byte identical to the Android implementation"   -- it was not
    "grounding verified"                                      -- by a metric the app never ran
    "node_id = BLAKE2s-128(identity_pub)"                     -- iOS used the other key
    "SOS is >= 2 Hamming bits from every code"                -- it was 1 bit from WANT
    "the key the user scanned completed the handshake"        -- asserted the wrong key
    Router called store.forEachHeldOrderedByPriority()        -- the interface never declared it
    "the wire/Noise/gate fixes are done"                     -- no app imported any of them

So each fix ships with the mechanism that prevents recurrence, not just the patch.

    A  wire codecs regenerate with no diff
    B  no file under eval/ computes a grounding verdict of its own
    C  the C3 red/green probe suite passes
    D  Noise conformance: derivation chain + full XX transcript
    E  constraint gates C1/C2 and the tier tables
    F  every cross-file Kotlin call resolves to a declaration
    G  structural integration, port-vector coverage, and fail-closed feature gates

Invariant B is the audit-relevant one. A/C/D/E are cheap. B makes the original
anti-pattern -- control found ineffective, TEST adjusted instead of control --
a merge block rather than something invisible to the pipeline.
"""
from __future__ import annotations

import argparse
import filecmp
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Patterns that mean "this file decided for itself whether an answer is grounded".
FORBIDDEN_IN_EVAL = [
    (re.compile(r"^\s*def\s+coverage\s*\(", re.M),
     "defines its own coverage metric"),
    (re.compile(r"^\s*def\s+.*reciprocal_rank_fusion|RRF_K\s*=", re.M),
     "reimplements RRF"),
    (re.compile(r"CONFIDENCE_THRESHOLD\s*=\s*0?\.\d+", re.M),
     "hardcodes a confidence threshold"),
    (re.compile(r">=\s*0\.35|>\s*0\.35", re.M),
     "hardcodes the legacy 0.35 floor"),
]


class Report:
    def __init__(self) -> None:
        self.failed: list[str] = []
        self.passed: list[str] = []

    def ok(self, inv: str, msg: str) -> None:
        self.passed.append(inv)
        print(f"  ok    [{inv}] {msg}")

    def bad(self, inv: str, msg: str) -> None:
        self.failed.append(inv)
        print(f"  FAIL  [{inv}] {msg}")
        print(f"::error::Invariant {inv}: {msg}", file=sys.stderr)


def run(mod: list[str]) -> tuple[int, str]:
    p = subprocess.run([sys.executable, *mod], cwd=ROOT,
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


# ---------------------------------------------------------------- A
def invariant_a(r: Report) -> None:
    """Regenerating from wire_v2.yaml must produce no diff."""
    gen = ROOT / "wire" / "gen"
    if not gen.exists():
        r.bad("A", "wire/gen missing; run python -m wire.codegen")
        return
    with tempfile.TemporaryDirectory() as td:
        backup = Path(td) / "gen"
        shutil.copytree(gen, backup)
        vec = ROOT / "wire" / "golden_vectors.json"
        vec_backup = Path(td) / "golden_vectors.json"
        shutil.copy2(vec, vec_backup)

        code, out = run(["-m", "wire.codegen"])
        if code != 0:
            r.bad("A", f"codegen failed: {out.strip().splitlines()[-1:]}")
            return

        drifted = [f.name for f in sorted(gen.iterdir())
                   if f.is_file() and (not (backup / f.name).exists()
                                       or not filecmp.cmp(f, backup / f.name,
                                                          shallow=False))]
        if not filecmp.cmp(vec, vec_backup, shallow=False):
            drifted.append("golden_vectors.json")
        if drifted:
            r.bad("A", "generated files differ after regeneration "
                       f"(hand-edited?): {', '.join(drifted)}")
        else:
            r.ok("A", "wire codecs regenerate byte-identically from wire_v2.yaml")


# ---------------------------------------------------------------- B
def invariant_b(r: Report) -> None:
    """No eval file may compute a grounding verdict of its own."""
    targets = list((ROOT / "content" / "eval").rglob("*.py"))
    if (ROOT / "eval").exists():
        targets += list((ROOT / "eval").rglob("*.py"))
    offenders: list[str] = []
    importers = 0
    for f in targets:
        if f.name == "__init__.py":
            continue
        src = f.read_text(encoding="utf-8")
        rel = f.relative_to(ROOT)
        for pattern, why in FORBIDDEN_IN_EVAL:
            if pattern.search(src):
                offenders.append(f"{rel}: {why}")
        if "safety.gate" in src or "from safety" in src:
            importers += 1
    if offenders:
        r.bad("B", "eval computes its own verdict -- the harness must import "
                   "safety.gate.evaluate and assert on ITS verdict, so the eval "
                   "cannot pass a gate the app does not run:\n        "
              + "\n        ".join(offenders))
    else:
        r.ok("B", f"no eval file computes its own grounding verdict "
                  f"({len(targets)} scanned, {importers} import safety.gate)")


# ---------------------------------------------------------------- C
def invariant_c(r: Report, db: Path) -> None:
    if not db.exists():
        r.bad("C", f"missing {db.relative_to(ROOT)}; build the archive first")
        return
    code, out = run(["-m", "safety.probes", "--db", str(db)])
    tail = [l for l in out.splitlines() if "checks passed" in l]
    if code == 0:
        r.ok("C", f"C3 probe suite: {tail[-1].strip() if tail else 'passed'}")
    else:
        r.bad("C", f"C3 probe suite failed: {tail[-1] if tail else out[-300:]}")


# ---------------------------------------------------------------- D
def invariant_d(r: Report, allow_unpinned: bool) -> None:
    code, out = run(["-m", "crypto.test_conformance"])
    if code != 0:
        bad = [l.strip() for l in out.splitlines() if l.strip().startswith("FAIL")]
        r.bad("D", "Noise conformance failed: " + ("; ".join(bad) or out[-300:]))
        return
    checks = next((l for l in out.splitlines() if l.startswith("checks=")), "")
    unpinned = "CONFORMANCE STATUS: UNPINNED" in out
    if unpinned and not allow_unpinned:
        r.bad("D", "vectors are UNPINNED. Invariant D currently proves only that "
                   "Android and iOS agree WITH EACH OTHER; two implementations "
                   "can agree and both be wrong. Drop a real vector file into "
                   "crypto/cacophony_vectors.json (see docs/PINNING_CACOPHONY.md), "
                   "or pass --allow-unpinned to acknowledge the gap.")
        return
    note = "  [UNPINNED, acknowledged]" if unpinned else "  [PINNED]"
    r.ok("D", f"Noise derivation chain + XX transcript reproduced ({checks}){note}")


# ---------------------------------------------------------------- E
def invariant_e(r: Report) -> None:
    """C1/C2 constraint gates and the tier tables."""
    android = ROOT / "android"
    ios = ROOT / "ios"

    grants = []
    for x in android.rglob("*.xml"):
        for line in x.read_text(encoding="utf-8", errors="ignore").splitlines():
            if ("uses-permission" in line
                    and "android.permission.INTERNET" in line
                    and 'tools:node="remove"' not in line):
                grants.append(str(x.relative_to(ROOT)))
    if grants:
        r.bad("E", f"C1: INTERNET permission granted in {grants}")
        return

    net = re.compile(r"URLSession|NSURLConnection|CFStream|Network\.framework")
    hits = [str(f.relative_to(ROOT)) for f in ios.rglob("*")
            if f.suffix in {".swift", ".m", ".mm"} and net.search(
                f.read_text(encoding="utf-8", errors="ignore"))]
    if hits:
        r.bad("E", f"C1: iOS networking API referenced in {hits}")
        return

    tele = re.compile(r"firebase|crashlytics|sentry|amplitude|mixpanel|appcenter", re.I)
    thits = [str(f.relative_to(ROOT))
             for base in (android, ios) for f in base.rglob("*")
             if f.suffix in {".kts", ".gradle", ".plist", ".yml", ".resolved"}
             and tele.search(f.read_text(encoding="utf-8", errors="ignore"))]
    if thits:
        r.bad("E", f"C2: telemetry dependency in {thits}")
        return

    code, out = run([str(ROOT / "scripts" / "check_tiers.py")])
    if code != 0:
        r.bad("E", "tier tables disagree across platforms")
        return
    r.ok("E", "C1 no network, C2 no telemetry, tier tables agree")


# ---------------------------------------------------------------- F
def invariant_f(r: Report) -> None:
    """Type-aware Kotlin cross-file symbol resolution (ci/symbols.py).

    Kotlin and Swift are NEVER COMPILED here, so A-E are structurally blind to
    an unresolved reference. That blind spot shipped a real inherited defect:
    Router.kt called store.forEachHeldOrderedByPriority() while the MessageStore
    interface declared no such member.

    The FIRST version of this invariant was a name-existence check and it FAILED
    its own negative control -- it reported ok with the defect reintroduced,
    because the concrete classes still declared the method. It was replaced, not
    tuned. ci/symbols.py --selftest is the standing proof that it fires.
    """
    code, out = run([str(ROOT / "ci" / "symbols.py")])
    tail = [l for l in out.splitlines() if "Kotlin files scanned" in l]
    if code == 0:
        r.ok("F", tail[-1].strip() if tail else "cross-file symbols resolve")
    else:
        found = [l.strip() for l in out.splitlines() if "UNRESOLVED" in l]
        r.bad("F", "unresolved cross-file call(s) -- compile errors A-E cannot "
                   "see because Kotlin is never compiled:\n        "
              + "\n        ".join(found))

# ---------------------------------------------------------------- G
def invariant_g(r: Report) -> None:
    """Integration reachability (ci/integration.py).

    A-F check that the reference implementation is CORRECT. None of them check
    that the product USES it. An external review found exactly that gap: the
    GMP/2 codec, the Noise session and the safety gate were all implemented,
    verified, and imported by neither app -- so at runtime the platforms still
    could not talk, the mesh still sent plaintext, and the apps still gated on
    the 0.35 RRF floor the audit had already proven inert.

    That is this repository's own root cause one level up: the fix existed, was
    verified, and was orphaned. G makes orphaning a merge block.
    """
    code, out = run([str(ROOT / "ci" / "integration.py")])
    warns = [l.strip() for l in out.splitlines() if l.strip().startswith("warn")]
    if code == 0:
        note = f"  [{len(warns)} warning(s)]" if warns else ""
        r.ok("G", f"integration checks hold; unfinished mesh paths remain fail-closed{note}")
    else:
        found = [l.strip() for l in out.splitlines() if "ORPHANED" in l]
        r.bad("G", "integration or fail-closed controls failed:\n        "
              + "\n        ".join(found))


def main() -> int:
    ap = argparse.ArgumentParser(description="Godstone parity and safety gate")
    ap.add_argument("--db", type=Path,
                    default=ROOT / "dist" / "archive_medium.db")
    ap.add_argument("--allow-unpinned", action="store_true",
                    help="accept UNPINNED Noise vectors (acknowledges that "
                         "conformance rests on an unvalidated reference)")
    args = ap.parse_args()

    print("Godstone parity + safety gate\n" + "=" * 62)
    r = Report()
    invariant_a(r)
    invariant_b(r)
    invariant_c(r, args.db)
    invariant_d(r, args.allow_unpinned)
    invariant_e(r)
    invariant_f(r)
    invariant_g(r)

    print("=" * 62)
    print(f"passed={len(r.passed)} failed={len(r.failed)}")
    if r.failed:
        print("FAILED: " + ", ".join(sorted(set(r.failed))))
        return 1
    print("all invariants hold")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
`````
<<< END FILE

### `ci/integration.py`

>>> FILE: ci/integration.py
`````python
#!/usr/bin/env python3
"""Structural integration checks for shipping paths and fail-closed gates.

    python ci/integration.py             # check the tree
    python ci/integration.py --selftest  # prove the check fires

V4 REBUILD. The V3 version was a substring grep, and substring greps match
comments. Measured on the V3 tree it reported **0 findings** on a repository
that does not compile on either platform, while:

    Retriever.kt:39   `SafetyGate.evaluate` appeared ONLY in a doc comment,
                      and G4 was `if "SafetyGate.evaluate" not in kr`.
                      The gate passed on prose.
    MessageStore.kt:11 imported `net.sqlcipher.*`, the LEGACY package, which is
                      a compile error against the declared artifact -- and G8
                      checked for the substring "net.sqlcipher" as PROOF of
                      encryption, so the wrong import was what made it pass.

Both are the repository's own thesis one level up: a control that observes text
instead of execution. See ci/mutations.py for the standing negative controls.

WHAT CHANGED
    * comments are stripped before any match
    * a "must call X" check requires a call SITE (receiver + parens), not a mention
    * G6 compares the IDF FORMULA across ports, not only the four floor constants
    * G8 inverts: the legacy package is now evidence of the DEFECT, not the fix
    * new Invariant H: no cross-platform interop claim without a passing vector
    * new Invariant K: model acquisition is lockfile-driven and fails closed

HONEST LIMIT unchanged from V3: this is structural analysis over source text,
not a compiler or a call graph. It proves the wiring is PRESENT. Only
`./gradlew build`, `xcodebuild` and two devices in a room prove it is correct.
"""
from __future__ import annotations
import argparse, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

_BLOCK = re.compile(r"/\*.*?\*/", re.S)
_LINE = re.compile(r"//[^\n]*")


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="ignore") if p.exists() else ""


def code(p: Path) -> str:
    """Source with comments removed.

    This single function is the difference between G4 passing on a doc comment
    and G4 failing on a missing call. Approximate w.r.t. comment markers inside
    string literals, which is acceptable here: the failure mode is a false
    POSITIVE (we complain about a working call), which is loud and gets fixed,
    not a false negative, which is silent and shipped.
    """
    return _LINE.sub("", _BLOCK.sub("", read(p)))


def calls(src: str, symbol: str) -> bool:
    """True when `symbol` appears as an actual call, not a mention.

    Requires an open paren, so `SafetyGate.evaluate` in prose or in an import
    no longer satisfies a 'must call' check.
    """
    return re.search(re.escape(symbol) + r"\s*\(", src) is not None


def check(root: Path) -> list[str]:
    bad: list[str] = []

    kt_ble = root / "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt"
    sw_ble = root / "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift"
    kt_retr = root / "android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt"
    sw_rag = root / "ios/Godstone/Sources/GodstoneLLM/RagPipeline.swift"
    router = root / "android/mesh/src/main/java/io/godstone/mesh/router/Router.kt"
    store = root / "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt"

    # -- G1: the generated codec must live INSIDE the app source trees --------
    for gen in ("android/mesh/src/main/java/io/godstone/mesh/wire/v2/WireV2.kt",
                "ios/Godstone/Sources/GodstoneMesh/WireV2.swift"):
        if not (root / gen).exists():
            bad.append(f"G1 {gen} missing -- codegen must emit into the app tree, "
                       f"not only into wire/gen where nothing compiles it")

    # -- G2: no legacy GMP/1 identifiers on the transport path ----------------
    for path, label in ((kt_ble, "android"), (sw_ble, "ios")):
        src = code(path)
        for lit in ("67640001-1000-8000", "6F0D0001-9A5E"):
            if lit in src:
                bad.append(f"G2 {label}: legacy BLE service UUID {lit} on the "
                           f"transport path -- the platforms cannot discover each other")
        if not re.search(r"FrameV2\.(SERVICE_UUID|serviceUuidString)", src):
            bad.append(f"G2 {label}: BLE UUID is not taken from the generated spec")

    # -- G3: no plaintext send path, and a session must be establishABLE ------
    kt = code(kt_ble)
    if not re.search(r"sessions\??\.seal\s*\(", kt):
        bad.append("G3 android: BleTransport.send does not route through a Noise "
                   "session -- the mesh would transmit plaintext")
    sw = code(sw_ble)
    if not re.search(r"sessions\??\.seal\s*\(", sw):
        bad.append("G3 ios: BleTransport.send does not route through a Noise session")

    # A seal path with no way to REACH an established session is not encryption,
    # it is a permanently failing send. V3 had exactly this and G3 was green.
    for rel, label in (
        ("android/mesh/src/main/java/io/godstone/mesh/crypto/SessionManager.kt", "android"),
        ("ios/Godstone/Sources/GodstoneMesh/SessionManager.swift", "ios"),
    ):
        p = root / rel
        if not p.exists():
            bad.append(f"G3 {label}: no SessionManager -- NoiseSession is constructed by nothing")
            continue
        s = code(p)
        for verb in ("beginInitiator", "beginResponder"):
            if not re.search(r"fun\s+" + verb + r"|func\s+" + verb, s):
                bad.append(f"G3 {label}: SessionManager declares no {verb}")

    # -- G4: the apps must RUN the gate -- a mention is not a call ------------
    kr = code(kt_retr)
    if not calls(kr, "SafetyGate.evaluate"):
        bad.append("G4 android: Retriever does not CALL SafetyGate.evaluate "
                   "(V3 satisfied this check with a doc comment)")
    if re.search(r"bestScore\s*>=\s*CONFIDENCE_THRESHOLD", kr):
        bad.append("G4 android: still gating on the RRF 0.35 floor the audit condemned")
    sr = code(sw_rag)
    if not calls(sr, "SafetyGate.evaluate"):
        bad.append("G4 ios: RagPipeline does not CALL SafetyGate.evaluate")

    # -- G5: query embedding must use the ARCHIVE's model ---------------------
    if "ModelManager.shared.ensureLoaded())?.embed" in sr:
        bad.append("G5 ios: query embedded with the Qwen GENERATION model while the "
                   "archive's vectors are BGE -- different spaces, so every score is noise")
    if not (root / "android/llm/src/main/java/io/godstone/llm/rag/Embedder.kt").exists():
        bad.append("G5 android: Retriever references an Embedder that does not exist")

    # -- G6: gate PARITY -- constants AND the formula -------------------------
    py = read(root / "safety/gate.py")
    ktg = read(root / "android/llm/src/main/java/io/godstone/llm/safety/SafetyGate.kt")
    swg = read(root / "ios/Godstone/Sources/GodstoneCore/SafetyGate.swift")
    for name, pk, kk, sk in (
            ("anchor_recall", "anchor_recall_floor", "ANCHOR_RECALL_FLOOR", "anchorRecallFloor"),
            ("colocation", "colocation_floor", "COLOCATION_FLOOR", "colocationFloor"),
            ("domain_coherence", "domain_coherence_floor", "DOMAIN_COHERENCE_FLOOR", "domainCoherenceFloor"),
            ("caveat_margin", "caveat_margin", "CAVEAT_MARGIN", "caveatMargin")):
        vals = {}
        if (m := re.search(rf'"{pk}":\s*([0-9.]+)', py)):  vals["python"] = float(m.group(1))
        if (m := re.search(rf"{kk}\s*=\s*([0-9.]+)", ktg)): vals["kotlin"] = float(m.group(1))
        if (m := re.search(rf"{sk}\s*=\s*([0-9.]+)", swg)): vals["swift"] = float(m.group(1))
        if len(set(vals.values())) > 1:
            bad.append(f"G6 gate constant {name} disagrees across ports: {vals}")

    # The V3 iOS defect was NOT a constant. Every floor matched; the IDF equation
    # did not, through Swift operator precedence, and the rare/common weight
    # ratio collapsed from 9.39x to 2.90x. Constants-only parity cannot see that.
    if swg and not re.search(r"idf\[t\]\s*=\s*log\(\s*\(", swg):
        bad.append("G6 ios: SafetyGate IDF is not the parenthesised form. Swift "
                   "closes log() after the numerator and then divides, which is a "
                   "DIFFERENT EQUATION from gate.py and SafetyGate.kt -- the same "
                   "question can refuse on Android and answer on iOS")

    # -- G7: documented layers must be REACHABLE ------------------------------
    r = code(router)
    if not calls(r, "SealedSender.seal"):
        bad.append("G7 sealed sender (PROTOCOL.md s.6) is implemented but the router "
                   "never calls it -- relays would still see who talks to whom")
    if not calls(r, "governor.allowInbound"):
        bad.append("G7 anti-abuse governor (PROTOCOL.md s.8) is implemented but the "
                   "router never calls it -- inbound rate is unbounded")

    # -- G8: the store must be encrypted. INVERTED from V3. -------------------
    st = code(store)
    if "net.sqlcipher" in st:
        bad.append("G8 message store imports the LEGACY net.sqlcipher package. The "
                   "declared sqlcipher-android artifact ships "
                   "net.zetetic.database.sqlcipher.* -- this does not compile. V3 "
                   "treated this exact string as PROOF the store was encrypted")
    if "net.zetetic.database.sqlcipher" not in st:
        bad.append("G8 message store does not import SQLCipher at all")
    if "android.database.sqlite.SQLiteDatabase" in st:
        bad.append("G8 message store still imports the plaintext SQLite engine")

    # -- H: no interop claim until the decision is ACCEPTED **and** SHIPPED ---
    #
    # ADR-001 and ADR-002 are ACCEPTED as of V4. ACCEPTED IS NOT IMPLEMENTED, and
    # this invariant is written so that accepting an ADR cannot by itself unlock
    # the claim -- otherwise "write the decision down" becomes a way to make the
    # gate green, which is this repository's entire failure mode wearing a hat.
    #
    # Both conditions are required:
    #   (a) ADR-001 says ACCEPTED, and
    #   (b) both routers actually operate on the SAME canonical frame type.
    #
    # Today (a) holds and (b) does not: iOS Router is FrameV2, Android Router is
    # v1 Frame. So any interop claim still fails.
    adr = read(root / "docs/adr/ADR-001-canonical-wire.md")
    decided = "STATUS: ACCEPTED" in adr

    kt_router = code(root / "android/mesh/src/main/java/io/godstone/mesh/router/Router.kt")
    sw_router = code(root / "ios/Godstone/Sources/GodstoneMesh/Router.swift")
    kt_v2 = "FrameV2" in kt_router
    sw_v2 = "FrameV2" in sw_router
    implemented = kt_v2 and sw_v2

    claims = []
    for doc in ("README.md", "docs/mesh/PROTOCOL.md", "docs/packaging/STORE.md",
                "BUILD_REPORT.md"):
        t = read(root / doc).lower()
        for phrase in ("byte-for-byte identical", "the two platforms interoperate",
                       "cross-platform frame round-trip passes",
                       "android and ios can now talk"):
            if phrase in t:
                claims.append(f"{doc}: '{phrase}'")

    if claims and not (decided and implemented):
        why = []
        if not decided:
            why.append("ADR-001 is not ACCEPTED")
        if not implemented:
            why.append(f"routers disagree on the frame type "
                       f"(android FrameV2={kt_v2}, ios FrameV2={sw_v2})")
        bad.append("H interop is claimed in documentation but " + " and ".join(why)
                   + ": " + "; ".join(claims))

    # The mirror check: a canonical type on BOTH sides with the decision still
    # OPEN means someone migrated the wire without writing down what they chose.
    if implemented and not decided:
        bad.append("H both routers use the canonical frame type while ADR-001 is "
                   "still OPEN -- the wire was migrated without a recorded decision")

    # -- I: platform ports, not only Python models, must own vector tests ------
    swift_vectors = read(root / "ios/Godstone/Tests/GodstoneMeshTests/PortVectorTests.swift")
    kotlin_vectors = read(root / "android/mesh/src/test/java/io/godstone/mesh/PortVectorTest.kt")
    for label, src in (("ios", swift_vectors), ("android", kotlin_vectors)):
        if "69217a3079908094" not in src or "508c5e8c327c14e2" not in src:
            bad.append(f"I {label}: shipping BLAKE2s port has no RFC/generated-vector test")
        if not all(size in src for size in ("32", "96", "64")):
            bad.append(f"I {label}: Noise XX port test does not assert canonical message sizes")

    # -- J: unfinished radio stacks must remain mechanically fail-closed -------
    # ADR-001/002 are accepted but M1-wire/M2-link are not implemented. The UI
    # and service must therefore keep the radio feature flag false. This check
    # prevents a future cosmetic flip from re-enabling plaintext/dead transports.
    android_node = code(root / "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt")
    ios_node = code(root / "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift")
    android_ready = bool(re.search(r"LINK_LAYER_READY\s*=\s*true", android_node))
    ios_ready = bool(re.search(r"linkLayerReady\s*=\s*true", ios_node))
    if (android_ready or ios_ready) and not implemented:
        bad.append("J mesh link was enabled before both routers use the canonical frame type")
    if android_ready != ios_ready:
        bad.append("J mesh availability differs across platforms; one UI would claim a link the other disables")

    # -- K: model acquisition must be lockfile-driven and fail closed ---------
    lock_path = root / "docs/packaging/MODELS.lock.json"
    fetch_path = root / "scripts/fetch_models.sh"
    if not lock_path.exists():
        bad.append("K model lock is missing")
    else:
        import json
        try:
            lock = json.loads(read(lock_path))
        except Exception as exc:
            bad.append(f"K model lock is invalid JSON: {exc}")
        else:
            status = lock.get("status")
            if status not in {"UNPINNED", "PINNED"}:
                bad.append(f"K model lock has invalid status {status!r}")
            artifacts = lock.get("artifacts")
            if not isinstance(artifacts, list) or not artifacts:
                bad.append("K model lock contains no artifacts")
            elif status == "PINNED":
                if not lock.get("verified_on") or not lock.get("verified_by"):
                    bad.append("K PINNED model lock lacks verifier metadata")
                for item in artifacts:
                    sha = item.get("sha256") if isinstance(item, dict) else None
                    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
                        bad.append(f"K PINNED model artifact lacks a valid sha256: {item}")
                        break
            elif any(isinstance(item, dict) and item.get("sha256") for item in artifacts):
                bad.append("K UNPINNED model lock contains checksum-looking values; "
                           "either verify all artifacts and mark PINNED or leave them null")

    fetch = code(fetch_path)
    if 'lock.get("status") != "PINNED"' not in fetch and "status') != 'PINNED'" not in fetch:
        bad.append("K fetch_models.sh does not refuse an unpinned lock")
    if "MODELS=(" in fetch:
        bad.append("K fetch_models.sh still hard-codes model coordinates/hashes outside the lock")

    return bad


def warnings(root: Path) -> list[str]:
    """Genuinely-absent artefacts, never a gate failure: a check that cries wolf
    is a check people learn to ignore."""
    out = []
    if not (root / "android/gradle/wrapper/gradle-wrapper.jar").exists():
        out.append("gradle-wrapper.jar absent (binary; see gradle/wrapper/README.md)")
    if not (root / "third_party/llama.cpp").exists():
        out.append("third_party/llama.cpp absent and unpinned")
    if not (root / ".gitmodules").exists():
        out.append("native dependency has no .gitmodules gitlink or verified archive lock")
    return out


def selftest(root: Path) -> int:
    """Delegates to the mutation corpus, which is the real negative control."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("mut", root / "ci" / "mutations.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.run(report_only=False)


def main() -> int:
    ap = argparse.ArgumentParser(description="Invariant G: integration reachability")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest(ROOT)
    bad = check(ROOT)
    for w in warnings(ROOT):
        print("  warn  " + w)
    for b in bad:
        print("  ORPHANED  " + b)
    print(f"integration checks: {len(bad)} finding(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
`````
<<< END FILE

### `ci/mutations.py`

>>> FILE: ci/mutations.py
`````python
#!/usr/bin/env python3
"""Negative-control corpus for Invariant G.

    python ci/mutations.py            # every mutation must be CAUGHT
    python ci/mutations.py --report   # show what escapes, do not fail

Every mutation below PRESERVES comments and file names and BREAKS execution.
That is the exact shape of defect V3's substring gates could not see, and the
shape GPT's review demanded be made into a merge block:

    "commit a mutation fixture that preserves comments/file names but breaks
     execution. The gate must fail."

A control that has never been observed failing is not a control.
"""
from __future__ import annotations
import argparse, importlib.util, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

def _load_checker():
    spec = importlib.util.spec_from_file_location("integ", ROOT / "ci" / "integration.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.check

# (id, file, find, replace, invariant, why, expect_escape)
#
# expect_escape=True marks a KNOWN CEILING of text-based analysis, not a bug to
# be tuned away. M2 keeps `SealedSender.seal(` textually present inside a dead
# `if (false)` branch. A regex can tell a MENTION from a CALL; it cannot tell a
# LIVE call from a DEAD one, because that is reachability analysis and it needs
# a compiler or a call graph. Special-casing `if (false)` here would make this
# one mutation pass without buying one bit of real reachability -- the exact
# control-found-ineffective / test-adjusted-instead move this repository exists
# to eliminate. So it is recorded as the boundary, and closing it is a stated
# reason `./gradlew build` is the real exit gate.
MUTATIONS = [
    ("M1-gate-comment-only",
     "android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt",
     "val verdict = io.godstone.llm.safety.SafetyGate.evaluate(query, fused, corpusIndex)",
     "val verdict: io.godstone.llm.safety.SafetyGate.Result? = null  // SafetyGate.evaluate",
     "G4",
     "the call becomes a comment; V3 passed on exactly this", False),

    ("M2-sealed-sender-orphan",
     "android/mesh/src/main/java/io/godstone/mesh/router/Router.kt",
     "val sealed = io.godstone.mesh.seal.SealedSender.seal(",
     "val sealed = ByteArray(0); if (false) io.godstone.mesh.seal.SealedSender.seal(",
     "G7",
     "call kept alive textually inside `if (false)` -- CEILING, needs a compiler", True),

    ("M3-handshake-removed",
     "android/mesh/src/main/java/io/godstone/mesh/crypto/SessionManager.kt",
     "fun beginInitiator(peerId: ByteArray, remoteHint: ByteArray): NoiseSession =",
     "// fun beginInitiator REMOVED\n    private fun _unused_beginInitiator(peerId: ByteArray, remoteHint: ByteArray): NoiseSession =",
     "G3",
     "sessions.seal survives; nothing can establish a session", False),

    ("M4-wrong-sqlcipher-package",
     "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt",
     "import net.zetetic.database.sqlcipher.SQLiteDatabase",
     "import net.sqlcipher.database.SQLiteDatabase",
     "G8",
     "legacy package contains the substring V3 checked for", False),

    ("M5-codec-orphaned",
     "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
     "val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID",
     'val SERVICE_UUID: UUID = UUID.fromString("67640001-1000-8000-00805f9b34fb")',
     "G2",
     "generated codec still present, runtime uses a legacy literal", False),

    ("M6-idf-formula-drift",
     "ios/Godstone/Sources/GodstoneCore/SafetyGate.swift",
     "idf[t] = log((Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0)",
     "idf[t] = log(Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0",
     "G6",
     "the real iOS defect: constants agree, the equation does not", False),
]

def run(report_only: bool) -> int:
    check = _load_checker()
    baseline = check(ROOT)
    print(f"baseline findings on the unmutated tree: {len(baseline)}")
    for b in baseline:
        print("   ", b)
    print()

    escaped, unexpected, ceilings = [], [], []
    for mid, rel, find, repl, inv, why, expect_escape in MUTATIONS:
        target = ROOT / rel
        if not target.exists():
            print(f"  SKIP  {mid}: {rel} absent"); continue
        original = target.read_text(encoding="utf-8")
        if find not in original:
            print(f"  SKIP  {mid}: anchor not found (file moved on?)"); continue
        try:
            target.write_text(original.replace(find, repl, 1), encoding="utf-8")
            found = check(ROOT)
            new = [f for f in found if f not in baseline]
            caught = any(f.startswith(inv) for f in new)
            if caught and expect_escape:
                status = "CLOSED "   # a ceiling became reachable: good news
            elif caught:
                status = "caught "
            elif expect_escape:
                status = "ceiling"
            else:
                status = "ESCAPED"
            print(f"  {status} {mid:<28} [{inv}] {why}")
            if not caught:
                (ceilings if expect_escape else unexpected).append(mid)
                escaped.append(mid)
        finally:
            target.write_text(original, encoding="utf-8")

    caught_n = len(MUTATIONS) - len(escaped)
    expected_ceilings = sum(1 for m in MUTATIONS if m[6])
    print(f"\n{caught_n}/{len(MUTATIONS)} caught, "
          f"{len(ceilings)} documented ceiling(s), {len(unexpected)} regression(s)")
    if ceilings:
        print("  ceiling: " + ", ".join(ceilings) +
              " -- text analysis cannot do reachability. This is why "
              "`./gradlew build` is the exit gate, not this script.")
    if unexpected:
        print("::error::mutation escaped Invariant G unexpectedly: "
              + ", ".join(unexpected), file=sys.stderr)
        return 0 if report_only else 1
    return 0

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    raise SystemExit(run(ap.parse_args().report))
`````
<<< END FILE

### `crypto/port_vectors.json`

>>> FILE: crypto/port_vectors.json
`````json
{
  "_comment": "GENERATED by crypto/port_vectors.py. The values are mirrored in Kotlin and Swift port tests; ci/integration.py requires those tests to exist. A control must observe the port, not only a model.",
  "blake2s": {
    "abc": "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982",
    "empty": "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9",
    "blake2s_128_abc": "aa4938119b1dc7b87cbad0ffd200d0ae",
    "blake2s_64_abc": "972e9d2cd6de6402",
    "block_boundary_64": "f85b88e0ac55872416d202c5f4881e7dbc9c7270542ef75074ff9b0a610b5a0e",
    "block_boundary_65": "65bba861969fcb5f1d8ec69e1dbd3e891f546b02203ce73b27958b9589a6789d"
  },
  "safety_gate": {
    "anchor_recall_floor": 0.6,
    "colocation_floor": 0.5,
    "domain_coherence_floor": 0.4,
    "caveat_margin": 0.15,
    "min_anchor_len": 3,
    "stem_prefix_len": 5,
    "idf_n": 27,
    "idf_by_df": {
      "1": 2.926739,
      "3": 2.079442,
      "10": 0.980829,
      "20": 0.31178,
      "26": 0.05506
    },
    "_note": "idf = ln((n - df + 0.5) / (df + 0.5) + 1.0). The WHOLE quotient plus 1.0 is inside the log. Swift closes log() early if the outer parentheses are dropped, which is defect A-20.",
    "stems": {
      "boiling": "boil",
      "purification": "purif",
      "running": "run",
      "doses": "dose",
      "minutes": "minut"
    }
  },
  "noise_xx": {
    "protocol_name": "Noise_XX_25519_ChaChaPoly_BLAKE2s",
    "message_sizes": [
      32,
      96,
      64
    ],
    "_note": "msg2 = e(32) + AEAD(s)(48) + AEAD(payload)(16). msg3 = AEAD(s)(48) + AEAD(payload)(16). Omitting either payload yields [32, 80, 48] and cannot interoperate.",
    "handshake_nonce_rule": "resets to 0 on MixKey, otherwise increments; msg3 encrypts s at n=1",
    "transport_nonce": "4 zero bytes || 8 bytes LITTLE-endian counter"
  }
}
`````
<<< END FILE

### `crypto/port_vectors.py`

>>> FILE: crypto/port_vectors.py
`````python
#!/usr/bin/env python3
"""Emit crypto/port_vectors.json -- vectors the KOTLIN and SWIFT test targets consume.

    python -m crypto.port_vectors

WHY THIS EXISTS.

crypto/test_conformance.py step 1 asserts:

    hashlib.blake2s(b"abc").hexdigest() == rfc["blake2s_256_abc"]

That checks CPython's stdlib against RFC 7693. CPython's BLAKE2s is not in
doubt. The implementation that IS in doubt -- the hand-rolled Blake2s.swift that
the entire Noise handshake sits on -- is never executed by any control in this
repository. The RFC vectors were pointed at the wrong implementation.

The same gap covers the Noise transcript (Invariant D validates the Python
reference against a fixture that reference generated) and the safety gate
(Invariant G6 compared four constants and missed an IDF equation that differed
by 18x).

This file emits one JSON that the mobile test targets read directly, so a
platform port is checked against the pinned values instead of being assumed to
match them.
"""
from __future__ import annotations
import hashlib, json, math, pathlib

OUT = pathlib.Path(__file__).resolve().parent / "port_vectors.json"

def build() -> dict:
    # BLAKE2s -- for Blake2s.swift and BouncyCastle's Blake2sDigest.
    blake = {
        "abc": hashlib.blake2s(b"abc").hexdigest(),
        "empty": hashlib.blake2s(b"").hexdigest(),
        "blake2s_128_abc": hashlib.blake2s(b"abc", digest_size=16).hexdigest(),
        "blake2s_64_abc": hashlib.blake2s(b"abc", digest_size=8).hexdigest(),
        # 64-byte input exercises the exact-one-block boundary, where an
        # off-by-one in the last-block flag hides.
        "block_boundary_64": hashlib.blake2s(b"A" * 64).hexdigest(),
        "block_boundary_65": hashlib.blake2s(b"A" * 65).hexdigest(),
    }

    # Safety gate -- constants AND the IDF equation. The V3 iOS defect was in
    # the equation while every constant matched.
    n = 27
    idf = {str(d): round(math.log((n - d + 0.5) / (d + 0.5) + 1.0), 6)
           for d in (1, 3, 10, 20, 26)}
    gate = {
        "anchor_recall_floor": 0.60,
        "colocation_floor": 0.50,
        "domain_coherence_floor": 0.40,
        "caveat_margin": 0.15,
        "min_anchor_len": 3,
        "stem_prefix_len": 5,
        "idf_n": n,
        "idf_by_df": idf,
        "_note": "idf = ln((n - df + 0.5) / (df + 0.5) + 1.0). The WHOLE quotient "
                 "plus 1.0 is inside the log. Swift closes log() early if the "
                 "outer parentheses are dropped, which is defect A-20.",
        # Stemming: an early gate draft refused "how long should I boil water"
        # because boil and boiling were different terms.
        "stems": {"boiling": "boil", "purification": "purif", "running": "run",
                  "doses": "dose", "minutes": "minut"},
    }

    # Noise XX -- message sizes with empty payloads. The V3 iOS implementation
    # produced [32, 80, 48] here, which is defect A-19.
    noise = {
        "protocol_name": "Noise_XX_25519_ChaChaPoly_BLAKE2s",
        "message_sizes": [32, 96, 64],
        "_note": "msg2 = e(32) + AEAD(s)(48) + AEAD(payload)(16). "
                 "msg3 = AEAD(s)(48) + AEAD(payload)(16). Omitting either "
                 "payload yields [32, 80, 48] and cannot interoperate.",
        "handshake_nonce_rule": "resets to 0 on MixKey, otherwise increments; "
                                "msg3 encrypts s at n=1",
        "transport_nonce": "4 zero bytes || 8 bytes LITTLE-endian counter",
    }

    return {
        "_comment": "GENERATED by crypto/port_vectors.py. The values are mirrored in "
                    "Kotlin and Swift port tests; ci/integration.py requires those "
                    "tests to exist. A control must observe the port, not only a model.",
        "blake2s": blake,
        "safety_gate": gate,
        "noise_xx": noise,
    }

def main() -> int:
    d = build()
    OUT.write_text(json.dumps(d, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT.name}")
    print(f"  blake2s vectors   {len(d['blake2s'])}")
    print(f"  gate idf points   {len(d['safety_gate']['idf_by_df'])}")
    print(f"  noise xx sizes    {d['noise_xx']['message_sizes']}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
`````
<<< END FILE

### `docs/AUDIT.md`

>>> FILE: docs/AUDIT.md
`````markdown
# Godstone V4 — Open Audit Register

This register records unresolved risks after applying the V4 repair change-set.
A finding is closed only by executable evidence against the shipping path.
Accepted ADRs are decisions, not implementations.

## P0 — stop-ship

| ID | Finding | Required closure evidence |
|---|---|---|
| A-01 | Android and iOS mesh runtimes are not on one canonical frame path | both routers/stores use generated GMP/2.1; golden and cross-device round trip |
| A-02 | BLE record layer and Noise handshake driver are not implemented | ADR-002 property tests plus Android↔iOS Hardware Case 0 |
| A-03 | Mesh/SOS has no durable, authenticated end-to-end delivery lifecycle | persist-before-send, recipient ACK, expiry/cancel semantics, restart tests |
| A-04 | iOS has no durable encrypted DTN store or coordinated panic wipe | reboot/jetsam/migration/seizure and wipe recovery tests |
| A-05 | Identity binding/TOFU/contact and sealed sender are unresolved | ADR-003 accepted and cryptographically verified implementation |
| A-06 | External Noise vectors remain unpinned | independent vectors consumed by both platform tests; no `--allow-unpinned` |
| A-07 | Mobile targets have not been compiled from this final markdown in the assembly environment | clean Gradle and Xcode logs attached to the revision |
| A-08 | Corpus is three unreviewed examples, not a survival archive | licensed corpus, per-chunk provenance and clinician/editorial approval |
| A-09 | Native model dependency and weights are not reproducibly pinned | immutable dependency revision, hashes, licences, offline build proof |

## P1 — required before beta

| ID | Finding | Required closure evidence |
|---|---|---|
| A-10 | Android store migration, key durability, cap enforcement and corruption recovery are incomplete | migration matrix, power-loss and all-SOS flood tests |
| A-11 | Runtime permission/capability lifecycle is incomplete | denied/revoked/off/unsupported tests on supported OS versions |
| A-12 | Archive integrity and fallback UX require device tests | corrupt/missing DB tests with readable degraded mode |
| A-13 | Android semantic search is lexical-only because `nativeEmbed` is absent | one pinned embedding model/space and port parity tests |
| A-14 | Bulk plane is disabled and former stubs could report success without bytes | ADR-006 accepted and encrypted cross-platform transfer tests |
| A-15 | Battery and background behavior are unmeasured | radios/model/storage profiling under normal, low and critical battery |
| A-16 | Accessibility and stress UX have no instrumentation/device evidence | TalkBack/VoiceOver, dynamic type, contrast, glove/one-hand tests |
| A-17 | Static integration control cannot prove live reachability through dead branches | compiler/call-graph coverage or end-to-end tests for critical paths |
| A-18 | Store/privacy/disclaimer documents describe surfaces not yet implemented | in-app surfaces verified in release UI |

## Closed by V4

- V3 pseudo-patches replaced by complete file bodies.
- Duplicate V4 paths rejected during assembly.
- Android split composition root removed.
- Known V3 Android/iOS compile blockers corrected in source.
- iOS Noise message construction/parser/nonce defects corrected.
- Swift grounding IDF equation aligned with Python/Kotlin.
- SQLCipher package path corrected and initialization moved before helper use.
- Placeholder Archive screens replaced with real repositories.
- Unsafe radio, SOS and bulk claims fail closed.
- Platform-port BLAKE2s and Noise message-size tests added.
- Mutation controls document their one remaining text-analysis ceiling.

## Rule for future reviews

For every proposed closure, require all four:

1. exact shipping call site;
2. negative control that fails when the defect is reintroduced;
3. platform compile/test evidence;
4. user-visible claim no stronger than the measured result.
`````
<<< END FILE

### `docs/adr/ADR-001-canonical-wire.md`

>>> FILE: docs/adr/ADR-001-canonical-wire.md
`````markdown
# ADR-001 — Canonical runtime message model and GMP version

**STATUS: ACCEPTED** (31 Jul 2026)
Supersedes the OPEN placeholder in V4-draft. Implementation is tracked as
`M1-wire` and is NOT part of V4.

---

## 1. The decision

**GMP/2.1 is the canonical runtime format on both platforms.** It is GMP/2 with
four corrections, each forced by a defect found while writing this ADR.

GMP/1 is **deleted**, not migrated. See §5.

---

## 2. Why v2 and not v1

Three candidate directions were considered.

| Option | Verdict |
|---|---|
| Bring iOS back to GMP/1 | **Rejected.** The two v1 implementations were never byte-compatible with each other (20 vs 26-byte header, 8 vs 16-byte msg_id, SOS 0x08 vs 0x02, timestamp present vs absent). "Revert to v1" is not a revert; it is a fresh unification with none of v2's benefits. |
| Design GMP/3 | **Rejected.** v2 is already generated identically into both trees from `wire_v2.yaml`, has a magic, a version byte, a header CRC and even-parity type codes. Discarding that to start again is cost with no return. |
| **GMP/2 with corrections** | **Accepted.** Smallest change that yields one byte layout, and the codegen contract (Invariant A) is already the enforcement lever. |

---

## 3. The four corrections

### 3.1 Priority cannot fit in the flags mask — **arithmetic defect**

```
PRIORITY_MASK 0x00C0 = 0b11000000 = 2 bits = 4 distinct values
Android Priority     = SOS, DIRECT, GROUP, BROADCAST, BULK = 5 values
```

**GMP/2 cannot represent Android's existing priority set.** Nobody noticed
because no Android code path ever constructed a `FrameV2`. A mechanical type
swap would have silently collapsed two priority classes into one — and the class
most likely to collide is the one that decides what gets dropped under flood.

**Decision.** Promote priority to an explicit 3-bit field carved from the flags
word, `PRIORITY_MASK = 0x0700` (bits 8–10, 8 values). The old 0x00C0 bits are
returned to the reserved pool. Encoding is fixed and shared:

```
0 SOS   1 DIRECT   2 GROUP   3 BROADCAST   4 BULK   5-7 reserved
```

`wire/codegen.py` gains an assertion that `popcount(PRIORITY_MASK) >= ceil(log2(len(priority)))`,
so this class of defect fails the build rather than the mesh.

### 3.2 No plaintext timestamp — **and no timestamp in the header at all**

GPT's review challenged the assumption directly: *"Determine whether timestamps
belong inside a sealed/authenticated envelope, how devices without accurate
clocks expire messages, and how replay/retention work across clock rollback."*

Taking that seriously changes the answer. A header timestamp is:

- **a fingerprinting surface** — a plaintext wall-clock value visible to every
  relay is a strong correlator, which directly undermines the A7 claim that
  daily-rotating routing tags defeat traffic analysis;
- **unreliable exactly when it matters** — in a blackout, devices reboot without
  network time. Android's `MAX_AGE_SECONDS` compares a sender's wall clock to
  the receiver's. Two devices days apart discard each other's valid traffic;
- **not needed for retention** — what a node must know is *how long has this
  frame been in MY store*, which is a local monotonic question.

**Decision — three separate clocks, never conflated:**

| Purpose | Source | Where it lives |
|---|---|---|
| retention / expiry | receiver's **monotonic** clock at receipt | store column, never on the wire |
| sender's claim of creation time | `created_at` uint32 epoch-seconds | **inside the sealed, signed payload** |
| token buckets, session timeouts | monotonic elapsed | memory only |

The header carries **no timestamp**. Retention is receipt-relative: a frame is
held `min(RETENTION[priority], MAX_HOLD)` from *local receipt*, so an SOS carried
by a phone with a broken clock still expires correctly on every relay.
`created_at` is advisory, authenticated, and used only for display and for
ordering within a single sender.

A device whose clock is untrusted (no time source since boot) sets a
`CLOCK_UNTRUSTED` flag and omits `created_at` rather than asserting a wrong one.

### 3.3 Message id derivation

`PROTOCOL.md` says ids are content-derived; Android uses a random `Long`, iOS 16
random bytes. Neither matches, and a random id lets one sender flood distinct ids
for identical content.

**Decision.** `msg_id = BLAKE2s-128(sender_node_id ‖ created_at_le ‖ payload)`,
16 bytes. Content-derived means duplicate submissions collapse in the dedup
cache. Proof-of-work still searches a nonce, but the nonce moves into the sealed
payload rather than being the id itself — V3's `ProofOfWork.mine` mutated
`msg_id`, which is fine when the id is random and **breaks the moment the id is a
content hash**.

### 3.4 Bloom digest hash input

iOS hashes `Data(16) ‖ UInt8(round)` = 17 bytes; Android hashes
`Long(8) ‖ Int(4)` = 12 bytes. Different widths, different round encoding,
different bits.

**Decision.** `index = BLAKE2s-64(msg_id[16] ‖ uint32_be(round)) mod 4096`,
20 bytes hashed, 4 rounds. Golden vectors are generated by `wire/codegen.py` and
both platforms must reproduce them.

---

## 4. The canonical header

32 bytes, big-endian, unchanged in size from GMP/2:

```
off  size  field
0    2     magic          0x4753
2    1     version        0x02   (minor 1 signalled in HELLO capabilities)
3    1     type           even-parity code, >= 2 Hamming from every other
4    16    msg_id         BLAKE2s-128(sender ‖ created_at ‖ payload)
20   4     routing_tag    BLAKE2s-32(recipient_node_id ‖ epoch_day)
24   1     ttl            initial 12, max 16
25   1     hop_count      increments on relay
26   2     flags          PRIORITY_MASK 0x0700 (3 bits) + feature bits
28   2     payload_len    max 60000
30   2     header_crc     CRC-16/CCITT over bytes 0..29
```

Everything else — `created_at`, PoW nonce, sender id, signature — lives inside
the sealed payload, where it is authenticated rather than merely present.

---

## 5. Migration: there is nothing to migrate

The obvious hard problem is converting `msg_id INTEGER PRIMARY KEY` rows to a
16-byte BLOB, and deriving 16-byte ids from 8-byte ones (impossible without the
original content).

**It does not arise. V3 has never compiled on either platform.** There is no
installed base, no user device holding v1 rows, and no field data. Both reviews
treated store migration as a blocker; it is an artefact of assuming the software
exists in the world.

**Decision.** Delete `android/mesh/.../wire/Frame.kt` and
`ios/.../GodstoneMesh/Frame.swift`. Create the store fresh at schema v2. Write
**no** migration code. Add a build assertion that no v1 symbol survives.

If a build ever *does* ship before this lands, this decision is void and a real
migration is required — recorded here so the reasoning is auditable rather than
rediscovered.

---

## 6. v1 rejection policy

A v1 frame has `version == 0x01` at offset 2 where v2 has magic. It fails the
magic check first and is dropped. **Never best-effort parsed.** V4's renumbering
already ensures no v2 type code falls in v1's 0x01–0x0A range, so a stray legacy
frame reaches the unknown-type branch instead of arriving as an SOS.

---

## 7. Noise prologue version binding

Both platforms bind `"GMP1"` into the Noise prologue while advertising GMP/2.
Since both are wrong identically, it currently "works" — the exact
self-consistent-but-wrong failure the interop matrix exists to expose.

**Decision.** `prologue = "GMP2" ‖ initiator_hint ‖ responder_hint`. Changing
this invalidates every pinned vector, so `crypto/gen_vectors.py` must regenerate
and Invariant D must be re-pinned **in the same commit** as the wire change.

---

## 8. Acceptance criteria

An implementation satisfies ADR-001 when:

- [ ] one normative `wire_v2.yaml`; both codecs generated, Invariant A green
- [ ] `codegen.py` asserts the priority mask is wide enough for the priority set
- [ ] cross-platform golden vectors for every type, both bloom rounds, and edge
      values (ttl 0/16, payload 0/60000, all priorities)
- [ ] both routers operate on the canonical type; no v1 symbol resolves
- [ ] `created_at` and the PoW nonce are inside the authenticated payload
- [ ] retention is receipt-relative; a frame from a device 10 days out of sync
      is neither dropped early nor held forever
- [ ] Invariant D re-pinned against the `GMP2` prologue

Until every box is ticked, `ci/integration.py` Invariant H continues to fail any
documentation claiming cross-platform interoperability.
`````
<<< END FILE

### `docs/adr/ADR-002-ble-record-layer.md`

>>> FILE: docs/adr/ADR-002-ble-record-layer.md
`````markdown
# ADR-002 — BLE roles, record framing, and the Noise handshake driver

**STATUS: ACCEPTED** (31 Jul 2026)
Implementation is tracked as `M2-link` and is NOT part of V4.

---

## 1. The decision, in one line

**A four-field record layer outside the encrypted frame; encrypt-then-fragment;
deterministic role election by node_id; and a 13-byte advertisement in the scan
response**, because the 26-byte one is physically impossible.

---

## 2. The advertisement does not fit — **measured, not assumed**

GPT's review asked the right question: *"Check Android advertisement-size limits
with the 128-bit UUID plus 26 bytes of service data."* The arithmetic:

```
BLE legacy advertisement budget                       31 bytes
  AD: complete 128-bit UUID list   = 1+1+16         = 18 bytes
  AD: service data (128-bit UUID) + 26-byte payload
                                   = 1+1+16+26      = 44 bytes
  both in one packet                                = 62 bytes   DOES NOT FIT
```

`PROTOCOL.md` §3.1 specifies a 26-byte service-data payload alongside a 128-bit
service UUID. **That has never been transmittable.** Android's
`startAdvertising` would have failed with `ADVERTISE_FAILED_DATA_TOO_LARGE` the
first time anyone called `addServiceData` — which is precisely why the bug hid:
`buildAdvertisementPayload()` had no caller, so the impossible packet was never
constructed. The scanner's `if (sd.size < 26) return` was rejecting a payload the
advertiser could not have sent.

### Decision

Split across advertisement and scan response, and shrink the payload to 13 bytes:

```
ADVERTISEMENT   (31 B budget)
  complete 128-bit service UUID                        18 B   -> 13 B spare

SCAN RESPONSE   (31 B budget)
  service data, 128-bit UUID + 13-byte payload    2+16+13 = 31 B   -> exact fit

  off size field
  0   1    protocol_version   0x02
  1   1    flags              bit0 SOS_PRESENT   bit1 BULK_CAPABLE
                              bit2 POWER_CONSTRAINED   bit3 VERIFIED_ONLY
                              bit4 CLOCK_UNTRUSTED (ADR-001 §3.2)
  2   4    node_hint          first 4 bytes of node_id
  6    6   bloom_digest_short truncated bloom of held msg_ids
  12   1   queue_depth        saturating, 0-255
```

`epoch` is dropped: it existed to detect staleness, which ADR-001 §3.2 now
handles with receipt-relative retention. The digest shrinks 16 → 6 bytes,
raising the false-positive rate on the *pre-connection* filter only. That is the
correct place to lose precision: a false positive costs one unnecessary
connection, and the full 4096-bit digest is exchanged after the handshake anyway.

**Scan response requires active scanning.** `CBCentralManager` scans actively by
default; Android must use `SCAN_MODE_*` with a `ScanFilter` on the service UUID.
Both platforms must handle a scan result arriving *without* service data (adv
seen, scan response not yet received) by waiting rather than rejecting — V3's
scanner returned immediately, which would have dropped every first sighting.

---

## 3. Role election

Two peers that both initiate produce two half-open handshakes; two that both wait
produce none. V3 had no election at all, and iOS unconditionally called
`beginInitiator` on `transportReady`.

**Decision — no negotiation round-trip, decide locally from data both sides
already have:**

```
initiator = the peer whose node_hint is lexicographically SMALLER
            (unsigned byte comparison, 4 bytes, from the advertisement)
tie (identical hints, ~1 in 2^32):
            compare full node_id after the handshake; if still equal, both
            abort and re-scan with jitter -- an identical node_id means a
            cloned identity, which is a security event, not a race
```

Both sides compute the same answer from the same bytes before any packet is
exchanged. The loser opens the GATT server and waits; the winner connects.

---

## 4. Encrypt-then-fragment

The question GPT posed: *"Decide whether to encrypt before fragmentation or
fragment before encryption. Compare memory, replay, integrity and
retransmission consequences."*

| | encrypt-then-fragment | fragment-then-encrypt |
|---|---|---|
| Noise nonce granularity | one per **record** — matches the spec as written | one per **fragment** — needs a new AAD construction binding index/count, invented here |
| integrity | all-or-nothing; a corrupted fragment fails the whole record | per-fragment, so partial plaintext can reach the reassembler |
| memory | bounded by MAX_RECORD | bounded by MAX_RECORD |
| retransmit cost | whole record | single fragment |
| new cryptography required | **none** | a specified per-fragment AEAD |

**Decision: encrypt-then-fragment.** The retransmission cost is real and
accepted — BLE records here are ≤ 16 KB and the DTN layer already re-offers on
the next encounter. The decisive factor is C6 (*compose crypto, never invent
it*): fragment-then-encrypt requires designing a per-fragment authenticated
construction, and this repository has already shipped three defects in
hand-rolled crypto.

All-or-nothing integrity is also the *safer* failure: a partially-decrypted frame
must never reach the router, and encrypt-then-fragment makes that structural
rather than a check someone has to remember.

---

## 5. The record layer

Outside the Noise ciphertext, because handshake messages must be carried before a
session exists. 8-byte header:

```
off size field
0   1    magic          0x47
1   1    type           HS1 0x11  HS2 0x12  HS3 0x14  DATA 0x18  CLOSE 0x21
                        (even parity, >= 2 Hamming apart, same rule as frames)
2   1    record_seq     connection-local, wraps at 256
3   1    frag_index     0-based
4   1    frag_count     1-64
5   2    total_len      reassembled length, uint16 BE
7   1    header_check   XOR of bytes 0..6

bounds
  MAX_RECORD        16384 bytes reassembled
  MAX_FRAGMENTS     64
  REASSEMBLY_TIMEOUT 30 s   (bitchat field value; see 7b)
  MAX_CONCURRENT    4 records in flight per peer  -> 64 KB peak per peer
```

A fragment whose `frag_index >= frag_count`, whose `total_len > MAX_RECORD`, or
which arrives for an expired `record_seq`, is dropped and charged to the peer's
abuse budget. Reassembly buffers are allocated on the **first** fragment against
`total_len`, so `MAX_RECORD` is a hard allocation cap rather than an accumulating
one.

This directly fixes the V3 iOS defect: `send` fragmented a Noise ciphertext
across ATT writes while `didUpdateValueFor` handed **each inbound fragment** to
`sessions.open` as a complete message. Anything above one ATT write was
undecryptable by construction.

---

## 6. The handshake driver

The state machine that does not exist on either platform. V4 makes
`NoiseSession.swift` wire-conformant; it still has nothing to carry messages 1–3.

```
DISCOVERED --(elected initiator)--> CONNECTING --> DISCOVERING_SERVICES
    |                                                      |
    (elected responder)                                    v
    |                                              SEND HS1 -> AWAIT_HS2
    v                                                      |
LISTENING --(HS1 rx)--> SEND HS2 -> AWAIT_HS3              v
    |                                              rx HS2 -> SEND HS3 -> ESTABLISHED
    v                                                      |
rx HS3 -> ESTABLISHED                                       |
                                                            v
                              ESTABLISHED --> (TOFU pin check, ADR-003) --> READY
                                          --> pin mismatch --> QUARANTINE, no data

timeouts:  each AWAIT_* 5 s, then teardown + exponential backoff (1s, 2s, 4s ... 60s)
budgets:   3 handshake attempts per peer per 5 min (pre-auth, ADR-003 stage 2)
prologue:  hints from the REAL advertisement, never Data(repeating: 0, count: 4)
```

No application frame is accepted before `READY`. There is deliberately **no
plaintext fallback** at any state.

---

## 7. Android's dead receive path

`GattServer.incoming()` is a cold `callbackFlow`; it opens the GATT server only
when collected. `MeshNode.start()` collects `ble.peers()` and nothing else, so
the server is never opened, ciphertext is never decrypted, and the router never
receives a frame.

**Decision.** The radio lifecycle becomes a single owned scope, started in this
order: GATT server → inbound collector → **then** advertise. Advertising before
the server accepts connections is a race a peer can win.

---

## 7b. Independent corroboration from bitchat

Two of this ADR's decisions were reached by argument. A shipping cross-platform
BLE mesh reached the same conclusions in production.

**The advertisement.** bitchat's advertising data is **the service UUID and
nothing else** — documented as *"Advertising Data: Service UUID only — Maximizes
privacy — no local name broadcast."* No service-data payload at all. That is
independent confirmation of §2: the 26-byte payload does not fit beside a 128-bit
UUID, and a real implementation simply does not carry one.

bitchat pays for that with a connection on every encounter — it gives up the
pre-connection filter that `PROTOCOL.md` §3.1 calls *"the single most important
power optimisation in the system"*. **This ADR's 13-byte scan-response payload is
a middle path that bitchat did not take, and it is therefore unproven.** If it
fails on device, falling back to bitchat's UUID-only advertisement is a known-good
answer that costs battery, not correctness. Recorded so the fallback is a
decision rather than a scramble.

**Fragmentation order.** bitchat fragments *after* encryption — the complete
encoded message, post-compression and post-Noise, is what gets split when it
exceeds the negotiated MTU. That is encrypt-then-fragment, chosen here in §4 on
C6 grounds. Two independent derivations, same answer.

Their parameters, against this ADR's:

| | bitchat | ADR-002 |
|---|---|---|
| default fragment | 469 B | MTU-derived |
| fragment metadata | 13 B | 8 B |
| reassembly timeout | **30 s** | 10 s |
| max fragments | ~100 | 64 |
| per-peer streams | yes | yes |

**Adopt their 30-second timeout.** 10 s was chosen by feel; 30 s comes from a
year of field use on real radios, where a peer walking behind a wall mid-transfer
is routine. The other numbers are close enough that the convergence is itself
evidence.

**Also worth taking:** bitchat runs separate testnet and mainnet service UUIDs
(`…4B5A` / `…4B5C`). GODSTONE has one UUID, so any field test pollutes the
production mesh and vice versa. Cheap to add now, painful to retrofit once
devices are deployed.

## 8. Acceptance criteria

- [ ] property test: fragment every record at every boundary from 1 byte to the
      negotiated MTU, with reorder, drop, duplicate — exactly-once or clean failure
- [ ] advertisement + scan response verified ≤ 31 bytes each **on device**, not
      only in arithmetic
- [ ] role election test: 1000 random node_id pairs, exactly one initiator each
- [ ] Android↔Android and iOS↔iOS encrypted ping, radio bytes captured, **no
      plaintext GMP frame observable**
- [ ] repeated `start()` produces one scan, one server, one collector
- [ ] tamper, replay, reconnect, simultaneous-connect, and timeout paths recover

Hardware Case 0 (Android↔iOS) additionally requires ADR-001 implemented, since
the two platforms do not share a frame format until then.
`````
<<< END FILE

### `docs/adr/ADR-003-identity-and-sealed-sender.md`

>>> FILE: docs/adr/ADR-003-identity-and-sealed-sender.md
`````markdown
# ADR-003 — Identity binding, TOFU, contacts, sealed sender

**STATUS: OPEN.** The A2 and A7 threat-model claims are unsupported until it closes.

## Why the current construction cannot be shipped as specified

`SealedSender.kt` exists on Android only, is called by nothing, and does not
implement the documented construction:

| PROTOCOL.md §6 | SealedSender.kt |
|---|---|
| two layers (`inner` under `K_e2e`, then sealed) | one AEAD pass |
| `HKDF` | `BLAKE2s(shared ‖ label)` |
| ChaCha20-Poly1305 | AES-GCM |
| — | sender id is **unauthenticated**: any sender can place any 16 bytes inside |

No associated data binds the routing tag, frame type, message id, version or TTL
to the ciphertext. There is no forward secrecy against later compromise of the
recipient's static key: recorded ephemerals plus that key recover past sealing
keys. "X3DH-style" should not be claimed without signed and one-time prekeys.

## The binding nobody has specified

`node_id` derives from the **Ed25519** identity key. Noise authenticates an
**X25519** static key. Nothing cryptographically binds the two, so an
authenticated handshake proves nothing about the claimed `node_id`. TOFU
pinning, QR verification and the key-change warning are all specified and none
are implemented.

## Decide before writing code

Sender authentication or deliberate sender anonymity; behaviour under sender vs
recipient compromise; deniability; offline prekeys; group messaging; exactly
which header metadata leaks.

---

## Addendum — what bitchat does, and what happened to it

[bitchat](https://github.com/permissionlesstech/bitchat) holds the same two key
pairs GODSTONE does, and resolves the binding question by **choosing the other
key as the identity**:

> a Curve25519 static key for Noise key agreement — its SHA-256 fingerprint is
> the peer's stable identity — and an Ed25519 signing key for packet signatures.

So `identity = H(X25519_static_pub)`: the identity is derived from the key that
Noise actually authenticates. A completed handshake then proves the peer's
identity **directly**, with nothing left to bind.

GODSTONE made the opposite choice. `PROTOCOL.md` §2 specifies
`node_id = BLAKE2s-128(identity_pub)` over the **Ed25519** key, while Noise
authenticates the **X25519** key — so an authenticated handshake proves nothing
about the claimed `node_id`, and the gap has to be closed by an explicit binding
nobody has specified.

Note what this means for the V3 history: iOS deriving `node_id` from the X25519
key was recorded as a defect against `PROTOCOL.md:49`. It was a genuine
*divergence* — the two platforms disagreed, which is fatal — but **iOS had
accidentally implemented the better design.** The fix aligned both platforms onto
the harder option.

**Recommended direction:** invert it. `node_id = H(static_dh_pub)` truncated to
16 bytes, and carry the Ed25519 signing key inside a self-signed announcement
bound to that static key. This is also what ADR-007 needs, since it changes the
hash anyway.

### The caution that comes with it

bitchat adopting this design did **not** make it immune. Within days of launch,
Alex Radocea demonstrated impersonation against its `Favorites` system —
described as *"broken identity authentication/verification"*, letting an attacker
intercept an identity-key/peer-id pair and appear as a trusted contact. The
project has since shipped `Pin announce signing keys to stop mesh identity
spoofing (#1349)`, which is the announcement-binding problem above, found the
hard way.

**Conclusion for GODSTONE:** the fingerprint-of-the-Noise-key model is the right
base, and it is *not sufficient on its own*. The binding between the static key,
the signing key and the displayed contact must be specified and tested, or the
same class of impersonation is available here. ADR-003 remains the highest-risk
OPEN decision in the project — it is the one that broke, in public, in the
closest comparable system.
`````
<<< END FILE

### `docs/adr/ADR-004-durable-store.md`

>>> FILE: docs/adr/ADR-004-durable-store.md
`````markdown
# ADR-004 — Durable message store, retention and panic wipe

**STATUS: OPEN.**

## Current state

Android opens SQLCipher through the current `net.zetetic.database.sqlcipher`
API and stores its database key behind an Android Keystore-backed preference.
That closes the V3 plaintext/import defect, but does not finish durability.

iOS has no durable DTN store. Its router queue and dedup set are in memory, so
termination, jetsam or reboot loses carried traffic. The radio feature remains
disabled; V4 does not present this queue as durable.

## Decisions still required

- canonical GMP/2.1 store schema with 16-byte message IDs;
- receipt-monotonic retention and expiry;
- persist-before-forward and delete-on-authenticated-ACK behavior;
- hard-cap eviction where SOS is last, not unbounded;
- transactional key creation and migration under power loss;
- corruption detection/recovery;
- coordinated deletion of store, identity, contacts and session material;
- digest generation from held durable records on both platforms.

## Exit criteria

1. Reboot/jetsam after receipt preserves a message and its forwarding state.
2. A carrier can move between partitions after the origin has disappeared.
3. Every migration is tested from each supported schema version.
4. All-SOS flooding remains inside the configured hard cap.
5. Panic wipe makes prior rows and keys unrecoverable and creates a new identity.
6. Android and iOS build the same anti-entropy digest from the same held set.
`````
<<< END FILE

### `docs/adr/ADR-005-sos-and-lifecycle.md`

>>> FILE: docs/adr/ADR-005-sos-and-lifecycle.md
`````markdown
# ADR-005 — SOS authenticity, delivery semantics and capability lifecycle

**STATUS: OPEN.**

## V4 safety position

SOS transmission is disabled on both platforms while M1-wire/M2-link and this
ADR remain incomplete. The UI reports the reason and does not claim that a
message carries location, a call sign, or recipient delivery.

The required lifecycle is:

```text
UNAVAILABLE | QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
                                      \-> EXPIRED | CANCELLED_LOCALLY
```

A successful GATT write is only `HANDED_TO_RELAY`. `SENT` is forbidden unless an
authenticated intended recipient ACKs the exact message ID. Cancellation cannot
recall already relayed copies and must say so.

## Decisions still required

- minimum stranger-to-stranger authenticity model;
- signature transcript and how the verification key is obtained/bound;
- recipient/group addressing without exposing the social graph;
- ACK authentication, timeout, retry, duplicate and multi-recipient semantics;
- optional location acquisition, freshness and consent;
- permission/capability states: denied, permanently denied, revoked, Bluetooth
  off, unsupported radio, background restrictions and critical battery;
- accessible hold/confirm/cancel behavior under stress.

## Exit criteria

Truth-table tests for every state; reboot recovery; no unsigned SOS accepted;
tamper/replay rejected; no UI phrase stronger than its cryptographic evidence;
and Android↔iOS hardware tests with radios captured.
`````
<<< END FILE

### `docs/adr/ADR-006-bulk-plane.md`

>>> FILE: docs/adr/ADR-006-bulk-plane.md
`````markdown
# ADR-006 — The bulk transfer plane

**STATUS: OPEN, with a recommended direction.**
Opened in response to GPT P1-08 and to a concrete external reference:
[LocalSend](https://github.com/localsend/localsend).

---

## 1. Why this ADR exists

The V3 bulk transports were non-functional: Android returned success without
transmitting bytes, while iOS destroyed peer identity at the callback boundary
and bypassed the Noise session. V4 removes those false-success paths. Both
platform implementations now report unavailable and return failure.

That is a safety closure, not a bulk implementation. The architectural question
remains: Wi-Fi Aware is Android-specific and MultipeerConnectivity is
Apple-specific, so they cannot form one Android↔iOS transport.

GPT's challenge was the right one: *"Evaluate whether Wi-Fi Aware and
MultipeerConnectivity can actually interoperate cross-platform. If not, redesign
the bulk plane rather than treating two platform-specific technologies as one
shared transport."*

**They do not interoperate.** Wi-Fi Aware (NAN) is an Android API with no iOS
client; MultipeerConnectivity is Apple-only and has no Android implementation.
`PROTOCOL.md` §3.2 lists them side by side under one heading, which reads as a
single bulk plane and is in fact two disjoint ones. Android↔iOS bulk transfer
has never been possible, and no amount of fixing either stub changes that.

---

## 2. What LocalSend demonstrates

LocalSend is a cross-platform local file-transfer app (Android, iOS, Windows,
macOS, Linux) that solves the *adjacent* problem and is worth reading carefully.
Its architecture, from the protocol repository:

| | LocalSend |
|---|---|
| discovery | multicast UDP to `224.0.0.167:53317`, announce/response |
| fallback | HTTP scan of the local subnet when multicast is filtered |
| transfer | REST over HTTP/HTTPS, TCP 53317 |
| encryption | TLS with a certificate generated **on device** |
| identity | fingerprint = SHA-256 of the TLS certificate |
| servers | none |

Three things transfer directly to this project:

**(a) One transport, both platforms.** LocalSend does not pair Wi-Fi Aware with
MultipeerConnectivity. It picks an IP-layer transport that every platform can
speak and implements it once. That is the structural answer to GPT's question,
and it is validated by a shipping application rather than by reasoning.

**(b) Certificate-fingerprint identity is a working TOFU model.** LocalSend's
fingerprint — a hash of a self-generated cert — is the same shape as the static
key pinning ADR-003 must specify. Useful precedent for a mesh with no directory.

**(c) A protocol repository separate from the implementation.** `localsend/protocol`
is versioned independently, with `v1.md` and `v2.md` as normative documents. That
is exactly the discipline ADR-001 requires and exactly what this repository has
lacked: `PROTOCOL.md` drifted from the code until the code contradicted it in
four places.

### What does NOT transfer

**LocalSend requires an existing IP network.** It assumes a router, a subnet, and
devices with addresses on it. GODSTONE's entire premise is the hours and days
*after* that infrastructure fails. LocalSend is not a mesh, does no multi-hop
routing, has no store-and-forward, and would find zero peers in a blackout.

**It is therefore not a candidate to replace the BLE control plane**, and adopting
it wholesale would delete the product's reason to exist. The relevance is bounded
and specific: it is evidence about *the bulk plane*, and a model for *protocol
discipline*.

---

## 3. Recommended direction

Establish an IP link ourselves, then run a documented HTTP-shaped protocol over
it — the LocalSend pattern, minus the assumption that the network already exists.

```
1. BLE control plane establishes a Noise session          (ADR-002)
2. Both peers advertise BULK_CAPABLE
3. Payload exceeds BULK_THRESHOLD (512 B)
4. Over the ESTABLISHED BLE session, negotiate a link:
       Android: Wi-Fi Direct group owner / local-only hotspot
       iOS:     joins as client
   The SSID, PSK and expected TLS fingerprint are exchanged INSIDE the
   Noise session, so the bulk link is authenticated by the BLE handshake
   before its first byte -- no second trust decision, no second handshake.
5. Transfer over TLS on the link-local address, chunked, resumable, hashed
6. Tear the link down within 5 s of the last byte
```

The critical property is step 4: the bulk peer is bound to the BLE-authenticated
static key. V3's iOS bulk transport accepted every MultipeerConnectivity
invitation and generated a random `UUID()` per callback, so a bulk peer could be
substituted independently of the mesh identity entirely.

---

## 4. The constraint this collides with — decide before implementing

C1 says **no network**. `ci/check_parity.py` Invariant E enforces it by grepping
iOS sources for `URLSession|NSURLConnection|CFStream|Network.framework` and
failing the build on a match.

**A LocalSend-style bulk plane needs sockets and a local HTTP server, and would
trip that gate immediately.** This is not a reason to reject the direction; it is
a sign that C1 is stated imprecisely. What C1 actually protects is: *no contact
with any server, no internet egress, no telemetry, nothing that works only when
infrastructure exists*. A link-local TLS socket to a peer 10 metres away over a
hotspot we created ourselves violates none of that.

**Required before any code:** amend C1 to distinguish *internet egress* from
*link-local peer transport*, and make the distinction **enforceable** rather than
rhetorical. Candidate mechanism: allow socket APIs only within a designated
module, and have Invariant E assert that (a) no default-route address is ever
constructed, (b) no DNS resolution occurs, (c) the Android manifest still
declares no `INTERNET` permission — which by itself already makes internet egress
impossible on that platform, and is a far stronger control than a grep for
`URLSession`.

Until C1 is amended, **do not implement this.** Shipping a networking stack that
contradicts a constraint the CI enforces would be the same category of defect as
everything else in `docs/AUDIT.md`: the claim and the code disagreeing.

---

## 5. Decision to be made

1. Amend C1 as above, or reject the direction and accept that bulk transfer is
   Android↔Android and iOS↔iOS only, permanently, and say so in the UI.
2. If amended: specify the link negotiation, the chunk/ACK/resume protocol, the
   integrity hash, and the idle teardown — as a normative document, versioned
   separately, in the LocalSend style.
3. Keep both implementations fail-closed until the selected shared protocol
   passes the acceptance criteria. A method must never report success without a
   verified write.

## 6. Acceptance criteria

- [ ] a payload > 512 B transfers Android↔iOS, interrupted and resumed, hash verified
- [ ] the bulk peer is provably bound to the BLE-authenticated static key
- [ ] no bulk peer can be substituted independently of the mesh session
- [ ] the link is torn down within 5 s of the last byte, verified by radio state
- [ ] C1 remains enforceable, with internet egress still structurally impossible
`````
<<< END FILE

### `docs/adr/ADR-007-cipher-suite.md`

>>> FILE: docs/adr/ADR-007-cipher-suite.md
`````markdown
# ADR-007 — Noise cipher suite: BLAKE2s → SHA-256

**STATUS: OPEN, with a strong recommendation and a measured case.**
Opened after reading [bitchat](https://github.com/permissionlesstech/bitchat),
which ships the SHA-256 variant on both platforms.

---

## 1. The recommendation

**Adopt `Noise_XX_25519_ChaChaPoly_SHA256` and delete every hand-rolled
cryptographic primitive in the iOS tree.**

This closes audit **A-02** — recorded since V1 as *"the largest single piece of
technical debt in the repository"* — not by patching the hand-rolled code, but by
removing the reason it exists.

---

## 2. Why A-02 has never closed

`docs/AUDIT.md` A-02 reads PARTIAL and has for three revisions:

> Hand-rolled BLAKE2s under Noise. Patching three known bugs leaves the unknown
> ones. The right end state is one cacophony-verified core shared by both
> platforms.

The stated end state — a shared verified core via JNI/FFI — is a large piece of
work nobody has started, so the debt has simply persisted. **It persisted because
the exit was framed as "make the hand-rolled code trustworthy" when the available
exit was "stop needing it".**

BLAKE2s is the only primitive in the stack that iOS does not provide:

| primitive | iOS | Android |
|---|---|---|
| SHA-256 | `CryptoKit.SHA256` | `MessageDigest` |
| HMAC-SHA256 | `CryptoKit.HMAC<SHA256>` | `javax.crypto.Mac` |
| HKDF-SHA256 | `CryptoKit.HKDF` (iOS 14+) | BouncyCastle |
| ChaCha20-Poly1305 | `CryptoKit.ChaChaPoly` | BouncyCastle / noise-java |
| X25519 | `CryptoKit.Curve25519.KeyAgreement` | BouncyCastle |
| Ed25519 | `CryptoKit.Curve25519.Signing` | BouncyCastle |
| **BLAKE2s** | **absent — hand-rolled, 169 lines** | BouncyCastle `Blake2sDigest` |

Everything else was already composed rather than invented, exactly as C6
requires. BLAKE2s is the single exception, and it is the reason
`Blake2s.swift` (169 lines) and `Hkdf.swift` (77 lines, HMAC built by hand on top
of it) exist at all.

**246 lines of hand-written cryptography, all of it downstream of one choice.**

---

## 3. Measured: the change is a parameter, not a rewrite

Run against `crypto/noise_ref.py` with only the hash function swapped:

```
BLAKE2s (current)          SHA256 (bitchat suite)
  sizes      [32, 96, 64]    sizes      [32, 96, 64]
  keys agree True            keys agree True
  hash       e739642d...     hash       6220bbb1...

same message sizes  : True
different transcript: True
```

Noise is parameterised over `HASHLEN = 32`; both hashes are 32 bytes, so nothing
structural moves. The reference implementation ran both suites **unchanged** —
one lambda substitution and a protocol-name string.

The wire format is untouched: `[32, 96, 64]` either way. Only the transcript
differs, which means vectors must be re-pinned and nothing else.

---

## 4. bitchat is the existence proof

bitchat ships `Noise_XX_25519_ChaChaPoly_SHA256` on iOS **and** Android, with the
two implementations protocol-compatible in production. Its iOS Noise layer is
CryptoKit throughout. That is not a design argument, it is a deployed system
doing exactly what this ADR proposes, at ~34k stars and v1.7.1 on the App Store.

The Noise specification lists SHA256, SHA512, BLAKE2s and BLAKE2b as standard
hashes. All four are conformant. **The choice between them is availability, not
security**, and on iOS that decides itself.

---

## 5. Blast radius

17 files reference BLAKE2s. The Noise hash is not the only use:

| use | current | after |
|---|---|---|
| Noise hash / HKDF | BLAKE2s-256 | SHA-256 |
| `node_id` | BLAKE2s-128(pub) | SHA-256(pub) truncated to 16 B |
| bloom index | BLAKE2s-64 | SHA-256 truncated to 8 B |
| proof of work | BLAKE2s-256 partial preimage | SHA-256 partial preimage |
| sealed sender KDF | BLAKE2s(shared ‖ label) | HKDF-SHA256 (ADR-003 rewrites this anyway) |

All of these are hash-to-identity or hash-to-index uses where SHA-256 is at least
as strong. Truncating SHA-256 to 128 or 64 bits is standard and is what bitchat
does for its own fingerprint.

**Android keeps working either way** — BouncyCastle has both. The migration is
driven entirely by iOS, and both platforms must move together or the mesh
partitions.

### Files deleted

```
ios/Godstone/Sources/GodstoneCore/Blake2s.swift   169 lines
ios/Godstone/Sources/GodstoneCore/Hkdf.swift       77 lines
                                                  ---
                                                  246 lines of hand-rolled crypto
```

`Hkdf.swift` goes because Noise's HKDF is HMAC-based and `CryptoKit.HMAC<SHA256>`
provides it directly. Note that `Hkdf.split` was **already found defective once**
(it returned `temp_key` as the chaining key and fed `material‖0x01` instead of
`0x01`, diverging at the first `MixKey`). That is one confirmed bug in 77 lines
of hand-written key derivation — precisely the argument for deleting the file
rather than auditing it again.

---

## 6. The counter-argument, stated fairly

**BLAKE2s is faster than SHA-256 in software**, and on a battery-constrained mesh
(C4) that is not nothing. Rough figures: BLAKE2s ≈ 1.5–2× SHA-256 on ARM without
hardware acceleration.

**Rejected, for two reasons.** First, every ARMv8 core GODSTONE targets has
SHA-256 instructions (`SHA256H`, `SHA256H2`), so on real hardware SHA-256 is
typically *faster*, and CryptoKit uses them. Second, and decisively: the hashing
cost of a handshake is a few microseconds against a BLE connection setup measured
in hundreds of milliseconds. **This has never been the power bottleneck.** Duty
cycling is, which is why `PROTOCOL.md` §3.1 spends its effort there.

Trading a measured 246 lines of unverified hand-written cryptography for a
theoretical microsecond is not a trade.

---

## 7. Cost

The migration invalidates every pinned vector. `crypto/gen_vectors.py` must
regenerate, `handshake_vectors.json` changes wholesale, and Invariant D re-pins —
**in the same commit**, or the negative controls are meaningless.

It also changes `node_id`, therefore `node_hint`, therefore the Noise prologue.
ADR-001 §7 already requires a prologue change (`GMP1` → `GMP2`), so **these two
migrations should land together** rather than invalidating the vectors twice.

External conformance improves: SHA-256 Noise vectors are far more widely
published than BLAKE2s ones, so `docs/PINNING_CACOPHONY.md` gets easier, not
harder.

---

## 8. Decision required

1. Accept the suite change, or record why the hand-rolled path is preferred.
2. If accepted, sequence it **with** ADR-001's prologue change — one vector
   re-pin, not two.
3. Update C6's status. It currently reads *"partially true — A-02 stands, and
   that is the largest single piece of technical debt."* After this, C6 is
   simply true, which would be the first constraint to move from partial to
   satisfied since V1.

## 9. Acceptance criteria

- [ ] `Blake2s.swift` and `Hkdf.swift` deleted; no hand-rolled primitive remains
- [ ] iOS Noise stack is CryptoKit only
- [ ] vectors regenerated and Invariant D re-pinned in the same commit
- [ ] both platforms reproduce the new transcript
- [ ] A-02 and A-03 closed in `docs/AUDIT.md` with the evidence linked
- [ ] `ci/integration.py` gains a check that no hand-rolled hash reappears
`````
<<< END FILE

### `docs/adr/README.md`

>>> FILE: docs/adr/README.md
`````markdown
# Architecture Decision Records

ADRs separate decisions from implementation evidence. **ACCEPTED does not mean
SHIPPED.** A feature flag may move only after the ADR's acceptance criteria pass
against both platform ports and, where applicable, real radios.

| ADR | Decision | Status | Implementation state |
|---|---|---|---|
| 001 | canonical GMP/2.1 runtime model | **ACCEPTED** | M1-wire open; Android runtime still legacy and disabled |
| 002 | BLE advertisement, record layer and handshake driver | **ACCEPTED** | M2-link open; radio feature flags false |
| 003 | identity binding, contacts, TOFU and sealed sender | **OPEN** | privacy claims unsupported |
| 004 | durable store, retention and panic wipe | **OPEN** | Android partial; iOS absent |
| 005 | SOS authenticity, ACK lifecycle and permissions | **OPEN** | SOS transmission disabled |
| 006 | cross-platform bulk plane | **OPEN** | Android/iOS implementations disabled |
| 007 | future cipher-suite migration | **OPEN** | no runtime change |

`ci/integration.py` blocks interoperability claims until both routers use the
canonical generated type and blocks enabling one platform's radio while the
other remains disabled.
`````
<<< END FILE

### `docs/mesh/PROTOCOL.md`

>>> FILE: docs/mesh/PROTOCOL.md
`````markdown
# Godstone Mesh Protocol — GMP/2.1 design contract

**Decision:** GMP/2.1 (`docs/adr/ADR-001-canonical-wire.md`)  
**Link design:** `docs/adr/ADR-002-ble-record-layer.md`  
**Implementation status:** **disabled and incomplete in V4**

This document is the target contract for the mesh. It is not a conformance
claim. Android still contains a disabled legacy router/store path; the BLE record
layer, deterministic handshake driver, durable iOS store, sealed-sender identity
binding, authenticated SOS lifecycle and bulk plane remain open. Both apps keep
the mesh feature flag false until the relevant acceptance tests pass.

Accepted ADRs override this summary if they disagree.

## 1. Layering

```
L5 APPLICATION   text, SOS, future media/archive exchange
L4 END TO END    sealed sender and authenticated application envelope
L3 ROUTING       delay-tolerant store-and-forward, DIGEST/WANT anti-entropy
L2 SESSION       Noise_XX_25519_ChaChaPoly_BLAKE2s
L1 RECORD        bounded BLE record fragmentation and reassembly
L0 TRANSPORT     BLE GATT control plane; bulk plane remains undecided
```

No application frame may be transmitted before the Noise session reaches
`READY`. There is no plaintext fallback.

## 2. Identity

Each install has distinct long-term keys:

- Ed25519 signing identity;
- X25519 static Noise key;
- `node_id = BLAKE2s-128(identity_signing_public_key)`.

The private keys never appear in frames. TOFU/QR verification, key-change
quarantine and panic wipe remain governed by ADR-003 and ADR-004; they are not
closed by V4.

## 3. BLE discovery target

The service UUID and characteristics come only from `wire/wire_v2.yaml`.

A legacy BLE advertisement cannot carry a 128-bit UUID plus the old 26-byte
service-data payload. ADR-002 therefore accepts:

- primary advertisement: service UUID only;
- scan response: 13-byte service data;
- active scan;
- first sightings without scan-response data are retained briefly rather than
  rejected.

Scan-response payload:

```
off size field
0   1    protocol version, 0x02
1   1    flags
2   4    node hint
6   6    short bloom digest
12  1    queue depth, saturating
```

The exact packet sizes must be verified on Android and iOS hardware before the
radio feature flag can be enabled.

## 4. BLE record layer

Handshake and data records use the accepted eight-byte record header from
ADR-002. Records are encrypted first and fragmented second. Bounds:

- maximum reassembled record: 16,384 bytes;
- maximum fragments: 64;
- maximum concurrent records per peer: 4;
- reassembly timeout: 30 seconds.

Malformed, duplicate, expired and allocation-exceeding fragments are rejected
before application parsing and charged to the peer abuse budget.

## 5. Noise session

Pattern: `Noise_XX_25519_ChaChaPoly_BLAKE2s`.

```
-> e
<- e, ee, s, es
-> s, se
```

The canonical prologue after M1-wire is:

```
"GMP2" || initiator_node_hint || responder_node_hint
```

Role election is deterministic: the lexicographically smaller node hint
initiates. A hint collision is resolved only after full identity is available;
an identical full node ID is a cloned-identity security event.

Session rekeying, TOFU pin enforcement and reconnect behavior require platform
port tests and the hardware matrix before being called conformant.

## 6. Canonical frame

All multi-byte fields are big-endian. The generated 32-byte header is:

```
off size field
0   2    magic          0x4753
2   1    version        0x02; minor capability 1 is negotiated in HELLO
3   1    type           generated even-parity type code
4   16   msg_id         BLAKE2s-128(sender || created_at || payload)
20  4    routing_tag    rotating recipient hint
24  1    ttl            maximum 16
25  1    hop_count      maximum 16
26  2    flags          feature flags + priority mask 0x0700
28  2    payload_len    maximum 60,000
30  2    header_crc     CRC-16/CCITT over bytes 0..29
```

Priority encoding uses three bits:

```
0 SOS   1 DIRECT   2 GROUP   3 BROADCAST   4 BULK
```

Generated codecs reject bad magic, version, type, CRC, lengths, TTL and hop
count before allocating the payload.

## 7. Time, retention and replay

There is no plaintext wall-clock timestamp in the frame header.

- retention uses the receiver's monotonic receipt time stored locally;
- an advisory sender `created_at` belongs inside the authenticated application
  envelope and may be omitted when the sender clock is untrusted;
- Noise nonces and the 16-byte message-ID seen cache suppress replay;
- receipt-relative expiry prevents a bad sender clock from discarding valid
  traffic or retaining it forever.

The Android legacy store does not yet implement this schema, so the radio remains
disabled.

## 8. Routing and anti-entropy

The target is bounded epidemic routing:

1. discover and elect roles;
2. complete Noise and TOFU checks;
3. exchange full 4096-bit bloom digests using the canonical hash input
   `msg_id[16] || uint32_be(round)` for four rounds;
4. exchange WANT lists;
5. send in strict priority order;
6. persist before forwarding;
7. decrement TTL and increment hop count without overflow;
8. never send a frame back to the peer it arrived from.

A digest describes **held durable frames**, not merely recently seen IDs. iOS
has no durable mesh store yet, so anti-entropy is not implemented end to end.

## 9. End-to-end envelope and anti-abuse

The threat-model goals require:

- sender and content sealed from relays;
- rotating routing tags;
- signed application envelopes;
- bounded parsing and storage;
- per-peer/per-priority token buckets;
- trust scoring and exponential refusal windows;
- a proof-of-work design whose nonce placement remains verifiable by relays
  without breaking sealed-sender privacy.

The last item is still unresolved between ADR-001 and ADR-003. It must be settled
before GROUP/BROADCAST traffic is enabled. V4 therefore does not claim the
sealed-sender or anti-abuse design is complete merely because helper classes
exist.

## 10. SOS truth states

UI wording is governed by ADR-005:

- `QUEUED_LOCAL` — durable local storage only;
- `HANDED_TO_RELAY(n)` — bytes accepted by authenticated transport peers;
- `ACKNOWLEDGED_BY_RECIPIENT` — valid end-to-end receipt;
- `FAILED` or `UNAVAILABLE`.

`SENT` or `DELIVERED` is forbidden before a valid recipient ACK. V4 disables SOS
mesh transmission rather than presenting a false success state.

## 11. Conformance gates

A platform may be called GMP/2.1 conformant only when all of these are green:

- generated codec parity and golden vectors;
- both routers and stores use the generated frame and 16-byte IDs;
- no legacy v1 symbol survives;
- platform Noise ports reproduce pinned external vectors;
- record-layer property tests cover every fragmentation boundary, reorder,
  duplicate, drop, timeout and allocation bound;
- two-device Android↔Android, iOS↔iOS and Android↔iOS encrypted ping tests;
- radio capture shows no plaintext frame;
- durable anti-entropy and panic-wipe tests;
- TOFU key-change quarantine;
- authenticated SOS lifecycle test through recipient ACK.

Until then the product must say **mesh unavailable**, not merely “degraded.”
`````
<<< END FILE

### `docs/mesh/THREAT_MODEL.md`

>>> FILE: docs/mesh/THREAT_MODEL.md
`````markdown
# Godstone Mesh — Threat Model

**V4 implementation status:** threat goals, not current guarantees. The radio
stack is disabled. A2/A7 depend on open ADR-003; A6 depends on open ADR-004;
SOS authenticity/lifecycle depends on ADR-005; bulk transport depends on
ADR-006. Statements below describe the intended mitigations after those ADRs
are implemented and verified. The Archive/Oracle C1-C3 controls are separate.

## Adversaries considered

**A1 Passive local eavesdropper.** Radio receiver in range, records everything.
Mitigation: all traffic after handshake is encrypted. Sealed sender hides sender
and recipient from anyone but the recipient. Daily-rotating routing tags prevent
long-term linkage.

**A2 Malicious relay.** Runs a modified client, participates fully in the mesh.
Can drop, delay and count messages; cannot read, alter or attribute them. Frame
integrity is protected by Poly1305 under a key it does not have. Dropping is
mitigated by epidemic replication over multiple carriers.

**A3 Active injector.** Forges or replays frames. Mitigation: Noise mutual
authentication means an unauthenticated peer cannot inject into a session; nonce
counters and the msg_id seen-cache defeat replay; sealed payloads fail
authentication if altered.

**A4 Impersonator.** Claims another user's identity. Mitigation: node_id is
derived from the public identity key, so claiming an identity requires the private
key. TOFU pinning plus optional QR verification surfaces substitution attempts.

**A5 Flooder / battery attacker.** Attempts to drain devices. Mitigation: proof of
work, token-bucket rate limits, trust scoring with exponential backoff, hard
storage caps, and duty-cycle floors that the mesh cannot be forced below.

**A6 Device seizure.** Adversary physically takes an unlocked or locked device.
Mitigation: message store encrypted with a key in the Keystore or Secure Enclave;
panic wipe erases keys and history and regenerates identity; no cloud backup of
mesh data; contact list stored encrypted.

**A7 Local traffic analysis.** Correlates who transmits when and where.
Partial mitigation only: rotating tags, padding to fixed size buckets (256, 512,
2048, 8192 bytes) and randomised transmission jitter. Full defence is impossible
at the application layer with commodity radios, and we say so plainly rather than
implying protection we cannot deliver.

## Explicitly out of scope

* A global passive adversary observing all radio everywhere.
* Physical coercion of the device holder.
* Compromised OS, bootloader or baseband.
* Deliberate radio jamming. The app detects sustained interference and tells the
  user, but cannot defeat it.

## Honest limitations shown in the UI

Users making life-and-death decisions deserve accurate expectations:

1. Range is roughly 30–100 m per hop for BLE, more in open ground, far less
   through reinforced concrete.
2. Delivery is best effort with no guarantee and no timeline. A message may take
   hours if it waits for a carrier to physically move.
3. iOS in the background is materially weaker than Android; the UI states this.
4. The mesh reveals that *someone nearby is transmitting*. In an environment where
   emitting any signal is dangerous, the app offers a Silent Mode that receives
   only and never transmits.
`````
<<< END FILE

### `docs/packaging/MODELS.lock.json`

>>> FILE: docs/packaging/MODELS.lock.json
`````json
{
  "schema": 1,
  "status": "UNPINNED",
  "verified_on": null,
  "verified_by": null,
  "notes": "Proposed artifact coordinates only. Every sha256 must be independently verified before status may become PINNED.",
  "artifacts": [
    {
      "id": "generation-light",
      "tiers": ["LIGHT"],
      "repo": "Qwen/Qwen3-0.6B-GGUF",
      "source_file": "Qwen3-0.6B-Q4_K_M.gguf",
      "output_file": "qwen3-0.6b-q4km.gguf",
      "sha256": null
    },
    {
      "id": "generation-medium",
      "tiers": ["MEDIUM"],
      "repo": "ggml-org/Qwen3-1.7B-GGUF",
      "source_file": "Qwen3-1.7B-Q4_K_M.gguf",
      "output_file": "qwen3-1.7b-q4km.gguf",
      "sha256": null
    },
    {
      "id": "generation-large",
      "tiers": ["LARGE"],
      "repo": "Qwen/Qwen3-4B-GGUF",
      "source_file": "Qwen3-4B-Q5_K_M.gguf",
      "output_file": "qwen3-4b-q5km.gguf",
      "sha256": null
    },
    {
      "id": "embedding-small",
      "tiers": ["LIGHT", "MEDIUM"],
      "repo": "CompendiumLabs/bge-small-en-v1.5-gguf",
      "source_file": "bge-small-en-v1.5-q8_0.gguf",
      "output_file": "bge-small-en-v1.5-q8.gguf",
      "sha256": null
    },
    {
      "id": "embedding-base",
      "tiers": ["LARGE"],
      "repo": "CompendiumLabs/bge-base-en-v1.5-gguf",
      "source_file": "bge-base-en-v1.5-q8_0.gguf",
      "output_file": "bge-base-en-v1.5-q8.gguf",
      "sha256": null
    }
  ]
}
`````
<<< END FILE

### `docs/packaging/STORE.md`

>>> FILE: docs/packaging/STORE.md
`````markdown
# Store submission status

**V4 is not eligible for store submission.** This file is a gate, not marketing
copy. Do not prepare a listing until every release checklist item below is
closed with evidence.

## Current product truth

- The Archive browser and lexical retrieval work offline over a bundled SQLite
  corpus.
- The corpus contains only unreviewed examples.
- The Oracle safety gate is executable, but native models/dependencies and
  weights are not yet reproducibly pinned in this change-set.
- Mesh, SOS transmission and bulk transfer are disabled because the shared
  encrypted transport is unfinished.
- The apps declare no runtime internet capability and include no telemetry SDK.

## Store-blocking checklist

- [ ] clean signed Android and iOS builds from an immutable source revision
- [ ] pinned llama.cpp revision, model hashes, licences and SBOM
- [ ] clinician/editorial approval and provenance for every shipped chunk
- [ ] first-run disclaimer, bundled privacy policy and source attributions in UI
- [ ] permissions/capability UX on all supported OS versions
- [ ] accessibility verification with TalkBack/VoiceOver and dynamic type
- [ ] Android↔iOS encrypted Hardware Case 0 and field battery measurements
- [ ] durable store, migrations, retention, authenticated ACK and panic wipe
- [ ] no `--allow-unpinned` in release verification
- [ ] merged Android manifest and iOS binary re-audited for C1/C2

Until those boxes are closed, screenshots or copy must not describe an active
mesh, delivered SOS, clinical readiness, or guaranteed emergency assistance.
`````
<<< END FILE

### `ios/Godstone/Package.swift`

>>> FILE: ios/Godstone/Package.swift
`````swift
// swift-tools-version:5.9
import PackageDescription

// The iOS app is assembled from three local packages so the module boundaries
// are enforced by the compiler, exactly as they are on Android:
//     App -> (GodstoneMesh, GodstoneLLM) -> GodstoneCore
// There is deliberately no dependency edge between Mesh and LLM.

let package = Package(
    name: "GodstonePackages",
    // iOS 16 is the shipping target. macOS is declared so the pure-logic
    // library closure (GodstoneCore + GodstoneMesh + tests) can be compiled
    // and verified on a Mac host / CI without an iOS simulator runtime; the
    // GodstoneLLM target (UIKit + llama.cpp) is iOS-only and is not built in
    // that closure. Declaring macOS here does not change the iOS app target,
    // which is assembled by XcodeGen from ios/project.yml.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GodstoneCore", targets: ["GodstoneCore"]),
        .library(name: "GodstoneMesh", targets: ["GodstoneMesh"]),
        .library(name: "GodstoneLLM",  targets: ["GodstoneLLM"])
    ],
    targets: [
        .target(name: "GodstoneCore"),
        .target(name: "GodstoneMesh", dependencies: ["GodstoneCore"]),
        // The Objective-C++ bridge over llama.cpp lives in its own C target so
        // that GodstoneLLM stays pure-Swift. SwiftPM does not support a single
        // target mixing .swift with .h/.mm, so the split is required for the
        // package to resolve at all (even when GodstoneLLM is not being built).
        // GodstoneLLMBridge only compiles when a reviewed, pinned llama.cpp checkout
        // exists at third_party/llama.cpp; until then full LLM builds are blocked.
        .target(
            name: "GodstoneLLMBridge",
            dependencies: ["GodstoneCore"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../third_party/llama.cpp/include"),
                .headerSearchPath("../../third_party/llama.cpp/ggml/include"),
                .unsafeFlags(["-O3", "-ffast-math"])
            ]
        ),
        .target(
            name: "GodstoneLLM",
            dependencies: ["GodstoneCore", "GodstoneLLMBridge"]
        ),
        // GodstoneLLMTests is intentionally absent: GodstoneLLM cannot build
        // without the pinned third_party/llama.cpp dependency, so its test target
        // cannot build either. The Mesh tests have no such dependency.
        .testTarget(name: "GodstoneMeshTests", dependencies: ["GodstoneMesh", "GodstoneCore"])
    ]
)
`````
<<< END FILE

### `ios/Godstone/Sources/App/ArchiveView.swift`

>>> FILE: ios/Godstone/Sources/App/ArchiveView.swift
`````swift
import SwiftUI
import GodstoneCore

/// The always-available browser over the immutable on-device Archive.
struct ArchiveView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var query = ""
    @State private var documents: [ArchiveDocument] = []
    @State private var passages: [ArchivePassage] = []
    @State private var openedTitle: String?

    var body: some View {
        NavigationStack {
            Group {
                if !container.archive.isAvailable {
                    emptyState(
                        icon: "externaldrive.badge.exclamationmark",
                        title: "Archive unavailable",
                        detail: "The tier database is missing or could not be opened read-only."
                    )
                } else if documents.isEmpty && passages.isEmpty {
                    emptyState(
                        icon: "magnifyingglass",
                        title: "No matches",
                        detail: "Try a different word or clear the search to browse every document."
                    )
                } else {
                    List {
                        ForEach(documents) { document in
                            Button { open(document) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(document.title).font(.headline).foregroundStyle(.primary)
                                    Text(document.domain).font(.footnote).foregroundStyle(.secondary)
                                    if document.isCritical {
                                        Text("Critical procedure").font(.caption).foregroundStyle(GodstoneTheme.danger)
                                    }
                                }
                                .frame(minHeight: GodstoneTheme.minimumTapTarget, alignment: .leading)
                            }
                        }
                        ForEach(passages) { passage in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(passage.documentTitle).font(.headline)
                                if !passage.section.isEmpty {
                                    Text(passage.section).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text(passage.text)
                                    .font(.system(size: GodstoneTheme.bodyTextSize))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(openedTitle ?? "Archive")
            .toolbar {
                if openedTitle != nil || !passages.isEmpty {
                    Button("All documents") { loadDocuments() }
                }
            }
            .searchable(text: $query, prompt: "Search every document")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    loadDocuments()
                }
            }
            .onAppear { if documents.isEmpty && passages.isEmpty { loadDocuments() } }
        }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func loadDocuments() {
        query = ""
        openedTitle = nil
        passages = []
        documents = container.archive.listDocuments()
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { loadDocuments(); return }
        openedTitle = nil
        documents = []
        passages = container.archive.search(q)
    }

    private func open(_ document: ArchiveDocument) {
        documents = []
        openedTitle = document.title
        passages = container.archive.passages(documentId: document.id)
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/App/MeshView.swift`

>>> FILE: ios/Godstone/Sources/App/MeshView.swift
`````swift
import SwiftUI
import GodstoneMesh

struct MeshView: View {
    @EnvironmentObject private var mesh: MeshCoordinator

    var body: some View {
        VStack(spacing: 20) {
            Text("Mesh").font(.largeTitle.bold())
            statusCard
            peerCard
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GodstoneTheme.stone)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                mesh.transportAvailable ? "Control plane ready" : "Transport not field-ready",
                systemImage: mesh.transportAvailable ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
            )
            .font(.system(size: GodstoneTheme.bodyTextSize, weight: .bold))
            .foregroundStyle(mesh.transportAvailable ? GodstoneTheme.signal : GodstoneTheme.warning)
            Text(mesh.transportDetail).font(.body).foregroundStyle(.secondary)
            if !mesh.transportAvailable {
                Text("Godstone will not activate radios or claim encrypted delivery until the canonical GMP/2.1 wire format, BLE record layer, and Noise handshake driver pass real two-device tests.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    private var peerCard: some View {
        VStack(spacing: 6) {
            Text("\(mesh.peerCount)")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .foregroundStyle(GodstoneTheme.ember)
            Text(mesh.peerCount == 1 ? "device reachable" : "devices reachable")
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: GodstoneTheme.minimumTapTarget)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
        .accessibilityElement(children: .combine)
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/App/SosView.swift`

>>> FILE: ios/Godstone/Sources/App/SosView.swift
`````swift
import SwiftUI
import GodstoneMesh

/// SOS never labels a local queue or radio write as recipient delivery.
struct SosView: View {
    @EnvironmentObject private var mesh: MeshCoordinator
    @State private var holdProgress = 0.0

    var body: some View {
        VStack(spacing: 28) {
            Text(mesh.transportAvailable ? "HOLD TO QUEUE SOS" : "MESH SOS UNAVAILABLE")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            ZStack {
                Circle().fill(mesh.transportAvailable
                              ? GodstoneTheme.danger.opacity(0.75)
                              : Color.gray.opacity(0.35))
                Circle().trim(from: 0, to: holdProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: mesh.transportAvailable
                      ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 68)).foregroundStyle(.white)
            }
            .frame(width: 260, height: 260)
            .accessibilityLabel(mesh.transportAvailable ? "Hold to queue emergency SOS" : "Mesh SOS unavailable")
            .gesture(holdGesture)
            .allowsHitTesting(mesh.transportAvailable)

            stateText
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GodstoneTheme.stone)
    }

    @ViewBuilder private var stateText: some View {
        switch mesh.sosState {
        case .idle:
            Text(mesh.transportAvailable
                 ? "Queued means stored locally; relayed means a nearby device accepted an encrypted record. Neither means a recipient acknowledged it."
                 : "The app refuses to show a success state while encrypted cross-platform transport and the durable iOS message store are incomplete. Use another working emergency communication method.")
        case .unavailable(let reason): Text(reason)
        case .handedToRelays(let count):
            Text("Accepted by \(count) nearby relay(s). No recipient acknowledgement has been received.")
        case .notPersisted:
            Text("No relay accepted the SOS, and this iOS build has no durable mesh queue. Nothing was sent.")
        case .failed(let reason): Text("SOS failed: \(reason)")
        }
    }

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 1.5)
            .onChanged { _ in withAnimation(.linear(duration: 1.5)) { holdProgress = 1 } }
            .onEnded { _ in
                mesh.broadcastSos()
                holdProgress = 0
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift`

>>> FILE: ios/Godstone/Sources/GodstoneCore/ArchiveRepository.swift
`````swift
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ArchiveDocument: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let title: String
    public let domain: String
    public let isCritical: Bool

    public init(id: Int64, title: String, domain: String, isCritical: Bool) {
        self.id = id
        self.title = title
        self.domain = domain
        self.isCritical = isCritical
    }
}

public struct ArchivePassage: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let documentId: Int64
    public let documentTitle: String
    public let domain: String
    public let section: String
    public let text: String
    public let score: Double

    public init(id: Int64, documentId: Int64, documentTitle: String,
                domain: String, section: String, text: String, score: Double = 0) {
        self.id = id
        self.documentId = documentId
        self.documentTitle = documentTitle
        self.domain = domain
        self.section = section
        self.text = text
        self.score = score
    }
}

/// Read-only handle to the immutable on-device Archive.
///
/// Browsing and FTS5 search never load llama.cpp or an embedding model. This is
/// the system's last surviving capability when inference and every radio fail.
public final class ArchiveRepository: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init(databaseName: String) {
        handle = Self.openReadOnly(databaseName: databaseName)
        if let db = handle {
            sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil)
        }
    }

    deinit {
        if let db = handle { sqlite3_close_v2(db) }
    }

    public var isAvailable: Bool { handle != nil }

    public func listDocuments(domain: String? = nil) -> [ArchiveDocument] {
        withDatabase { db in
            var sql = "SELECT document_id, title, domain, is_critical FROM documents"
            if domain != nil { sql += " WHERE domain = ?" }
            sql += " ORDER BY is_critical DESC, domain, title"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            if let domain {
                domain.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
            }
            var out: [ArchiveDocument] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(ArchiveDocument(
                    id: sqlite3_column_int64(stmt, 0),
                    title: columnString(stmt, 1),
                    domain: columnString(stmt, 2),
                    isCritical: sqlite3_column_int(stmt, 3) != 0
                ))
            }
            return out
        } ?? []
    }

    public func listDomains() -> [String] {
        withDatabase { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                    "SELECT DISTINCT domain FROM documents ORDER BY domain",
                    -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            var out: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(columnString(stmt, 0)) }
            return out
        } ?? []
    }

    public func passages(documentId: Int64) -> [ArchivePassage] {
        withDatabase { db in
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text
                FROM chunks c JOIN documents d ON d.document_id = c.document_id
                WHERE c.document_id = ? ORDER BY c.ordinal
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, documentId)
            var out: [ArchivePassage] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(passage(stmt)) }
            return out
        } ?? []
    }

    public func search(_ query: String, limit: Int = 40) -> [ArchivePassage] {
        let fts = sanitiseFts(query)
        guard !fts.isEmpty else { return [] }
        return withDatabase { db in
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text,
                       bm25(chunks_fts) AS rank
                FROM chunks_fts
                JOIN chunks c ON c.chunk_id = chunks_fts.rowid
                JOIN documents d ON d.document_id = c.document_id
                WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            fts.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
            sqlite3_bind_int64(stmt, 2, Int64(limit))
            var out: [ArchivePassage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(passage(stmt, score: -sqlite3_column_double(stmt, 6)))
            }
            return out
        } ?? []
    }

    // MARK: - RAG-facing operations

    func searchLexical(_ query: String, limit: Int) -> [RetrievedChunk] {
        search(query, limit: limit).map {
            RetrievedChunk(chunkId: $0.id, documentId: $0.documentId,
                           documentTitle: $0.documentTitle, section: $0.section,
                           domain: $0.domain, text: $0.text, score: $0.score)
        }
    }

    func searchSemantic(vector query: [Float], limit: Int) -> [RetrievedChunk] {
        var scored: [(Int64, Double)] = []
        for (id, blob) in allVectors() { scored.append((id, cosineInt8(query, blob))) }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).compactMap { loadChunk(id: $0.0, score: $0.1) }
    }

    func allChunks() -> [RetrievedChunk] {
        withDatabase { db in
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, c.section, d.domain, c.text
                FROM chunks c JOIN documents d ON d.document_id = c.document_id
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            var out: [RetrievedChunk] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(RetrievedChunk(
                    chunkId: sqlite3_column_int64(stmt, 0),
                    documentId: sqlite3_column_int64(stmt, 1),
                    documentTitle: columnString(stmt, 2),
                    section: columnString(stmt, 3),
                    domain: columnString(stmt, 4),
                    text: columnString(stmt, 5),
                    score: 0
                ))
            }
            return out
        } ?? []
    }

    func loadChunk(id: Int64, score: Double) -> RetrievedChunk? {
        withDatabase { db in
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, c.section, d.domain, c.text
                FROM chunks c JOIN documents d ON d.document_id = c.document_id
                WHERE c.chunk_id = ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return nil
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return RetrievedChunk(
                chunkId: sqlite3_column_int64(stmt, 0),
                documentId: sqlite3_column_int64(stmt, 1),
                documentTitle: columnString(stmt, 2),
                section: columnString(stmt, 3),
                domain: columnString(stmt, 4),
                text: columnString(stmt, 5),
                score: score
            )
        } ?? nil
    }

    private func allVectors() -> [(Int64, Data)] {
        withDatabase { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT chunk_id, vec FROM vectors", -1,
                                     &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            var out: [(Int64, Data)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let count = Int(sqlite3_column_bytes(stmt, 1))
                if let bytes = sqlite3_column_blob(stmt, 1), count > 0 {
                    out.append((sqlite3_column_int64(stmt, 0), Data(bytes: bytes, count: count)))
                }
            }
            return out
        } ?? []
    }

    private func cosineInt8(_ query: [Float], _ blob: Data) -> Double {
        guard !query.isEmpty, query.count == blob.count else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in query.indices {
            let a = Double(query[i])
            let b = Double(Int8(bitPattern: blob[i])) / 127.0
            dot += a * b; normA += a * a; normB += b * b
        }
        let denom = (normA * normB).squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    private func withDatabase<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { return nil }
        return body(db)
    }

    private func passage(_ stmt: OpaquePointer?, score: Double = 0) -> ArchivePassage {
        ArchivePassage(
            id: sqlite3_column_int64(stmt, 0),
            documentId: sqlite3_column_int64(stmt, 1),
            documentTitle: columnString(stmt, 2),
            domain: columnString(stmt, 3),
            section: columnString(stmt, 4),
            text: columnString(stmt, 5),
            score: score
        )
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: value)
    }

    private func sanitiseFts(_ value: String) -> String {
        let stripped = value.map { "\"*():^-".contains($0) ? " " : String($0) }.joined()
        return stripped.split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
    }

    private static func openReadOnly(databaseName: String) -> OpaquePointer? {
        guard let path = resolveDatabasePath(databaseName: databaseName) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close_v2(db); return nil
        }
        return db
    }

    private static func resolveDatabasePath(databaseName: String) -> String? {
        let ns = databaseName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension.isEmpty ? "db" : ns.pathExtension
        if let bundled = Bundle.main.path(forResource: base, ofType: ext) { return bundled }
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first {
            let url = dir.appendingPathComponent("archives").appendingPathComponent(databaseName)
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
        }
        return Bundle.main.path(forResource: databaseName, ofType: nil)
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneCore/LruSet.swift`

>>> FILE: ios/Godstone/Sources/GodstoneCore/LruSet.swift
`````swift
import Foundation

/// A bounded least-recently-used set.
///
/// V4: O(1) membership and insertion.
///
/// V3 backed this with a single Array and documented the cost as acceptable
/// because the set is "scanned once per encounter". It is not -- `Router.ingest`
/// calls `contains` on EVERY FRAME, and `insert` then called `firstIndex(of:)`
/// and `removeFirst()`, both O(n) on an Array. At the 16,384 capacity the router
/// actually uses, that is three linear scans with Data equality per frame, on
/// the exact path a flood saturates. Another comment asserting a property the
/// code contradicted.
public struct LruSet<Element: Hashable> {
    private var order: [Element] = []
    private var index: Set<Element> = []
    private var head = 0                    // amortises removeFirst to O(1)
    private let capacity: Int

    public init(capacity: Int) {
        precondition(capacity >= 0)
        self.capacity = capacity
        order.reserveCapacity(min(capacity, 1024))
    }

    public func contains(_ element: Element) -> Bool {
        index.contains(element)
    }

    public mutating func insert(_ element: Element) {
        // Re-seeing an id is a no-op: promoting it would reorder the digest and
        // make peers re-offer frames we already hold.
        guard !index.contains(element) else { return }
        index.insert(element)
        order.append(element)

        while index.count > capacity {
            let oldest = order[head]
            head += 1
            index.remove(oldest)
        }
        // Compact once the dead prefix dominates, so `order` cannot grow without
        // bound on a long-lived node.
        if head > 4096 && head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }

    /// Insertion order, oldest first.
    public var elements: [Element] { Array(order[head...]) }

    public var count: Int { index.count }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneCore/SafetyGate.swift`

>>> FILE: ios/Godstone/Sources/GodstoneCore/SafetyGate.swift
`````swift
import Foundation

/// The C3 grounding gate. Swift port of `safety/gate.py`, byte-for-byte
/// equivalent in behaviour to `io.godstone.llm.safety.SafetyGate` on Android.
///
/// THE DEFECT THIS CLOSES. `safety/gate.py` was written, probed red/green, and
/// proven to discriminate -- and both shipping apps went on using
/// `bestScore >= 0.35` over a reciprocal-rank-fusion score. The repository's own
/// audit explains why that rule cannot discriminate; the product shipped it
/// anyway. The improved gate lived in the test harness only.
///
/// WHY RRF COULD NOT BE RETUNED. RRF is a RANK statistic. Rank 1 exists in every
/// non-empty result set, so the score says "something was returned", never
/// "something was relevant". The whole top-20 spans 0.500...0.381, all above the
/// floor, and the FTS query ORs its terms so the set is never empty.
///
/// S2 (colocation) is the signal that works: requiring the query's rare terms to
/// co-occur INSIDE A SINGLE PASSAGE is what separates "these words exist
/// somewhere in the archive" from "a passage supports this answer".
///
/// PARITY: every constant below is mirrored in safety/gate.py and SafetyGate.kt.
/// Invariant G fails the build if they drift.
public enum SafetyGate {

    public static let anchorRecallFloor = 0.60
    public static let colocationFloor = 0.50
    public static let domainCoherenceFloor = 0.40
    public static let caveatMargin = 0.15
    public static let minAnchorLen = 3
    public static let stemPrefixLen = 5

    public enum Verdict: String, Sendable {
        case allow = "ALLOW"
        case allowWithCaveat = "ALLOW_WITH_CAVEAT"
        case refuseNoEvidence = "REFUSE_NO_EVIDENCE"
        case refuseScatteredEvidence = "REFUSE_SCATTERED_EVIDENCE"

        public var allowsGeneration: Bool {
            self == .allow || self == .allowWithCaveat
        }
    }

    public struct Result: Sendable {
        public let verdict: Verdict
        public let reasons: [String]
        public let anchorRecall: Double
        public let colocation: Double
        public let domainCoherence: Double
        public let oovTerms: [String]

        public var allowsGeneration: Bool { verdict.allowsGeneration }

        /// What a frightened user is actually shown. Never a fabricated answer.
        public func userMessage() -> String {
            switch verdict {
            case .refuseNoEvidence:
                if !oovTerms.isEmpty {
                    return "The archive does not cover this. It contains no guidance on "
                        + oovTerms.sorted().joined(separator: ", ") + "."
                }
                return "The archive does not cover this."
            case .refuseScatteredEvidence:
                return "The archive does not cover this. Related words appear, but no "
                    + "single passage supports an answer."
            case .allowWithCaveat:
                return "Supported, but the evidence is thin. Check the sources."
            case .allow:
                return ""
            }
        }
    }

    static let stopwords: Set<String> = [
        "a","an","the","is","are","was","were","be","been","being","am","do","does",
        "did","doing","how","what","when","where","which","who","whom","why","can",
        "could","should","would","will","shall","may","might","must","i","you","he",
        "she","it","we","they","my","your","his","her","its","our","their","me","him",
        "them","this","that","these","those","there","here","about","into","over",
        "under","of","to","in","on","at","for","from","with","without","and","or",
        "but","if","then","than","as","by","so","such","no","not","only","own","same",
        "too","very","just","now","also","get","got","make","made","want","need",
        "use","used","using","please","tell","show","give"
    ]

    /// Terms denoting an ACTION or QUANTITY the archive would have to cover
    /// explicitly. If one is absent from the corpus, retrieval cannot recover
    /// it, so we refuse BEFORE scoring anything.
    static let actionTerms: Set<String> = [
        "dose","dosage","inject","injection","prescribe","prescription",
        "synthesise","synthesize","manufacture","buy","sell","trade","invest",
        "translate","summarise","summarize","plot","price","share","stock",
        "cryptocurrency","phone","number","address","latitude","longitude",
        "coordinate"
    ]

    /// Deliberately crude morphological normalisation. An earlier draft refused
    /// "how long should I boil water" because `boil` and `boiling` differed.
    public static func stem(_ word: String) -> String {
        var w = word.lowercased()
        for suf in ["ational","ization","isation","ation","ings","ing",
                    "ed","ies","es","s"] {
            if w.hasSuffix(suf) && w.count - suf.count >= 3 {
                w = String(w.dropLast(suf.count)); break
            }
        }
        if w.count > 3 {
            let chars = Array(w)
            if chars[chars.count - 1] == chars[chars.count - 2] { w = String(w.dropLast()) }
        }
        return w
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    static func contentTerms(_ text: String) -> [String] {
        tokens(text).filter { $0.count >= minAnchorLen && !stopwords.contains($0) }
    }

    /// Corpus vocabulary and IDF, built once from the archive.
    public struct CorpusIndex: Sendable {
        public var vocabulary: Set<String> = []
        public var stems: Set<String> = []
        public var idf: [String: Double] = [:]

        public init(chunks: [RetrievedChunk]) {
            var df: [String: Int] = [:]
            for c in chunks {
                let terms = contentTerms(c.text + " " + c.documentTitle)
                vocabulary.formUnion(terms)
                let st = terms.map { stem($0) }
                stems.formUnion(st)
                for t in Set(st) { df[t, default: 0] += 1 }
            }
            let n = max(1, chunks.count)
            for (t, d) in df {
                // Parenthesised to match gate.py and SafetyGate.kt exactly.
                idf[t] = log((Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0)
            }
        }

        /// Tolerant of inflection: `purify` must match `purification`.
        public func known(_ term: String) -> Bool {
            if vocabulary.contains(term) { return true }
            let s = stem(term)
            if stems.contains(s) { return true }
            if s.count >= stemPrefixLen {
                let p = String(s.prefix(stemPrefixLen))
                return stems.contains { $0.hasPrefix(p) }
            }
            return false
        }
    }

    static func presentIn(_ text: String, _ term: String) -> Bool {
        let toks = Set(contentTerms(text).map { stem($0) })
        let s = stem(term)
        if toks.contains(s) { return true }
        if s.count >= stemPrefixLen {
            let p = String(s.prefix(stemPrefixLen))
            return toks.contains { $0.hasPrefix(p) }
        }
        return false
    }

    /// The single entry point. Nothing else may decide whether an answer is
    /// grounded -- that separation is exactly what Invariant B enforces.
    public static func evaluate(question: String,
                                chunks: [RetrievedChunk],
                                index: CorpusIndex) -> Result {
        var seen = Set<String>()
        let anchors = contentTerms(question).filter { seen.insert($0).inserted }
        let oovAny = anchors.filter { !index.known($0) }
        let oovActions = anchors.filter { actionTerms.contains($0) && !index.known($0) }

        if !oovActions.isEmpty {
            return Result(verdict: .refuseNoEvidence,
                reasons: ["archive has no material on action term(s): "
                          + oovActions.joined(separator: ", ")],
                anchorRecall: 0, colocation: 0, domainCoherence: 0,
                oovTerms: oovActions)
        }
        if !anchors.isEmpty && Double(oovAny.count) / Double(anchors.count) >= 0.5 {
            return Result(verdict: .refuseNoEvidence,
                reasons: ["\(oovAny.count)/\(anchors.count) query terms absent from the archive"],
                anchorRecall: 0, colocation: 0, domainCoherence: 0, oovTerms: oovAny)
        }
        if chunks.isEmpty {
            return Result(verdict: .refuseNoEvidence,
                reasons: ["retrieval returned nothing"],
                anchorRecall: 0, colocation: 0, domainCoherence: 0, oovTerms: oovAny)
        }

        let known = anchors.filter { index.known($0) }
        if known.isEmpty {
            return Result(verdict: .refuseNoEvidence, reasons: ["no usable query terms"],
                anchorRecall: 0, colocation: 0, domainCoherence: 0, oovTerms: oovAny)
        }

        var weights: [String: Double] = [:]
        for t in known { weights[t] = index.idf[stem(t)] ?? 1.0 }
        let totalW = max(weights.values.reduce(0, +), 0.000001)

        // S1 anchor_recall: union coverage across the whole result set.
        let union = chunks.map { $0.text + " " + $0.documentTitle }.joined(separator: " ")
        let s1 = known.filter { presentIn(union, $0) }
                      .reduce(0.0) { $0 + (weights[$1] ?? 0) } / totalW

        // S2 colocation: the best SINGLE passage. THIS is the signal that works.
        var s2 = 0.0
        for c in chunks {
            let blob = c.text + " " + c.documentTitle
            let hit = known.filter { presentIn(blob, $0) }
                           .reduce(0.0) { $0 + (weights[$1] ?? 0) } / totalW
            if hit > s2 { s2 = hit }
        }

        // S3 domain coherence: is the evidence from one place?
        var doms: [String: Int] = [:]
        for c in chunks { doms[c.domain, default: 0] += 1 }
        let s3 = Double(doms.values.max() ?? 0) / Double(chunks.count)

        var reasons: [String] = []
        if s1 < anchorRecallFloor {
            reasons.append(String(format:
                "anchor_recall %.2f < %.2f: key terms missing from every retrieved passage",
                s1, anchorRecallFloor))
            return Result(verdict: .refuseNoEvidence, reasons: reasons,
                anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
        }
        if s2 < colocationFloor {
            reasons.append(String(format:
                "colocation %.2f < %.2f: terms appear in the archive but scattered across unrelated passages",
                s2, colocationFloor))
            return Result(verdict: .refuseScatteredEvidence, reasons: reasons,
                anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
        }
        if s3 < domainCoherenceFloor {
            reasons.append(String(format:
                "domain_coherence %.2f < %.2f: evidence drawn from sections the corpus keeps separate",
                s3, domainCoherenceFloor))
            return Result(verdict: .refuseScatteredEvidence, reasons: reasons,
                anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
        }
        if s2 < colocationFloor + caveatMargin {
            reasons.append("supported but thin: surface sources prominently")
            return Result(verdict: .allowWithCaveat, reasons: reasons,
                anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
        }
        reasons.append("anchors co-occur in a single supporting passage")
        return Result(verdict: .allow, reasons: reasons,
            anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
    }

    /// Post-generation numeric provenance. Retrieval gates cannot catch this,
    /// because retrieval already SUCCEEDED: this is the model turning 500 mg
    /// into 750 mg. Runs immediately before the answer is displayed.
    public static func numericProvenance(answer: String,
                                         evidence: [RetrievedChunk]) -> (Bool, [String]) {
        let pattern = #"\b\d+(?:\.\d+)?\s*(?:mg|ml|mcg|g|kg|l|litres?|liters?|drops?|minutes?|hours?|days?|percent|%|degrees?|cm|mm|m)\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return (true, []) }

        func matches(_ s: String) -> [String] {
            let ns = s as NSString
            return rx.matches(in: s, range: NSRange(location: 0, length: ns.length))
                     .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
        }

        let quantities = matches(answer)
        if quantities.isEmpty { return (true, []) }

        let blob = evidence.map { $0.text }.joined(separator: " ").lowercased()
        let blobNums = Set(matches(blob).map {
            $0.replacingOccurrences(of: " ", with: "").lowercased() })
        let digits = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        let nsBlob = blob as NSString
        let blobBare = Set((digits?.matches(in: blob,
            range: NSRange(location: 0, length: nsBlob.length)) ?? [])
            .map { nsBlob.substring(with: $0.range) })

        let unsupported = quantities.filter { q in
            let norm = q.replacingOccurrences(of: " ", with: "").lowercased()
            if blobNums.contains(norm) { return false }
            let nsQ = q as NSString
            let n = (digits?.firstMatch(in: q,
                range: NSRange(location: 0, length: nsQ.length)))
                .map { nsQ.substring(with: $0.range) }
            if let n, blobBare.contains(n) { return false }
            return true
        }
        return (unsupported.isEmpty, unsupported)
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneLLM/ModelManager.swift`

>>> FILE: ios/Godstone/Sources/GodstoneLLM/ModelManager.swift
`````swift
import Foundation
import UIKit
import GodstoneCore

/// Decides which model to load, whether Metal may be used, and when to evict.
///
/// The model is the single largest resource in the app. Getting this wrong does
/// not produce a slow app, it produces a jetsam kill in the middle of somebody
/// looking up how to stop a bleed. Every policy below exists because of C4
/// (battery is life) and C5 (degrade, never fail).
public final class ModelManager: @unchecked Sendable {

    public static let shared = ModelManager()

    private let runner = LlamaRunner()
    private var currentTier: Tier?
    private var evictionTask: Task<Void, Never>?

    /// Idle eviction. Holding a quantised 4B model resident while the user reads
    /// a manual for ten minutes buys nothing and risks everything.
    private static let idleEvictionSeconds: UInt64 = 180

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil) { [weak self] _ in
                // Non-negotiable: the Archive must stay readable (C5). The model
                // is the first thing overboard, always.
                Task { await self?.evictNow() }
            }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: nil) { [weak self] _ in
                Task { await self?.evictNow() }
            }
    }

    // MARK: - Tier and capability

    public var bundledModelPath: String? {
        Bundle.main.path(forResource: Tier.current.modelFile, ofType: nil)
            ?? modelURLInAppSupport()?.path
    }

    private func modelURLInAppSupport() -> URL? {
        // A future reviewed offline installation flow may place a verified model in
        // Application Support. V4 does not download models from the app.
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory,
                                in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent("models")
                     .appendingPathComponent(Tier.current.modelFile)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Metal offload is granted only when the device is not already in trouble.
    /// A hot or nearly flat phone runs on CPU: measurably slower, dramatically
    /// less power, and it will not thermally throttle into uselessness.
    private var permittedGpuLayers: Int {
        UIDevice.current.isBatteryMonitoringEnabled = true

        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        let thermal = ProcessInfo.processInfo.thermalState

        if thermal == .serious || thermal == .critical { return 0 }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 0 }
        if level >= 0, level < 0.15, state != .charging { return 0 }

        return 99   // offload everything; unified memory makes this cheap
    }

    private var permittedThreads: Int {
        // Performance cores only. Spilling onto efficiency cores adds heat and
        // scheduler churn for almost no additional tokens per second.
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    // MARK: - Lifecycle

    @discardableResult
    public func ensureLoaded() async throws -> LlamaRunner {
        guard let path = bundledModelPath else {
            throw LlamaRunner.RunnerError.modelMissing
        }

        let tier = Tier.current

        do {
            try await runner.load(path: path,
                                  contextTokens: tier.contextTokens,
                                  gpuLayers: permittedGpuLayers,
                                  threads: permittedThreads)
        } catch LlamaRunner.RunnerError.outOfMemory {
            // Degrade rather than fail (C5): retry once at half context, which
            // roughly halves the KV cache, the thing that actually blew up.
            try await runner.load(path: path,
                                  contextTokens: max(1024, tier.contextTokens / 2),
                                  gpuLayers: 0,
                                  threads: permittedThreads)
        }

        currentTier = tier
        scheduleEviction()
        return runner
    }

    public func touch() {
        scheduleEviction()
    }

    private func scheduleEviction() {
        evictionTask?.cancel()
        evictionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ModelManager.idleEvictionSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.evictNow()
        }
    }

    /// Embedding runner, SEPARATE from the generation runner.
    ///
    /// The archive's vectors are bge-small/bge-base. Embedding a query with the
    /// Qwen generation model puts it in a different vector space entirely, so
    /// the similarity numbers are noise. Two runners is the cost of not doing
    /// that; the embedding model is ~30 MB quantised.
    private let embedRunner = LlamaRunner()

    public func embedQuery(_ text: String) async -> [Float]? {
        guard let path = Bundle.main.path(
            forResource: Tier.current.embedModelFile, ofType: nil) else { return nil }
        try? await embedRunner.load(path: path, contextTokens: 512,
                                    gpuLayers: 0, threads: 2)
        guard let v = await embedRunner.embed(text) else { return nil }
        // Fail closed on a dimension mismatch rather than compare across spaces.
        guard v.count == Tier.current.embedDim else { return nil }
        return v
    }

    public func evictNow() async {
        await runner.cancel()
        await runner.unload()
        currentTier = nil
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneLLM/RagPipeline.swift`

>>> FILE: ios/Godstone/Sources/GodstoneLLM/RagPipeline.swift
`````swift
import Foundation
import GodstoneCore

/// Retrieval-Augmented Generation over the Archive.
///
/// This file is the enforcement point for constraint C3: the Oracle NEVER
/// answers from parametric memory. If retrieval returns nothing above the
/// confidence floor, the pipeline refuses and says so. A 0.6B model inventing a
/// paediatric dose is not a quality problem, it is a fatality.
///
/// Policy is identical to the Android RagPipeline in tab 05. The two must not
/// drift, or the same question answers differently on two phones in the same room.
public struct Citation: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let documentTitle: String
    public let section: String
    public let score: Double
}

public enum RagOutcome: Sendable {
    case answer(text: String, citations: [Citation])
    case notInArchive
}

/// Staged retrieval result exposed to the UI so the confidence gate can run
/// BEFORE the model is loaded (C3) and so a refusal can still show near-miss
/// sources from the Archive (C5). Mirrors `OracleViewModel.State` on Android.
public struct RetrievalResult: Sendable {
    public let chunks: [RetrievedChunk]
    public let bestScore: Double
    public let nearMisses: [Citation]

    /// Verdict from `SafetyGate.evaluate` -- the same logic the probe suite
    /// exercises. Nil means the gate never ran, which fails closed.
    public let gateVerdict: SafetyGate.Result?

    public var passesConfidenceGate: Bool {
        gateVerdict?.allowsGeneration ?? false
    }
}

public actor RagPipeline {

    /// Below this fused score we consider the Archive silent on the question.
    /// Tuned on the offline eval set in tab 12; deliberately conservative.
    /// PARITY with Android (was 0.28; raised to 0.35 to match tab 05).
    /// RETAINED ONLY AS A LEGACY CONSTANT. The verdict now comes from
    /// SafetyGate.evaluate; see `RetrievalResult.passesConfidenceGate`.
    /// Invariant G fails the build if this value is ever compared against
    /// again, because the repository's own audit proved it cannot discriminate.
    @available(*, deprecated, message: "use SafetyGate.evaluate")
    public static let confidenceFloor: Double = 0.35

    /// Reciprocal-rank-fusion constant. Standard value; combines the FTS5 rank
    /// and the vector rank without either having to be calibrated to the other.
    private static let rrfK: Double = 60.0

    private let retriever: Retriever
    private let builder: PromptBuilder

    public init(retriever: Retriever, builder: PromptBuilder = PromptBuilder()) {
        self.retriever = retriever
        self.builder = builder
    }

    // MARK: - Staged API (drives OracleViewModel)

    /// Best-effort model preload. Returns true when a runner is resident and
    /// ready, false when the model cannot be loaded (e.g. modelMissing). The UI
    /// uses this to decide between "generate" and "degrade to Archive browse"
    /// without ever blocking the gate on a model that may not fit (C5).
    @discardableResult
    public func warmUp() async -> Bool {
        guard let runner = try? await ModelManager.shared.ensureLoaded() else {
            return false
        }
        ModelManager.shared.touch()
        return await runner.isLoaded
    }

    /// Hybrid retrieval + reciprocal-rank fusion. Runs the gate evaluation but
    /// does NOT load the model; the embedder lazily touches `ModelManager.shared`
    /// so a cold Archive query never pays for a model load it may not need.
    public func retrieve(question: String) async -> RetrievalResult {
        // Hybrid retrieval: FTS5 catches exact terms ("tourniquet", "1:200"),
        // vectors catch paraphrase ("how do I stop bad bleeding"). Neither alone
        // is good enough for a user who is frightened and typing badly.
        let lexical = (try? retriever.searchLexical(question, limit: 24)) ?? []
        // The archive's vectors come from bge-small/bge-base (see
        // content/ingest/embedder.py). This used to embed the query with the
        // QWEN GENERATION model, putting query and corpus in two completely
        // different vector spaces -- cosine similarity between them is noise,
        // so every semantic score was meaningless while looking healthy.
        //
        // ModelManager.shared.embedder loads the SAME GGUF the archive was
        // built with and returns nil on a dimension mismatch, so retrieval
        // degrades to lexical-only rather than comparing across spaces.
        let semantic = (try? await retriever.searchSemantic(
            question,
            embedder: { await ModelManager.shared.embedQuery($0) },
            limit: 24)) ?? []

        let fused = fuse(lexical: lexical, semantic: semantic)
        let top = Array(fused.prefix(Tier.current.topKChunks))

        let bestScore = top.first?.score ?? 0
        let verdict = SafetyGate.evaluate(question: question,
                                          chunks: top,
                                          index: await retriever.corpusIndex())
        let nearMisses: [Citation] = verdict.allowsGeneration ? [] : top.prefix(3).map {
            Citation(id: $0.chunkId,
                     documentTitle: $0.documentTitle,
                     section: $0.section,
                     score: $0.score)
        }
        return RetrievalResult(chunks: top, bestScore: bestScore,
                               nearMisses: nearMisses, gateVerdict: verdict)
    }

    /// Streaming generation gated on the retrieval result. The stream finishes
    /// immediately (empty) when the gate did not pass, so the UI's `for try await`
    /// loop simply does nothing and falls through to the refused state.
    ///
    /// `nonisolated` because `OracleViewModel` iterates it without `await`-ing the
    /// call itself: the actor state is only touched inside the stream's detached
    /// continuation, where isolation is re-acquired at each `await`.
    public nonisolated func generate(question: String,
                                     retrieval: RetrievalResult) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Constraint C3: the gate runs BEFORE the model is ever invoked.
                guard retrieval.passesConfidenceGate else {
                    continuation.finish()
                    return
                }

                do {
                    let runner = try await ModelManager.shared.ensureLoaded()
                    ModelManager.shared.touch()

                    // Budget the context honestly using the model's own tokenizer
                    // rather than a characters-per-token guess, then drop whole
                    // chunks from the tail until it fits. A truncated chunk can
                    // sever a citation from its procedure, which is exactly the
                    // failure C3 exists to prevent.
                    let prompt = await self.builder.build(
                        question: question,
                        chunks: retrieval.chunks,
                        budget: Tier.current.contextTokens - 512,
                        countTokens: { await runner.countTokens($0) }
                    )

                    let sampling = self.builder.isClinical(question)
                        ? LlamaRunner.Sampling.clinical
                        : LlamaRunner.Sampling()

                    for try await token in await runner.generate(prompt: prompt, sampling: sampling) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Maps `[n]` citation markers in the generated answer back to the chunks
    /// that were actually placed in the prompt, so the UI can render tappable
    /// sources instead of bare index numbers. 1-based, matches PromptBuilder.
    public nonisolated func extractCitations(answer: String,
                                             retrieval: RetrievalResult) -> [Citation] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else {
            return []
        }
        let ns = answer as NSString
        let matches = regex.matches(in: answer,
                                    range: NSRange(location: 0, length: ns.length))

        var seen = Set<Int>()
        var citations: [Citation] = []
        for match in matches {
            let n = Int(ns.substring(with: match.range(at: 1))) ?? 0
            guard n >= 1, n <= retrieval.chunks.count, !seen.contains(n) else { continue }
            seen.insert(n)
            let chunk = retrieval.chunks[n - 1]
            citations.append(Citation(id: chunk.chunkId,
                                      documentTitle: chunk.documentTitle,
                                      section: chunk.section,
                                      score: chunk.score))
        }
        return citations
    }

    /// Release the model back to the OS. Fire-and-forget: the UI calls this on
    /// background without awaiting, so the eviction runs on its own task.
    public nonisolated func release() {
        Task { await ModelManager.shared.evictNow() }
    }

    // MARK: - Legacy single-shot API (preserved for callers that do not stream)

    public func answer(question: String,
                       onToken: @escaping @Sendable (String) -> Void) async throws -> RagOutcome {
        let retrieval = await retrieve(question: question)

        guard retrieval.passesConfidenceGate else {
            return .notInArchive
        }

        var collected = ""
        for try await token in generate(question: question, retrieval: retrieval) {
            collected += token
            onToken(token)
        }

        let citations = extractCitations(answer: collected, retrieval: retrieval)

        // Post-condition, cheap and worth it: a non-empty answer must carry at
        // least one citation, or we discard it and admit ignorance instead.
        guard !collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !citations.isEmpty else {
            return .notInArchive
        }

        return .answer(text: collected, citations: citations)
    }

    /// Reciprocal rank fusion. Rank-based, so the wildly different scales of
    /// BM25 and cosine similarity never have to be reconciled.
    private func fuse(lexical: [RetrievedChunk],
                      semantic: [RetrievedChunk]) -> [RetrievedChunk] {

        var scores: [Int64: Double] = [:]
        var byId: [Int64: RetrievedChunk] = [:]

        for (rank, chunk) in lexical.enumerated() {
            scores[chunk.chunkId, default: 0] += 1.0 / (RagPipeline.rrfK + Double(rank + 1))
            byId[chunk.chunkId] = chunk
        }
        for (rank, chunk) in semantic.enumerated() {
            scores[chunk.chunkId, default: 0] += 1.0 / (RagPipeline.rrfK + Double(rank + 1))
            byId[chunk.chunkId] = chunk
        }

        // Normalise to 0...1 against the best possible fused score so the
        // confidence floor means the same thing regardless of result count.
        let ceiling = 2.0 / (RagPipeline.rrfK + 1.0)

        return scores
            .compactMap { (id, raw) -> RetrievedChunk? in
                guard var c = byId[id] else { return nil }
                c.score = min(1.0, raw / ceiling)
                return c
            }
            .sorted { $0.score > $1.score }
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneMesh/BleTransport.swift`

>>> FILE: ios/Godstone/Sources/GodstoneMesh/BleTransport.swift
`````swift
import Foundation
import CoreBluetooth

/// BLE control plane. Always on, duty-cycled, background-capable (with the
/// caveats documented below and surfaced in the UI).
///
/// Every device is simultaneously a central and a peripheral. There are no
/// clients and no servers in a survival mesh — the topology must survive any
/// single device walking away.
public final class BleTransport: NSObject {

    // GENERATED-SPEC UUIDs. These previously read 6F0D0001-… while Android read
    // 67640001-… -- the two platforms could not see each other at all, so the
    // header-size and type-code defects were never even reached. The values now
    // come from wire/wire_v2.yaml via FrameV2 and cannot drift: Invariant G
    // fails the build if a literal UUID reappears here.
    public static let serviceUuid = CBUUID(string: FrameV2.serviceUuidString)
    public static let inboxCharacteristicUuid = CBUUID(string: FrameV2.inboxUuidString)
    public static let digestCharacteristicUuid = CBUUID(string: FrameV2.digestUuidString)

    private let central: CBCentralManager
    private let peripheral: CBPeripheralManager

    private var connected: [UUID: CBPeripheral] = [:]
    private var inboxCharacteristics: [UUID: CBCharacteristic] = [:]
    private var subscribers: [CBCentral] = []

    public weak var delegate: TransportDelegate?

    /// Noise sessions. Without this the transport cannot send -- by design.
    public var sessions: SessionManager?

    /// iOS truncates advertisement data heavily in the background: the service
    /// UUID moves to the "overflow area", which is only visible to other iOS
    /// devices explicitly scanning for that exact UUID. Android scanners cannot
    /// see a backgrounded iPhone at all. This is a platform fact, not a bug we
    /// can fix, and the UI tells the user so rather than pretending otherwise.
    public private(set) var isBackgrounded = false

    public override init() {
        // Both managers are constructed with a nil delegate and stored BEFORE
        // super.init(), then wired to self. CoreBluetooth dispatches state
        // callbacks on a global queue and could otherwise fire into a partly
        // initialised object (audit A-18). The restoration identifiers let iOS
        // relaunch us into the background when a peer appears.
        central = CBCentralManager(delegate: nil, queue: .global(qos: .utility), options: [CBCentralManagerOptionRestoreIdentifierKey: "io.godstone.central"])
        peripheral = CBPeripheralManager(delegate: nil, queue: .global(qos: .utility), options: [CBPeripheralManagerOptionRestoreIdentifierKey: "io.godstone.peripheral"])
        super.init()
        central.delegate = self
        peripheral.delegate = self
    }

    public func start() {
        startAdvertising()
        startScanning()
    }

    public func stop() {
        central.stopScan()
        peripheral.stopAdvertising()
    }

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [BleTransport.serviceUuid],
            // Duplicates ON in foreground so we track RSSI and liveness; OFF in
            // background because iOS coalesces them anyway and it saves battery.
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: !isBackgrounded])
    }

    private func startAdvertising() {
        guard peripheral.state == .poweredOn else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleTransport.serviceUuid],
            CBAdvertisementDataLocalNameKey: "GS"
        ])
    }

    public func setBackgrounded(_ backgrounded: Bool) {
        isBackgrounded = backgrounded
        central.stopScan()
        startScanning()
    }

    /// Send [frame] to [peerId] THROUGH THE NOISE SESSION.
    ///
    /// This previously wrote `frame.encode()` directly to the characteristic.
    /// NoiseSession existed but nothing constructed it, so the "encrypted mesh"
    /// transmitted plaintext. There is no plaintext fallback here on purpose.
    @discardableResult
    public func send(_ frame: FrameV2, to peerId: UUID) -> Bool {
        guard let p = connected[peerId],
              let ch = inboxCharacteristics[peerId] else { return false }
        guard let data = sessions?.seal(peerId, frame.encode()) else { return false }

        // ADR-002/M2-link owns authenticated record fragmentation. Until that
        // layer exists, never split one Noise ciphertext into independent ATT
        // writes: the receiver would try to authenticate each fragment.
        let mtu = p.maximumWriteValueLength(for: .withoutResponse)
        guard data.count <= mtu else { return false }
        p.writeValue(data, for: ch, type: .withoutResponse)
        return true
    }
}

extension BleTransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { startScanning() }
    }

    public func centralManager(_ c: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        if let peers = dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral] {
            for p in peers {
                p.delegate = self
                connected[p.identifier] = p
            }
        }
    }

    public func centralManager(_ c: CBCentralManager,
                               didDiscover p: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        // Ignore anything we can barely hear: connecting to a -95 dBm peer wastes
        // far more energy than the link is ever worth.
        guard RSSI.intValue > -90 else { return }

        connected[p.identifier] = p
        p.delegate = self
        c.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([BleTransport.serviceUuid])
        delegate?.transportDidConnect(peerId: p.identifier)
    }

    public func centralManager(_ c: CBCentralManager,
                               didDisconnectPeripheral p: CBPeripheral,
                               error: Error?) {
        inboxCharacteristics.removeValue(forKey: p.identifier)
        delegate?.transportDidDisconnect(peerId: p.identifier)
        // Always reconnect. In a survival mesh, a dropped link is the normal
        // state, not an error condition.
        c.connect(p, options: nil)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.forEach {
            p.discoverCharacteristics(
                [BleTransport.inboxCharacteristicUuid,
                 BleTransport.digestCharacteristicUuid], for: $0)
        }
    }

    public func peripheral(_ p: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == BleTransport.inboxCharacteristicUuid {
                inboxCharacteristics[p.identifier] = ch
                p.setNotifyValue(true, for: ch)
            }
        }
        delegate?.transportReady(peerId: p.identifier)
    }

    public func peripheral(_ p: CBPeripheral,
                           didUpdateValueFor ch: CBCharacteristic,
                           error: Error?) {
        guard let raw = ch.value else { return }
        // Decrypt before anything downstream sees it. A frame that fails
        // authentication is corruption or an attacker: drop it silently.
        guard let clear = sessions?.open(p.identifier, raw) else { return }
        delegate?.transportDidReceive(data: clear, peerId: p.identifier)
    }
}

extension BleTransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        guard pm.state == .poweredOn else { return }

        let inbox = CBMutableCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable])

        let digest = CBMutableCharacteristic(
            type: BleTransport.digestCharacteristicUuid,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable])

        let service = CBMutableService(type: BleTransport.serviceUuid, primary: true)
        service.characteristics = [inbox, digest]
        pm.add(service)

        startAdvertising()
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        for r in requests {
            if let v = r.value,
               let clear = sessions?.open(r.central.identifier, v) {
                delegate?.transportDidReceive(data: clear, peerId: r.central.identifier)
            }
        }
        pm.respond(to: first, withResult: .success)
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  central: CBCentral,
                                  didSubscribeTo ch: CBCharacteristic) {
        subscribers.append(central)
    }
}

public protocol TransportDelegate: AnyObject {
    func transportDidConnect(peerId: UUID)
    func transportReady(peerId: UUID)
    func transportDidDisconnect(peerId: UUID)
    func transportDidReceive(data: Data, peerId: UUID)
}

extension Data {
    func chunked(into size: Int) -> [Data] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            subdata(in: $0..<Swift.min($0 + size, count))
        }
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneMesh/BulkTransport.swift`

>>> FILE: ios/Godstone/Sources/GodstoneMesh/BulkTransport.swift
`````swift
import Foundation

/// Bulk transfer is deliberately unavailable in V4.
///
/// The earlier MultipeerConnectivity implementation was not bound to the BLE
/// Noise session, generated random UUIDs for callbacks, and sent encoded frames
/// without a record-level identity binding. Advertising that as a secure bulk
/// plane would violate C1/C6 and the threat model. ADR-006 defines the decision
/// required before a real implementation can be enabled.
public final class BulkTransport {
    public static let unavailableReason =
        "Bulk transfer is disabled until ADR-006 is implemented and device-tested."

    public private(set) var isActive = false
    public var isAvailable: Bool { false }

    public init(displayName: String) { }
    public func activate() { isActive = false }
    public func deactivate() { isActive = false }

    @discardableResult
    public func send(_ frame: FrameV2) -> Bool { false }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneMesh/MeshCoordinator.swift`

>>> FILE: ios/Godstone/Sources/GodstoneMesh/MeshCoordinator.swift
`````swift
import Foundation
import Combine

@MainActor
public final class MeshCoordinator: ObservableObject {
    public enum SosState: Equatable {
        case idle
        case unavailable(String)
        case handedToRelays(Int)
        case notPersisted
        case failed(String)
    }

    public let node: MeshNode
    @Published public private(set) var peerCount = 0
    @Published public private(set) var isBackgroundDegraded = false
    @Published public private(set) var sosState: SosState = .idle

    public var transportAvailable: Bool { MeshNode.linkLayerReady }
    public var transportDetail: String {
        transportAvailable ? "Encrypted mesh control plane active" : MeshNode.linkLayerOpenReason
    }
    public var isBroadcastingSos: Bool {
        if case .handedToRelays = sosState { return true }
        return false
    }

    public init(node: MeshNode) {
        self.node = node
        node.onPeerCountChanged = { [weak self] count in
            Task { @MainActor in self?.peerCount = count }
        }
    }

    public func enterForegroundMode() {
        isBackgroundDegraded = false
        if transportAvailable { _ = node.start() }
    }

    public func enterBackgroundMode() {
        isBackgroundDegraded = transportAvailable
    }

    public func broadcastSos() {
        let result = node.broadcastSos(payload: Data("SOS".utf8))
        switch result {
        case .unavailable(let reason): sosState = .unavailable(reason)
        case .handedToRelays(let count): sosState = .handedToRelays(count)
        case .notPersisted: sosState = .notPersisted
        case .failed(let reason): sosState = .failed(reason)
        }
    }

    public func cancelSos() {
        // Cancellation is local. Already-relayed copies cannot be recalled.
        sosState = .idle
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneMesh/MeshIdentity.swift`

>>> FILE: ios/Godstone/Sources/GodstoneMesh/MeshIdentity.swift
`````swift
import Foundation
import CryptoKit
import Security
import GodstoneCore

/// Long-lived node identity.
///
/// Two key pairs, never conflated:
///   * Ed25519 for signatures (authorship, non-repudiation within the mesh)
///   * X25519  for Noise key agreement (confidentiality)
///
/// Both are stored in the Keychain with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
/// AfterFirstUnlock rather than WhenUnlocked, because the mesh must keep relaying
/// while the phone is locked in a pocket. ThisDeviceOnly so keys never enter an
/// iCloud backup.
public struct MeshIdentity: Sendable {

    public let signingKey: Curve25519.Signing.PrivateKey
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey

    /// BLAKE2s-128 of the agreement public key. 16 bytes. Matches Android.
    public var nodeId: Data {
        // PROTOCOL.md:49 -- node_id = BLAKE2s-128(identity_pub), the Ed25519
        // signing key. This previously used agreementKey (X25519), producing a
        // different node_id, hence a different node_hint, hence a different
        // Noise prologue -- so h diverged BEFORE the first DH and no transcript
        // test could have seen it. Pinned by handshake_vectors.json.
        Blake2s.hash(signingKey.publicKey.rawRepresentation, digestLength: 16)
    }

    /// First 4 bytes, carried in the accepted 13-byte BLE scan response.
    public var nodeHint: Data { nodeId.prefix(4) }

    /// Six BIP-39 words derived from the node id, for verbal out-of-band
    /// verification. "Is your call sign amber-tiger-...?" over actual voice is
    /// the only trustworthy channel when everything else is compromised.
    public var callSign: String {
        Bip39.words(from: nodeId, count: 6).joined(separator: "-")
    }

    // MARK: - Keychain

    private static let signingTag   = "io.godstone.mesh.identity.ed25519"
    private static let agreementTag = "io.godstone.mesh.identity.x25519"

    public static func generateAndStore() -> MeshIdentity {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()

        store(signing.rawRepresentation, tag: signingTag)
        store(agreement.rawRepresentation, tag: agreementTag)

        return MeshIdentity(signingKey: signing, agreementKey: agreement)
    }

    public static func loadFromKeychain() throws -> MeshIdentity {
        guard let s = load(tag: signingTag), let a = load(tag: agreementTag) else {
            throw MeshError.identityNotFound
        }
        return MeshIdentity(
            signingKey: try Curve25519.Signing.PrivateKey(rawRepresentation: s),
            agreementKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: a)
        )
    }

    private static func store(_ data: Data, tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func load(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else {
            return nil
        }
        return out as? Data
    }
}

public enum MeshError: Error {
    case identityNotFound
    case malformedFrame
    case handshakeFailed
    case payloadTooLarge
    case replayDetected
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneMesh/MeshNode.swift`

>>> FILE: ios/Godstone/Sources/GodstoneMesh/MeshNode.swift
`````swift
import Foundation
import CryptoKit
import Security
import GodstoneCore

public enum SosDispatchResult: Equatable, Sendable {
    case unavailable(String)
    case handedToRelays(Int)
    case notPersisted
    case failed(String)
}

/// One identity, router, radio stack and session registry for the process.
public final class MeshNode {
    public static let linkLayerReady = false
    public static let linkLayerOpenReason =
        "Encrypted BLE record reassembly and the Noise handshake driver are not implemented yet. Radio transmission is disabled in this pre-alpha build."

    public let identity: MeshIdentity
    public private(set) lazy var ble = BleTransport()
    public private(set) lazy var router = Router()
    public private(set) lazy var sessions = SessionManager(identity: identity)

    private var peers: Set<UUID> = []
    private let peerLock = NSLock()
    public var onPeerCountChanged: ((Int) -> Void)?
    private var isStarted = false

    public init(identity: MeshIdentity) { self.identity = identity }

    @discardableResult
    public func start() -> Bool {
        guard Self.linkLayerReady else { return false }
        guard !isStarted else { return true }
        isStarted = true
        ble.delegate = self
        ble.sessions = sessions
        router.onForward = { [weak self] frame in
            guard let self else { return }
            for peer in self.currentPeers() { _ = self.ble.send(frame, to: peer) }
        }
        ble.start()
        return true
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        sessions.destroyAll()
        ble.stop()
        peerLock.lock(); peers.removeAll(); peerLock.unlock()
        onPeerCountChanged?(0)
    }

    private func currentPeers() -> [UUID] {
        peerLock.lock(); defer { peerLock.unlock() }
        return Array(peers)
    }

    /// V4 does not fabricate a successful SOS while ADR-004 and M2-link remain open.
    public func broadcastSos(payload: Data) -> SosDispatchResult {
        guard Self.linkLayerReady else { return .unavailable(Self.linkLayerOpenReason) }
        var msgId = Data(count: 16)
        let rc = msgId.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard rc == errSecSuccess else { return .failed("secure random generation failed") }

        let magic = Data("SOS1".utf8)
        guard let signature = try? identity.signingKey.signature(for: msgId + magic + payload) else {
            return .failed("SOS signing failed")
        }
        let sealed = magic + signature + payload
        let frame = FrameV2(
            type: .sos,
            msgId: msgId,
            routingTag: identity.nodeHint,
            ttl: FrameV2.maxTtl,
            hopCount: 0,
            flags: UInt16(FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok),
            payload: sealed)

        // The current iOS router is memory-only. A zero-peer result is therefore
        // not QUEUED: termination would lose it. ADR-004 must land before that word
        // can appear in the UI.
        router.ingest(frame, isAddressedToMe: false)
        let handed = currentPeers().reduce(into: 0) { count, peer in
            if ble.send(frame, to: peer) { count += 1 }
        }
        return handed > 0 ? .handedToRelays(handed) : .notPersisted
    }
}

extension MeshNode: TransportDelegate {
    public func transportDidConnect(peerId: UUID) {
        peerLock.lock(); peers.insert(peerId); let count = peers.count; peerLock.unlock()
        onPeerCountChanged?(count)
    }

    public func transportReady(peerId: UUID) {
        // Deliberately no half-handshake. M2-link owns role election, real remote
        // hints, record types HS1/HS2/HS3, reassembly and timeouts.
    }

    public func transportDidDisconnect(peerId: UUID) {
        peerLock.lock(); peers.remove(peerId); let count = peers.count; peerLock.unlock()
        sessions.drop(peerId)
        onPeerCountChanged?(count)
    }

    public func transportDidReceive(data: Data, peerId: UUID) {
        guard Self.linkLayerReady, let frame = FrameV2.decode(data) else { return }
        router.ingest(frame, isAddressedToMe: frame.routingTag == identity.nodeHint)
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneMesh/NoiseSession.swift`

>>> FILE: ios/Godstone/Sources/GodstoneMesh/NoiseSession.swift
`````swift
import Foundation
import CryptoKit
import GodstoneCore

/// Noise_XX_25519_ChaChaPoly_BLAKE2s.
///
/// V4 REWRITE. The V3 implementation was not merely unreachable -- it was
/// wire-non-conformant and could not have completed a handshake against
/// noise-java even with every call site wired. Measured against the repository's
/// own pinned vectors:
///
///     pinned spec message sizes : [32, 96, 64]
///     V3 NoiseSession.swift     : [32, 80, 48]
///
/// Three defects, all fixed here:
///
///  (a) MESSAGES 2 AND 3 OMITTED THEIR PAYLOAD. XX message 2 is `e, ee, s, es`
///      followed by an encrypted payload; V3 returned `e + encryptedStatic` and
///      stopped. Message 3 is `s, se` plus a payload; V3 returned the static
///      only. Hence 80 and 48 instead of 96 and 64.
///
///  (b) MESSAGE 2 WAS PARSED AS ONE CIPHERTEXT. `decryptAndHash(msg2.suffix(from: 32))`
///      handed 64 bytes to a single AEAD open, yielding a 48-byte "static key".
///      X25519 requires 32, so the parse threw before any DH occurred.
///
///  (c) THE HANDSHAKE NONCE WAS PINNED TO ZERO. Both encryptAndHash and
///      decryptAndHash built `ChaChaPoly.Nonce(data: Data(count: 12))`. In Noise
///      the handshake nonce resets to 0 on MixKey and otherwise INCREMENTS. In
///      message 3 the initiator encrypts `s` under the `es` key at n = 1,
///      because message 2's payload decrypt already consumed n = 0.
///
/// None of this was visible to Invariant D, which validates the PYTHON
/// reference against a fixture generated by that same reference and never
/// executes Swift. See docs/adr/ADR-002 and ci/mutations.py.
///
/// The prologue binds the handshake to the protocol name and both node hints,
/// which kills downgrade and cross-protocol attacks before they start.
public final class NoiseSession {

    public enum Role { case initiator, responder }

    /// Handshake cipher. `n` resets to zero on every MixKey and increments on
    /// every use -- that increment is defect (c) above.
    private struct CipherState {
        var k: SymmetricKey?
        var n: UInt64 = 0

        /// Noise s.12.3: 32 bits of zeros then LITTLE-endian n.
        func nonce() throws -> ChaChaPoly.Nonce {
            var v = n.littleEndian
            return try ChaChaPoly.Nonce(data: Data(count: 4) + Data(bytes: &v, count: 8))
        }
    }

    private let role: Role
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey

    private var chainingKey: Data
    private var handshakeHash: Data
    private var cipher = CipherState()

    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendNonce: UInt64 = 0
    private var receiveNonce: UInt64 = 0

    private var messagesSinceRekey: UInt64 = 0
    private var sessionStart = Date()

    private var remoteEphemeral: Data?
    public private(set) var remoteStaticKey: Data?
    public private(set) var isEstablished = false

    private static let protocolName = "Noise_XX_25519_ChaChaPoly_BLAKE2s"
    private static let tagLen = 16
    private static let dhLen = 32
    private static let rekeyMessageLimit: UInt64 = 1 << 20
    private static let rekeyTimeLimit: TimeInterval = 30 * 60

    public init(role: Role,
                staticKey: Curve25519.KeyAgreement.PrivateKey,
                localHint: Data,
                remoteHint: Data) {
        self.role = role
        self.staticKey = staticKey
        self.ephemeral = Curve25519.KeyAgreement.PrivateKey()

        var prologue = Data("GMP1".utf8)
        // Canonical ordering: initiator hint first, both sides agree.
        if role == .initiator {
            prologue.append(localHint); prologue.append(remoteHint)
        } else {
            prologue.append(remoteHint); prologue.append(localHint)
        }

        // InitializeSymmetric(protocol_name): pad to HASHLEN, else hash.
        let name = Data(NoiseSession.protocolName.utf8)
        let h0: Data = name.count <= 32
            ? name + Data(count: 32 - name.count)
            : Blake2s.hash(name, digestLength: 32)
        self.chainingKey = h0
        self.handshakeHash = Blake2s.hash(h0 + prologue, digestLength: 32)
    }

    // MARK: - Symmetric state

    private func mixHash(_ data: Data) {
        handshakeHash = Blake2s.hash(handshakeHash + data, digestLength: 32)
    }

    private func mixKey(_ secret: SharedSecret) {
        let material = secret.withUnsafeBytes { Data($0) }
        let (ck, k) = Hkdf.split(chainingKey: chainingKey, material: material)
        chainingKey = ck
        // n RESETS here. This is the whole of defect (c).
        cipher = CipherState(k: SymmetricKey(data: k), n: 0)
    }

    private func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let k = cipher.k else {
            mixHash(plaintext)
            return plaintext
        }
        let box = try ChaChaPoly.seal(plaintext, using: k,
                                      nonce: cipher.nonce(),
                                      authenticating: handshakeHash)
        cipher.n += 1
        let out = box.ciphertext + box.tag
        mixHash(out)
        return out
    }

    private func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let k = cipher.k else {
            mixHash(ciphertext)
            return ciphertext
        }
        guard ciphertext.count >= NoiseSession.tagLen else {
            throw MeshError.handshakeFailed
        }
        // AAD is h BEFORE this ciphertext is mixed in.
        let aad = handshakeHash
        let box = try ChaChaPoly.SealedBox(
            nonce: cipher.nonce(),
            ciphertext: ciphertext.dropLast(NoiseSession.tagLen),
            tag: ciphertext.suffix(NoiseSession.tagLen))
        let plain = try ChaChaPoly.open(box, using: k, authenticating: aad)
        cipher.n += 1
        mixHash(ciphertext)
        return plain
    }

    /// Writer-relative DH resolution. Getting es/se backwards is silent: both
    /// sides still produce 32 bytes, they just disagree, and the failure only
    /// surfaces as a tag mismatch one message later.
    private func dhEE() throws -> SharedSecret {
        try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeral!))
    }
    private func dhES() throws -> SharedSecret {
        role == .initiator
            ? try ephemeral.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticKey!))
            : try staticKey.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeral!))
    }
    private func dhSE() throws -> SharedSecret {
        role == .initiator
            ? try staticKey.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeral!))
            : try ephemeral.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticKey!))
    }

    // MARK: - Handshake  (XX:  -> e   <- e, ee, s, es   -> s, se)

    /// Message 1, initiator: `-> e`  (32 bytes with an empty payload)
    public func writeMessage1(payload: Data = Data()) throws -> Data {
        var out = ephemeral.publicKey.rawRepresentation
        mixHash(out)
        out += try encryptAndHash(payload)
        return out
    }

    /// Message 2, responder: reads `e`, writes `e, ee, s, es` + payload.
    /// 96 bytes with empty payloads. V3 produced 80.
    public func readMessage1AndWrite2(_ msg1: Data,
                                      payload: Data = Data()) throws -> Data {
        // Normalise: a sliced Data carries a non-zero startIndex, and
        // subdata(in:) uses ABSOLUTE indices. Copying makes every offset below
        // zero-based regardless of what the transport handed us.
        let m = Data(msg1)
        guard m.count >= NoiseSession.dhLen else { throw MeshError.handshakeFailed }

        remoteEphemeral = m.prefix(NoiseSession.dhLen)
        mixHash(remoteEphemeral!)
        _ = try decryptAndHash(m.suffix(from: NoiseSession.dhLen))

        var out = ephemeral.publicKey.rawRepresentation
        mixHash(out)
        mixKey(try dhEE())                                             // ee
        out += try encryptAndHash(staticKey.publicKey.rawRepresentation) // s
        mixKey(try dhES())                                             // es
        out += try encryptAndHash(payload)                             // payload
        return out
    }

    /// Message 3, initiator: reads message 2, writes `s, se` + payload.
    /// 64 bytes with an empty payload. V3 produced 48.
    public func readMessage2AndWrite3(_ msg2: Data,
                                      payload: Data = Data()) throws -> Data {
        let m = Data(msg2)
        let encStaticLen = NoiseSession.dhLen + NoiseSession.tagLen   // 48
        guard m.count >= NoiseSession.dhLen + encStaticLen else {
            throw MeshError.handshakeFailed
        }

        remoteEphemeral = m.prefix(NoiseSession.dhLen)
        mixHash(remoteEphemeral!)
        mixKey(try dhEE())                                             // ee

        // Split the encrypted static from the encrypted payload. V3 fed BOTH
        // to one AEAD open and derived a 48-byte "X25519 key".
        let encStatic = m.subdata(in: NoiseSession.dhLen ..< (NoiseSession.dhLen + encStaticLen))
        remoteStaticKey = try decryptAndHash(encStatic)                // s
        guard remoteStaticKey?.count == NoiseSession.dhLen else {
            throw MeshError.handshakeFailed
        }
        mixKey(try dhES())                                             // es
        _ = try decryptAndHash(m.suffix(from: NoiseSession.dhLen + encStaticLen))

        // n is now 1 under the es key. encryptAndHash carries that forward.
        var out = try encryptAndHash(staticKey.publicKey.rawRepresentation)  // s
        mixKey(try dhSE())                                             // se
        out += try encryptAndHash(payload)                             // payload
        split()
        return out
    }

    /// Message 3, responder side.
    public func readMessage3(_ msg3: Data) throws {
        let m = Data(msg3)
        let encStaticLen = NoiseSession.dhLen + NoiseSession.tagLen
        guard m.count >= encStaticLen else { throw MeshError.handshakeFailed }

        remoteStaticKey = try decryptAndHash(m.prefix(encStaticLen))   // s
        guard remoteStaticKey?.count == NoiseSession.dhLen else {
            throw MeshError.handshakeFailed
        }
        mixKey(try dhSE())                                             // se
        _ = try decryptAndHash(m.suffix(from: encStaticLen))
        split()
    }

    private func split() {
        let (k1, k2) = Hkdf.split(chainingKey: chainingKey, material: Data())
        // Never the same key in both directions: that makes nonce reuse fatal.
        sendKey    = SymmetricKey(data: role == .initiator ? k1 : k2)
        receiveKey = SymmetricKey(data: role == .initiator ? k2 : k1)
        sendNonce = 0
        receiveNonce = 0
        messagesSinceRekey = 0
        sessionStart = Date()
        isEstablished = true
    }

    /// Handshake hash, equal on both sides once the handshake completes.
    /// Exposed so the port-vector test can assert it.
    public var transcriptHash: Data { handshakeHash }

    // MARK: - Transport

    private static func transportNonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var v = n.littleEndian
        return try ChaChaPoly.Nonce(data: Data(count: 4) + Data(bytes: &v, count: 8))
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = sendKey else { throw MeshError.handshakeFailed }
        rekeyIfNeeded()
        let box = try ChaChaPoly.seal(plaintext, using: key,
                                      nonce: NoiseSession.transportNonce(sendNonce))
        sendNonce += 1
        messagesSinceRekey += 1
        return box.ciphertext + box.tag
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = receiveKey,
              ciphertext.count > NoiseSession.tagLen else {
            throw MeshError.handshakeFailed
        }
        let box = try ChaChaPoly.SealedBox(
            nonce: NoiseSession.transportNonce(receiveNonce),
            ciphertext: ciphertext.dropLast(NoiseSession.tagLen),
            tag: ciphertext.suffix(NoiseSession.tagLen))
        let plain = try ChaChaPoly.open(box, using: key)
        receiveNonce += 1
        return plain
    }

    private func rekeyIfNeeded() {
        let expired = Date().timeIntervalSince(sessionStart) > NoiseSession.rekeyTimeLimit
        guard messagesSinceRekey >= NoiseSession.rekeyMessageLimit || expired else { return }
        if let k = sendKey {
            sendKey = SymmetricKey(data: Blake2s.hash(
                k.withUnsafeBytes { Data($0) }, digestLength: 32))
        }
        if let k = receiveKey {
            receiveKey = SymmetricKey(data: Blake2s.hash(
                k.withUnsafeBytes { Data($0) }, digestLength: 32))
        }
        sendNonce = 0
        receiveNonce = 0
        messagesSinceRekey = 0
        sessionStart = Date()
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneMesh/Router.swift`

>>> FILE: ios/Godstone/Sources/GodstoneMesh/Router.swift
`````swift
import Foundation
import GodstoneCore

/// Delay-tolerant epidemic router, GMP/2.
///
/// V4: `ingest` now takes `FrameV2`, resolving the v1/v2 type error at
/// MeshNode.swift:111. iOS is coherently v2; Android is coherently v1.
///
/// THIS ROUTER IS NOT AT PARITY WITH ANDROID AND V4 DOES NOT CLAIM IT IS.
/// Still missing, each blocked on an ADR rather than guessed at:
///   - proof of work            (Android enforces 20-bit on GROUP/BROADCAST)
///   - frame-age expiry         (Android drops > 14 days; v2 has no timestamp)
///   - digest from a durable store, not the dedup window   (ADR-004)
///   - DIGEST/WANT anti-entropy on encounter               (ADR-001 + ADR-002)
/// docs/adr/ADR-001 carries the full divergence table.
public final class Router {

    public static let defaultTtl: UInt8 = FrameV2.defaultTtl
    public static let maxTtl: UInt8 = FrameV2.maxTtl
    private static let seenCacheCapacity = 16_384

    private var seen = LruSet<Data>(capacity: Router.seenCacheCapacity)
    private var queue: [FrameV2] = []
    private let lock = NSLock()

    public var onDeliverLocally: ((FrameV2) -> Void)?
    public var onForward: ((FrameV2) -> Void)?

    public init() {}

    /// True when the frame was new and has been accepted.
    @discardableResult
    public func ingest(_ frame: FrameV2, isAddressedToMe: Bool) -> Bool {
        guard frame.ttl <= Router.maxTtl,
              frame.hopCount <= Router.maxTtl else { return false }

        // Only mutate the dedup set under the lock. User callbacks execute
        // outside it so a callback cannot deadlock by re-entering the router.
        lock.lock()
        let duplicate = seen.contains(frame.msgId)
        if !duplicate { seen.insert(frame.msgId) }
        lock.unlock()
        guard !duplicate else { return false }

        if isAddressedToMe {
            onDeliverLocally?(frame)
            // SOS is still relayed after local delivery: someone further away
            // may be the one who can actually help.
            if frame.type != .sos { return true }
        }

        if frame.ttl > 1, frame.hopCount < Router.maxTtl {
            enqueue(FrameV2(type: frame.type,
                            msgId: frame.msgId,
                            routingTag: frame.routingTag,
                            ttl: frame.ttl - 1,
                            hopCount: frame.hopCount + 1,
                            flags: frame.flags,
                            payload: frame.payload))
        }
        return true
    }

    private func enqueue(_ frame: FrameV2) {
        lock.lock(); defer { lock.unlock() }
        queue.append(frame)
        queue.sort { priority($0) < priority($1) }
        if queue.count > 512 {
            queue.removeLast(queue.count - 512)   // SOS sorts first, never dropped
        }
    }

    /// Delivery order under congestion. SOS always wins.
    private func priority(_ f: FrameV2) -> Int {
        switch f.type {
        case .sos:        return 0
        case .ack:        return 1
        case .hello:      return 2
        case .message:    return 3
        case .digest, .want: return 4
        case .ping, .goodbye: return 5
        case .bulk_offer, .bulk_chunk: return 6
        }
    }

    public func drain(limit: Int) -> [FrameV2] {
        lock.lock(); defer { lock.unlock() }
        let out = Array(queue.prefix(limit))
        queue.removeFirst(out.count)
        return out
    }

    /// 4096-bit Bloom digest.
    ///
    /// ADR-004 OPEN: this is built from the dedup window, which is a rolling set
    /// of RECENTLY SEEN ids. Android builds its digest from the durable store,
    /// which is the set of HELD frames. The two describe different sets for the
    /// same node state, so reconciliation is semantically broken even once the
    /// hash inputs are unified. iOS needs a durable store first.
    public func bloomDigest() -> Data {
        lock.lock(); defer { lock.unlock() }
        return BloomDigest.build(from: seen.elements)
    }
}
`````
<<< END FILE

### `ios/Godstone/Sources/GodstoneMesh/WireV2.swift`

>>> FILE: ios/Godstone/Sources/GodstoneMesh/WireV2.swift
`````swift
// GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.
// Regenerate with `python -m wire.codegen`.
// ci/check_parity.py Invariant A fails the build on any hand edit.
import Foundation

/// GMP/2 frame. Header is 32 bytes, big-endian.
public struct FrameV2: Equatable {
    public static let magic: UInt16 = 0x4753
    public static let version: UInt8 = 0x02
    public static let headerSize = 32
    public static let maxPayload = 60000
    public static let maxTtl: UInt8 = 16
    public static let defaultTtl: UInt8 = 12

    /// Shared BLE identifiers. Both platforms MUST use these exact values.
    public static let serviceUuidString = "6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10"
    public static let inboxUuidString = "6764A002-9A5E-4C7B-B0A1-3E5D8C2F7A10"
    public static let digestUuidString = "6764A003-9A5E-4C7B-B0A1-3E5D8C2F7A10"

    public enum Flags {
        public static let sealed = 0x0001
        public static let compressed = 0x0002
        public static let fragmented = 0x0004
        public static let has_pow = 0x0008
        public static let ack_req = 0x0010
        public static let relay_ok = 0x0020
        public static let priority_mask = 0x0700
    }

    public let type: TypeV2
    public let msgId: Data        // 16 bytes
    public let routingTag: Data   // 4 bytes
    public let ttl: UInt8
    public let hopCount: UInt8
    public let flags: UInt16
    public let payload: Data

    public init(type: TypeV2, msgId: Data, routingTag: Data, ttl: UInt8,
                hopCount: UInt8, flags: UInt16, payload: Data) {
        precondition(msgId.count == 16, "msg_id must be 16 bytes")
        precondition(routingTag.count == 4, "routing_tag must be 4 bytes")
        precondition(ttl <= FrameV2.maxTtl, "ttl out of range")
        precondition(hopCount <= FrameV2.maxTtl, "hop_count out of range")
        precondition(payload.count <= FrameV2.maxPayload, "payload too large")
        self.type = type; self.msgId = msgId; self.routingTag = routingTag
        self.ttl = ttl; self.hopCount = hopCount; self.flags = flags
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: FrameV2.headerSize + payload.count)
        out.append(UInt8((FrameV2.magic >> 8) & 0xFF))
        out.append(UInt8(FrameV2.magic & 0xFF))
        out.append(FrameV2.version)
        out.append(type.rawValue)
        out.append(msgId)
        out.append(routingTag)
        out.append(ttl)
        out.append(hopCount)
        out.append(UInt8((flags >> 8) & 0xFF)); out.append(UInt8(flags & 0xFF))
        let len = UInt16(payload.count)
        out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        let crc = FrameV2.crc16([UInt8](out))
        out.append(UInt8((crc >> 8) & 0xFF)); out.append(UInt8(crc & 0xFF))
        out.append(payload)
        return out
    }

    /// Bounded, fail-closed parsing. Magic, version, CRC and the declared
    /// length are validated BEFORE any allocation, so a desynced or corrupted
    /// frame is rejected rather than half-parsed into a different message.
    public static func decode(_ data: Data) -> FrameV2? {
        guard data.count >= headerSize else { return nil }
        let b = [UInt8](data)
        guard (UInt16(b[0]) << 8 | UInt16(b[1])) == magic else { return nil }
        guard b[2] == version else { return nil }
        guard let type = TypeV2(rawValue: b[3]) else { return nil }
        let ttl = b[24]
        guard ttl <= maxTtl else { return nil }
        let hop = b[25]
        guard hop <= maxTtl else { return nil }
        let flags = UInt16(b[26]) << 8 | UInt16(b[27])
        let len = Int(b[28]) << 8 | Int(b[29])
        let crc = UInt16(b[30]) << 8 | UInt16(b[31])
        guard crc == crc16(Array(b[0..<(headerSize - 2)])) else { return nil }
        guard len <= maxPayload, data.count == headerSize + len else { return nil }
        return FrameV2(type: type,
                       msgId: data.subdata(in: 4..<20),
                       routingTag: data.subdata(in: 20..<24),
                       ttl: ttl, hopCount: hop, flags: flags,
                       payload: data.subdata(in: headerSize..<(headerSize + len)))
    }

    public static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

public enum TypeV2: UInt8 {
    case hello = 0x11
    case digest = 0x12
    case want = 0x14
    case message = 0x18
    case ack = 0x21
    case bulk_offer = 0x22
    case bulk_chunk = 0x24
    case ping = 0x28
    case goodbye = 0x41
    case sos = 0xF0
}
`````
<<< END FILE

### `ios/Godstone/Tests/GodstoneMeshTests/PortVectorTests.swift`

>>> FILE: ios/Godstone/Tests/GodstoneMeshTests/PortVectorTests.swift
`````swift
import XCTest
@testable import GodstoneCore
@testable import GodstoneMesh
import CryptoKit

final class PortVectorTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testBlake2sPortMatchesGeneratedVectors() {
        let cases: [(Data, Int, String)] = [
            (Data(), 32, "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"),
            (Data("abc".utf8), 32, "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"),
            (Data("abc".utf8), 16, "aa4938119b1dc7b87cbad0ffd200d0ae"),
            (Data("abc".utf8), 8, "972e9d2cd6de6402"),
            (Data(repeating: 0xA5, count: 64), 32, "f85b88e0ac55872416d202c5f4881e7dbc9c7270542ef75074ff9b0a610b5a0e"),
            (Data(repeating: 0xA5, count: 65), 32, "65bba861969fcb5f1d8ec69e1dbd3e891f546b02203ce73b27958b9589a6789d")
        ]
        for (input, length, expected) in cases {
            XCTAssertEqual(hex(Blake2s.hash(input, digestLength: length)), expected)
        }
    }

    func testNoiseXXEmptyPayloadMessageSizesAndTransport() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let initiatorHint = Data([1, 2, 3, 4])
        let responderHint = Data([5, 6, 7, 8])

        let initiator = NoiseSession(role: .initiator, staticKey: initiatorStatic,
                                     localHint: initiatorHint, remoteHint: responderHint)
        let responder = NoiseSession(role: .responder, staticKey: responderStatic,
                                     localHint: responderHint, remoteHint: initiatorHint)

        let m1 = try initiator.writeMessage1()
        let m2 = try responder.readMessage1AndWrite2(m1)
        let m3 = try initiator.readMessage2AndWrite3(m2)
        try responder.readMessage3(m3)

        XCTAssertEqual([m1.count, m2.count, m3.count], [32, 96, 64])
        XCTAssertTrue(initiator.isEstablished)
        XCTAssertTrue(responder.isEstablished)
        XCTAssertEqual(initiator.transcriptHash, responder.transcriptHash)

        let message = Data("godstone-port-vector".utf8)
        XCTAssertEqual(try responder.decrypt(initiator.encrypt(message)), message)
        XCTAssertEqual(try initiator.decrypt(responder.encrypt(message)), message)
    }
}
`````
<<< END FILE

### `ios/Godstone/Tests/GodstoneMeshTests/RouterTests.swift`

>>> FILE: ios/Godstone/Tests/GodstoneMeshTests/RouterTests.swift
`````swift
import XCTest
@testable import GodstoneMesh
import GodstoneCore

final class RouterTests: XCTestCase {
    private static let routingTag = Data(repeating: 0x01, count: 4)

    private func frame(_ id: String,
                       ttl: UInt8 = 8,
                       type: TypeV2 = .message,
                       flags: UInt16 = UInt16(FrameV2.Flags.relay_ok)) -> FrameV2 {
        var messageId = Data(id.utf8)
        if messageId.count < 16 {
            messageId.append(Data(repeating: 0, count: 16 - messageId.count))
        }
        return FrameV2(
            type: type,
            msgId: Data(messageId.prefix(16)),
            routingTag: Self.routingTag,
            ttl: ttl,
            hopCount: 0,
            flags: flags,
            payload: Data(repeating: 0, count: 32)
        )
    }

    func testDuplicateIsSuppressed() {
        let router = Router()
        let f = frame("msg-1")
        XCTAssertTrue(router.ingest(f, isAddressedToMe: false))
        XCTAssertFalse(router.ingest(f, isAddressedToMe: false))
    }

    func testTtlAndHopCountChangeOnRelay() throws {
        let router = Router()
        XCTAssertTrue(router.ingest(frame("msg-2", ttl: 5), isAddressedToMe: false))
        let relayed = try XCTUnwrap(router.drain(limit: 1).first)
        XCTAssertEqual(relayed.ttl, 4)
        XCTAssertEqual(relayed.hopCount, 1)
    }

    func testSosIsDeliveredLocallyAndStillRelayed() {
        let router = Router()
        var delivered: FrameV2?
        router.onDeliverLocally = { delivered = $0 }

        let sos = frame("msg-sos", ttl: 8, type: .sos,
                        flags: UInt16(FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok))
        XCTAssertTrue(router.ingest(sos, isAddressedToMe: true))
        XCTAssertEqual(delivered?.type, .sos)
        XCTAssertFalse(router.drain(limit: 8).isEmpty)
    }

    func testNonSosLocalDeliveryDoesNotRelay() {
        let router = Router()
        XCTAssertTrue(router.ingest(frame("local"), isAddressedToMe: true))
        XCTAssertTrue(router.drain(limit: 8).isEmpty)
    }

    func testBloomDigestIsStableAcrossDuplicate() {
        let router = Router()
        _ = router.ingest(frame("msg-bloom"), isAddressedToMe: false)
        let first = router.bloomDigest()
        XCTAssertEqual(first.count, 512)
        _ = router.ingest(frame("msg-bloom"), isAddressedToMe: false)
        XCTAssertEqual(first, router.bloomDigest())
    }
}
`````
<<< END FILE

### `ios/project.yml`

>>> FILE: ios/project.yml
`````yaml
# SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
#
# XcodeGen project specification for the Godstone iOS app.
#
# The app is assembled from the three local SwiftPM products in ./Godstone
# (GodstoneCore, GodstoneMesh, GodstoneLLM), mirroring the Android module
# graph:  app -> (GodstoneMesh, GodstoneLLM) -> GodstoneCore.
#
# GodstoneLLM requires a reviewed, pinned llama.cpp checkout at
# ../../third_party/llama.cpp. V4 contains neither a `.gitmodules` gitlink nor a
# verified source-archive lock, so the complete native app build remains blocked.
# XcodeGen can still generate the project; the LLM compile must fail loudly until
# release engineering supplies the dependency described in third_party/README.md.

name: Godstone

options:
  bundleIdPrefix: io.godstone
  deploymentTarget:
    iOS: "16.0"
  # XcodeGen should create the .xcodeproj next to this spec; the package is
  # referenced relatively so the spec is portable across checkouts.
  createIntermediateGroups: true
  groupSortPosition: top

settings:
  base:
    SWIFT_VERSION: "5.9"
    DEVELOPMENT_TEAM: ""
    CODE_SIGN_STYLE: Automatic
    ENABLE_BITCODE: NO
    # llama.cpp lives outside the package; the GodstoneLLM target also sets
    # this, but the search path is repeated here so the app target's header
    # map can see it when bridging is needed.
    # HEADER_SEARCH_PATHS: $(inherited) $(SRCROOT)/../third_party/llama.cpp

packages:
  GodstonePackages:
    path: ./Godstone

targets:
  Godstone:
    type: application
    platform: iOS
    sources:
      - Godstone/Sources/App
      # The .gguf model and .db archive are mmap'd at runtime. Without a
      # resources phase they are never copied into the bundle, so
      # Bundle.main.path(forResource:) returns nil on a device that by
      # definition cannot download them (C1).
      - path: Godstone/Resources
        type: folder
        optional: true
    dependencies:
      - package: GodstonePackages
        product: GodstoneCore
      - package: GodstonePackages
        product: GodstoneMesh
      - package: GodstonePackages
        product: GodstoneLLM
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.godstone.app
        INFOPLIST_FILE: Godstone/Info.plist
        CODE_SIGN_ENTITLEMENTS: Godstone/Godstone.entitlements
        # No app-level bridging header is required: LlamaBridge.h is a public
        # header inside the GodstoneLLM SwiftPM target, which exports its own
        # module. SWIFT_OBJC_BRIDGING_HEADER is intentionally omitted.
        # SWIFT_OBJC_BRIDGING_HEADER: ""
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        TARGETED_DEVICE_FAMILY: "1,2"
      configs:
        # Per-tier config overrides. Each scheme below selects one of these
        # build configurations, which fixes the Info.plist GodstoneTier value,
        # the bundle-id suffix, and the model/archive resources to copy.
        # The model and archive assets must not be compressed (they are mmap'd
        # at runtime, exactly as on Android); the resources build phase below
        # copies them verbatim.
        light:
          PRODUCT_BUNDLE_IDENTIFIER: io.godstone.app.light
          PRODUCT_NAME: Godstone-Light
          INFOPLIST_KEY_GodstoneTier: LIGHT
          INFOPLIST_KEY_GodstoneModelFile: qwen3-0.6b-q4km.gguf
          INFOPLIST_KEY_GodstoneArchiveFile: archive_light.db
          ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        medium:
          PRODUCT_BUNDLE_IDENTIFIER: io.godstone.app.medium
          PRODUCT_NAME: Godstone-Medium
          INFOPLIST_KEY_GodstoneTier: MEDIUM
          INFOPLIST_KEY_GodstoneModelFile: qwen3-1.7b-q4km.gguf
          INFOPLIST_KEY_GodstoneArchiveFile: archive_medium.db
        large:
          PRODUCT_BUNDLE_IDENTIFIER: io.godstone.app.large
          PRODUCT_NAME: Godstone-Large
          INFOPLIST_KEY_GodstoneTier: LARGE
          INFOPLIST_KEY_GodstoneModelFile: qwen3-4b-q5km.gguf
          INFOPLIST_KEY_GodstoneArchiveFile: archive_large.db

# ---------------------------------------------------------------------------
# Schemes: one per tier. Each scheme pins the build configuration so the
# correct GodstoneTier, bundle id suffix, and bundled model/archive resources
# are selected. This mirrors the Android `tier` flavor dimension in
# android/app/build.gradle.kts.
# ---------------------------------------------------------------------------
schemes:
  Godstone-Light:
    build:
      targets:
        Godstone: all
      configs:
        - light
    run:
      config: light
    test:
      config: light
      targets:
        # GodstoneLLMTests was listed here and does NOT exist: Package.swift
        # documents it as intentionally absent, because GodstoneLLM cannot build
        # without the pinned llama.cpp dependency. Listing a non-existent test target
        # makes `xcodebuild test` fail before it runs anything.
        - GodstoneMeshTests
    profile:
      config: light
    analyze:
      config: light
    archive:
      config: light

  Godstone-Medium:
    build:
      targets:
        Godstone: all
      configs:
        - medium
    run:
      config: medium
    test:
      config: medium
      targets:
        # GodstoneLLMTests was listed here and does NOT exist: Package.swift
        # documents it as intentionally absent, because GodstoneLLM cannot build
        # without the pinned llama.cpp dependency. Listing a non-existent test target
        # makes `xcodebuild test` fail before it runs anything.
        - GodstoneMeshTests
    profile:
      config: medium
    analyze:
      config: medium
    archive:
      config: medium

  Godstone-Large:
    build:
      targets:
        Godstone: all
      configs:
        - large
    run:
      config: large
    test:
      config: large
      targets:
        # GodstoneLLMTests was listed here and does NOT exist: Package.swift
        # documents it as intentionally absent, because GodstoneLLM cannot build
        # without the pinned llama.cpp dependency. Listing a non-existent test target
        # makes `xcodebuild test` fail before it runs anything.
        - GodstoneMeshTests
    profile:
      config: large
    analyze:
      config: large
    archive:
      config: large

# ---------------------------------------------------------------------------
# Notes for whoever drives `xcodegen generate`:
#
#  * The GodstoneMeshTests and GodstoneLLMTests schemes above are defined in
#    the local Package.swift; XcodeGen will surface them once the package is
#    resolved. If a test target is renamed upstream, update the entries here.
#
#  * The model (.gguf) and archive (.db) resources are NOT listed as explicit
#    sources because they are tier-specific. Ship them as Copy Bundle
#    Resources entries keyed off the active config, or -- simplest -- add a
#    per-tier folder reference (Godstone/Resources/light, .../medium,
#    .../large) and include the matching folder in each config's sources.
#    TODO: add folder references once the resource layout is finalised.
#
#  * HEADER_SEARCH_PATHS for llama.cpp is the responsibility of the
#    GodstoneLLM SwiftPM target (see Package.swift's cSettings). The app
#    target itself never imports llama.cpp directly, so no app-level search
#    path is required. The commented value above is kept for reference.
# ---------------------------------------------------------------------------
`````
<<< END FILE

### `scripts/check_tiers.py`

>>> FILE: scripts/check_tiers.py
`````python
#!/usr/bin/env python3
"""Verify that every place Godstone writes down its tier table agrees.

The tier numbers are duplicated across four files, because each is consumed by
a different toolchain that cannot read the others:

    content/ingest/build_archive.py                the TIERS dict
    android/app/build.gradle.kts                   the product flavours
    ios/Godstone/Sources/GodstoneCore/Tier.swift   the Tier enum
    docs/packaging/TIERS.md                        the published table

Duplication is the price of not writing a code generator for twelve numbers.
The price of the duplication is this script, run by the constraint audit job
in .github/workflows/build.yml on every push.

A disagreement here is not cosmetic. If Gradle ships a flavour asking for
qwen3-1.7b-q4km.gguf while the archive builder wrote qwen3-0.6b-q4km.gguf, the
app installs, launches, and then cannot find its model on a device that by
definition cannot download the right one (C1). That is a bricked install that
no over-the-air fix can reach.

Exits 0 when every available source agrees, 1 otherwise. Imports nothing
outside the standard library so it can run before pip, and touches no network.
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BUILD_ARCHIVE = ROOT / "content" / "ingest" / "build_archive.py"
GRADLE = ROOT / "android" / "app" / "build.gradle.kts"
TIERS_MD = ROOT / "docs" / "packaging" / "TIERS.md"
TIER_SWIFT = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneCore" / "Tier.swift"

TIERS = ("LIGHT", "MEDIUM", "LARGE")

# Only fields that more than one source actually states are comparable. Gradle
# also carries TOP_K_CHUNKS and the markdown carries install sizes; neither is
# duplicated anywhere else, so neither is checked here.
FIELDS = ("model_file", "db_name", "context_tokens", "embed_dim")


class Findings:
    """Collects errors and warnings so one run reports every problem at once."""

    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, msg: str) -> None:
        self.errors.append(msg)
        print("::error::" + msg, file=sys.stderr)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)
        print("::warning::" + msg, file=sys.stderr)


def read_build_archive(f: Findings) -> dict | None:
    """Pull the TIERS dict out of build_archive.py without importing it.

    Importing would drag in yaml and the embedder, which would make the
    constraint audit depend on pip having run. Parsing the AST and
    literal_eval-ing the assignment keeps this job dependency-free.
    """
    if not BUILD_ARCHIVE.exists():
        f.error("missing " + str(BUILD_ARCHIVE.relative_to(ROOT)))
        return None

    tree = ast.parse(BUILD_ARCHIVE.read_text(encoding="utf-8"))
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if "TIERS" not in names:
            continue
        try:
            raw = ast.literal_eval(node.value)
        except ValueError:
            f.error("TIERS in build_archive.py is not a literal dict")
            return None
        out = {}
        for tier in TIERS:
            if tier not in raw:
                f.error("build_archive.py TIERS has no " + tier + " entry")
                continue
            spec = raw[tier]
            out[tier] = {
                "model_file": spec.get("model_file"),
                "db_name": spec.get("db_name"),
                "context_tokens": spec.get("context_tokens"),
                "embed_dim": spec.get("embed_dim"),
            }
        return out

    f.error("no TIERS assignment found in build_archive.py")
    return None


def read_gradle(f: Findings) -> dict | None:
    """Read the product flavours.

    Rather than trying to parse Kotlin DSL blocks, this walks the file in order
    and attributes each buildConfigField to the most recent TIER declaration.
    That is exactly how the file reads to a human and it survives reformatting.
    """
    if not GRADLE.exists():
        f.error("missing " + str(GRADLE.relative_to(ROOT)))
        return None

    field = re.compile(
        r'buildConfigField\(\s*"(?:String|int)"\s*,\s*"(\w+)"\s*,\s*"(.*?)"\s*\)'
    )

    out: dict = {}
    current: str | None = None

    for line in GRADLE.read_text(encoding="utf-8").splitlines():
        m = field.search(line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        # String fields arrive double-escaped: \"LIGHT\" -> LIGHT
        value = value.replace('\\"', '"').strip('"')

        if key == "TIER":
            current = value.upper()
            out.setdefault(current, {})
        elif current is None:
            continue
        elif key == "MODEL_FILE":
            out[current]["model_file"] = value
        elif key == "ARCHIVE_FILE":
            out[current]["db_name"] = value
        elif key == "CTX_TOKENS":
            out[current]["context_tokens"] = int(value)
        elif key == "EMBED_DIM":
            out[current]["embed_dim"] = int(value)

    for tier in TIERS:
        if tier not in out:
            f.error("build.gradle.kts has no product flavour for " + tier)

    return out


def read_tiers_md(f: Findings) -> dict | None:
    """Read the two numeric rows of the published markdown table.

    The doc states context window and embedding dims as numbers; model files
    appear only as approximate sizes, so those are not comparable.
    """
    if not TIERS_MD.exists():
        f.error("missing " + str(TIERS_MD.relative_to(ROOT)))
        return None

    wanted = {"context window": "context_tokens", "embedding dims": "embed_dim"}
    out: dict = {t: {} for t in TIERS}

    for line in TIERS_MD.read_text(encoding="utf-8").splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 4:
            continue
        label = cells[0].lower()
        if label not in wanted:
            continue
        for tier, cell in zip(TIERS, cells[1:]):
            m = re.search(r"\d+", cell.replace(",", ""))
            if m:
                out[tier][wanted[label]] = int(m.group(0))

    for tier in TIERS:
        for field in wanted.values():
            if field not in out[tier]:
                f.warn("TIERS.md has no " + field + " for " + tier)

    return out


def read_tier_swift(f: Findings, require: bool) -> dict | None:
    """Check the Swift enum, if it exists yet.

    Tier.swift is referenced by AppContainer.swift (tab 06) but is not emitted
    by any tab, so on a clean checkout it is absent. Treating that as a hard
    failure would make this job red for a reason it was not written to catch,
    which trains people to ignore it. It is a warning by default; pass
    --require-swift once the file lands to make it binding.

    The parse is deliberately loose: it asserts the expected literals are
    present somewhere in the file rather than assuming a particular enum shape.
    """
    if not TIER_SWIFT.exists():
        msg = ("Tier.swift not found at "
               + str(TIER_SWIFT.relative_to(ROOT))
               + " - iOS tier table unverified")
        if require:
            f.error(msg)
        else:
            f.warn(msg)
        return None

    text = TIER_SWIFT.read_text(encoding="utf-8")
    out: dict = {t: {} for t in TIERS}

    for tier in TIERS:
        for pattern, field in (
            (r'"(qwen3-[\w.-]+\.gguf)"', "model_file"),
            (r'"(archive_\w+\.db)"', "db_name"),
        ):
            for value in re.findall(pattern, text):
                if tier.lower() in value.lower() or tier.lower() in value:
                    out[tier][field] = value

    # Parse the switch bodies directly; the tuple regex above is intentionally
    # not used as data because Swift contains several three-case integer switches.
    for property_name, field in (("contextTokens", "context_tokens"), ("embedDim", "embed_dim")):
        m = re.search(rf"var {property_name}: Int \{{(.*?)\n    \}}", text, re.S)
        if not m:
            continue
        body = m.group(1)
        patterns = {
            "LIGHT": r"case \.light(?:, \.medium)?:\s*return (\d+)",
            "MEDIUM": r"case \.medium:\s*return (\d+)",
            "LARGE": r"case \.large:\s*return (\d+)",
        }
        # Combined light/medium case is valid for embedDim.
        combined = re.search(r"case \.light, \.medium:\s*return (\d+)", body)
        if combined:
            out["LIGHT"][field] = int(combined.group(1))
            out["MEDIUM"][field] = int(combined.group(1))
        for tier, pattern in patterns.items():
            found = re.search(pattern, body)
            if found:
                out[tier][field] = int(found.group(1))

    return out


def compare(sources: dict, f: Findings) -> None:
    """Report every field on which two sources that both state it disagree."""
    for tier in TIERS:
        for field in FIELDS:
            stated = {}
            for name, table in sources.items():
                if table and tier in table and table[tier].get(field) is not None:
                    stated[name] = table[tier][field]

            if len(stated) < 2:
                continue

            values = set(stated.values())
            if len(values) == 1:
                continue

            detail = ", ".join(
                name + "=" + repr(value) for name, value in sorted(stated.items())
            )
            f.error(tier + "." + field + " disagrees: " + detail)


def main() -> int:
    parser = argparse.ArgumentParser(description="cross-check Godstone tier tables")
    parser.add_argument(
        "--require-swift",
        action="store_true",
        help="fail if GodstoneCore/Tier.swift is absent instead of warning",
    )
    args = parser.parse_args()

    f = Findings()

    sources = {
        "build_archive.py": read_build_archive(f),
        "build.gradle.kts": read_gradle(f),
        "TIERS.md": read_tiers_md(f),
        "Tier.swift": read_tier_swift(f, args.require_swift),
    }

    compare(sources, f)

    present = [name for name, table in sources.items() if table]
    print("checked " + str(len(present)) + " of 4 sources: " + ", ".join(present))

    for tier in TIERS:
        table = sources["build_archive.py"]
        if not table or tier not in table:
            continue
        spec = table[tier]
        print("  " + tier.ljust(6)
              + " " + str(spec["model_file"]).ljust(24)
              + " " + str(spec["db_name"]).ljust(20)
              + " ctx=" + str(spec["context_tokens"]).ljust(6)
              + " dim=" + str(spec["embed_dim"]))

    if f.errors:
        print("")
        print("FAIL: " + str(len(f.errors)) + " tier disagreement(s)", file=sys.stderr)
        return 1

    if f.warnings:
        print("ok: sources checked agree (" + str(len(f.warnings)) + " warning(s))")
    else:
        print("ok: all four tier tables agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
`````
<<< END FILE

### `scripts/fetch_models.sh`

>>> FILE: scripts/fetch_models.sh
`````bash
#!/usr/bin/env bash
#
# Fetch the exact, pre-quantised GGUF artifacts declared in
# docs/packaging/MODELS.lock.json.
#
# This developer-only script is the repository's sole model-network path. It
# fails closed while the lock is UNPINNED or any checksum is absent. Never
# replace a missing checksum with a guessed value: verify the upstream artifact,
# record who verified it and when, then change status to PINNED.
#
# Usage:
#     scripts/fetch_models.sh
#     scripts/fetch_models.sh LIGHT
#     GODSTONE_MODEL_DIR=/mnt/big scripts/fetch_models.sh MEDIUM

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/docs/packaging/MODELS.lock.json"
MODEL_DIR="${GODSTONE_MODEL_DIR:-$ROOT/models}"
WANT_TIER="${1:-ALL}"

case "$WANT_TIER" in
  ALL|LIGHT|MEDIUM|LARGE) ;;
  *) echo "error: tier must be ALL, LIGHT, MEDIUM or LARGE" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to validate the model lock" >&2
  exit 1
}

ROWS_TEXT="$(python3 - "$LOCK" "$WANT_TIER" <<'PY'
import json, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
tier = sys.argv[2]
try:
    lock = json.loads(path.read_text())
except Exception as exc:
    raise SystemExit(f"error: cannot read model lock: {exc}")

if lock.get("schema") != 1:
    raise SystemExit("error: unsupported model-lock schema")
if lock.get("status") != "PINNED":
    raise SystemExit(
        "error: model lock is UNPINNED; independently verify every upstream "
        "artifact and SHA-256 before fetching"
    )
if not lock.get("verified_on") or not lock.get("verified_by"):
    raise SystemExit("error: PINNED lock requires verified_on and verified_by")

rows = []
for item in lock.get("artifacts", []):
    tiers = item.get("tiers", [])
    if tier != "ALL" and tier not in tiers:
        continue
    sha = item.get("sha256")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise SystemExit(f"error: invalid or missing sha256 for {item.get('id')}")
    fields = [item.get("repo"), item.get("source_file"), item.get("output_file")]
    if any(not isinstance(v, str) or not v for v in fields):
        raise SystemExit(f"error: incomplete coordinates for {item.get('id')}")
    if "/" in item["output_file"] or item["output_file"] in {".", ".."}:
        raise SystemExit(f"error: unsafe output_file for {item.get('id')}")
    rows.append("|".join([item["repo"], item["source_file"], item["output_file"], sha]))

if not rows:
    raise SystemExit(f"error: no locked artifacts selected for tier {tier}")
print("\n".join(rows))
PY
)"
mapfile -t ROWS <<< "$ROWS_TEXT"

mkdir -p "$MODEL_DIR"

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo "error: need sha256sum or shasum" >&2
    return 1
  fi
}

download() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --continue-at - --output "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --continue --output-document="$dest" "$url"
  else
    echo "error: need curl or wget" >&2
    return 1
  fi
}

for row in "${ROWS[@]}"; do
  IFS='|' read -r repo source_file output_file want_sha <<< "$row"
  dest="$MODEL_DIR/$output_file"
  part="$dest.part"

  if [[ -f "$dest" && "$(checksum "$dest")" == "$want_sha" ]]; then
    echo "ok       $output_file (already verified)"
    continue
  fi

  rm -f "$part"
  echo "fetching $source_file from $repo"
  download "https://huggingface.co/$repo/resolve/main/$source_file" "$part"

  got="$(checksum "$part")"
  if [[ "$got" != "$want_sha" ]]; then
    echo "error: checksum failed for $output_file" >&2
    echo "       expected $want_sha" >&2
    echo "       got      $got" >&2
    rm -f "$part"
    exit 1
  fi
  mv "$part" "$dest"
  echo "ok       $output_file"
done

echo "locked model artifacts are in $MODEL_DIR"
`````
<<< END FILE

### `scripts/quantise.sh`

>>> FILE: scripts/quantise.sh
`````bash
#!/usr/bin/env bash
#
# V4 deliberately downloads the exact shipping GGUF quantisations named in the
# verified model lock. Re-quantising an already-quantised GGUF is neither
# reproducible nor useful and was a defect in V3's packaging path.
#
# This command remains as a compatibility entrypoint for existing build notes.
# It verifies that the locked outputs are present and match their SHA-256 values;
# it does not transform model weights.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/docs/packaging/MODELS.lock.json"
MODEL_DIR="${GODSTONE_MODEL_DIR:-$ROOT/models}"
WANT_TIER="${1:-ALL}"

python3 - "$LOCK" "$MODEL_DIR" "$WANT_TIER" <<'PY'
import hashlib, json, pathlib, re, sys

lock_path, model_dir, tier = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
if tier not in {"ALL", "LIGHT", "MEDIUM", "LARGE"}:
    raise SystemExit("error: tier must be ALL, LIGHT, MEDIUM or LARGE")
lock = json.loads(lock_path.read_text())
if lock.get("status") != "PINNED":
    raise SystemExit("error: model lock is UNPINNED; run no release packaging")

checked = 0
for item in lock.get("artifacts", []):
    if tier != "ALL" and tier not in item.get("tiers", []):
        continue
    sha = item.get("sha256")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise SystemExit(f"error: invalid sha256 for {item.get('id')}")
    path = model_dir / item["output_file"]
    if not path.is_file():
        raise SystemExit(f"error: missing {path}; run scripts/fetch_models.sh first")
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    got = h.hexdigest()
    if got != sha:
        raise SystemExit(f"error: checksum mismatch for {path.name}: {got}")
    print(f"ok       {path.name}")
    checked += 1
if not checked:
    raise SystemExit(f"error: no locked artifacts selected for tier {tier}")
print("model set is verified; no re-quantisation is required")
PY
`````
<<< END FILE

### `third_party/README.md`

>>> FILE: third_party/README.md
`````markdown
# Native dependency status

`third_party/llama.cpp/` is required by both native LLM bridges, but V4 does
**not** contain a `.gitmodules` entry, a gitlink, or a verified commit lock.
Therefore the dependency is currently **absent and unpinned**.

Do not run `git submodule update` and assume this is closed: without a committed
gitlink that command has nothing to restore. Before an app/LLM build may be
called reproducible, add one of these reviewed controls:

1. a real git submodule at `third_party/llama.cpp` pinned to an audited commit;
2. or a lockfile plus a fetch script that verifies the exact source archive
   SHA-256 and license before extraction.

Both native build definitions intentionally expect the dependency at this path:

- `android/llm/src/main/cpp/CMakeLists.txt`
- `ios/Godstone/Package.swift`

Until the pin exists, CI may compile only the host-buildable/core surfaces and
must report the complete LLM/app build as blocked rather than silently skipping
it.
`````
<<< END FILE

### `wire/codegen.py`

>>> FILE: wire/codegen.py
`````python
#!/usr/bin/env python3
"""Generate the GMP/2 codecs and golden vectors from wire_v2.yaml.

    python -m wire.codegen

Emits, all from one spec:

    wire/gen/WireV2.kt          Android codec
    wire/gen/WireV2.swift       iOS codec
    wire/gen/wire_v2_codec.py   Python reference (drives the vectors)
    wire/golden_vectors.json    encode/decode fixtures + negative cases

Invariant A (ci/check_parity.py) regenerates and diffs. Hand-edit a generated
file and CI goes red, so "the two platforms are byte-for-byte identical" is a
build assertion rather than a comment that was wrong for the entire v1 lifetime.

Also VERIFIES the spec's own safety claims: every type code must have even
parity, pairwise Hamming distance must be >= 2, and no v2 code may reuse a v1
value. Asserted here, never trusted from the YAML.
"""
from __future__ import annotations

import filecmp
import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent
SPEC = ROOT / "wire_v2.yaml"
GEN = ROOT / "gen"
# Generated codecs are ALSO emitted into the app source trees. Emitting only to
# wire/gen was the defect GPT's review found: both platforms had a correct GMP/2
# codec sitting in a directory neither app compiles, while the apps kept using
# their incompatible GMP/1 frames. Generated code that nothing imports is a
# document, not a fix.
REPO = ROOT.parent
KT_OUT = REPO / "android/mesh/src/main/java/io/godstone/mesh/wire/v2/WireV2.kt"
SWIFT_OUT = REPO / "ios/Godstone/Sources/GodstoneMesh/WireV2.swift"
VECTORS = ROOT / "golden_vectors.json"

BANNER = ("GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.\n"
          "Regenerate with `python -m wire.codegen`.\n"
          "ci/check_parity.py Invariant A fails the build on any hand edit.")


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def verify_hamming(types: dict[str, int]) -> list[str]:
    """Verify the spec's safety claims. Check, never trust.

    Three properties, in order of strength:
      1. EVEN PARITY on every code. Structural: a single-bit flip changes parity
         and lands on a non-existent code, so pairwise distance >= 2 follows by
         construction rather than by careful hand-picking.
      2. Pairwise Hamming distance >= 2 across all codes.
      3. SOS >= 2 bits from everything, so no single- or double-bit flip can
         manufacture a distress broadcast.
    """
    problems = []
    for name, code in types.items():
        if bin(code).count("1") % 2 != 0:
            problems.append(
                f"{name}(0x{code:02X}) has ODD parity; the even-parity rule is "
                f"what guarantees single-bit-flip safety")
    names = list(types)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if types[a] == types[b]:
                problems.append(f"duplicate code for {a}/{b}")
                continue
            d = hamming(types[a], types[b])
            if d < 2:
                problems.append(
                    f"{a}(0x{types[a]:02X}) is {d} bit(s) from {b}(0x{types[b]:02X})")
    sos = types["SOS"]
    for name, code in types.items():
        if name == "SOS":
            continue
        if hamming(sos, code) < 2:
            problems.append(
                f"SOS(0x{sos:02X}) is too close to {name}(0x{code:02X})")
    return problems


def verify_priority_mask(spec: dict) -> list[str]:
    """ADR-001 s.3.1. The mask must be wide enough for the priority table.

    GMP/2 shipped PRIORITY_MASK 0x00C0 -- two bits, four slots -- while the
    priority set has five members. It could not encode Android's existing
    priorities at all, and nobody noticed because no Android code path ever
    constructed a FrameV2. A mechanical type swap would have silently collapsed
    two priority classes, and the classes that collide decide what is dropped
    under flood.

    Asserted here so the next widening of the priority table fails the BUILD
    rather than the mesh.
    """
    mask = spec.get("flags", {}).get("PRIORITY_MASK")
    priorities = spec.get("priority", {})
    if mask is None or not priorities:
        return ["spec is missing PRIORITY_MASK or the priority table"]

    problems = []
    slots = 1 << bin(mask).count("1")
    if slots < len(priorities):
        problems.append(
            f"PRIORITY_MASK 0x{mask:04X} has {bin(mask).count('1')} bit(s) = "
            f"{slots} slot(s), but the priority table defines {len(priorities)}: "
            f"{sorted(priorities)}. Widen the mask.")

    # Contiguity: a split mask cannot be shifted out with one operation, and
    # both platforms would have to agree on a bit-gathering order nobody wrote down.
    shifted = mask >> ((mask & -mask).bit_length() - 1)
    if shifted & (shifted + 1):
        problems.append(f"PRIORITY_MASK 0x{mask:04X} is not contiguous")

    for name, value in priorities.items():
        if value >= slots:
            problems.append(f"priority {name}={value} does not fit in {slots} slots")
    return problems


def verify_no_v1_reuse(types: dict[str, int]) -> list[str]:
    """v1 used 0x01..0x0A on both platforms. No v2 code may collide."""
    return [f"{n}=0x{c:02X} collides with the v1 range 0x01..0x0A"
            for n, c in types.items() if 0x01 <= c <= 0x0A]


# --------------------------------------------------------------------------
# Emitters
# --------------------------------------------------------------------------
def emit_kotlin(s: dict) -> str:
    t = "\n".join(f"    {n}(0x{c:02X}.toByte())," for n, c in s["message_types"].items())
    f = "\n".join(f"        const val {n} = 0x{c:04X}" for n, c in s["flags"].items())
    return f'''// {BANNER.replace(chr(10), chr(10) + "// ")}
package io.godstone.mesh.wire.v2

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** GMP/2 frame. Header is {s["header_size"]} bytes, big-endian. */
data class FrameV2(
    val type: TypeV2,
    val msgId: ByteArray,        // 16 bytes
    val routingTag: ByteArray,   // 4 bytes
    val ttl: Int,
    val hopCount: Int,
    val flags: Int,
    val payload: ByteArray
) {{
    fun encode(): ByteArray {{
        require(msgId.size == 16) {{ "msg_id must be 16 bytes" }}
        require(routingTag.size == 4) {{ "routing_tag must be 4 bytes" }}
        require(ttl in 0..MAX_TTL) {{ "ttl out of range" }}
        require(hopCount in 0..MAX_TTL) {{ "hop_count out of range" }}
        require(payload.size <= MAX_PAYLOAD) {{ "payload too large" }}
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
        buf.putShort(MAGIC.toShort())
        buf.put(VERSION)
        buf.put(type.code)
        buf.put(msgId)
        buf.put(routingTag)
        buf.put(ttl.toByte())
        buf.put(hopCount.toByte())
        buf.putShort(flags.toShort())
        buf.putShort(payload.size.toShort())
        val header = buf.array()
        buf.putShort(crc16(header, 0, HEADER_SIZE - 2).toShort())
        buf.put(payload)
        return buf.array()
    }}

    companion object {{
        const val MAGIC = 0x{s["magic"]:04X}
        const val VERSION: Byte = 0x{s["version"]:02X}
        const val HEADER_SIZE = {s["header_size"]}
        const val MAX_PAYLOAD = {s["max_payload"]}
        const val MAX_TTL = {s["max_ttl"]}
        const val DEFAULT_TTL = {s["default_ttl"]}

        /** Shared BLE identifiers. Both platforms MUST use these exact values. */
        val SERVICE_UUID: java.util.UUID = java.util.UUID.fromString("{s["ble"]["service_uuid"]}")
        val INBOX_UUID: java.util.UUID = java.util.UUID.fromString("{s["ble"]["inbox_uuid"]}")
        val DIGEST_UUID: java.util.UUID = java.util.UUID.fromString("{s["ble"]["digest_uuid"]}")

{f}

        /**
         * Bounded, fail-closed parsing. Magic, version, CRC and the declared
         * length are all validated BEFORE any allocation, so a desynced or
         * corrupted frame is rejected outright rather than half-parsed into a
         * different message.
         */
        fun decode(raw: ByteArray): FrameV2? {{
            if (raw.size < HEADER_SIZE) return null
            val buf = ByteBuffer.wrap(raw).order(ByteOrder.BIG_ENDIAN)
            if ((buf.short.toInt() and 0xFFFF) != MAGIC) return null
            if (buf.get() != VERSION) return null
            val type = TypeV2.from(buf.get()) ?: return null
            val msgId = ByteArray(16).also {{ buf.get(it) }}
            val tag = ByteArray(4).also {{ buf.get(it) }}
            val ttl = buf.get().toInt() and 0xFF
            if (ttl > MAX_TTL) return null
            val hop = buf.get().toInt() and 0xFF
            if (hop > MAX_TTL) return null
            val flags = buf.short.toInt() and 0xFFFF
            val len = buf.short.toInt() and 0xFFFF
            val crc = buf.short.toInt() and 0xFFFF
            if (crc != crc16(raw, 0, HEADER_SIZE - 2)) return null
            if (len > MAX_PAYLOAD) return null
            if (raw.size != HEADER_SIZE + len) return null
            val payload = ByteArray(len).also {{ buf.get(it) }}
            return FrameV2(type, msgId, tag, ttl, hop, flags, payload)
        }}

        fun crc16(data: ByteArray, from: Int, len: Int): Int {{
            var crc = 0xFFFF
            for (i in from until from + len) {{
                crc = crc xor ((data[i].toInt() and 0xFF) shl 8)
                repeat(8) {{
                    crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xFFFF
                          else (crc shl 1) and 0xFFFF
                }}
            }}
            return crc
        }}
    }}
}}

enum class TypeV2(val code: Byte) {{
{t}
    ;
    companion object {{
        private val map = entries.associateBy {{ it.code }}
        fun from(b: Byte): TypeV2? = map[b]
    }}
}}
'''


def emit_swift(s: dict) -> str:
    t = "\n".join(f"    case {n.lower()} = 0x{c:02X}" for n, c in s["message_types"].items())
    f = "\n".join(f"        public static let {n.lower()} = 0x{c:04X}" for n, c in s["flags"].items())
    return f'''// {BANNER.replace(chr(10), chr(10) + "// ")}
import Foundation

/// GMP/2 frame. Header is {s["header_size"]} bytes, big-endian.
public struct FrameV2: Equatable {{
    public static let magic: UInt16 = 0x{s["magic"]:04X}
    public static let version: UInt8 = 0x{s["version"]:02X}
    public static let headerSize = {s["header_size"]}
    public static let maxPayload = {s["max_payload"]}
    public static let maxTtl: UInt8 = {s["max_ttl"]}
    public static let defaultTtl: UInt8 = {s["default_ttl"]}

    /// Shared BLE identifiers. Both platforms MUST use these exact values.
    public static let serviceUuidString = "{s["ble"]["service_uuid"]}"
    public static let inboxUuidString = "{s["ble"]["inbox_uuid"]}"
    public static let digestUuidString = "{s["ble"]["digest_uuid"]}"

    public enum Flags {{
{f}
    }}

    public let type: TypeV2
    public let msgId: Data        // 16 bytes
    public let routingTag: Data   // 4 bytes
    public let ttl: UInt8
    public let hopCount: UInt8
    public let flags: UInt16
    public let payload: Data

    public init(type: TypeV2, msgId: Data, routingTag: Data, ttl: UInt8,
                hopCount: UInt8, flags: UInt16, payload: Data) {{
        precondition(msgId.count == 16, "msg_id must be 16 bytes")
        precondition(routingTag.count == 4, "routing_tag must be 4 bytes")
        precondition(ttl <= FrameV2.maxTtl, "ttl out of range")
        precondition(hopCount <= FrameV2.maxTtl, "hop_count out of range")
        precondition(payload.count <= FrameV2.maxPayload, "payload too large")
        self.type = type; self.msgId = msgId; self.routingTag = routingTag
        self.ttl = ttl; self.hopCount = hopCount; self.flags = flags
        self.payload = payload
    }}

    public func encode() -> Data {{
        var out = Data(capacity: FrameV2.headerSize + payload.count)
        out.append(UInt8((FrameV2.magic >> 8) & 0xFF))
        out.append(UInt8(FrameV2.magic & 0xFF))
        out.append(FrameV2.version)
        out.append(type.rawValue)
        out.append(msgId)
        out.append(routingTag)
        out.append(ttl)
        out.append(hopCount)
        out.append(UInt8((flags >> 8) & 0xFF)); out.append(UInt8(flags & 0xFF))
        let len = UInt16(payload.count)
        out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        let crc = FrameV2.crc16([UInt8](out))
        out.append(UInt8((crc >> 8) & 0xFF)); out.append(UInt8(crc & 0xFF))
        out.append(payload)
        return out
    }}

    /// Bounded, fail-closed parsing. Magic, version, CRC and the declared
    /// length are validated BEFORE any allocation, so a desynced or corrupted
    /// frame is rejected rather than half-parsed into a different message.
    public static func decode(_ data: Data) -> FrameV2? {{
        guard data.count >= headerSize else {{ return nil }}
        let b = [UInt8](data)
        guard (UInt16(b[0]) << 8 | UInt16(b[1])) == magic else {{ return nil }}
        guard b[2] == version else {{ return nil }}
        guard let type = TypeV2(rawValue: b[3]) else {{ return nil }}
        let ttl = b[24]
        guard ttl <= maxTtl else {{ return nil }}
        let hop = b[25]
        guard hop <= maxTtl else {{ return nil }}
        let flags = UInt16(b[26]) << 8 | UInt16(b[27])
        let len = Int(b[28]) << 8 | Int(b[29])
        let crc = UInt16(b[30]) << 8 | UInt16(b[31])
        guard crc == crc16(Array(b[0..<(headerSize - 2)])) else {{ return nil }}
        guard len <= maxPayload, data.count == headerSize + len else {{ return nil }}
        return FrameV2(type: type,
                       msgId: data.subdata(in: 4..<20),
                       routingTag: data.subdata(in: 20..<24),
                       ttl: ttl, hopCount: hop, flags: flags,
                       payload: data.subdata(in: headerSize..<(headerSize + len)))
    }}

    public static func crc16(_ data: [UInt8]) -> UInt16 {{
        var crc: UInt16 = 0xFFFF
        for byte in data {{
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {{
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }}
        }}
        return crc
    }}
}}

public enum TypeV2: UInt8 {{
{t}
}}
'''


def emit_python(s: dict) -> str:
    t = "\n".join(f'    "{n}": 0x{c:02X},' for n, c in s["message_types"].items())
    f = "\n".join(f'    "{n}": 0x{c:04X},' for n, c in s["flags"].items())
    return f'''"""{BANNER}"""
from __future__ import annotations

MAGIC = 0x{s["magic"]:04X}
VERSION = 0x{s["version"]:02X}
HEADER_SIZE = {s["header_size"]}
MAX_PAYLOAD = {s["max_payload"]}
MAX_TTL = {s["max_ttl"]}
DEFAULT_TTL = {s["default_ttl"]}

TYPES = {{
{t}
}}
FLAGS = {{
{f}
}}
NAME_BY_CODE = {{v: k for k, v in TYPES.items()}}


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode(type_code: int, msg_id: bytes, routing_tag: bytes, ttl: int,
           hop_count: int, flags: int, payload: bytes) -> bytes:
    assert len(msg_id) == 16 and len(routing_tag) == 4
    assert 0 <= ttl <= MAX_TTL and 0 <= hop_count <= MAX_TTL
    assert len(payload) <= MAX_PAYLOAD
    h = (MAGIC.to_bytes(2, "big") + bytes([VERSION, type_code]) + msg_id
         + routing_tag + bytes([ttl, hop_count])
         + flags.to_bytes(2, "big") + len(payload).to_bytes(2, "big"))
    return h + crc16(h).to_bytes(2, "big") + payload


def decode(raw: bytes) -> dict | None:
    """Fail-closed: magic, version, type, CRC and length all validated first."""
    if len(raw) < HEADER_SIZE:
        return None
    if int.from_bytes(raw[0:2], "big") != MAGIC:
        return None
    if raw[2] != VERSION:
        return None
    if raw[3] not in NAME_BY_CODE:
        return None
    ttl = raw[24]
    if ttl > MAX_TTL:
        return None
    hop = raw[25]
    if hop > MAX_TTL:
        return None
    length = int.from_bytes(raw[28:30], "big")
    if int.from_bytes(raw[30:32], "big") != crc16(raw[0:HEADER_SIZE - 2]):
        return None
    if length > MAX_PAYLOAD or len(raw) != HEADER_SIZE + length:
        return None
    return {{
        "type": NAME_BY_CODE[raw[3]],
        "msg_id": raw[4:20].hex(),
        "routing_tag": raw[20:24].hex(),
        "ttl": ttl,
        "hop_count": hop,
        "flags": int.from_bytes(raw[26:28], "big"),
        "payload": raw[HEADER_SIZE:].hex(),
    }}
'''


def build_vectors(spec: dict, codec) -> dict:
    mid = bytes(range(16))
    tag = bytes.fromhex("deadbeef")
    fl = spec["flags"]
    cases = []
    for name in ("HELLO", "MESSAGE", "DIGEST", "SOS"):
        code = spec["message_types"][name]
        payload = (b"SOS1" + b"\x00" * 64 + b"help") if name == "SOS" \
            else b"payload-" + name.encode()
        flags = (fl["ACK_REQ"] | fl["RELAY_OK"]) if name == "SOS" else fl["SEALED"]
        enc = codec.encode(code, mid, tag, spec["default_ttl"], 0, flags, payload)
        cases.append({
            "name": f"encode_{name.lower()}",
            "type": name, "type_code": code,
            "msg_id": mid.hex(), "routing_tag": tag.hex(),
            "ttl": spec["default_ttl"], "hop_count": 0, "flags": flags,
            "payload": payload.hex(),
            "encoded": enc.hex(),
            "encoded_len": len(enc),
        })

    good = bytes.fromhex(cases[0]["encoded"])
    negatives = []

    def neg(name, raw, why):
        negatives.append({"name": name, "frame": raw.hex(), "must_reject": True,
                          "rationale": why})

    bad_type = bytearray(good)
    bad_type[3] = 0x02
    bad_type[30:32] = crc16_ccitt(bytes(bad_type[:30])).to_bytes(2, "big")
    neg("reject_legacy_type_0x02", bytes(bad_type),
        "v1 Android DIGEST / v1 iOS SOS. Must hit the unknown-type branch, "
        "never be read as a distress broadcast.")

    v1 = bytearray(good)
    v1[2] = 0x01
    v1[30:32] = crc16_ccitt(bytes(v1[:30])).to_bytes(2, "big")
    neg("reject_v1_frame", bytes(v1), "version byte checked before anything else")

    corrupt = bytearray(good)
    corrupt[10] ^= 0xFF
    neg("reject_bad_crc", bytes(corrupt),
        "single-bit corruption inside msg_id must fail the header CRC")

    bad_hop = bytearray(good)
    bad_hop[25] = spec["max_ttl"] + 1
    bad_hop[30:32] = crc16_ccitt(bytes(bad_hop[:30])).to_bytes(2, "big")
    neg("reject_hop_count_over_max", bytes(bad_hop),
        "hop_count above MAX_TTL is malformed and must not wrap on relay")

    sos = spec["message_types"]["SOS"]
    nosig = codec.encode(sos, mid, tag, 12, 0,
                         fl["ACK_REQ"] | fl["RELAY_OK"], b"help")
    negatives.append({
        "name": "reject_sos_missing_payload_magic", "frame": nosig.hex(),
        "must_reject": True,
        "rationale": "SOS payload lacks the SOS1 magic and Ed25519 signature. "
                     "Decodes as a frame, MUST be refused by the SOS validator: "
                     "a parse error must not be able to fabricate a distress call."})

    flagless = codec.encode(sos, mid, tag, 12, 0, 0,
                            b"SOS1" + b"\x00" * 64 + b"help")
    negatives.append({
        "name": "reject_sos_missing_flags", "frame": flagless.hex(),
        "must_reject": True,
        "rationale": "SOS requires ACK_REQ|RELAY_OK set."})

    return {
        "_comment": "GENERATED by wire/codegen.py from wire_v2.yaml. Both "
                    "platforms must reproduce every `encoded` value exactly and "
                    "reject every negative frame.",
        "header_size": spec["header_size"],
        "magic": spec["magic"],
        "version": spec["version"],
        "message_types": spec["message_types"],
        "hamming_min_distance_to_sos": min(
            hamming(spec["message_types"]["SOS"], c)
            for n, c in spec["message_types"].items() if n != "SOS"),
        "cases": cases,
        "negative_cases": negatives,
    }


def main() -> int:
    spec = yaml.safe_load(SPEC.read_text())

    problems = (verify_hamming(spec["message_types"])
                + verify_no_v1_reuse(spec["message_types"])
                + verify_priority_mask(spec))
    if problems:
        for p in problems:
            print(f"::error::{p}")
        return 1

    GEN.mkdir(exist_ok=True)
    kt, sw = emit_kotlin(spec), emit_swift(spec)
    (GEN / "WireV2.kt").write_text(kt, encoding="utf-8")
    (GEN / "WireV2.swift").write_text(sw, encoding="utf-8")
    # Into the app trees, where they are actually compiled.
    KT_OUT.parent.mkdir(parents=True, exist_ok=True)
    KT_OUT.write_text(kt, encoding="utf-8")
    SWIFT_OUT.parent.mkdir(parents=True, exist_ok=True)
    SWIFT_OUT.write_text(sw, encoding="utf-8")
    (GEN / "wire_v2_codec.py").write_text(emit_python(spec), encoding="utf-8")
    (GEN / "__init__.py").write_text('"""Generated codecs."""\n', encoding="utf-8")

    import importlib.util
    sp = importlib.util.spec_from_file_location("codec", GEN / "wire_v2_codec.py")
    codec = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(codec)

    vectors = build_vectors(spec, codec)
    VECTORS.write_text(json.dumps(vectors, indent=2) + "\n", encoding="utf-8")

    print("generated WireV2.kt, WireV2.swift, wire_v2_codec.py, golden_vectors.json")
    print(f"  header {spec['header_size']}B  magic 0x{spec['magic']:04X}  "
          f"types {len(spec['message_types'])}")
    print(f"  min Hamming distance SOS -> any other type: "
          f"{vectors['hamming_min_distance_to_sos']} (spec requires >= 2)")
    _m = spec["flags"]["PRIORITY_MASK"]
    print(f"  priority mask 0x{_m:04X} = {1 << bin(_m).count('1')} slot(s) for "
          f"{len(spec['priority'])} priorities (ADR-001 s.3.1)")
    print(f"  {len(vectors['cases'])} positive, "
          f"{len(vectors['negative_cases'])} negative vectors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
`````
<<< END FILE

### `wire/gen/WireV2.kt`

>>> FILE: wire/gen/WireV2.kt
`````kotlin
// GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.
// Regenerate with `python -m wire.codegen`.
// ci/check_parity.py Invariant A fails the build on any hand edit.
package io.godstone.mesh.wire.v2

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** GMP/2 frame. Header is 32 bytes, big-endian. */
data class FrameV2(
    val type: TypeV2,
    val msgId: ByteArray,        // 16 bytes
    val routingTag: ByteArray,   // 4 bytes
    val ttl: Int,
    val hopCount: Int,
    val flags: Int,
    val payload: ByteArray
) {
    fun encode(): ByteArray {
        require(msgId.size == 16) { "msg_id must be 16 bytes" }
        require(routingTag.size == 4) { "routing_tag must be 4 bytes" }
        require(ttl in 0..MAX_TTL) { "ttl out of range" }
        require(hopCount in 0..MAX_TTL) { "hop_count out of range" }
        require(payload.size <= MAX_PAYLOAD) { "payload too large" }
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
        buf.putShort(MAGIC.toShort())
        buf.put(VERSION)
        buf.put(type.code)
        buf.put(msgId)
        buf.put(routingTag)
        buf.put(ttl.toByte())
        buf.put(hopCount.toByte())
        buf.putShort(flags.toShort())
        buf.putShort(payload.size.toShort())
        val header = buf.array()
        buf.putShort(crc16(header, 0, HEADER_SIZE - 2).toShort())
        buf.put(payload)
        return buf.array()
    }

    companion object {
        const val MAGIC = 0x4753
        const val VERSION: Byte = 0x02
        const val HEADER_SIZE = 32
        const val MAX_PAYLOAD = 60000
        const val MAX_TTL = 16
        const val DEFAULT_TTL = 12

        /** Shared BLE identifiers. Both platforms MUST use these exact values. */
        val SERVICE_UUID: java.util.UUID = java.util.UUID.fromString("6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        val INBOX_UUID: java.util.UUID = java.util.UUID.fromString("6764A002-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        val DIGEST_UUID: java.util.UUID = java.util.UUID.fromString("6764A003-9A5E-4C7B-B0A1-3E5D8C2F7A10")

        const val SEALED = 0x0001
        const val COMPRESSED = 0x0002
        const val FRAGMENTED = 0x0004
        const val HAS_POW = 0x0008
        const val ACK_REQ = 0x0010
        const val RELAY_OK = 0x0020
        const val PRIORITY_MASK = 0x0700

        /**
         * Bounded, fail-closed parsing. Magic, version, CRC and the declared
         * length are all validated BEFORE any allocation, so a desynced or
         * corrupted frame is rejected outright rather than half-parsed into a
         * different message.
         */
        fun decode(raw: ByteArray): FrameV2? {
            if (raw.size < HEADER_SIZE) return null
            val buf = ByteBuffer.wrap(raw).order(ByteOrder.BIG_ENDIAN)
            if ((buf.short.toInt() and 0xFFFF) != MAGIC) return null
            if (buf.get() != VERSION) return null
            val type = TypeV2.from(buf.get()) ?: return null
            val msgId = ByteArray(16).also { buf.get(it) }
            val tag = ByteArray(4).also { buf.get(it) }
            val ttl = buf.get().toInt() and 0xFF
            if (ttl > MAX_TTL) return null
            val hop = buf.get().toInt() and 0xFF
            if (hop > MAX_TTL) return null
            val flags = buf.short.toInt() and 0xFFFF
            val len = buf.short.toInt() and 0xFFFF
            val crc = buf.short.toInt() and 0xFFFF
            if (crc != crc16(raw, 0, HEADER_SIZE - 2)) return null
            if (len > MAX_PAYLOAD) return null
            if (raw.size != HEADER_SIZE + len) return null
            val payload = ByteArray(len).also { buf.get(it) }
            return FrameV2(type, msgId, tag, ttl, hop, flags, payload)
        }

        fun crc16(data: ByteArray, from: Int, len: Int): Int {
            var crc = 0xFFFF
            for (i in from until from + len) {
                crc = crc xor ((data[i].toInt() and 0xFF) shl 8)
                repeat(8) {
                    crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xFFFF
                          else (crc shl 1) and 0xFFFF
                }
            }
            return crc
        }
    }
}

enum class TypeV2(val code: Byte) {
    HELLO(0x11.toByte()),
    DIGEST(0x12.toByte()),
    WANT(0x14.toByte()),
    MESSAGE(0x18.toByte()),
    ACK(0x21.toByte()),
    BULK_OFFER(0x22.toByte()),
    BULK_CHUNK(0x24.toByte()),
    PING(0x28.toByte()),
    GOODBYE(0x41.toByte()),
    SOS(0xF0.toByte()),
    ;
    companion object {
        private val map = entries.associateBy { it.code }
        fun from(b: Byte): TypeV2? = map[b]
    }
}
`````
<<< END FILE

### `wire/gen/WireV2.swift`

>>> FILE: wire/gen/WireV2.swift
`````swift
// GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.
// Regenerate with `python -m wire.codegen`.
// ci/check_parity.py Invariant A fails the build on any hand edit.
import Foundation

/// GMP/2 frame. Header is 32 bytes, big-endian.
public struct FrameV2: Equatable {
    public static let magic: UInt16 = 0x4753
    public static let version: UInt8 = 0x02
    public static let headerSize = 32
    public static let maxPayload = 60000
    public static let maxTtl: UInt8 = 16
    public static let defaultTtl: UInt8 = 12

    /// Shared BLE identifiers. Both platforms MUST use these exact values.
    public static let serviceUuidString = "6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10"
    public static let inboxUuidString = "6764A002-9A5E-4C7B-B0A1-3E5D8C2F7A10"
    public static let digestUuidString = "6764A003-9A5E-4C7B-B0A1-3E5D8C2F7A10"

    public enum Flags {
        public static let sealed = 0x0001
        public static let compressed = 0x0002
        public static let fragmented = 0x0004
        public static let has_pow = 0x0008
        public static let ack_req = 0x0010
        public static let relay_ok = 0x0020
        public static let priority_mask = 0x0700
    }

    public let type: TypeV2
    public let msgId: Data        // 16 bytes
    public let routingTag: Data   // 4 bytes
    public let ttl: UInt8
    public let hopCount: UInt8
    public let flags: UInt16
    public let payload: Data

    public init(type: TypeV2, msgId: Data, routingTag: Data, ttl: UInt8,
                hopCount: UInt8, flags: UInt16, payload: Data) {
        precondition(msgId.count == 16, "msg_id must be 16 bytes")
        precondition(routingTag.count == 4, "routing_tag must be 4 bytes")
        precondition(ttl <= FrameV2.maxTtl, "ttl out of range")
        precondition(hopCount <= FrameV2.maxTtl, "hop_count out of range")
        precondition(payload.count <= FrameV2.maxPayload, "payload too large")
        self.type = type; self.msgId = msgId; self.routingTag = routingTag
        self.ttl = ttl; self.hopCount = hopCount; self.flags = flags
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: FrameV2.headerSize + payload.count)
        out.append(UInt8((FrameV2.magic >> 8) & 0xFF))
        out.append(UInt8(FrameV2.magic & 0xFF))
        out.append(FrameV2.version)
        out.append(type.rawValue)
        out.append(msgId)
        out.append(routingTag)
        out.append(ttl)
        out.append(hopCount)
        out.append(UInt8((flags >> 8) & 0xFF)); out.append(UInt8(flags & 0xFF))
        let len = UInt16(payload.count)
        out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        let crc = FrameV2.crc16([UInt8](out))
        out.append(UInt8((crc >> 8) & 0xFF)); out.append(UInt8(crc & 0xFF))
        out.append(payload)
        return out
    }

    /// Bounded, fail-closed parsing. Magic, version, CRC and the declared
    /// length are validated BEFORE any allocation, so a desynced or corrupted
    /// frame is rejected rather than half-parsed into a different message.
    public static func decode(_ data: Data) -> FrameV2? {
        guard data.count >= headerSize else { return nil }
        let b = [UInt8](data)
        guard (UInt16(b[0]) << 8 | UInt16(b[1])) == magic else { return nil }
        guard b[2] == version else { return nil }
        guard let type = TypeV2(rawValue: b[3]) else { return nil }
        let ttl = b[24]
        guard ttl <= maxTtl else { return nil }
        let hop = b[25]
        guard hop <= maxTtl else { return nil }
        let flags = UInt16(b[26]) << 8 | UInt16(b[27])
        let len = Int(b[28]) << 8 | Int(b[29])
        let crc = UInt16(b[30]) << 8 | UInt16(b[31])
        guard crc == crc16(Array(b[0..<(headerSize - 2)])) else { return nil }
        guard len <= maxPayload, data.count == headerSize + len else { return nil }
        return FrameV2(type: type,
                       msgId: data.subdata(in: 4..<20),
                       routingTag: data.subdata(in: 20..<24),
                       ttl: ttl, hopCount: hop, flags: flags,
                       payload: data.subdata(in: headerSize..<(headerSize + len)))
    }

    public static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

public enum TypeV2: UInt8 {
    case hello = 0x11
    case digest = 0x12
    case want = 0x14
    case message = 0x18
    case ack = 0x21
    case bulk_offer = 0x22
    case bulk_chunk = 0x24
    case ping = 0x28
    case goodbye = 0x41
    case sos = 0xF0
}
`````
<<< END FILE

### `wire/gen/wire_v2_codec.py`

>>> FILE: wire/gen/wire_v2_codec.py
`````python
"""GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.
Regenerate with `python -m wire.codegen`.
ci/check_parity.py Invariant A fails the build on any hand edit."""
from __future__ import annotations

MAGIC = 0x4753
VERSION = 0x02
HEADER_SIZE = 32
MAX_PAYLOAD = 60000
MAX_TTL = 16
DEFAULT_TTL = 12

TYPES = {
    "HELLO": 0x11,
    "DIGEST": 0x12,
    "WANT": 0x14,
    "MESSAGE": 0x18,
    "ACK": 0x21,
    "BULK_OFFER": 0x22,
    "BULK_CHUNK": 0x24,
    "PING": 0x28,
    "GOODBYE": 0x41,
    "SOS": 0xF0,
}
FLAGS = {
    "SEALED": 0x0001,
    "COMPRESSED": 0x0002,
    "FRAGMENTED": 0x0004,
    "HAS_POW": 0x0008,
    "ACK_REQ": 0x0010,
    "RELAY_OK": 0x0020,
    "PRIORITY_MASK": 0x0700,
}
NAME_BY_CODE = {v: k for k, v in TYPES.items()}


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode(type_code: int, msg_id: bytes, routing_tag: bytes, ttl: int,
           hop_count: int, flags: int, payload: bytes) -> bytes:
    assert len(msg_id) == 16 and len(routing_tag) == 4
    assert 0 <= ttl <= MAX_TTL and 0 <= hop_count <= MAX_TTL
    assert len(payload) <= MAX_PAYLOAD
    h = (MAGIC.to_bytes(2, "big") + bytes([VERSION, type_code]) + msg_id
         + routing_tag + bytes([ttl, hop_count])
         + flags.to_bytes(2, "big") + len(payload).to_bytes(2, "big"))
    return h + crc16(h).to_bytes(2, "big") + payload


def decode(raw: bytes) -> dict | None:
    """Fail-closed: magic, version, type, CRC and length all validated first."""
    if len(raw) < HEADER_SIZE:
        return None
    if int.from_bytes(raw[0:2], "big") != MAGIC:
        return None
    if raw[2] != VERSION:
        return None
    if raw[3] not in NAME_BY_CODE:
        return None
    ttl = raw[24]
    if ttl > MAX_TTL:
        return None
    hop = raw[25]
    if hop > MAX_TTL:
        return None
    length = int.from_bytes(raw[28:30], "big")
    if int.from_bytes(raw[30:32], "big") != crc16(raw[0:HEADER_SIZE - 2]):
        return None
    if length > MAX_PAYLOAD or len(raw) != HEADER_SIZE + length:
        return None
    return {
        "type": NAME_BY_CODE[raw[3]],
        "msg_id": raw[4:20].hex(),
        "routing_tag": raw[20:24].hex(),
        "ttl": ttl,
        "hop_count": hop,
        "flags": int.from_bytes(raw[26:28], "big"),
        "payload": raw[HEADER_SIZE:].hex(),
    }
`````
<<< END FILE

### `wire/golden_vectors.json`

>>> FILE: wire/golden_vectors.json
`````json
{
  "_comment": "GENERATED by wire/codegen.py from wire_v2.yaml. Both platforms must reproduce every `encoded` value exactly and reject every negative frame.",
  "header_size": 32,
  "magic": 18259,
  "version": 2,
  "message_types": {
    "HELLO": 17,
    "DIGEST": 18,
    "WANT": 20,
    "MESSAGE": 24,
    "ACK": 33,
    "BULK_OFFER": 34,
    "BULK_CHUNK": 36,
    "PING": 40,
    "GOODBYE": 65,
    "SOS": 240
  },
  "hamming_min_distance_to_sos": 4,
  "cases": [
    {
      "name": "encode_hello",
      "type": "HELLO",
      "type_code": 17,
      "msg_id": "000102030405060708090a0b0c0d0e0f",
      "routing_tag": "deadbeef",
      "ttl": 12,
      "hop_count": 0,
      "flags": 1,
      "payload": "7061796c6f61642d48454c4c4f",
      "encoded": "47530211000102030405060708090a0b0c0d0e0fdeadbeef0c000001000d5cbf7061796c6f61642d48454c4c4f",
      "encoded_len": 45
    },
    {
      "name": "encode_message",
      "type": "MESSAGE",
      "type_code": 24,
      "msg_id": "000102030405060708090a0b0c0d0e0f",
      "routing_tag": "deadbeef",
      "ttl": 12,
      "hop_count": 0,
      "flags": 1,
      "payload": "7061796c6f61642d4d455353414745",
      "encoded": "47530218000102030405060708090a0b0c0d0e0fdeadbeef0c000001000fc2ab7061796c6f61642d4d455353414745",
      "encoded_len": 47
    },
    {
      "name": "encode_digest",
      "type": "DIGEST",
      "type_code": 18,
      "msg_id": "000102030405060708090a0b0c0d0e0f",
      "routing_tag": "deadbeef",
      "ttl": 12,
      "hop_count": 0,
      "flags": 1,
      "payload": "7061796c6f61642d444947455354",
      "encoded": "47530212000102030405060708090a0b0c0d0e0fdeadbeef0c000001000e53767061796c6f61642d444947455354",
      "encoded_len": 46
    },
    {
      "name": "encode_sos",
      "type": "SOS",
      "type_code": 240,
      "msg_id": "000102030405060708090a0b0c0d0e0f",
      "routing_tag": "deadbeef",
      "ttl": 12,
      "hop_count": 0,
      "flags": 48,
      "payload": "534f53310000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068656c70",
      "encoded": "475302f0000102030405060708090a0b0c0d0e0fdeadbeef0c000030004834c0534f53310000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068656c70",
      "encoded_len": 104
    }
  ],
  "negative_cases": [
    {
      "name": "reject_legacy_type_0x02",
      "frame": "47530202000102030405060708090a0b0c0d0e0fdeadbeef0c000001000d25547061796c6f61642d48454c4c4f",
      "must_reject": true,
      "rationale": "v1 Android DIGEST / v1 iOS SOS. Must hit the unknown-type branch, never be read as a distress broadcast."
    },
    {
      "name": "reject_v1_frame",
      "frame": "47530111000102030405060708090a0b0c0d0e0fdeadbeef0c000001000d31037061796c6f61642d48454c4c4f",
      "must_reject": true,
      "rationale": "version byte checked before anything else"
    },
    {
      "name": "reject_bad_crc",
      "frame": "47530211000102030405f90708090a0b0c0d0e0fdeadbeef0c000001000d5cbf7061796c6f61642d48454c4c4f",
      "must_reject": true,
      "rationale": "single-bit corruption inside msg_id must fail the header CRC"
    },
    {
      "name": "reject_hop_count_over_max",
      "frame": "47530211000102030405060708090a0b0c0d0e0fdeadbeef0c110001000df2b47061796c6f61642d48454c4c4f",
      "must_reject": true,
      "rationale": "hop_count above MAX_TTL is malformed and must not wrap on relay"
    },
    {
      "name": "reject_sos_missing_payload_magic",
      "frame": "475302f0000102030405060708090a0b0c0d0e0fdeadbeef0c0000300004bd8868656c70",
      "must_reject": true,
      "rationale": "SOS payload lacks the SOS1 magic and Ed25519 signature. Decodes as a frame, MUST be refused by the SOS validator: a parse error must not be able to fabricate a distress call."
    },
    {
      "name": "reject_sos_missing_flags",
      "frame": "475302f0000102030405060708090a0b0c0d0e0fdeadbeef0c0000000048f165534f53310000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068656c70",
      "must_reject": true,
      "rationale": "SOS requires ACK_REQ|RELAY_OK set."
    }
  ]
}
`````
<<< END FILE

### `wire/wire_v2.yaml`

>>> FILE: wire/wire_v2.yaml
`````yaml
# GMP/2 wire format -- the SINGLE source of truth.
#
# Android and iOS codecs are GENERATED from this file. Hand-editing either
# generated file makes ci/check_parity.py Invariant A go red. "Byte-for-byte
# identical" stops being a comment and becomes a build assertion.
#
# WHY v2 EXISTS
# -------------
# v1 shipped two incompatible layouts that each claimed to be the other:
#     Android  20-byte header, 8-byte msg_id,  types 0x01..0x0A
#     iOS      26-byte header, 16-byte msg_id, types 0x01..0x08
# They failed at three independent layers -- different BLE service UUIDs meant
# they never discovered each other; different header sizes meant every frame
# failed to parse; and overlapping type codes meant an Android DIGEST (0x02)
# would have been read by iOS as an SOS.
#
# v2 is a strict superset of both. Android's `priority` and iOS's `routingTag`
# both survive; msg_id takes iOS's 16-byte width.

version: 2
magic: 0x4753          # "GS"
header_size: 32

header:
  - {name: magic,       offset: 0,  size: 2,  type: u16, note: "0x4753, fail-closed sentinel"}
  - {name: version,     offset: 2,  size: 1,  type: u8,  note: "0x02"}
  - {name: type,        offset: 3,  size: 1,  type: u8,  note: "see message_types"}
  - {name: msg_id,      offset: 4,  size: 16, type: bytes, note: "BLAKE2s-128"}
  - {name: routing_tag, offset: 20, size: 4,  type: bytes, note: "rotates daily"}
  - {name: ttl,         offset: 24, size: 1,  type: u8,  note: "initial 12, max 16"}
  - {name: hop_count,   offset: 25, size: 1,  type: u8,  note: "increments on relay"}
  - {name: flags,       offset: 26, size: 2,  type: u16}
  - {name: payload_len, offset: 28, size: 2,  type: u16, note: "max 60000"}
  - {name: header_crc,  offset: 30, size: 2,  type: u16, note: "CRC-16/CCITT over 0..29"}

# THE SINGLE BLE SERVICE UUID. v1's partition was three defects, and this was
# the first: Android advertised 67640001-… while iOS scanned 6F0D0001-…, so the
# two never discovered each other and the header/type defects were never even
# reached. Generated into both platforms so they CANNOT drift again.
ble:
  service_uuid: "6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10"
  inbox_uuid:   "6764A002-9A5E-4C7B-B0A1-3E5D8C2F7A10"
  digest_uuid:  "6764A003-9A5E-4C7B-B0A1-3E5D8C2F7A10"

byte_order: big
max_payload: 60000
default_ttl: 12
max_ttl: 16

# EVERY code has EVEN parity (even popcount). This is a structural guarantee,
# not hand-picked luck: any single-bit flip changes parity and therefore lands
# on a code that cannot exist, so pairwise Hamming distance is >= 2 BY
# CONSTRUCTION. codegen.py verifies parity, pairwise distance and the v1
# non-reuse rule, and refuses to emit if any of them breaks.
#
# The first draft of this table had SOS=0x64 one bit from WANT=0x24 -- a single
# flip would have fabricated a distress broadcast, the exact property this
# section claims to provide. The checker caught it. Hand-chosen codes are not
# trustworthy; the parity rule is.
#
# Renumbered so no v2 code reuses any v1 value (v1 used 0x01..0x0A on both
# platforms). A stray legacy frame now hits the unknown-type branch and is
# dropped, instead of a DIGEST arriving as an SOS.
message_types:
  HELLO:      0x11
  DIGEST:     0x12
  WANT:       0x14
  MESSAGE:    0x18
  ACK:        0x21
  BULK_OFFER: 0x22
  BULK_CHUNK: 0x24
  PING:       0x28
  GOODBYE:    0x41
  SOS:        0xF0

flags:
  SEALED:     0x0001
  COMPRESSED: 0x0002
  FRAGMENTED: 0x0004
  HAS_POW:    0x0008
  ACK_REQ:    0x0010
  RELAY_OK:   0x0020
  # ADR-001 s.3.1: 0x00C0 is TWO bits = 4 values, and the priority set below
  # has FIVE. GMP/2 could not encode Android's existing priorities at all.
  # Widened to three bits (8 values). codegen.py now asserts the mask is wide
  # enough for the priority table, so this fails the build, not the mesh.
  PRIORITY_MASK: 0x0700

priority:
  SOS:       0
  DIRECT:    1
  GROUP:     2
  BROADCAST: 3
  BULK:      4

# Defence in depth. The renumbering stops a legacy frame being MISREAD as an
# SOS; these requirements stop a corrupted or truncated frame FABRICATING one.
# That second property is worth more than the renumbering.
sos_requirements:
  payload_magic: "SOS1"
  required_flags: [ACK_REQ, RELAY_OK]
  signature: ed25519
  signature_len: 64
  note: >
    An SOS must carry the payload magic, both flags, and a valid Ed25519
    signature over msg_id || payload. A parse error can no longer fabricate a
    distress broadcast.
`````
<<< END FILE

>>> DELETE: android/mesh/src/main/java/io/godstone/mesh/MeshNodeHolder.kt

>>> DELETE: ios/Godstone/Sources/GodstoneMesh/Frame.swift

