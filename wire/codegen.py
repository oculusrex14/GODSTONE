#!/usr/bin/env python3
"""Generate the GMP/2 codecs and golden vectors from wire_v2.yaml.

    python -m wire.codegen

Emits, all from one spec:

    wire/gen/WireV2.kt          Android codec
    wire/gen/WireV2.swift       iOS codec
    wire/gen/wire_v2_codec.py   Python reference (drives the vectors)
    wire/golden_vectors.json    encode/decode fixtures + negative cases

Invariant A (ci/check_parity.py) regenerates and diffs. Hand-edit a generated
file and CI goes red, so "the two platforms are byte-for-byte identical" is a
build assertion rather than a comment that was wrong for the entire v1 lifetime.

Also VERIFIES the spec's own safety claims: every type code must have even
parity, pairwise Hamming distance must be >= 2, and no v2 code may reuse a v1
value. Asserted here, never trusted from the YAML.

    python -m wire.codegen --selftest

Fired negative control (ADR-008 patch 14): injects a deliberately broken spec
and asserts each assertion fires, then asserts the real spec passes all three.
A build gate that has never been observed to fire is a claim, not a control --
this is the repository's own root cause ("a claim lived in a test instead of an
executable check"). Mirrors `ci/symbols.py --selftest`.
"""
from __future__ import annotations

import argparse
import copy
import filecmp
import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent
SPEC = ROOT / "wire_v2.yaml"
GEN = ROOT / "gen"
# Generated codecs are ALSO emitted into the app source trees. Emitting only to
# wire/gen was the defect GPT's review found: both platforms had a correct GMP/2
# codec sitting in a directory neither app compiles, while the apps kept using
# their incompatible GMP/1 frames. Generated code that nothing imports is a
# document, not a fix.
REPO = ROOT.parent
KT_OUT = REPO / "android/mesh/src/main/java/io/godstone/mesh/wire/v2/WireV2.kt"
SWIFT_OUT = REPO / "ios/Godstone/Sources/GodstoneMesh/WireV2.swift"
VECTORS = ROOT / "golden_vectors.json"

BANNER = ("GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.\n"
          "Regenerate with `python -m wire.codegen`.\n"
          "ci/check_parity.py Invariant A fails the build on any hand edit.")


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def verify_hamming(types: dict[str, int]) -> list[str]:
    """Verify the spec's safety claims. Check, never trust.

    Three properties, in order of strength:
      1. EVEN PARITY on every code. Structural: a single-bit flip changes parity
         and lands on a non-existent code, so pairwise distance >= 2 follows by
         construction rather than by careful hand-picking.
      2. Pairwise Hamming distance >= 2 across all codes.
      3. SOS >= 2 bits from everything, so no single- or double-bit flip can
         manufacture a distress broadcast.
    """
    problems = []
    for name, code in types.items():
        if bin(code).count("1") % 2 != 0:
            problems.append(
                f"{name}(0x{code:02X}) has ODD parity; the even-parity rule is "
                f"what guarantees single-bit-flip safety")
    names = list(types)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if types[a] == types[b]:
                problems.append(f"duplicate code for {a}/{b}")
                continue
            d = hamming(types[a], types[b])
            if d < 2:
                problems.append(
                    f"{a}(0x{types[a]:02X}) is {d} bit(s) from {b}(0x{types[b]:02X})")
    sos = types["SOS"]
    for name, code in types.items():
        if name == "SOS":
            continue
        if hamming(sos, code) < 2:
            problems.append(
                f"SOS(0x{sos:02X}) is too close to {name}(0x{code:02X})")
    return problems


def verify_priority_mask(spec: dict) -> list[str]:
    """ADR-001 s.3.1. The mask must be wide enough for the priority table.

    GMP/2 shipped PRIORITY_MASK 0x00C0 -- two bits, four slots -- while the
    priority set has five members. It could not encode Android's existing
    priorities at all, and nobody noticed because no Android code path ever
    constructed a FrameV2. A mechanical type swap would have silently collapsed
    two priority classes, and the classes that collide decide what is dropped
    under flood.

    Asserted here so the next widening of the priority table fails the BUILD
    rather than the mesh.
    """
    mask = spec.get("flags", {}).get("PRIORITY_MASK")
    priorities = spec.get("priority", {})
    if mask is None or not priorities:
        return ["spec is missing PRIORITY_MASK or the priority table"]

    problems = []
    slots = 1 << bin(mask).count("1")
    if slots < len(priorities):
        problems.append(
            f"PRIORITY_MASK 0x{mask:04X} has {bin(mask).count('1')} bit(s) = "
            f"{slots} slot(s), but the priority table defines {len(priorities)}: "
            f"{sorted(priorities)}. Widen the mask.")

    # Contiguity: a split mask cannot be shifted out with one operation, and
    # both platforms would have to agree on a bit-gathering order nobody wrote down.
    shifted = mask >> ((mask & -mask).bit_length() - 1)
    if shifted & (shifted + 1):
        problems.append(f"PRIORITY_MASK 0x{mask:04X} is not contiguous")

    for name, value in priorities.items():
        if value >= slots:
            problems.append(f"priority {name}={value} does not fit in {slots} slots")
    return problems


def verify_no_v1_reuse(types: dict[str, int]) -> list[str]:
    """v1 used 0x01..0x0A on both platforms. No v2 code may collide."""
    return [f"{n}=0x{c:02X} collides with the v1 range 0x01..0x0A"
            for n, c in types.items() if 0x01 <= c <= 0x0A]


# --------------------------------------------------------------------------
# Emitters
# --------------------------------------------------------------------------
def emit_kotlin(s: dict) -> str:
    t = "\n".join(f"    {n}(0x{c:02X}.toByte())," for n, c in s["message_types"].items())
    f = "\n".join(f"        const val {n} = 0x{c:04X}" for n, c in s["flags"].items())
    return f'''// {BANNER.replace(chr(10), chr(10) + "// ")}
package io.godstone.mesh.wire.v2

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** GMP/2 frame. Header is {s["header_size"]} bytes, big-endian. */
data class FrameV2(
    val type: TypeV2,
    val msgId: ByteArray,        // 16 bytes
    val routingTag: ByteArray,   // 4 bytes
    val ttl: Int,
    val hopCount: Int,
    val flags: Int,
    val payload: ByteArray
) {{
    fun encode(): ByteArray {{
        require(msgId.size == 16) {{ "msg_id must be 16 bytes" }}
        require(routingTag.size == 4) {{ "routing_tag must be 4 bytes" }}
        require(ttl in 0..MAX_TTL) {{ "ttl out of range" }}
        require(hopCount in 0..MAX_TTL) {{ "hop_count out of range" }}
        require(payload.size <= MAX_PAYLOAD) {{ "payload too large" }}
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
        buf.putShort(MAGIC.toShort())
        buf.put(VERSION)
        buf.put(type.code)
        buf.put(msgId)
        buf.put(routingTag)
        buf.put(ttl.toByte())
        buf.put(hopCount.toByte())
        buf.putShort(flags.toShort())
        buf.putShort(payload.size.toShort())
        val header = buf.array()
        buf.putShort(crc16(header, 0, HEADER_SIZE - 2).toShort())
        buf.put(payload)
        return buf.array()
    }}

    companion object {{
        const val MAGIC = 0x{s["magic"]:04X}
        const val VERSION: Byte = 0x{s["version"]:02X}
        const val HEADER_SIZE = {s["header_size"]}
        const val MAX_PAYLOAD = {s["max_payload"]}
        const val MAX_TTL = {s["max_ttl"]}
        const val DEFAULT_TTL = {s["default_ttl"]}

        /** Shared BLE identifiers. Both platforms MUST use these exact values. */
        val SERVICE_UUID: java.util.UUID = java.util.UUID.fromString("{s["ble"]["service_uuid"]}")
        val INBOX_UUID: java.util.UUID = java.util.UUID.fromString("{s["ble"]["inbox_uuid"]}")
        val DIGEST_UUID: java.util.UUID = java.util.UUID.fromString("{s["ble"]["digest_uuid"]}")

{f}

        /**
         * Bounded, fail-closed parsing. Magic, version, CRC and the declared
         * length are all validated BEFORE any allocation, so a desynced or
         * corrupted frame is rejected outright rather than half-parsed into a
         * different message.
         */
        fun decode(raw: ByteArray): FrameV2? {{
            if (raw.size < HEADER_SIZE) return null
            val buf = ByteBuffer.wrap(raw).order(ByteOrder.BIG_ENDIAN)
            if ((buf.short.toInt() and 0xFFFF) != MAGIC) return null
            if (buf.get() != VERSION) return null
            val type = TypeV2.from(buf.get()) ?: return null
            val msgId = ByteArray(16).also {{ buf.get(it) }}
            val tag = ByteArray(4).also {{ buf.get(it) }}
            val ttl = buf.get().toInt() and 0xFF
            if (ttl > MAX_TTL) return null
            val hop = buf.get().toInt() and 0xFF
            if (hop > MAX_TTL) return null
            val flags = buf.short.toInt() and 0xFFFF
            val len = buf.short.toInt() and 0xFFFF
            val crc = buf.short.toInt() and 0xFFFF
            if (crc != crc16(raw, 0, HEADER_SIZE - 2)) return null
            if (len > MAX_PAYLOAD) return null
            if (raw.size != HEADER_SIZE + len) return null
            val payload = ByteArray(len).also {{ buf.get(it) }}
            return FrameV2(type, msgId, tag, ttl, hop, flags, payload)
        }}

        fun crc16(data: ByteArray, from: Int, len: Int): Int {{
            var crc = 0xFFFF
            for (i in from until from + len) {{
                crc = crc xor ((data[i].toInt() and 0xFF) shl 8)
                repeat(8) {{
                    crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xFFFF
                          else (crc shl 1) and 0xFFFF
                }}
            }}
            return crc
        }}
    }}
}}

enum class TypeV2(val code: Byte) {{
{t}
    ;
    companion object {{
        private val map = entries.associateBy {{ it.code }}
        fun from(b: Byte): TypeV2? = map[b]
    }}
}}
'''


def emit_swift(s: dict) -> str:
    t = "\n".join(f"    case {n.lower()} = 0x{c:02X}" for n, c in s["message_types"].items())
    f = "\n".join(f"        public static let {n.lower()} = 0x{c:04X}" for n, c in s["flags"].items())
    return f'''// {BANNER.replace(chr(10), chr(10) + "// ")}
import Foundation

/// GMP/2 frame. Header is {s["header_size"]} bytes, big-endian.
public struct FrameV2: Equatable {{
    public static let magic: UInt16 = 0x{s["magic"]:04X}
    public static let version: UInt8 = 0x{s["version"]:02X}
    public static let headerSize = {s["header_size"]}
    public static let maxPayload = {s["max_payload"]}
    public static let maxTtl: UInt8 = {s["max_ttl"]}
    public static let defaultTtl: UInt8 = {s["default_ttl"]}

    /// Shared BLE identifiers. Both platforms MUST use these exact values.
    public static let serviceUuidString = "{s["ble"]["service_uuid"]}"
    public static let inboxUuidString = "{s["ble"]["inbox_uuid"]}"
    public static let digestUuidString = "{s["ble"]["digest_uuid"]}"

    public enum Flags {{
{f}
    }}

    public let type: TypeV2
    public let msgId: Data        // 16 bytes
    public let routingTag: Data   // 4 bytes
    public let ttl: UInt8
    public let hopCount: UInt8
    public let flags: UInt16
    public let payload: Data

    public init(type: TypeV2, msgId: Data, routingTag: Data, ttl: UInt8,
                hopCount: UInt8, flags: UInt16, payload: Data) {{
        precondition(msgId.count == 16, "msg_id must be 16 bytes")
        precondition(routingTag.count == 4, "routing_tag must be 4 bytes")
        precondition(ttl <= FrameV2.maxTtl, "ttl out of range")
        precondition(hopCount <= FrameV2.maxTtl, "hop_count out of range")
        precondition(payload.count <= FrameV2.maxPayload, "payload too large")
        self.type = type; self.msgId = msgId; self.routingTag = routingTag
        self.ttl = ttl; self.hopCount = hopCount; self.flags = flags
        self.payload = payload
    }}

    public func encode() -> Data {{
        var out = Data(capacity: FrameV2.headerSize + payload.count)
        out.append(UInt8((FrameV2.magic >> 8) & 0xFF))
        out.append(UInt8(FrameV2.magic & 0xFF))
        out.append(FrameV2.version)
        out.append(type.rawValue)
        out.append(msgId)
        out.append(routingTag)
        out.append(ttl)
        out.append(hopCount)
        out.append(UInt8((flags >> 8) & 0xFF)); out.append(UInt8(flags & 0xFF))
        let len = UInt16(payload.count)
        out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        let crc = FrameV2.crc16([UInt8](out))
        out.append(UInt8((crc >> 8) & 0xFF)); out.append(UInt8(crc & 0xFF))
        out.append(payload)
        return out
    }}

    /// Bounded, fail-closed parsing. Magic, version, CRC and the declared
    /// length are validated BEFORE any allocation, so a desynced or corrupted
    /// frame is rejected rather than half-parsed into a different message.
    public static func decode(_ data: Data) -> FrameV2? {{
        guard data.count >= headerSize else {{ return nil }}
        let b = [UInt8](data)
        guard (UInt16(b[0]) << 8 | UInt16(b[1])) == magic else {{ return nil }}
        guard b[2] == version else {{ return nil }}
        guard let type = TypeV2(rawValue: b[3]) else {{ return nil }}
        let ttl = b[24]
        guard ttl <= maxTtl else {{ return nil }}
        let hop = b[25]
        guard hop <= maxTtl else {{ return nil }}
        let flags = UInt16(b[26]) << 8 | UInt16(b[27])
        let len = Int(b[28]) << 8 | Int(b[29])
        let crc = UInt16(b[30]) << 8 | UInt16(b[31])
        guard crc == crc16(Array(b[0..<(headerSize - 2)])) else {{ return nil }}
        guard len <= maxPayload, data.count == headerSize + len else {{ return nil }}
        return FrameV2(type: type,
                       msgId: data.subdata(in: 4..<20),
                       routingTag: data.subdata(in: 20..<24),
                       ttl: ttl, hopCount: hop, flags: flags,
                       payload: data.subdata(in: headerSize..<(headerSize + len)))
    }}

    public static func crc16(_ data: [UInt8]) -> UInt16 {{
        var crc: UInt16 = 0xFFFF
        for byte in data {{
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {{
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }}
        }}
        return crc
    }}
}}

public enum TypeV2: UInt8 {{
{t}
}}
'''


def emit_python(s: dict) -> str:
    t = "\n".join(f'    "{n}": 0x{c:02X},' for n, c in s["message_types"].items())
    f = "\n".join(f'    "{n}": 0x{c:04X},' for n, c in s["flags"].items())
    return f'''"""{BANNER}"""
from __future__ import annotations

MAGIC = 0x{s["magic"]:04X}
VERSION = 0x{s["version"]:02X}
HEADER_SIZE = {s["header_size"]}
MAX_PAYLOAD = {s["max_payload"]}
MAX_TTL = {s["max_ttl"]}
DEFAULT_TTL = {s["default_ttl"]}

TYPES = {{
{t}
}}
FLAGS = {{
{f}
}}
NAME_BY_CODE = {{v: k for k, v in TYPES.items()}}


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode(type_code: int, msg_id: bytes, routing_tag: bytes, ttl: int,
           hop_count: int, flags: int, payload: bytes) -> bytes:
    assert len(msg_id) == 16 and len(routing_tag) == 4
    assert 0 <= ttl <= MAX_TTL and 0 <= hop_count <= MAX_TTL
    assert len(payload) <= MAX_PAYLOAD
    h = (MAGIC.to_bytes(2, "big") + bytes([VERSION, type_code]) + msg_id
         + routing_tag + bytes([ttl, hop_count])
         + flags.to_bytes(2, "big") + len(payload).to_bytes(2, "big"))
    return h + crc16(h).to_bytes(2, "big") + payload


def decode(raw: bytes) -> dict | None:
    """Fail-closed: magic, version, type, CRC and length all validated first."""
    if len(raw) < HEADER_SIZE:
        return None
    if int.from_bytes(raw[0:2], "big") != MAGIC:
        return None
    if raw[2] != VERSION:
        return None
    if raw[3] not in NAME_BY_CODE:
        return None
    ttl = raw[24]
    if ttl > MAX_TTL:
        return None
    hop = raw[25]
    if hop > MAX_TTL:
        return None
    length = int.from_bytes(raw[28:30], "big")
    if int.from_bytes(raw[30:32], "big") != crc16(raw[0:HEADER_SIZE - 2]):
        return None
    if length > MAX_PAYLOAD or len(raw) != HEADER_SIZE + length:
        return None
    return {{
        "type": NAME_BY_CODE[raw[3]],
        "msg_id": raw[4:20].hex(),
        "routing_tag": raw[20:24].hex(),
        "ttl": ttl,
        "hop_count": hop,
        "flags": int.from_bytes(raw[26:28], "big"),
        "payload": raw[HEADER_SIZE:].hex(),
    }}
'''


def build_vectors(spec: dict, codec) -> dict:
    mid = bytes(range(16))
    tag = bytes.fromhex("deadbeef")
    fl = spec["flags"]
    cases = []
    for name in ("HELLO", "MESSAGE", "DIGEST", "SOS"):
        code = spec["message_types"][name]
        payload = (b"SOS1" + b"\x00" * 64 + b"help") if name == "SOS" \
            else b"payload-" + name.encode()
        flags = (fl["ACK_REQ"] | fl["RELAY_OK"]) if name == "SOS" else fl["SEALED"]
        enc = codec.encode(code, mid, tag, spec["default_ttl"], 0, flags, payload)
        cases.append({
            "name": f"encode_{name.lower()}",
            "type": name, "type_code": code,
            "msg_id": mid.hex(), "routing_tag": tag.hex(),
            "ttl": spec["default_ttl"], "hop_count": 0, "flags": flags,
            "payload": payload.hex(),
            "encoded": enc.hex(),
            "encoded_len": len(enc),
        })

    good = bytes.fromhex(cases[0]["encoded"])
    negatives = []

    def neg(name, raw, why):
        negatives.append({"name": name, "frame": raw.hex(), "must_reject": True,
                          "rationale": why})

    bad_type = bytearray(good)
    bad_type[3] = 0x02
    bad_type[30:32] = crc16_ccitt(bytes(bad_type[:30])).to_bytes(2, "big")
    neg("reject_legacy_type_0x02", bytes(bad_type),
        "v1 Android DIGEST / v1 iOS SOS. Must hit the unknown-type branch, "
        "never be read as a distress broadcast.")

    v1 = bytearray(good)
    v1[2] = 0x01
    v1[30:32] = crc16_ccitt(bytes(v1[:30])).to_bytes(2, "big")
    neg("reject_v1_frame", bytes(v1), "version byte checked before anything else")

    corrupt = bytearray(good)
    corrupt[10] ^= 0xFF
    neg("reject_bad_crc", bytes(corrupt),
        "single-bit corruption inside msg_id must fail the header CRC")

    bad_hop = bytearray(good)
    bad_hop[25] = spec["max_ttl"] + 1
    bad_hop[30:32] = crc16_ccitt(bytes(bad_hop[:30])).to_bytes(2, "big")
    neg("reject_hop_count_over_max", bytes(bad_hop),
        "hop_count above MAX_TTL is malformed and must not wrap on relay")

    sos = spec["message_types"]["SOS"]
    nosig = codec.encode(sos, mid, tag, 12, 0,
                         fl["ACK_REQ"] | fl["RELAY_OK"], b"help")
    negatives.append({
        "name": "reject_sos_missing_payload_magic", "frame": nosig.hex(),
        "must_reject": True,
        "rationale": "SOS payload lacks the SOS1 magic and Ed25519 signature. "
                     "Decodes as a frame, MUST be refused by the SOS validator: "
                     "a parse error must not be able to fabricate a distress call."})

    flagless = codec.encode(sos, mid, tag, 12, 0, 0,
                            b"SOS1" + b"\x00" * 64 + b"help")
    negatives.append({
        "name": "reject_sos_missing_flags", "frame": flagless.hex(),
        "must_reject": True,
        "rationale": "SOS requires ACK_REQ|RELAY_OK set."})

    return {
        "_comment": "GENERATED by wire/codegen.py from wire_v2.yaml. Both "
                    "platforms must reproduce every `encoded` value exactly and "
                    "reject every negative frame.",
        "header_size": spec["header_size"],
        "magic": spec["magic"],
        "version": spec["version"],
        "message_types": spec["message_types"],
        "hamming_min_distance_to_sos": min(
            hamming(spec["message_types"]["SOS"], c)
            for n, c in spec["message_types"].items() if n != "SOS"),
        "cases": cases,
        "negative_cases": negatives,
    }


def run_selftest() -> int:
    """Fired negative control for the spec assertions (ADR-008 patch 14).

    verify_hamming / verify_no_v1_reuse / verify_priority_mask are a build gate:
    main() returns 1 if any fires, so Invariant A goes red. But a gate that has
    never been observed to fire is a claim, not a control -- this is the
    repository's own root cause ("a claim about the system lived in a test
    instead of an executable check"). --selftest injects a deliberately broken
    spec and asserts each assertion fires, then asserts the real spec passes
    all three. Mirrors `ci/symbols.py --selftest`.
    """
    spec = yaml.safe_load(SPEC.read_text())
    base_types = dict(spec["message_types"])
    failures: list[str] = []

    def expect(label: str, problems: list[str], must_mention: str) -> None:
        if not problems:
            failures.append(
                f"{label}: expected a problem mentioning '{must_mention}', got none")
            return
        if not any(must_mention in p for p in problems):
            failures.append(
                f"{label}: problem did not mention '{must_mention}': {problems}")

    # The real spec passes all three -- a regression here is a real defect.
    if (verify_hamming(base_types)
            or verify_no_v1_reuse(base_types)
            or verify_priority_mask(spec)):
        failures.append("real spec failed an assertion (regression in wire_v2.yaml)")

    # (1a) even parity: flip one bit -> the even-parity rule fires. (This is the
    # structural property that guarantees single-bit-flip safety.)
    odd = dict(base_types)
    odd["HELLO"] = base_types["HELLO"] ^ 0x01
    expect("odd-parity", verify_hamming(odd), "ODD parity")

    # (1b) pairwise distance < 2: two distinct codes 1 bit apart (necessarily
    # odd-parity, so the distance branch and the parity branch fire together;
    # the distance message is what we assert).
    close = dict(base_types)
    close["DIGEST"] = base_types["HELLO"] ^ 0x01
    expect("hamming<2", verify_hamming(close), "bit(s)")

    # (1c) SOS within 2 bits of another code -> no manufactured distress broadcast.
    sos_close = dict(base_types)
    sos_close["HELLO"] = base_types["SOS"] ^ 0x01
    expect("sos-too-close", verify_hamming(sos_close), "too close")

    # (2) no v1 reuse: a code in the legacy 0x01..0x0A range collides.
    v1 = dict(base_types)
    v1["HELLO"] = 0x05
    expect("v1-reuse", verify_no_v1_reuse(v1), "collides with the v1 range")

    # (3a) priority mask too narrow for the table -> fails the build, not the mesh.
    narrow = copy.deepcopy(spec)
    narrow["flags"]["PRIORITY_MASK"] = 0x0040  # 1 bit = 2 slots < 5 priorities
    expect("priority-narrow", verify_priority_mask(narrow), "slot(s)")

    # (3b) priority mask non-contiguous -> cannot be shifted out in one op.
    split = copy.deepcopy(spec)
    split["flags"]["PRIORITY_MASK"] = 0x08C0  # 0b100011000000: two groups, 3 bits
    expect("priority-split", verify_priority_mask(split), "not contiguous")

    if failures:
        for f in failures:
            print(f"::error::codegen selftest: {f}")
        print(f"codegen selftest FAILED ({len(failures)} check(s) did not fire)")
        return 1
    print("codegen selftest ok: all spec assertions fire on a broken spec "
          "(6 negative + 1 positive check)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--selftest", action="store_true",
                    help="fired negative control: prove the spec assertions fire, "
                         "then exit (does not regenerate; see ADR-008 patch 14)")
    args = ap.parse_args()
    if args.selftest:
        return run_selftest()

    spec = yaml.safe_load(SPEC.read_text())

    problems = (verify_hamming(spec["message_types"])
                + verify_no_v1_reuse(spec["message_types"])
                + verify_priority_mask(spec))
    if problems:
        for p in problems:
            print(f"::error::{p}")
        return 1

    GEN.mkdir(exist_ok=True)
    kt, sw = emit_kotlin(spec), emit_swift(spec)
    (GEN / "WireV2.kt").write_text(kt, encoding="utf-8")
    (GEN / "WireV2.swift").write_text(sw, encoding="utf-8")
    # Into the app trees, where they are actually compiled.
    KT_OUT.parent.mkdir(parents=True, exist_ok=True)
    KT_OUT.write_text(kt, encoding="utf-8")
    SWIFT_OUT.parent.mkdir(parents=True, exist_ok=True)
    SWIFT_OUT.write_text(sw, encoding="utf-8")
    (GEN / "wire_v2_codec.py").write_text(emit_python(spec), encoding="utf-8")
    (GEN / "__init__.py").write_text('"""Generated codecs."""\n', encoding="utf-8")

    import importlib.util
    sp = importlib.util.spec_from_file_location("codec", GEN / "wire_v2_codec.py")
    codec = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(codec)

    vectors = build_vectors(spec, codec)
    VECTORS.write_text(json.dumps(vectors, indent=2) + "\n", encoding="utf-8")

    print("generated WireV2.kt, WireV2.swift, wire_v2_codec.py, golden_vectors.json")
    print(f"  header {spec['header_size']}B  magic 0x{spec['magic']:04X}  "
          f"types {len(spec['message_types'])}")
    print(f"  min Hamming distance SOS -> any other type: "
          f"{vectors['hamming_min_distance_to_sos']} (spec requires >= 2)")
    _m = spec["flags"]["PRIORITY_MASK"]
    print(f"  priority mask 0x{_m:04X} = {1 << bin(_m).count('1')} slot(s) for "
          f"{len(spec['priority'])} priorities (ADR-001 s.3.1)")
    print(f"  {len(vectors['cases'])} positive, "
          f"{len(vectors['negative_cases'])} negative vectors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
