# The independent audit's source references, verbatim

The audit at `godstone-audit/` cites its evidence as `S01`–`S23` and `E01`–`E05`. Those tokens are **resolvable
only inside the audit report**: source references are pinned GitHub blob reads of the candidate, and external
references are official documentation. A reader of the code sees `S03` in a finding and has nowhere to go.

This file is that way-point. It maps every token to a path **relative to this checkout**, so a finding's citation
can be turned into a file in one step. It adds no claim of its own.

| token | what it is | path in this checkout |
|---|---|---|
| `S01`, `S02` | candidate repository identity and branch state | — (audit provenance; no in-repo file) |
| `S03` | iOS Mesh runtime composition root | `ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift` |
| `S04` | Android DI composition root | `android/mesh/src/main/java/io/godstone/mesh/di/MeshModule.kt` |
| `S05` | iOS crash-resumable wipe coordinator | `ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift` |
| `S06` | Android crash-resumable wipe coordinator | `android/mesh/src/main/java/io/godstone/mesh/identity/CrashResumableWipe.kt` |
| `S07` | iOS encrypted-store factory | `ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift` |
| `S08` | iOS message store | `ios/Godstone/Sources/GodstoneMesh/MessageStore.swift` |
| `S09` | Android Mesh node | `android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt` |
| `S10`–`S13` | iOS/Android archive reading surfaces | `ios/Godstone/Sources/App/ArchiveView.swift`, `ios/Godstone/Sources/GodstoneCore/ArchiveSceneModel.swift`, `android/app/src/main/java/io/godstone/app/ui/browse/BrowseScreen.kt`, `android/app/src/main/java/io/godstone/app/ui/browse/BrowseViewModel.kt` |
| `S18` | **the evidence-digest control — the ONLY source the audit byte-recomputed and executed** | `ci/check_evidence_digests.py` (audited blob `f87c0694877b6dd42c4638f2962d11dbe8b4c1a2`) |
| `S21` | protected-data projection | `android/app/src/main/java/io/godstone/app/mesh/MeshContracts.kt`, `android/app/src/main/java/io/godstone/app/mesh/MeshViewModel.kt` |
| `S23` | node shutdown latch | `ios/Godstone/Sources/GodstoneMesh/MeshNode.swift` |
| `E01`–`E05` | official external documentation | — (not in this repository) |

## What this table does not say

- The tokens `S10`–`S13` and `S14`–`S17`, `S19`, `S20`, `S22` are **not individually enumerated in the audit's own
  `SOURCE_INDEX.md`** beyond the groups above; where a finding cites a token this table renders as a group, read the
  group's files, not a single one.
- **The audit read the candidate through GitHub blob reads, not a local checkout**, and its own report states this.
  A path here proves the audit HAD a citation, not that the audit verified the file's behaviour.
- The authoritative source index is `godstone-audit/SOURCE_INDEX.md` and `godstone-audit/data/source_index.json`.
  **If those disagree with this table, they win.**
