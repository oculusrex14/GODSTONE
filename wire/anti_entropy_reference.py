#!/usr/bin/env python3
"""Anti-entropy control-plane payload reference (T40; ADR-009; blueprint section 14).

This is the INDEPENDENT implementation of the frozen control-payload table.
It shares no code with the Android (``router.ControlPayloadV1.kt``) or iOS
(``ControlPayloadV1.swift``) production codecs.  The generator
``crypto/gen_anti_entropy_vectors.py`` strikes the vectors here; the two
isles' courts read the one table ``crypto/anti_entropy_vectors.json`` and
the isles must agree with this reference byte for byte -- proving the two
codecs agree with the specification, not merely with each other.

The table (section 14, verbatim law)::

    DIGEST   version u8(1) || snapshotId u64_be (nonzero) || bloom[512]
    WANT     version u8(1) || snapshotId u64_be (nonzero) || count u8 (1..32) || msgID[count][16]
    HELLO/1  version u8(1) || u8(1) || snapshotId u64_be || cursorPresent u8 || cursor[16]
    HELLO/2  version u8(1) || u8(2) || snapshotId u64_be || done u8 || count u8 || msgID[count][16]
    HELLO/3  version u8(1) || u8(3) || newSnapshotId u64_be (nonzero)
    PING     version u8(1) || reply u8 (0..1) || nonce u64_be

Wire names (typed failures; the isles name them identically)::

    truncated, wrong_size, unsupported_version, count_out_of_range,
    duplicate_ids, bad_cursor, bad_done, bad_reply, zero_snapshot_id,
    unknown_subtype, sequence_break

Envelope law: control frames ride the frozen outer codes HELLO 0x11,
DIGEST 0x12, WANT 0x14, PING 0x28 with flags/ttl/hop control-only zero
values -- local to the authenticated link, never forwarded, never through
the generic expiration; they never enter held message storage.
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from crypto.gmp21 import (BLOOM_HASHES, BLOOM_SHORT_BYTES, BLOOM_SIZE_BITS,
                          BLOOM_SIZE_BYTES, bloom_build, bloom_index)
from wire.gen.wire_v2_codec import encode as frame_encode

VERSION: int = 1

ARM_DIGEST: str = "digest"
ARM_WANT: str = "want"
ARM_INVENTORY_REQUEST: str = "inventory_request"
ARM_INVENTORY_PAGE: str = "inventory_page"
ARM_RESET: str = "reset"
ARM_PING: str = "ping"
ARMS: Tuple[str, ...] = (ARM_DIGEST, ARM_WANT, ARM_INVENTORY_REQUEST,
                         ARM_INVENTORY_PAGE, ARM_RESET, ARM_PING)

TYPECODE_HELLO: int = 0x11
TYPECODE_DIGEST: int = 0x12
TYPECODE_WANT: int = 0x14
TYPECODE_PING: int = 0x28
ARM_TYPECODE: Dict[str, int] = {
    ARM_DIGEST: TYPECODE_DIGEST,
    ARM_WANT: TYPECODE_WANT,
    ARM_INVENTORY_REQUEST: TYPECODE_HELLO,
    ARM_INVENTORY_PAGE: TYPECODE_HELLO,
    ARM_RESET: TYPECODE_HELLO,
    ARM_PING: TYPECODE_PING,
}

SUBTYPE_INVENTORY_REQUEST: int = 1
SUBTYPE_INVENTORY_PAGE: int = 2
SUBTYPE_RESET: int = 3

ID_SIZE: int = 16              # bytes per msg_id (wire name: msgID_size)
BLOOM_BYTES: int = BLOOM_SIZE_BYTES      # 512
MAX_IDS_PER_ARM: int = 32      # WANT and page list bound (wire name: want_max / page_max)

# authority context bounds (section 14 snapshot law)
SNAPSHOT_MAX_ROWS: int = 100_000
SNAPSHOT_MAX_ID_BYTES: int = 1_600_000      # 1.6MiB of ids
SNAPSHOT_MAX_AGE_MS: int = 300_000           # five minutes
SNAPSHOT_MIN_BUILD_GAP_MS: int = 30_000      # one build per thirty seconds
SNAPSHOT_READ_BUDGET_MS: int = 2_000         # two-second read transaction
SNAPSHOT_MAX_LEASED: int = 2                 # current + referenced predecessor
MAX_PAGES_PER_RUN: int = 64
MAX_WANTS_PER_RUN: int = 256
PERIODIC_INVENTORY_MS: int = 300_000         # five minutes while linked

FAILURES: Tuple[str, ...] = (
    "truncated", "wrong_size", "unsupported_version", "count_out_of_range",
    "duplicate_ids", "bad_cursor", "bad_done", "bad_reply",
    "zero_snapshot_id", "unknown_subtype", "sequence_break",
)


def _u64_be(buf: bytes, off: int) -> int:
    return int.from_bytes(buf[off:off + 8], "big")


def _be64(v: int) -> bytes:
    return v.to_bytes(8, "big")


def _distinct(ids: List[str]) -> bool:
    return len(set(ids)) == len(ids)


def _valid_u16_hex(mid: str) -> bool:
    return isinstance(mid, str) and len(mid) == 2 * ID_SIZE and all(
        c in "0123456789ABCDEF" for c in mid.upper())


# ---------------------------------------------------------------------
# encode -- struct (dict) to canonical payload bytes
# ---------------------------------------------------------------------

def encode(st: Dict) -> bytes:
    """Encode a control struct; the mirror of every isle's encode()."""
    arm = st.get("arm")
    if arm == ARM_DIGEST:
        sid = int(st["snapshot_id"])
        if sid == 0 or sid >= 1 << 64:
            raise ValueError("zero_snapshot_id")
        bloom = bytes.fromhex(st["bloom"])
        if len(bloom) != BLOOM_BYTES:
            raise ValueError("wrong_size")
        return bytes([VERSION]) + _be64(sid) + bloom
    if arm == ARM_WANT:
        sid = int(st["snapshot_id"])
        ids = list(st["ids"])
        if sid == 0 or sid >= 1 << 64:
            raise ValueError("zero_snapshot_id")
        if not 1 <= len(ids) <= MAX_IDS_PER_ARM:
            raise ValueError("count_out_of_range")
        if not all(_valid_u16_hex(m) for m in ids) or not _distinct(ids):
            raise ValueError("duplicate_ids")
        return (bytes([VERSION]) + _be64(sid) + bytes([len(ids)])
                + b"".join(bytes.fromhex(m) for m in ids))
    if arm == ARM_INVENTORY_REQUEST:
        sid = int(st["snapshot_id"])
        cp = int(st["cursor_present"])
        cursor = st.get("cursor") or "0" * (2 * ID_SIZE)
        if sid == 0 or sid >= 1 << 64:
            raise ValueError("zero_snapshot_id")
        if cp not in (0, 1):
            raise ValueError("bad_cursor")
        cur = bytes.fromhex(cursor.upper())
        if len(cur) != ID_SIZE:
            raise ValueError("bad_cursor")
        if cp == 0 and cur != bytes(ID_SIZE):
            raise ValueError("bad_cursor")
        return bytes([VERSION, SUBTYPE_INVENTORY_REQUEST]) + _be64(sid) + bytes([cp]) + cur
    if arm == ARM_INVENTORY_PAGE:
        sid = int(st["snapshot_id"])
        done = int(st["done"])
        ids = list(st["ids"])
        if sid == 0 or sid >= 1 << 64:
            raise ValueError("zero_snapshot_id")
        if done not in (0, 1):
            raise ValueError("bad_done")
        if len(ids) > MAX_IDS_PER_ARM:
            raise ValueError("count_out_of_range")
        if done == 0 and len(ids) == 0:
            raise ValueError("bad_done")
        if not all(_valid_u16_hex(m) for m in ids) or not _distinct(ids):
            raise ValueError("duplicate_ids")
        return (bytes([VERSION, SUBTYPE_INVENTORY_PAGE]) + _be64(sid)
                + bytes([done, len(ids)]) + b"".join(bytes.fromhex(m) for m in ids))
    if arm == ARM_RESET:
        sid = int(st["new_snapshot_id"])
        if sid == 0 or sid >= 1 << 64:
            raise ValueError("zero_snapshot_id")
        return bytes([VERSION, SUBTYPE_RESET]) + _be64(sid)
    if arm == ARM_PING:
        reply = int(st["reply"])
        nonce = int(st["nonce"])
        if reply not in (0, 1):
            raise ValueError("bad_reply")
        if not 0 <= nonce < 1 << 64:
            raise ValueError("wrong_size")
        return bytes([VERSION, reply]) + _be64(nonce)
    raise ValueError("unknown_subtype")


# ---------------------------------------------------------------------
# decode -- bytes to struct; (None, failure-name) on any rejection
# ---------------------------------------------------------------------

def decode(arm: str, buf: bytes) -> Tuple[Optional[Dict], Optional[str]]:
    """Decode canonically; fail closed with a named typed failure."""
    if arm not in ARMS:
        return None, "unknown_subtype"
    if arm == ARM_DIGEST:
        need = 1 + 8 + BLOOM_BYTES
        if len(buf) < need:
            return None, "truncated"
        if len(buf) > need:
            return None, "wrong_size"
        if buf[0] != VERSION:
            return None, "unsupported_version"
        sid = _u64_be(buf, 1)
        if sid == 0:
            return None, "zero_snapshot_id"
        return ({"arm": ARM_DIGEST, "version": VERSION, "snapshot_id": sid,
                 "bloom": buf[9:].hex().upper()}, None)
    if arm == ARM_WANT:
        if len(buf) < 10:
            return None, "truncated"
        if buf[0] != VERSION:
            return None, "unsupported_version"
        sid = _u64_be(buf, 1)
        if sid == 0:
            return None, "zero_snapshot_id"
        count = buf[9]
        if not 1 <= count <= MAX_IDS_PER_ARM:
            return None, "count_out_of_range"
        need = 10 + 16 * count
        if len(buf) < need:
            return None, "truncated"
        if len(buf) > need:
            return None, "wrong_size"
        ids = [buf[10 + 16 * i:10 + 16 * (i + 1)].hex().upper() for i in range(count)]
        if not _distinct(ids):
            return None, "duplicate_ids"
        return ({"arm": ARM_WANT, "version": VERSION, "snapshot_id": sid,
                 "count": count, "ids": ids}, None)
    if arm in (ARM_INVENTORY_REQUEST, ARM_INVENTORY_PAGE, ARM_RESET):
        if len(buf) < 2:
            return None, "truncated"
        if buf[0] != VERSION:
            return None, "unsupported_version"
        subtype = buf[1]
        if subtype == SUBTYPE_INVENTORY_REQUEST:
            if arm != ARM_INVENTORY_REQUEST:
                return None, "unknown_subtype"
            need = 2 + 8 + 1 + 16
            if len(buf) < need:
                return None, "truncated"
            if len(buf) > need:
                return None, "wrong_size"
            sid = _u64_be(buf, 2)
            if sid == 0:
                return None, "zero_snapshot_id"
            cp = buf[10]
            if cp not in (0, 1):
                return None, "bad_cursor"
            cur = buf[11:27].hex().upper()
            if cp == 0 and cur != "0" * 32:
                return None, "bad_cursor"
            return ({"arm": ARM_INVENTORY_REQUEST, "version": VERSION,
                     "subtype": subtype, "snapshot_id": sid,
                     "cursor_present": cp, "cursor": cur}, None)
        if subtype == SUBTYPE_INVENTORY_PAGE:
            if arm != ARM_INVENTORY_PAGE:
                return None, "unknown_subtype"
            if len(buf) < 4:
                return None, "truncated"
            sid = _u64_be(buf, 2)
            if sid == 0:
                return None, "zero_snapshot_id"
            done = buf[10]
            count = buf[11]
            if done not in (0, 1):
                return None, "bad_done"
            if count > MAX_IDS_PER_ARM:
                return None, "count_out_of_range"
            if done == 0 and count == 0:
                return None, "bad_done"
            need = 12 + 16 * count
            if len(buf) < need:
                return None, "truncated"
            if len(buf) > need:
                return None, "wrong_size"
            ids = [buf[12 + 16 * i:12 + 16 * (i + 1)].hex().upper() for i in range(count)]
            if not _distinct(ids):
                return None, "duplicate_ids"
            return ({"arm": ARM_INVENTORY_PAGE, "version": VERSION,
                     "subtype": subtype, "snapshot_id": sid, "done": done,
                     "count": count, "ids": ids}, None)
        if subtype == SUBTYPE_RESET:
            if arm != ARM_RESET:
                return None, "unknown_subtype"
            need = 2 + 8
            if len(buf) < need:
                return None, "truncated"
            if len(buf) > need:
                return None, "wrong_size"
            sid = _u64_be(buf, 2)
            if sid == 0:
                return None, "zero_snapshot_id"
            return ({"arm": ARM_RESET, "version": VERSION, "subtype": subtype,
                     "new_snapshot_id": sid}, None)
        return None, "unknown_subtype"
    # ARM_PING
    need = 1 + 1 + 8
    if len(buf) < need:
        return None, "truncated"
    if len(buf) > need:
        return None, "wrong_size"
    if buf[0] != VERSION:
        return None, "unsupported_version"
    reply = buf[1]
    if reply not in (0, 1):
        return None, "bad_reply"
    nonce = _u64_be(buf, 2)
    return ({"arm": ARM_PING, "version": VERSION, "reply": reply,
             "nonce": nonce}, None)


# ---------------------------------------------------------------------
# the snapshot authority (store executor) and the pager walk
# ---------------------------------------------------------------------

def snapshot(ids: List[str], snapshot_id: int) -> Dict:
    """Build the stable, bounded, sorted immutable vector (hex ids)."""
    if snapshot_id <= 0 or snapshot_id >= 1 << 64:
        raise ValueError("zero_snapshot_id")
    if any(not _valid_u16_hex(m) for m in ids):
        raise ValueError("wrong_size")
    if len(ids) > SNAPSHOT_MAX_ROWS:
        raise ValueError("count_out_of_range")
    if len(ids) * ID_SIZE > SNAPSHOT_MAX_ID_BYTES:
        raise ValueError("count_out_of_range")
    ordered = sorted(set(ids))          # the durable store is distinct by key
    if len(ordered) != len(ids):
        raise ValueError("duplicate_ids")
    return {"snapshot_id": snapshot_id, "ids": ordered, "size": len(ordered)}


def page_after(snap: Dict, cursor: Optional[str],
               max_ids: int = MAX_IDS_PER_ARM) -> Dict:
    """Page pinned to the captured vector: ids strictly after the exclusive
    lexicographic cursor (None restarts the walk from the beginning)."""
    if max_ids < 1 or max_ids > MAX_IDS_PER_ARM:
        raise ValueError("count_out_of_range")
    ids: List[str] = snap["ids"]
    start = 0
    if cursor is not None:
        c = cursor.upper()
        if not _valid_u16_hex(c):
            raise ValueError("bad_cursor")
        while start < len(ids) and ids[start] <= c:
            start += 1
    window = ids[start:start + max_ids]
    done = 1 if start + len(window) >= len(ids) else 0
    return {"arm": ARM_INVENTORY_PAGE, "version": VERSION,
            "subtype": SUBTYPE_INVENTORY_PAGE, "snapshot_id": snap["snapshot_id"],
            "done": done, "count": len(window), "ids": window}


def walk(snap: Dict, max_ids: int = MAX_IDS_PER_ARM) -> List[Dict]:
    """The full cursor walk until done -- pages received over one run."""
    pages: List[Dict] = []
    cursor: Optional[str] = None
    while True:
        page = page_after(snap, cursor, max_ids)
        pages.append(page)
        if page["done"] == 1:
            return pages
        cursor = page["ids"][-1]


def check_sequence(pages: List[Dict], active_snapshot_id: int) -> Optional[str]:
    """Owner-side sequence check over the pages received in one run."""
    last: Optional[str] = None
    for page in pages:
        if page["snapshot_id"] != active_snapshot_id:
            return "sequence_break"
        if page["count"] > MAX_IDS_PER_ARM:
            return "count_out_of_range"
        if page["count"] == 0 and page["done"] != 1:
            return "bad_done"
        if page["ids"]:
            if not _distinct(page["ids"]):
                return "duplicate_ids"
            if page["ids"] != sorted(page["ids"]):
                return "sequence_break"
            if last is not None and page["ids"][0] <= last:
                return "sequence_break"
            last = page["ids"][-1]
    done_flags = [p["done"] for p in pages]
    if done_flags and done_flags[-1] != 1:
        return "sequence_break"
    if any(done_flags[:-1]):        # done must not be set before the end
        return "sequence_break"
    return None


def find_collision(store_ids: List[str], start: int = 0,
                   max_probe: int = 1 << 20) -> Dict:
    """Probe for a foreign id whose four canonical bit indices all lie in
    the bits the durable store set -- a true bloom collision (section 14:
    the exact-ID reconciliation exists precisely for this)."""
    store = sorted(set(store_ids))
    store_set = set(store)
    digest = bloom_build([bytes.fromhex(m) for m in store])
    bitset: List[int] = []
    for i in range(BLOOM_SIZE_BYTES):
        for bit in range(8):
            if digest[i] >> bit & 1:
                bitset.append(i * 8 + bit)
    bits = set(bitset)
    i = start
    while i < start + max_probe:
        half = (i * 0x9E37_79B9_7F4A_7C15 ^ (i * i + 0xA5A5)) & 0xFFFF_FFFF_FFFF_FFFF
        mid = half.to_bytes(8, "big") + (half ^ 0x0FF0_0FF0_0FF0_0FF0).to_bytes(8, "big")
        mhex = mid.hex().upper()
        if mhex in store_set:
            i += 1
            continue
        if all(bloom_index(mid, r) in bits for r in range(BLOOM_HASHES)):
            return {"id": mhex, "indices": [bloom_index(mid, r) for r in range(BLOOM_HASHES)],
                    "probes": i - start + 1}
        i += 1
    raise AssertionError("no collision found within the probe bound")


def frame_for(st: Dict, msg_id: str, routing_tag: str) -> Dict:
    """The control frame as sent: the frozen envelope with control-only zero
    values (flags/ttl/hop), the frozen outer type code, the canonical
    payload -- struck by the independent wire_v2 reference codec."""
    payload = encode(st)
    raw = frame_encode(ARM_TYPECODE[st["arm"]], bytes.fromhex(msg_id),
                       bytes.fromhex(routing_tag), 0, 0, 0, payload)
    return {"arm": st["arm"], "type_code": ARM_TYPECODE[st["arm"]],
            "msg_id": msg_id.upper(), "routing_tag": routing_tag.upper(),
            "ttl": 0, "hop_count": 0, "flags": 0,
            "payload_hex": payload.hex().upper(), "frame_hex": raw.hex().upper()}
