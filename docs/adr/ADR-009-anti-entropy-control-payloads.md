# ADR-009 — The anti-entropy control-plane payload scope freeze

**STATUS: ACCEPTED (T40).** Freezes the versioned payloads that ride the
already-frozen outer codes HELLO (0x11), DIGEST (0x12), WANT (0x14) and
PING (0x28), per blueprint section 14. It adds **no new outer wire codes**
and moves no byte of the frozen frame tables; the `control_payloads`
section of `wire/wire_v2.yaml` is the human-readable record of this ADR and
is deliberately invisible to `wire/codegen.py` (regeneration after this
amendment is byte-identical, verified in the T40 evidence).

---

## 1. Why this ADR exists

The bloom and WANT helpers existed, but no interoperable control exchange
was wired: every non-ACK inbound frame -- DIGEST included -- was dispatched
to the generic epidemic Router, which ran it through policy, the seen-dedup
window, the TTL gate and `store.persist`. Control frames therefore entered
held message storage, consumed the 64MiB held quota, poisoned dedup, and
were offered for relay; nothing owned them. Section 14 names the remedy:
*"Control frames never enter held message storage... Demultiplex link
controls before generic Router TTL/dedup/persistence."*

Payload decisions that the frozen table left open must be made once, in
writing, with vectors -- otherwise the two isles drift and the helpers stay
decorative. That decision is this ADR.

## 2. The payload table (version u8(1) heads every arm)

| arm | outer code | canonical payload | bound |
|---|---|---|---|
| DIGEST | 0x12 | `version ‖ snapshotId u64_be ‖ bloom[512]` | snapshotId ≠ 0 |
| WANT | 0x14 | `version ‖ snapshotId u64_be ‖ count u8 ‖ msgID[count][16]` | 1 ≤ count ≤ 32, ids distinct |
| HELLO/1 inventory request | 0x11, subtype 1 | `version ‖ u8(1) ‖ snapshotId u64_be ‖ cursorPresent u8 ‖ cursor[16]` | cursorPresent ∈ {0,1}; 0 ⇒ all-zero filler |
| HELLO/2 inventory page | 0x11, subtype 2 | `version ‖ u8(2) ‖ snapshotId u64_be ‖ done u8 ‖ count u8 ‖ msgID[count][16]` | count ≤ 32; count 0 ⇒ done=1 |
| HELLO/3 reset | 0x11, subtype 3 | `version ‖ u8(3) ‖ newSnapshotId u64_be` | newSnapshotId ≠ 0 |
| PING | 0x28 | `version ‖ reply u8(0..1) ‖ nonce u64_be` | see §3 |

Every u64 is big-endian. Cursors are **exclusive lexicographic last-seen
msgIDs**, never SQL offsets. The bloom uses the canonical four rounds of
`crypto/gmp21.py`:
`((BE64(BLAKE2s64(msgID16 ‖ round u32_be)) >> 1) & 0x7fffffff) % 4096`;
the LinkInfo six-byte digest remains a short change hint only. Decode is
strict and fail-closed: each rejection carries one typed failure name from
{truncated, wrong_size, unsupported_version, count_out_of_range,
duplicate_ids, bad_cursor, bad_done, bad_reply, zero_snapshot_id,
unknown_subtype, sequence_break}; a rejected control frame mutates nothing.

## 3. The one open field: PING has no PONG

The frozen table never allocated a PONG code and this ADR refuses to
invent one post hoc. PING is its own answer: the `reply` flag separates a
request (0) from the reply (1); a reply echoes the request's 64-bit nonce
unchanged; a reply is never answered (no echo storm); the first reply to a
relation for an unknown nonce is refused (`bad_reply` is reserved for the
peer that breaks this rule). The relation's RTT sample is the monotonic
pair (request sent, reply heard) taken under the node's own clock -- the
link is authenticated (T23), so the nonce is a replay discriminator, not a
challenge of identity.

## 4. Snapshot authority (section 14, verbatim law)

The store executor builds the stable, bounded, **sorted immutable** id
vector from one consistent short read transaction over durable held rows --
never from the in-memory seen cache -- bounded by 100 000 rows and 1.6 MiB
of ids. `snapshotId` is a nonzero monotonic u64 allocated by the authority
context; exhaustion retires the context. At most two snapshots are shared
(current plus one referenced predecessor), maximum age 300 s; at most one
new build per 30 s under a 2 s read-transaction budget -- abort safely,
defer, never grow memory. Pages are pinned to the captured vector. A
consumer requesting a stale snapshot receives the reset subtype plus the
current DIGEST and restarts with `cursorPresent=0`; ordinary new holds do
**not** restart an active immutable snapshot. Control state and producer
leases release on relation terminal (reconnect is a new relation).

## 5. Dispatch statute (node ingress, before the generic path)

PING/HELLO/DIGEST/WANT → the per-relation sync/control owner; ACK → the ACK
dispatcher (unchanged); MESSAGE/SOS → durable message routing (unchanged);
everything else (the bulk pair and any unknown) → refused in this profile.
The Router itself keeps a second gate by type name, so a caller that skips
the demultiplex still cannot persist or relay control. A ttl-0 control frame
is local to the authenticated link: never forwarded, never through the
generic expiration. The sync-run budget is 64 pages and 256 requested
frames per turn, yielding with a resumable exclusive cursor; exact
inventory is scheduled at first encounter and every 300 s while linked --
*"to eliminate permanent bloom false-positive suppression"*.

## 6. The semantic negative (what the roster must kill)

Building the digest from seen-but-not-held ids, or disabling the exact-ID
reconciliation, must make the eviction and forced-collision tests fail.
The bloom may suppress; the walk must never lie.

## 7. Authorities and vectors

The independent reference is `wire/anti_entropy_reference.py` (it imports
the bloom only from `crypto/gmp21.py`, the frame only from
`wire/gen/wire_v2_codec.py`, the ATT leg only from
`wire/ble_record_reference.py`). The one table
`crypto/anti_entropy_vectors.json` is struck by
`crypto/gen_anti_entropy_vectors.py` (deterministic, self-verifying, no
timestamps) and is the single source of truth for BOTH isles' courts: 18
well-formed payload vectors, 37 malformed rejection vectors (every typed
failure exercised), 5 walk vectors (including four sequence_break legs),
18 frame vectors with control-only zero envelope values, and the ATT plan
carrying the full 512-byte bloom at MTU 20. If generated code and this
table ever disagree, the regeneration path is the resolution, not editing
the table.

## 8. Consequences

* Production codecs: `router/ControlPayloadV1.kt`,
  `router/StableInventorySnapshot.kt`, `router/SyncControlOwner.kt`
  (Android) and their iOS mirrors -- hand-written (the generator's inputs
  are the frozen tables, not these types), reviewed against the reference.
* The MeshNode ingress demultiplexes controls first; the Router refuses by
  type name in depth.
* No sealed court of T01-T39+T83 changes: none of them exercised the seven
  non-message types through the generic path (survey of record), so the
  refusal adds strictness without breaking an accepted truth.
* What remains open: the durable anti-entropy pump itself -- the outbound
  scheduling of digests/wants/pages over real links and the forwarding
  integration -- lands in T41 (Android) and T42 (iOS) on top of this frozen
  contract; this ADR freezes the payloads, the budgets, and the dispatch
  only. Device evidence stays deferred (T73-T75).
