# GS-FINAL-003 — the iOS startup permit, RED BY DESIGN

These arms are **red by design and do not belong in a lane expected green**. Gradle and Swift both run every test
source in a module, so a red arm inside one reddens that lane — and the convergence rules require the lanes green.
That is why this file is `.txt`.

## What the arms measure

`GsFinal003StartupPermitTests.swift.txt` holds the three arms written during round 549:

| arm | what it demands |
|---|---|
| `aPendingWipeThatCannotResolveRefusesTheStartup` | with the journal at `runtimeDrained` (a wipe the deferred create-time seams cannot advance), construction must **throw** and must **not** create the private store |
| `aCleanFirstLaunchStillOpensExactlyOnce` | an absent journal is a **validated no-pending-wipe state** — the gate must not refuse an ordinary start |
| `aCompletedWipeIsReadyRatherThanBlocked` | a journal at `newIdentity` is **ready**, not blocked |

Run against the current tree, the first arm FAILS and the other two PASS. That is the measurement: **the permit is
specified and its decision function is written; the call site cannot consume it yet.**

## Why it cannot be landed, and what has to exist first

1. The only path that can finish a pending wipe is `MeshRuntime.continuePendingWipeIfNeeded()`.
2. **That is a method on a CONSTRUCTED runtime.**
3. It drains through `meshNode.ble`; `MeshNode` is built **from the very stores** the permit would refuse to open.
4. So refusing at `create` means: no runtime → no transport → no drain → **the wipe can never complete.**

A gate that makes its own remedy unreachable is worse than the defect it closes. The first version of this repair
**deadlocked the composition exactly that way**, and the failure was measured, not reasoned: `testSR02` threw
`startupBlockedByPendingWipe("a wipe is outstanding at requested and the startup could not resolve it")` while being
the very arm that asserts a runtime comes back.

## The prerequisite, named

iOS needs a **recovery entry point that drives the wipe ladder with a LIVE transport without constructing the private
store graph** — i.e. a composition whose transport seam exists before, and independently of, the store graph. The
Android isle does not have this problem because its wipe authority (`MeshPanicWipe`) is built from the DI graph's own
`MeshNode`, and its barrier's permit gates providers that are downstream of the node, not upstream of it.

Until that entry point exists, **GS-FINAL-003's iOS half is OPEN** and is recorded as such in
`docs/remediation/REMEDIATION_STATE.json`. The `StartupPermit` type and its `decide` function — the typed decision the
audit asked for, covering all four of its cases — are preserved inside this probe rather than deleted, because they are
the part that will be adopted.

## The run recipe

Copy the arms into `ios/Godstone/Tests/GodstoneMeshTests/`, regenerate the mirror, run, then **remove them again**:

```sh
cd /Users/oculus/Projects/GODSTONE
cp tools/readiness/audit_probes/swift/GsFinal003StartupPermitTests.swift.txt \
   ios/Godstone/Tests/GodstoneMeshTests/GsFinal003StartupPermitTests.swift
python3 scripts/sync_ios_foundation_package.py
swift test --package-path ios/Packages/GodstoneFoundation --filter 'testGSFINAL003'
# expected: 1 failure (the refusal arm), 2 passes (the two positive controls)
rm ios/Godstone/Tests/GodstoneMeshTests/GsFinal003StartupPermitTests.swift
python3 scripts/sync_ios_foundation_package.py
```
