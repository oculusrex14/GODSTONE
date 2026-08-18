# ADR-004 — Durable message store, retention and panic wipe

**STATUS: OPEN.**

## Current state

Android opens SQLCipher through the current `net.zetetic.database.sqlcipher`
API and stores its database key behind an Android Keystore-backed preference.
That closes the V3 plaintext/import defect, but does not finish durability.

iOS had no durable DTN store. Its router queue and dedup set were in memory, so
termination, jetsam or reboot lost carried traffic. The radio feature remains
disabled; V4 does not present this queue as durable. Phase G gives iOS the same
durable hold Android gained in Phase E (see the Phase G section below).

### Stage 3 Phase E — Android store, repo-owned evidence (NOT closed)

The Android store (`SqliteMessageStore` in `:mesh`) now has repo-owned
executable evidence for the repo-controlled durability invariants, gained
without a device and without putting the store on a shipping path:

- The store logic runs behind a `StoreDb` seam with two real engines: the
  production `SqlcipherStoreDb` (SQLCipher + Keystore-held key) and a test-only
  `JdbcStoreDb` (real on-disk SQLite via sqlite-jdbc). The SQL — schema, `INSERT
  OR IGNORE` dedup, window-function eviction, `SUM(LENGTH(payload))` byte
  accounting, priority `ORDER BY` — is shared via `StoreSchema`, so the
  invariants proven host-side are the invariants production enforces
  (SQLCipher is SQLite plus page encryption; the SQL semantics are identical).
- Bounded capacity is **precise byte accounting**, not the approximate row count
  of the prior form: the smallest oldest (non-SOS-first) prefix whose cumulative
  byte cost meets the overshoot is deleted, so the store always returns to or
  under the cap. SOS is evicted **last** — only after every non-SOS row is gone —
  and **all-SOS flooding stays inside the configured hard cap** (criterion 4) as
  a bounded FIFO that keeps the newest SOS.
- The SQLCipher engine is pinned structurally (`StoreEngineTest` reflects that
  the helper is `net.zetetic.database.sqlcipher.SQLiteOpenHelper`, not
  `android.database.sqlite`), so the A-06 plaintext-engine regression cannot
  revert silently.

Criterion coverage after Phase E (repo-controlled subset only):

1. Persist + read-back across a reopened on-disk store is tested (round-trip).
   A true reboot/jetsam survival proof on a device is still pending.
2. Carrier partition mobility needs the epidemic router + link layer (disabled);
   the store holds frames but this criterion is not yet met.
3. No installed base exists (GMP/1 never shipped), so `onUpgrade` drop+recreate
   is correct, not an unsafe migration; there is no prior shipped schema to
   migrate from. The v2 schema is centralised in `StoreSchema` and exercised.
4. **Met at the store layer**: all-SOS flooding stays inside the cap (tested).
5. `panicWipe` deletes the store file + key prefs atomically; the **coordinated
   resumable** wipe across store/identity/keys is Phase F (repo-tested, see the
   Phase F section below; on-device + shipping-path pending).
6. Anti-entropy digest from the held set is built from `allHeldMsgIds`; Android
   side is testable. iOS parity is Phase G (repo-tested; see the Phase G section
   below; on-device + shipping-path pending).

**Not closed.** The store is in the non-shipping `:mesh` module (LIGHT has no
`:mesh` dependency edge; `check_shipping_path.py` PASS), at-rest encryption is
verified on device only (the SQLCipher native core + Keystore are not exercised
host-side), authenticated-ACK deletion (criterion 2) depends on the inbound ACK
path the link layer gates closed, and iOS has no durable store yet (Phase G).

### Stage 3 Phase F — coordinated resumable panic wipe, repo-owned evidence (NOT closed)

The coordinated, crash-safe wipe across store + identity + the key material that
protects them (`PanicWipe` in `:mesh` on Android, `PanicWipe` in `GodstoneMesh`
on iOS) now has repo-owned executable evidence for the coordination, ordering
and resumability invariants, without a device and without putting the wipe on a
shipping path:

- It is a small persisted state machine: `IDLE → REQUESTED → KEY_ERASED →
  ARTIFACTS_DELETED → NEW_IDENTITY → IDLE`. The state is written to a durable
  `WipeJournal` AFTER each step completes, and every step is idempotent, so a
  crash-then-resume re-runs at most the one interrupted step and then continues
  forward. `resumeIfPending()` on the next launch finishes any interrupted wipe.
- **Crypto-erasure-first**: `eraseKeys()` destroys the KEK before any file is
  deleted. On Android that is the AndroidKeystore master key
  (`_androidx_security_master_key_`) that both the identity prefs and the store
  key prefs are encrypted under, so deleting it renders every
  EncryptedSharedPreferences ciphertext undecryptable even if its file still sits
  on disk. On iOS the private keys ARE the secret (no separate KEK), so
  `MeshIdentity.deleteFromKeychain()` deleting both Keychain items is both key
  destruction and artifact deletion in one step. After `KEY_ERASED`, prior data
  is unrecoverable regardless of whether the later cleanup steps ever run.
- `deleteArtifacts()` reuses the existing, tested store + identity panic-wipe
  methods on Android (`SqliteMessageStore.panicWipe` + `Identity.panicWipe`);
  on iOS it is a reserved hook for the Phase G durable store (a no-op today, but
  the state machine already runs it so Phase G only registers a store-wipe
  there). `regenerateIdentity()` builds a fresh identity on both platforms.

The machine itself is pure (no Context / no Keychain) with the platform glue
injected, so it is host-testable. `PanicWipeTest` (Android, 7 tests) and
`PanicWipeTests` (iOS, 7 tests) drive it with fakes that simulate a crash before
each step and assert: a no-crash wipe runs every step once in the
crypto-erasure-first order; a crash before any step leaves the journal at the
last COMPLETED step and resumes to full completion; a destroying step is never
double-run nor skipped; `resumeIfPending` is a no-op when idle and completes a
pending wipe. The production glue (Keystore entry delete, Keychain `SecItemDelete`,
file deletion) is thin and is an on-device verification, not host-testable.

Criterion coverage after Phase F:

5. **Coordinated resumable wipe is repo-tested** (state machine + crypto-erasure
   ordering + crash-resume on both platforms). On-device Keystore/Keychain
   actual deletion + shipping-path integration remain pending. NOT closed.

**Not closed.** The wipe is non-shipping (`:mesh` on Android, test-only
`GodstoneMesh` on iOS — neither is on the LIGHT shipping path), the actual
Keystore master-key deletion / Keychain item deletion is verified on device
only, and the iOS durable-store artifacts that `deleteArtifacts()` will
coordinate are Phase G. A-04's "coordinated wipe" half advances to
NONSHIPPING_TESTED; its "iOS durable store" half remains open until Phase G.

### Stage 3 Phase G — iOS durable DTN store, repo-owned evidence (NOT closed)

The iOS router queue and dedup set were in memory (see "Current state"). Phase G
gives iOS the same durable hold Android gained in Phase E, so a termination,
jetsam or reboot no longer loses carried traffic and the anti-entropy digest is
built from the held set, not the rolling dedup window.

Implementation (mirrors the Android Phase E store so the two are query-compatible;
all repo-owned evidence below runs in CI on a real on-disk sqlite3 file):

- A `MessageStore` protocol in `GodstoneMesh` with the same surface as the
  Android interface: persist, `allHeldOrderedByPriority`, `allHeldMsgIds`,
  `forEachHeldOrderedByPriority`, `forEachHeldMsgId`, `heldBytes`, `panicWipe`.
- `SqliteMessageStore` backed by the system `sqlite3` C API (the same library
  `GodstoneCore/ArchiveRepository` already links — `import SQLite3`, no extra
  dependency, auto-linked on Apple platforms). The schema, `INSERT OR IGNORE`
  dedup, window-function eviction, `SUM(LENGTH(payload))` byte accounting and
  priority `ORDER BY` are byte-identical to Android `StoreSchema` (same table
  `held_frames`, same columns, `ROW_OVERHEAD = 64`, same `evictPrefixSql`,
  `PRIORITY_ORDER`). A hand-written `Priority` twin derives the `priority`
  column from the flags bits 8..10 exactly as Android `Priority.fromFlags`
  (SOS 0 / DIRECT 1 / GROUP 2 / BROADCAST 3 / BULK 4, fail-safe to DIRECT).
- **At-rest encryption** is iOS Data Protection, not SQLCipher: the DB file is
  created with `FileProtectionType.complete` (encrypted at rest with a
  device-passcode-derived key, unreadable when the device is locked). On the
  macOS host this attribute is accepted but not enforced, so the SQL invariants
  run in CI while the encryption is device-verified — the SAME split as
  Android's SQLCipher (page encryption not exercised host-side). Because iOS
  uses the real `sqlite3` for both production and tests (no SQLCipher/sqlite-jdbc
  seam as on Android), the production engine itself executes in CI. The
  `.complete` default is pinned structurally (`SqliteMessageStoreTests.
  testFileProtectionDefaultIsComplete`), so a regression to a weaker class is a
  test failure, not a silent weakening.
- No installed base on iOS either (GMP/1 never shipped) → `onUpgrade`
  drop+recreate, same as Android; no migration code by design.
- **Anti-entropy digest (criterion 6)**: `Router.bloomDigest()` builds from
  `store.allHeldMsgIds()` when a store is attached (was: the dedup window, which
  describes recently-seen ids, not held frames). `BloomDigest` itself is already
  byte-identical cross-platform (Phase C KAT), so the two platforms now build the
  same digest from the same held set.
- **Panic-wipe integration (Phase F hook)**: `KeychainWipeArtifacts.deleteArtifacts()`
  calls `SqliteMessageStore.panicWipe(at:)` to delete the DB file alongside the
  Keychain key erasure, so the resumable wipe coordinates store + identity on
  iOS as it does on Android.
- `SqliteMessageStoreTests` (12 tests via `swift test` + `xcodebuild` on the iOS
  Simulator) mirror the Android `SqliteMessageStoreTest` one-for-one: persist +
  read-back field preservation, `INSERT OR IGNORE` dedup, SOS-first priority
  ordering with recency tie-break, no-eviction-under-budget, precise
  smallest-prefix byte eviction, SOS-retained-when-oldest, all-SOS flooding
  stays inside the hard cap (criterion 4), streaming early-exit, unknown-type
  rows skipped not thrown, and the `.complete` protection default pinned.

Criterion coverage after Phase G (repo-controlled subset):

6. **Android and iOS build the same anti-entropy digest from the same held
   set**: both expose `allHeldMsgIds` over the same schema and feed it to the
   byte-identical `BloomDigest` (Phase C KAT). iOS store-backed digest is
   repo-tested; on-device + shipping-path pending. NOT closed.

**Not closed.** The store is in the test-only `GodstoneMesh` module (not on the
LIGHT shipping path — the shipping app links only `GodstoneCore`), at-rest
encryption is device-only (Data Protection is not enforced on the macOS host),
authenticated-ACK deletion (criterion 2) depends on the inbound ACK path the
link layer gates closed, and the carrier-partition mobility (criterion 2) needs
the disabled link layer. A-04's "iOS durable store" half advances to
NONSHIPPING_TESTED; on-device + transport remain.

### Stage 4 Phase C7.4 / C7.5 / C7.5.1 — atomic ACK & terminal retirement architecture (NOT closed)

Persist-before-forward, delete-on-authenticated-ACK (C7.4.1), and local terminal retirement (EXPIRE, CANCEL under C7.5/C7.5.1) are REPO-VERIFIED and NONSHIPPING-TESTED on both Android and iOS:
- Transition policy is explicitly declared for all transitions via `HeldDisposition` (`RETAIN` for `MARK_HANDED`, `RETIRE_ATOMICALLY` for `EXPIRE` and `CANCEL`).
- State mutation and held-frame deletion execute inside a single atomic SQLite transaction closure on both platforms.
- Negative controls prove crash-safety, fault rollback, and concurrent race resolution.

**Not closed.** The store and delivery tracker remain in the non-shipping `:mesh` and `GodstoneMesh` modules. On-device evidence, physical storage power-loss tests, and shipping-path deployment remain pending.

## Decisions still required

- canonical GMP/2.1 store schema with 16-byte message IDs (repo-verified/nonshipping);
- receipt-monotonic retention and expiry (repo-verified/nonshipping);
- persist-before-forward, delete-on-authenticated-ACK, and local terminal retirement (EXPIRE, CANCEL) (repo-verified / nonshipping; on-device/shipping pending);
- hard-cap eviction where SOS is last, not unbounded (repo-verified/nonshipping);
- transactional key creation and migration under power loss;
- corruption detection/recovery;
- coordinated deletion of store, identity, contacts and session material (repo-verified/nonshipping; on-device pending);
- digest generation from held durable records on both platforms (repo-verified/nonshipping).

## Exit criteria

1. Reboot/jetsam after receipt preserves a message and its forwarding state.
2. A carrier can move between partitions after the origin has disappeared.
3. Every migration is tested from each supported schema version.
4. All-SOS flooding remains inside the configured hard cap.
5. Panic wipe makes prior rows and keys unrecoverable and creates a fresh identity.
6. Android and iOS build the same anti-entropy digest from the same held set.
