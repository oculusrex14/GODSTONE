# GodstoneFoundation — GENERATED package (do not edit)

This SwiftPM package is a **generated artifact**. It exists so the pure-logic
Core + Mesh closure can be built and `swift test`-ed on a Mac host / CI
**without** compiling the iOS-only `GodstoneLLMBridge` target, which requires
a pinned `third_party/llama.cpp` checkout (see `third_party/README.md`).

## Authoritative sources

All sources and tests under `Sources/` and `Tests/` here are **copies** of the
canonical trees:

| Generated copy                          | Authoritative source                              |
|-----------------------------------------|---------------------------------------------------|
| `Sources/GodstoneCore`                  | `ios/Godstone/Sources/GodstoneCore`                |
| `Sources/GodstoneMesh`                  | `ios/Godstone/Sources/GodstoneMesh`                |
| `Tests/GodstoneCoreTests`               | `ios/Godstone/Tests/GodstoneCoreTests`            |
| `Tests/GodstoneMeshTests`               | `ios/Godstone/Tests/GodstoneMeshTests`            |

`ios/Godstone` is the **single source of truth**. There must never be two
independently editable copies of Core or Mesh.

## Do not edit the copies

Editing a file under `Sources/` or `Tests/` here has no lasting effect: the next
run of the sync script (`scripts/sync_ios_foundation_package.py`) deletes the
destination tree (`rmtree`) and re-copies from canonical, silently discarding
your edit. Make every change in `ios/Godstone` and re-run the sync.

## Regenerating

```
python scripts/sync_ios_foundation_package.py        # regenerate (destructive)
python scripts/sync_ios_foundation_package.py --check  # fail if committed tree drifted
```

## CI drift gate

`production-evidence.yml` runs `sync_ios_foundation_package.py --check` before
`swift test --package-path ios/Packages/GodstoneFoundation`. The `--check` mode
fails the build if the committed generated tree is not byte-identical to what
the script would regenerate from canonical. This catches both:

* a direct edit to the generated copy (silently lost on next sync), and
* a canonical Core/Mesh edit that was not followed by a re-sync + commit.

`SOURCE_MANIFEST.json` (SHA-256 of each generated path + bytes, including
`Package.swift`) is the material the `--check` mode compares against.

## Package.swift is hand-maintained

`Package.swift` here is **not** a copy — it is a deliberately trimmed subset of
`ios/Godstone/Package.swift` that omits the `GodstoneLLMBridge` and `GodstoneLLM`
targets (the whole point of the split). It is edited by hand when the canonical
package's target structure changes; its hash is recorded in
`SOURCE_MANIFEST.json` so `--check` detects uncommitted edits to it as well.

## What consumes this package

Only the CI `swift test --package-path ios/Packages/GodstoneFoundation` step.
The shipping app (assembled by XcodeGen from `ios/project.yml`) consumes the
**canonical** `ios/Godstone` package, not this one.