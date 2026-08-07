# ADR-004 — Durable message store, retention and panic wipe

**STATUS: OPEN.**

## Current state

Android opens SQLCipher through the current `net.zetetic.database.sqlcipher`
API and stores its database key behind an Android Keystore-backed preference.
That closes the V3 plaintext/import defect, but does not finish durability.

iOS has no durable DTN store. Its router queue and dedup set are in memory, so
termination, jetsam or reboot loses carried traffic. The radio feature remains
disabled; V4 does not present this queue as durable.

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
   side is testable. iOS parity is Phase G.

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
