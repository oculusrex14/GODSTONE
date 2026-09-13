#!/usr/bin/env python3
"""Generate crypto/anti_entropy_vectors.json -- the T40 control-plane fixture.

    python3 -m crypto.gen_anti_entropy_vectors

The table is struck by the INDEPENDENT references only:
  * bloom            -- crypto/gmp21.py (hashlib.blake2s, RFC 7693)
  * frame codec      -- wire/gen/wire_v2_codec.py (ADR-001 reference)
  * ATT fragmentation-- wire/ble_record_reference.py (ADR-002 reference)
  * payload table    -- wire/anti_entropy_reference.py (this task's reference)

The generator verifies every vector against the references before emitting
(it raises instead of writing an untrue table) and is deterministic: no
timestamps, sorted keys, stable LCG id sources -- re-running reproduces the
file byte for byte.  Both isles' readiness courts read this one file; the
Android and iOS codecs must agree with it byte for byte.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Dict, List

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import wire.anti_entropy_reference as AE
from crypto.gmp21 import BLOOM_SIZE_BYTES, bloom_build, bloom_index
from wire.ble_record_reference import (HEADER_BYTES, BleRecordType,
                                       decode_fragment, fragment_record)
from wire.gen.wire_v2_codec import NAME_BY_CODE, decode as frame_decode

OUT = Path(__file__).resolve().parent / "anti_entropy_vectors.json"
MASK = (1 << 128) - 1


def id_of(i: int) -> str:
    """Deterministic LCG-shaped msg id as 32 uppercase hex digits."""
    return "%032X" % ((i * 0x9E37_79B9_7F4A_7C15 + 0xA5A5 * i + 0x0BADF00D) & MASK)


def id_of_b(i: int) -> bytes:
    return bytes.fromhex(id_of(i))


def main() -> int:
    store = sorted({id_of(i) for i in range(1, 101)})
    assert len(store) == 100
    collision_store = sorted({id2 for id2 in
                             ("%032X" % ((i * 0x1234_5677_89AB_CCD1 + 0xCAFE_BEEF + i * i) & MASK)
                              for i in range(1, 121))})
    assert len(collision_store) == 120

    # ---- the one real bloom: built by gmp21 alone, over the durable store ids
    digest_bits_hex = bloom_build([bytes.fromhex(m) for m in store]).hex().upper()
    assert len(digest_bits_hex) == 2 * BLOOM_SIZE_BYTES

    # ---- the forced collision (bounded deterministic probe, verified twice)
    hit = AE.find_collision(collision_store)
    bits = {b for b in range(4096)
            if bloom_build([bytes.fromhex(m) for m in collision_store])[b >> 3] >> (b & 7) & 1}
    assert all(x in bits for x in hit["indices"]) and hit["id"] not in set(collision_store)

    # ---- well-formed payload vectors
    well: List[Dict] = []

    def _expected(st: Dict) -> Dict:
        e = dict(st)
        e.setdefault("version", AE.VERSION)
        if st["arm"] == AE.ARM_INVENTORY_REQUEST:
            e.setdefault("subtype", AE.SUBTYPE_INVENTORY_REQUEST)
        if st["arm"] == AE.ARM_INVENTORY_PAGE:
            e.setdefault("subtype", AE.SUBTYPE_INVENTORY_PAGE)
        if st["arm"] == AE.ARM_RESET:
            e.setdefault("subtype", AE.SUBTYPE_RESET)
        if st["arm"] in (AE.ARM_WANT, AE.ARM_INVENTORY_PAGE):
            e.setdefault("count", len(st["ids"]))
        return e

    def add_well(name: str, st: Dict) -> Dict:
        raw = AE.encode(st)
        struct, failure = AE.decode(st["arm"], raw)
        assert failure is None and struct is not None, (name, failure)
        assert AE.encode(struct) == raw and struct == _expected(st), (name, struct, st)
        v = {"name": name, "arm": st["arm"], "input": st, "struct": struct,
             "payload_hex": raw.hex().upper()}
        well.append(v)
        return v

    add_well("digest_basic", {"arm": "digest", "snapshot_id": 42, "bloom": digest_bits_hex})
    add_well("digest_empty_bloom", {"arm": "digest", "snapshot_id": 1, "bloom": "00" * 512})
    add_well("want_min", {"arm": "want", "snapshot_id": 1, "ids": [store[0]]})
    add_well("want_mid", {"arm": "want", "snapshot_id": 42, "ids": store[3:20]})
    add_well("want_max", {"arm": "want", "snapshot_id": 2 ** 64 - 1, "ids": store[:32]})
    add_well("want_unsorted_preserved",
             {"arm": "want", "snapshot_id": 7, "ids": [store[9], store[2], store[5]]})
    add_well("request_start",
             {"arm": "inventory_request", "snapshot_id": 42, "cursor_present": 0,
              "cursor": "0" * 32})
    add_well("request_continuation",
             {"arm": "inventory_request", "snapshot_id": 42, "cursor_present": 1,
              "cursor": store[63]})
    add_well("request_max_cursor",
             {"arm": "inventory_request", "snapshot_id": 2 ** 64 - 1, "cursor_present": 1,
              "cursor": "FF" * 16})
    snap = AE.snapshot(store, 42)
    pages = AE.walk(snap)
    add_well("page_mid", {"arm": "inventory_page", "snapshot_id": 42, "done": 0,
                          "ids": pages[0]["ids"]})
    add_well("page_full_32", {"arm": "inventory_page", "snapshot_id": 42, "done": 0,
                              "ids": store[:32]})
    add_well("page_final_done", {"arm": "inventory_page", "snapshot_id": 42, "done": 1,
                                 "ids": pages[-1]["ids"]})
    add_well("page_empty_done", {"arm": "inventory_page", "snapshot_id": 42, "done": 1,
                                 "ids": []})
    add_well("reset_min", {"arm": "reset", "new_snapshot_id": 1})
    add_well("reset_max", {"arm": "reset", "new_snapshot_id": 2 ** 64 - 1})
    add_well("ping_request", {"arm": "ping", "reply": 0, "nonce": 0xDEAD_BEEF_CAFE_BABE})
    add_well("ping_reply", {"arm": "ping", "reply": 1, "nonce": 0xDEAD_BEEF_CAFE_BABE})
    add_well("ping_nonce_zero", {"arm": "ping", "reply": 0, "nonce": 0})

    # ---- malformed vectors: every name in FAILURES is exercised
    bad: List[Dict] = []

    def add_bad(name: str, arm: str, raw: bytes, expect: str) -> None:
        struct, failure = AE.decode(arm, raw)
        assert struct is None and failure == expect, (name, failure, expect)
        bad.append({"name": name, "arm": arm, "payload_hex": raw.hex().upper(),
                    "expect_failure": expect})

    dg = AE.encode({"arm": "digest", "snapshot_id": 42, "bloom": digest_bits_hex})
    add_bad("digest_truncated_head", "digest", dg[:4], "truncated")
    add_bad("digest_truncated_bloom", "digest", dg[:520], "truncated")
    add_bad("digest_wrong_size_over", "digest", dg + b"\x00", "wrong_size")
    add_bad("digest_unsupported_version", 'digest', bytes([2]) + dg[1:], "unsupported_version")
    add_bad("digest_zero_snapshot_id", 'digest', bytes([1]) + (0).to_bytes(8, "big") + dg[9:],
            "zero_snapshot_id")
    wt = AE.encode({"arm": "want", "snapshot_id": 7, "ids": [store[0], store[1]]})
    add_bad("want_truncated_ids", "want", wt[:-8], "truncated")
    add_bad("want_wrong_size_over", "want", wt + b"\xAB", "wrong_size")
    add_bad("want_count_zero", "want", wt[:9] + bytes([0]) + bytes.fromhex(store[0]),
            "count_out_of_range")
    add_bad("want_count_over", "want",
            bytes([1]) + (7).to_bytes(8, "big") + bytes([33]) + bytes.fromhex(store[0] * 33),
            "count_out_of_range")
    add_bad("want_duplicate_ids", "want",
            bytes([1]) + (7).to_bytes(8, "big") + bytes([2])
            + bytes.fromhex(store[0] + store[0]), "duplicate_ids")
    add_bad("want_unsupported_version", 'want', bytes([0]) + wt[1:], "unsupported_version")
    add_bad("want_zero_snapshot_id", 'want', bytes([1]) + (0).to_bytes(8, "big") + wt[9:],
            "zero_snapshot_id")
    add_bad("want_truncated_head", "want", b"\x01\x00", "truncated")
    rq = AE.encode({"arm": "inventory_request", "snapshot_id": 42, "cursor_present": 0,
                    "cursor": "0" * 32})
    add_bad("request_truncated", "inventory_request", rq[:20], "truncated")
    add_bad("request_wrong_size_over", "inventory_request", rq + b"\x00", "wrong_size")
    add_bad("request_bad_cursor_value", "inventory_request",
            bytes([1, 1]) + (42).to_bytes(8, "big") + bytes([2]) + bytes(16), "bad_cursor")
    add_bad("request_nonzero_filler", "inventory_request",
            bytes([1, 1]) + (42).to_bytes(8, "big") + bytes([0]) + bytes.fromhex(store[5]),
            "bad_cursor")
    add_bad("request_unknown_subtype", "inventory_request",
            bytes([1, 4]) + (42).to_bytes(8, "big") + bytes([0]) + bytes(16),
            "unknown_subtype")
    add_bad("request_unsupported_version", 'inventory_request', bytes([2]) + rq[1:], "unsupported_version")
    add_bad("request_zero_snapshot_id", 'inventory_request', bytes([1, 1]) + (0).to_bytes(8, "big") + rq[10:],
            "zero_snapshot_id")
    pg = AE.encode({"arm": "inventory_page", "snapshot_id": 42, "done": 0,
                    "ids": store[:32]})
    add_bad("page_truncated_ids", "inventory_page", pg[:30], "truncated")
    add_bad("page_wrong_size_over", "inventory_page", pg + b"\xFF", "wrong_size")
    add_bad("page_count_over", "inventory_page",
            bytes([1, 2]) + (42).to_bytes(8, "big") + bytes([0, 33]) + bytes.fromhex(store[0] * 33),
            "count_out_of_range")
    add_bad("page_zero_count_not_done", "inventory_page",
            bytes([1, 2]) + (42).to_bytes(8, "big") + bytes([0, 0]), "bad_done")
    add_bad("page_bad_done_value", "inventory_page",
            bytes([1, 2]) + (42).to_bytes(8, "big") + bytes([2, 1]) + bytes.fromhex(store[0]),
            "bad_done")
    add_bad("page_duplicate_ids", "inventory_page",
            bytes([1, 2]) + (42).to_bytes(8, "big") + bytes([1, 2])
            + bytes.fromhex(store[3] + store[3]), "duplicate_ids")
    add_bad("page_unknown_subtype", "inventory_page",
            bytes([1, 0]) + (42).to_bytes(8, "big") + bytes([1, 0]), "unknown_subtype")
    add_bad("page_unsupported_version", 'inventory_page', bytes([3]) + pg[1:], "unsupported_version")
    add_bad("page_zero_snapshot_id", 'inventory_page', bytes([1, 2]) + (0).to_bytes(8, "big") + pg[10:],
            "zero_snapshot_id")
    # cross-arm confusion: a page read under the request arm (and back) is
    # not that arm's creature -- the subtype names the arm, reject by name
    rq_any = bytes([1, 1]) + (42).to_bytes(8, "big") + bytes([0]) + bytes(16)
    pg_any = bytes([1, 2]) + (42).to_bytes(8, "big") + bytes([1, 1]) + bytes.fromhex(store[0])
    add_bad("request_under_page_arm", "inventory_page", rq_any, "unknown_subtype")
    add_bad("page_under_request_arm", "inventory_request", pg_any, "unknown_subtype")
    add_bad("reset_under_page_arm", "inventory_page", bytes([1, 3]) + (42).to_bytes(8, "big"),
            "unknown_subtype")
    rs = AE.encode({"arm": "reset", "new_snapshot_id": 42})
    add_bad("reset_truncated", "reset", rs[:6], "truncated")
    add_bad("reset_wrong_size_over", "reset", rs + b"\x00", "wrong_size")
    add_bad("reset_zero_snapshot_id", 'reset', bytes([1, 3]) + (0).to_bytes(8, "big"),
            "zero_snapshot_id")
    add_bad("reset_unsupported_version", 'reset', bytes([4]) + rs[1:], "unsupported_version")
    pn = AE.encode({"arm": "ping", "reply": 0, "nonce": 9})
    add_bad("ping_truncated", "ping", pn[:9], "truncated")
    add_bad("ping_wrong_size_over", "ping", pn + b"\x00", "wrong_size")
    add_bad("ping_bad_reply_value", 'ping', bytes([1, 2]) + (9).to_bytes(8, "big"), "bad_reply")
    add_bad("ping_unsupported_version", 'ping', bytes([9, 0]) + (9).to_bytes(8, "big"),
            "unsupported_version")

    # ---- the walk over the captured snapshot (owner-side expectations)
    assert AE.check_sequence(pages, 42) is None, "the clean walk must validate"
    walk_vectors = [{
        "name": "walk_100_by_32",
        "snapshot_id": 42,
        "pages": [{"snapshot_id": p["snapshot_id"], "done": p["done"], "count": p["count"], "ids": p["ids"]} for p in pages],
        "after_end_empty": {"done": 1, "count": 0, "ids": []},
        "restart_from_zero": {"done": pages[0]["done"], "count": pages[0]["count"],
                              "ids": pages[0]["ids"]},
    }]
    # corrupted walks the owner's sequence check must name (section 14: pages
    # received out of order, or against another snapshot, break the run)
    back_one = {"arm": AE.ARM_INVENTORY_PAGE, "version": AE.VERSION,
                "subtype": AE.SUBTYPE_INVENTORY_PAGE, "snapshot_id": 42,
                "done": 0, "count": 2, "ids": [store[5], store[6]]}
    wrong_sid = {"arm": AE.ARM_INVENTORY_PAGE, "version": AE.VERSION,
                 "subtype": AE.SUBTYPE_INVENTORY_PAGE, "snapshot_id": 4242,
                 "done": 1, "count": 1, "ids": [store[99]]}
    no_final_done = [dict(p) for p in pages]
    no_final_done[-1] = {**no_final_done[-1], "done": 0}
    mid_done = [dict(p) for p in pages]
    mid_done[1] = {**mid_done[1], "done": 1}
    for nm, plist, why in (("back_one_first", [pages[0], back_one], "sequence_break"),
                           ("wrong_snapshot_id", [pages[0], wrong_sid], "sequence_break"),
                           ("missing_final_done", no_final_done, "sequence_break"),
                           ("done_before_end", mid_done, "sequence_break")):
        got = AE.check_sequence(plist, 42)
        assert got == why, (nm, got, why)
        walk_vectors.append({"name": nm, "snapshot_id": 42,
                             "pages": [{"snapshot_id": p["snapshot_id"], "done": p["done"], "count": p["count"],
                                        "ids": p["ids"]} for p in plist],
                             "expect_failure": why})

    # ---- the frames as sent: control-only zero values on the frozen envelope
    frames: List[Dict] = []
    for k, v in enumerate(well):
        msg_id = "%032X" % ((0x4D45_5348_0000_0000 + k * 0x10001 + 0x23) & MASK)
        tag = "%08X" % (0x0A0B_0C0D + k)
        f = AE.frame_for(v["input"], msg_id, tag)
        decoded = frame_decode(bytes.fromhex(f["frame_hex"]))
        assert decoded is not None
        assert decoded["ttl"] == 0 and decoded["hop_count"] == 0 and decoded["flags"] == 0
        assert decoded["payload"] == f["payload_hex"].lower()
        assert decoded["msg_id"] == msg_id.lower()
        assert decoded["routing_tag"] == tag.lower()
        assert decoded["type"] == NAME_BY_CODE[f["type_code"]]
        f["name"] = v["name"]
        frames.append(f)

    # ---- the ATT plan at MTU 20: the full DIGEST frame over the smallest leg
    digest_frame = next(f for f in frames if f["name"] == "digest_basic")
    raw = bytes.fromhex(digest_frame["frame_hex"])
    frags = fragment_record(BleRecordType.DATA, 7, raw, 20)
    capacity = 20 - HEADER_BYTES
    expected_frags = (len(raw) + capacity - 1) // capacity
    assert all(len(x) <= 20 for x in frags) and len(frags) == expected_frags, \
        (len(raw), len(frags), expected_frags)
    rejo = b"".join(decode_fragment(x).payload for x in frags)
    assert rejo == raw
    att = {"name": "digest_basic_at_t_mtu20", "record_type": int(BleRecordType.DATA),
           "record_seq": 7, "max_att_value_length": 20,
           "fragments_hex": [x.hex().upper() for x in frags], "reassembled_frame_hex": raw.hex().upper()}

    table = {
        "schema_version": 1,
        "task": "T40",
        "generated_by": "crypto/gen_anti_entropy_vectors.py",
        "authorities": {
            "bloom": "crypto/gmp21.py (independent, RFC 7693 blake2s)",
            "payload_table": "wire/anti_entropy_reference.py (independent reference)",
            "frame_codec": "wire/gen/wire_v2_codec.py (ADR-001 reference)",
            "att_fragmentation": "wire/ble_record_reference.py (ADR-002 reference)",
        },
        "constants": {
            "version": AE.VERSION, "arms": list(AE.ARMS), "typecode": dict(AE.ARM_TYPECODE),
            "subtype": {"inventory_request": AE.SUBTYPE_INVENTORY_REQUEST,
                       "inventory_page": AE.SUBTYPE_INVENTORY_PAGE, "reset": AE.SUBTYPE_RESET},
            "id_size_bytes": AE.ID_SIZE, "bloom_bytes": AE.BLOOM_BYTES,
            "bloom_bits": 4096, "bloom_hashes": 4, "max_ids_per_arm": AE.MAX_IDS_PER_ARM,
            "snapshot_max_rows": AE.SNAPSHOT_MAX_ROWS,
            "snapshot_max_id_bytes": AE.SNAPSHOT_MAX_ID_BYTES,
            "snapshot_max_age_ms": AE.SNAPSHOT_MAX_AGE_MS,
            "snapshot_min_build_gap_ms": AE.SNAPSHOT_MIN_BUILD_GAP_MS,
            "snapshot_read_budget_ms": AE.SNAPSHOT_READ_BUDGET_MS,
            "snapshot_max_leased": AE.SNAPSHOT_MAX_LEASED,
            "max_pages_per_run": AE.MAX_PAGES_PER_RUN, "max_wants_per_run": AE.MAX_WANTS_PER_RUN,
            "periodic_inventory_ms": AE.PERIODIC_INVENTORY_MS,
            "failures": list(AE.FAILURES),
        },
        "store": store,
        "collision": {"store": collision_store, "foreign": hit["id"],
                      "indices": hit["indices"], "probes": hit["probes"],
                      "digest_hex": bloom_build([bytes.fromhex(m) for m in collision_store]).hex().upper()},
        "payloads": well,
        "malformed": bad,
        "walk": walk_vectors,
        "frames": frames,
        "att": att,
    }
    OUT.write_text(json.dumps(table, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {OUT} with {len(well)} well-formed, {len(bad)} malformed vectors, "
          f"{len(frames)} frames, 1 att plan")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
