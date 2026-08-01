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
