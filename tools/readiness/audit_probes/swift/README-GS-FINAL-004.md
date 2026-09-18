# GS-FINAL-004 — the discarded verified handle, RED BY DESIGN

`GsFinal004VerifiedHandleTests.swift.txt` holds the arms written during round 551. They are **red by design and do not
belong in a lane expected green** (Swift runs every test source in a module, so a red arm reddens the lane).

## What is measured, and what was measured wrong first

| arm | subject |
|---|---|
| `theStoreRunsOnTheFactoriesVerifiedConnection` | **the core requirement, positively asserted — RED by design** |
| `aHandleThatIsNotEncryptedAtRestIsRefused` | a non-encrypted verdict must refuse composition (**passes today** — the one part that already works) |
| `theArchiveOnlyGraphConstructsNoPrivateStore` | an archive-only graph must contain no private store (**FAILS today**) |

## The defect, at its root cause

The audit's words: *"The factory yields descriptive metadata rather than an owned operational connection/capability,
and composition performs a second independent open."* And the sentence that scopes every repair:

> **"Acquiring SQLCipher cannot repair a discarded handle."**

Measured at source: `EncryptedStoreHandle` carries `path`, `kind`, `encryptedAtRest`, `cipherVersion` — **and no
connection at all**. There is nothing for composition to hand to a store, so `SqliteMessageStore(url:)` runs its own,
independent, **unkeyed** `sqlite3_open_v2` on the same path. The verdict is computed and thrown away.

## The arms, and which way each falls

| arm | today |
|---|---|
| `theArchiveOnlyGraphConstructsNoPrivateStore` | **PASSES** — the split is landed |
| `aHandleThatIsNotEncryptedAtRestIsRefused` | **PASSES** — the guard already worked |
| `theStoreRunsOnTheFactoriesVerifiedConnection` | **FAILS — the core defect, and it cannot pass yet** |

## Three false arms I wrote and corrected

1. **The first draft asserted only that the engine was asked for a keyed open** — which *passes on the unrepaired tree*,
   because the factory genuinely does ask. It measured the one part that already worked.
2. **The second draft asserted `XCTAssertFalse(storeWasBuiltFromHandle)`** — which asserts **the defect as the
   requirement**: green on the broken tree, and it would *fail* the moment someone fixed the finding. An arm that
   demands the bug is worse than no arm.
3. **THE VACUOUS PAIR.** After (1) and (2) were deleted, an arm remained asserting the fake's own tallies
   (`handlesReturned > 0`, opened == returned). **Those pass on the unrepaired tree** — the same false-proof species as
   `wipeAuthorityForTest`'s literal tuple, re-entering through the test file. It is replaced by
   `theStoreRunsOnTheFactoriesVerifiedConnection`, which asserts the REAL requirement (the store's connection IS the
   factory's, by identity) and therefore STAYS RED until the handle carries a connection.
4. **A `messageStoreWasBuiltFromVerifiedHandle` production flag was considered and REJECTED**: that is GS-FINAL-011 over
   again — a proof hook that asserts an architecture instead of observing the runtime. The remaining measurements are
   the **engine's own record** of what it handed back.

## The external boundary, stated precisely

**The connection-ownership refactor is INTERNAL and host-verifiable.** `EncryptedStoreFactory` documents "a
deterministic fake in the court" as its engine seam, and `RecordingEngine` here is exactly that — so parts 1 and 2
below can be implemented and proven on the host today. **Only the ON-DEVICE at-rest cipher proof is the external
acquisition** (the pinned SQLCipher engine, the `NATIVE_MODELS` gate). Do not cite the native artifact as the reason
this finding is open; the reason is that the handle type carries no connection.

## Why the full remediation is not closeable in one round

The remediation the audit prescribes has three parts, and the third is architectural:

1. `EncryptedStoreFactory` must return an **owned verified connection** with explicit close ownership.
2. `SqliteMessageStore` must **accept** that connection instead of reopening by path.
3. **"Split the archive-only graph from private-store construction."**

Part 3 is the load-bearing one, and it is measured here: `MeshRuntime.create` **delegates to**
`createArchiveOnlyHostComposition`, so the "archive-only" name is wrong and the private-store construction is **shared**
by both roads. Separating them restructures the composition root that **25+ courts** and the shipping target build
through.

## Also owed and NOT claimed

- **`acquisition never closes a gate`** applies to the reverse too: the pinned native SQLCipher engine remains an
  external artifact (the `NATIVE_MODELS` gate). The *code and harness* need not wait for it — parts 1 and 2 are
  writable today — but no arm here may claim an at-rest or cryptographic-erasure result on the host.
- The composition already checks the factory verdict, and that guard **works**. What it does not do is *use* the handle
  whose verdict it checked.

## Run recipe

```sh
cd /Users/oculus/Projects/GODSTONE
cp tools/readiness/audit_probes/swift/GsFinal004VerifiedHandleTests.swift.txt \
   ios/Godstone/Tests/GodstoneMeshTests/GsFinal004VerifiedHandleTests.swift
python3 scripts/sync_ios_foundation_package.py
swift test --package-path ios/Packages/GodstoneFoundation --filter 'GsFinal004'
# expected: the archive-only arm FAILS; the encrypted-at-rest arm passes
rm ios/Godstone/Tests/GodstoneMeshTests/GsFinal004VerifiedHandleTests.swift
python3 scripts/sync_ios_foundation_package.py
```
