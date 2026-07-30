# GODSTONE

**Offline survival + encrypted mesh communications.** A one-time-purchase mobile
app that keeps a human being alive when the grid, the towers and the internet are
gone. Inspired by *Dr. Stone*: rebuild capability from first principles, offline,
on a phone.

Targets: **Android** (Kotlin / Jetpack Compose) and **iOS** (Swift / SwiftUI) —
fully native, twice.

---

## Three pillars

| Pillar | What it is |
|--------|------------|
| **The Archive** | A curated, indexed corpus of survival knowledge. SQLite + FTS5 + a quantised vector index. 100% on device, zero network calls, usable in airplane mode forever. |
| **The Oracle** | A tiny dense language model (Qwen3 0.6B–4B class) running locally through llama.cpp. Retrieval-Augmented Generation: it answers **grounded**, citing the source manual, so a hallucinated dosage can never kill someone. |
| **The Mesh** | Phones talk directly via Bluetooth + Wi-Fi. Encrypted, store-and-forward, multi-hop. No servers, no SIM, no towers. Every install is another relay node. |

## Non-negotiable engineering constraints

- **C1 — No network.** Shipping apps have no internet capability on the critical path.
- **C2 — No telemetry, no analytics, no accounts.** Ever.
- **C3 — Grounded answers only.** Every Oracle response cites Archive documents; below-threshold retrieval says "not in the archive" rather than inventing.
- **C4 — Battery is life.** Mesh duty-cycles aggressively; target < 3%/hour listening.
- **C5 — Degrade, never fail.** Every subsystem has a defined degraded mode; the Archive stays readable even when the model cannot load.
- **C6 — Crypto is composed, not invented.** Noise Protocol Framework over X25519 / Ed25519 / ChaCha20-Poly1305 / BLAKE2s.
- **C7 — Accessible under stress.** High contrast, oversized targets, red night mode, full offline TTS.

## Workbook-as-repository

`Godstone.xlsx` is the canonical source. Each tab is a project folder; column A
holds the verbatim source between `>>> FILE: <path>` and `<<< END FILE` markers
(column B is human commentary only). Re-extract the whole tree deterministically:

```bash
python3 -m pip install openpyxl
python3 scripts/extract_workbook.py
```

## Repository layout

```
docs/                 mesh protocol, threat model, packaging/tier/store docs
android/              :app, :mesh, :llm  (Gradle modules, Kotlin/Compose + JNI)
ios/                  Godstone app + GodstoneMesh + GodstoneLLM (SwiftPM)
content/              db schema, ingestion pipeline, seed corpus, eval
scripts/              model fetch/quantise, tier checker, workbook extractor
meshsim/              discrete mesh simulator (200-node city-blackout, etc.)
.github/workflows/    CI
```

## Build order

1. **Extract** every file from the workbook (above).
2. **Content pipeline** (produces the `.db` artifacts both apps embed):
   ```bash
   cd content && python -m pip install -r requirements.txt
   python -m ingest.build_archive --tier light  --out dist/archive_light.db
   python -m ingest.build_archive --tier medium --out dist/archive_medium.db
   python -m ingest.build_archive --tier large  --out dist/archive_large.db
   ```
3. **Models**: `./scripts/fetch_models.sh && ./scripts/quantise.sh`
4. **Android**: `cd android && ./gradlew :app:assembleLightRelease`
5. **iOS**: `cd ios && xcodegen generate && xcodebuild -scheme Godstone-Light -configuration Release`
6. **Tests**: `./gradlew test`, `xcodebuild test -scheme GodstoneTests`,
   `python -m meshsim.run --nodes 200 --scenario city_blackout`

## Product tiers

| Tier | Install | Model | Archive |
|------|---------|-------|---------|
| LIGHT  | ~1.2 GB | Qwen3-0.6B Q4_K_M | text + diagrams, 8 core domains |
| MEDIUM | ~4.5 GB | Qwen3-1.7B Q4_K_M | + voice, all 20 domains, 480p video |
| LARGE  | ~14 GB  | Qwen3-4B   Q5_K_M | + 1080p, regional packs, deep chemistry/metallurgy |

The mesh is **never** tier-limited — a LIGHT user relays for a LARGE user at full
capability. Communication is a safety function.

---

*Derived from the `00_README` and `01_ARCHITECTURE` tabs of `Godstone.xlsx`. See
those tabs for the full manifest, data-flow walkthroughs, and threat model.*