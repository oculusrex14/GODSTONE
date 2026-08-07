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
   resumable** wipe across store/identity/contacts is Phase F.
6. Anti-entropy digest from the held set is built from `allHeldMsgIds`; Android
   side is testable. iOS parity is Phase G.

**Not closed.** The store is in the non-shipping `:mesh` module (LIGHT has no
`:mesh` dependency edge; `check_shipping_path.py` PASS), at-rest encryption is
verified on device only (the SQLCipher native core + Keystore are not exercised
host-side), authenticated-ACK deletion (criterion 2) depends on the inbound ACK
path the link layer gates closed, and iOS has no durable store yet (Phase G).

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
