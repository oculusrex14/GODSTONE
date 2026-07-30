# Godstone tiers

Godstone ships as three builds from one codebase. The tier decides how much
knowledge and how large a model the device carries. It never decides what the
app is allowed to do.

**The mesh is never tier-limited.** A phone running LIGHT relays, routes and
decrypts exactly as a phone running LARGE does. Restricting emergency
communication by install size would be indefensible, and a mesh whose nodes
have different capabilities is a mesh with silent dead spots.

## The three tiers

| | LIGHT | MEDIUM | LARGE |
|---|---|---|---|
| Install size | ~1.2 GB | ~4.5 GB | ~14 GB |
| Model | Qwen3-0.6B | Qwen3-1.7B | Qwen3-4B |
| Quantisation | Q4_K_M | Q4_K_M | Q5_K_M |
| Model file | ~420 MB | ~1.1 GB | ~2.9 GB |
| Context window | 2048 tokens | 4096 tokens | 8192 tokens |
| Embedding dims | 384 | 384 | 768 |
| Chunks in Archive | ~40k | ~150k | ~400k |
| Domains | 8 core | 20 full | 20 full + regional |
| Media | diagrams | + voice, 480p video | + 1080p, regional |
| Minimum storage | 3 GB | 8 GB | 22 GB |
| Minimum RAM | 3 GB | 6 GB | 8 GB |

These numbers are duplicated in three places that must agree:

- `content/ingest/build_archive.py` - the `TIERS` dict
- `android/app/build.gradle.kts` - the product flavours (tab 03)
- `ios/Godstone/Sources/GodstoneCore/Tier.swift` - the `Tier` enum (tab 06)

If you change a tier, change all three or the app will look for a model file
that was never built.

## The core 8 domains

Present in every tier, including LIGHT. These are what matter in the first 72
hours:

1. Water
2. Medical - trauma
3. Shelter and warmth
4. Fire
5. Food procurement
6. Navigation
7. Signalling and rescue
8. Immediate hazard response

## The full 20

MEDIUM and LARGE add: CBRN and fallout, siege and urban conflict, flood,
drought, earthquake, wildfire, pandemic and sanitation, food preservation,
toolmaking and repair, practical chemistry, metallurgy, agriculture, power
generation, and radio and electronics.

LARGE additionally carries regional supplements - temperate maritime,
continental cold, arid subtropical, humid tropical and montane - because
climate, endemic species and local emergency conventions vary too much to
generalise safely.

## Choosing a tier

**LIGHT** is the default recommendation. It fits on a phone somebody already
owns without deleting their photographs, which is the difference between an app
that is installed before the emergency and an app that is not. An uninstalled
archive has a survival value of zero.

**MEDIUM** suits a phone with room to spare and is the best balance of answer
quality against size.

**LARGE** is for a dedicated device - an old phone or tablet kept charged in a
drawer, a vehicle, a boat, a shelter. It is not a good choice for a daily
driver.

## Degradation within a tier

Tier decides what is installed. The device decides what actually runs, moment
to moment (C5):

- Thermally stressed, in low power mode, or under 15 percent battery and not
  charging: Metal and GPU offload are refused, inference runs on CPU.
- Memory warning or backgrounded: the model is evicted immediately. The
  Archive stays readable and searchable without it.
- Model missing or corrupt: the app falls back to browse and lexical search,
  and says so.

At no point does the app refuse to open. It degrades to a searchable offline
library, then to a mesh radio, and each of those alone is worth carrying.

## Upgrading

A tier is chosen at install. Moving from LIGHT to LARGE means installing the
LARGE build; mesh identity and message history are preserved because they live
outside the tier-specific storage.

LARGE ships its weights as a post-install download pack rather than inside the
bundle, because store limits make a 14 GB binary impossible. The pack lands in
Application Support and is verified by hash before first use.
