# ADR-004 — Durable message store, retention and panic wipe

**STATUS: OPEN.**

## Current state

Android opens SQLCipher through the current `net.zetetic.database.sqlcipher`
API and stores its database key behind an Android Keystore-backed preference.
That closes the V3 plaintext/import defect, but does not finish durability.

iOS has no durable DTN store. Its router queue and dedup set are in memory, so
termination, jetsam or reboot loses carried traffic. The radio feature remains
disabled; V4 does not present this queue as durable.

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
