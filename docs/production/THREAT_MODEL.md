# Threat model

## Protected assets

Reviewed Archive content, release manifests, model/native artifacts, device identity keys, contact trust, encrypted message payloads, recipient acknowledgments, local search/history, and wipe state.

## Principal adversaries

- A malicious or compromised content producer attempting to introduce unreviewed, expired, incorrectly licensed, or warning-stripped material.
- A local attacker modifying Archive/model files or restoring stale/cross-tier assets.
- A model producing fabricated citations, quantities, units, qualifiers, contraindications, or instructions.
- A network/relay attacker replaying, mutating, forging, or misrouting Mesh records and acknowledgments.
- A device-seizure attacker reading databases, keys, caches, diagnostics, or interrupted wipe state.
- A supply-chain attacker changing actions, dependencies, native code, models, generated sources, or build tools.

## Enforced controls in this overlay

- No generated answer is visible before complete validation.
- Exact citation and quantity/unit/qualifier matching; no bare-number fallback.
- Production content and assets fail closed without immutable evidence and hashes.
- Archive manifest is Ed25519 signed and binds tier, schema, file hash, counts, build input hashes, and metadata.
- Production apps are Archive-only and have no Mesh dependency edge or radio/SOS permissions.
- CI actions are pinned to immutable commits; mutable references and release bypasses are scanned.

## Unclosed threats

Identity continuity, trust introduction/reset, rotation/revocation, independent Noise conformance, canonical GMP/2.1 transport, durable authenticated delivery, low-storage behavior, full cryptographic erasure, native/model reproducibility, and physical-device radio/battery behavior remain unproven. Consequently Mesh/SOS/Oracle must remain disabled in production.
