#!/usr/bin/env python3
"""Structural integration checks for shipping paths and fail-closed gates.

    python ci/integration.py             # check the tree
    python ci/integration.py --selftest  # prove the check fires

V4 REBUILD. The V3 version was a substring grep, and substring greps match
comments. Measured on the V3 tree it reported **0 findings** on a repository
that does not compile on either platform, while:

    Retriever.kt:39   `SafetyGate.evaluate` appeared ONLY in a doc comment,
                      and G4 was `if "SafetyGate.evaluate" not in kr`.
                      The gate passed on prose.
    MessageStore.kt:11 imported `net.sqlcipher.*`, the LEGACY package, which is
                      a compile error against the declared artifact -- and G8
                      checked for the substring "net.sqlcipher" as PROOF of
                      encryption, so the wrong import was what made it pass.

Both are the repository's own thesis one level up: a control that observes text
instead of execution. See ci/mutations.py for the standing negative controls.

WHAT CHANGED
    * comments are stripped before any match
    * a "must call X" check requires a call SITE (receiver + parens), not a mention
    * G6 compares the IDF FORMULA across ports, not only the four floor constants
    * G8 inverts: the legacy package is now evidence of the DEFECT, not the fix
    * new Invariant H: no cross-platform interop claim without a passing vector
    * new Invariant K: model acquisition is lockfile-driven and fails closed

HONEST LIMIT unchanged from V3: this is structural analysis over source text,
not a compiler or a call graph. It proves the wiring is PRESENT. Only
`./gradlew build`, `xcodebuild` and two devices in a room prove it is correct.
"""
from __future__ import annotations
import argparse, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

_BLOCK = re.compile(r"/\*.*?\*/", re.S)
_LINE = re.compile(r"//[^\n]*")


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="ignore") if p.exists() else ""


def code(p: Path) -> str:
    """Source with comments removed.

    This single function is the difference between G4 passing on a doc comment
    and G4 failing on a missing call. Approximate w.r.t. comment markers inside
    string literals, which is acceptable here: the failure mode is a false
    POSITIVE (we complain about a working call), which is loud and gets fixed,
    not a false negative, which is silent and shipped.
    """
    return _LINE.sub("", _BLOCK.sub("", read(p)))


def calls(src: str, symbol: str) -> bool:
    """True when `symbol` appears as an actual call, not a mention.

    Requires an open paren, so `SafetyGate.evaluate` in prose or in an import
    no longer satisfies a 'must call' check.
    """
    return re.search(re.escape(symbol) + r"\s*\(", src) is not None


def check(root: Path) -> list[str]:
    bad: list[str] = []

    kt_ble = root / "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt"
    sw_ble = root / "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift"
    kt_retr = root / "android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt"
    sw_rag = root / "ios/Godstone/Sources/GodstoneLLM/RagPipeline.swift"
    router = root / "android/mesh/src/main/java/io/godstone/mesh/router/Router.kt"
    store = root / "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt"

    # -- G1: the generated codec must live INSIDE the app source trees --------
    for gen in ("android/mesh/src/main/java/io/godstone/mesh/wire/v2/WireV2.kt",
                "ios/Godstone/Sources/GodstoneMesh/WireV2.swift"):
        if not (root / gen).exists():
            bad.append(f"G1 {gen} missing -- codegen must emit into the app tree, "
                       f"not only into wire/gen where nothing compiles it")

    # -- G2: no legacy GMP/1 identifiers on the transport path ----------------
    for path, label in ((kt_ble, "android"), (sw_ble, "ios")):
        src = code(path)
        for lit in ("67640001-1000-8000", "6F0D0001-9A5E"):
            if lit in src:
                bad.append(f"G2 {label}: legacy BLE service UUID {lit} on the "
                           f"transport path -- the platforms cannot discover each other")
        if not re.search(r"FrameV2\.(SERVICE_UUID|serviceUuidString)", src):
            bad.append(f"G2 {label}: BLE UUID is not taken from the generated spec")

    # -- G3: no plaintext send path, and a session must be establishABLE ------
    kt = code(kt_ble)
    if not re.search(r"sessions\??\.seal\s*\(", kt):
        bad.append("G3 android: BleTransport.send does not route through a Noise "
                   "session -- the mesh would transmit plaintext")
    sw = code(sw_ble)
    if not re.search(r"sessions\??\.seal\s*\(", sw):
        bad.append("G3 ios: BleTransport.send does not route through a Noise session")

    # A seal path with no way to REACH an established session is not encryption,
    # it is a permanently failing send. V3 had exactly this and G3 was green.
    for rel, label in (
        ("android/mesh/src/main/java/io/godstone/mesh/crypto/SessionManager.kt", "android"),
        ("ios/Godstone/Sources/GodstoneMesh/SessionManager.swift", "ios"),
    ):
        p = root / rel
        if not p.exists():
            bad.append(f"G3 {label}: no SessionManager -- NoiseSession is constructed by nothing")
            continue
        s = code(p)
        for verb in ("beginInitiator", "beginResponder"):
            if not re.search(r"fun\s+" + verb + r"|func\s+" + verb, s):
                bad.append(f"G3 {label}: SessionManager declares no {verb}")

    # -- G4: the apps must RUN the gate -- a mention is not a call ------------
    kr = code(kt_retr)
    if not calls(kr, "SafetyGate.evaluate"):
        bad.append("G4 android: Retriever does not CALL SafetyGate.evaluate "
                   "(V3 satisfied this check with a doc comment)")
    if re.search(r"bestScore\s*>=\s*CONFIDENCE_THRESHOLD", kr):
        bad.append("G4 android: still gating on the RRF 0.35 floor the audit condemned")
    sr = code(sw_rag)
    if not calls(sr, "SafetyGate.evaluate"):
        bad.append("G4 ios: RagPipeline does not CALL SafetyGate.evaluate")

    # -- G5: query embedding must use the ARCHIVE's model ---------------------
    if "ModelManager.shared.ensureLoaded())?.embed" in sr:
        bad.append("G5 ios: query embedded with the Qwen GENERATION model while the "
                   "archive's vectors are BGE -- different spaces, so every score is noise")
    if not (root / "android/llm/src/main/java/io/godstone/llm/rag/Embedder.kt").exists():
        bad.append("G5 android: Retriever references an Embedder that does not exist")

    # -- G6: gate PARITY -- constants AND the formula -------------------------
    py = read(root / "safety/gate.py")
    ktg = read(root / "android/llm/src/main/java/io/godstone/llm/safety/SafetyGate.kt")
    swg = read(root / "ios/Godstone/Sources/GodstoneCore/SafetyGate.swift")
    for name, pk, kk, sk in (
            ("anchor_recall", "anchor_recall_floor", "ANCHOR_RECALL_FLOOR", "anchorRecallFloor"),
            ("colocation", "colocation_floor", "COLOCATION_FLOOR", "colocationFloor"),
            ("domain_coherence", "domain_coherence_floor", "DOMAIN_COHERENCE_FLOOR", "domainCoherenceFloor"),
            ("caveat_margin", "caveat_margin", "CAVEAT_MARGIN", "caveatMargin")):
        vals = {}
        if (m := re.search(rf'"{pk}":\s*([0-9.]+)', py)):  vals["python"] = float(m.group(1))
        if (m := re.search(rf"{kk}\s*=\s*([0-9.]+)", ktg)): vals["kotlin"] = float(m.group(1))
        if (m := re.search(rf"{sk}\s*=\s*([0-9.]+)", swg)): vals["swift"] = float(m.group(1))
        if len(set(vals.values())) > 1:
            bad.append(f"G6 gate constant {name} disagrees across ports: {vals}")

    # The V3 iOS defect was NOT a constant. Every floor matched; the IDF equation
    # did not, through Swift operator precedence, and the rare/common weight
    # ratio collapsed from 9.39x to 2.90x. Constants-only parity cannot see that.
    if swg and not re.search(r"idf\[t\]\s*=\s*log\(\s*\(", swg):
        bad.append("G6 ios: SafetyGate IDF is not the parenthesised form. Swift "
                   "closes log() after the numerator and then divides, which is a "
                   "DIFFERENT EQUATION from gate.py and SafetyGate.kt -- the same "
                   "question can refuse on Android and answer on iOS")

    # -- G7: documented layers must be REACHABLE ------------------------------
    r = code(router)
    if not calls(r, "SealedSender.seal"):
        bad.append("G7 sealed sender (PROTOCOL.md s.6) is implemented but the router "
                   "never calls it -- relays would still see who talks to whom")
    if not calls(r, "governor.allowInbound"):
        bad.append("G7 anti-abuse governor (PROTOCOL.md s.8) is implemented but the "
                   "router never calls it -- inbound rate is unbounded")

    # -- G8: the store must be encrypted. INVERTED from V3. -------------------
    st = code(store)
    if "net.sqlcipher" in st:
        bad.append("G8 message store imports the LEGACY net.sqlcipher package. The "
                   "declared sqlcipher-android artifact ships "
                   "net.zetetic.database.sqlcipher.* -- this does not compile. V3 "
                   "treated this exact string as PROOF the store was encrypted")
    if "net.zetetic.database.sqlcipher" not in st:
        bad.append("G8 message store does not import SQLCipher at all")
    if "android.database.sqlite.SQLiteDatabase" in st:
        bad.append("G8 message store still imports the plaintext SQLite engine")

    # -- H: no interop claim until the decision is ACCEPTED **and** SHIPPED ---
    #
    # ADR-001 and ADR-002 are ACCEPTED as of V4. ACCEPTED IS NOT IMPLEMENTED, and
    # this invariant is written so that accepting an ADR cannot by itself unlock
    # the claim -- otherwise "write the decision down" becomes a way to make the
    # gate green, which is this repository's entire failure mode wearing a hat.
    #
    # Both conditions are required:
    #   (a) ADR-001 says ACCEPTED, and
    #   (b) both routers actually operate on the SAME canonical frame type.
    #
    # Today (a) holds and (b) does not: iOS Router is FrameV2, Android Router is
    # v1 Frame. So any interop claim still fails.
    adr = read(root / "docs/adr/ADR-001-canonical-wire.md")
    decided = "STATUS: ACCEPTED" in adr

    kt_router = code(root / "android/mesh/src/main/java/io/godstone/mesh/router/Router.kt")
    sw_router = code(root / "ios/Godstone/Sources/GodstoneMesh/Router.swift")
    kt_v2 = "FrameV2" in kt_router
    sw_v2 = "FrameV2" in sw_router
    implemented = kt_v2 and sw_v2

    claims = []
    for doc in ("README.md", "docs/mesh/PROTOCOL.md", "docs/packaging/STORE.md",
                "BUILD_REPORT.md"):
        t = read(root / doc).lower()
        for phrase in ("byte-for-byte identical", "the two platforms interoperate",
                       "cross-platform frame round-trip passes",
                       "android and ios can now talk"):
            if phrase in t:
                claims.append(f"{doc}: '{phrase}'")

    if claims and not (decided and implemented):
        why = []
        if not decided:
            why.append("ADR-001 is not ACCEPTED")
        if not implemented:
            why.append(f"routers disagree on the frame type "
                       f"(android FrameV2={kt_v2}, ios FrameV2={sw_v2})")
        bad.append("H interop is claimed in documentation but " + " and ".join(why)
                   + ": " + "; ".join(claims))

    # The mirror check: a canonical type on BOTH sides with the decision still
    # OPEN means someone migrated the wire without writing down what they chose.
    if implemented and not decided:
        bad.append("H both routers use the canonical frame type while ADR-001 is "
                   "still OPEN -- the wire was migrated without a recorded decision")

    # -- I: platform ports, not only Python models, must own vector tests ------
    swift_vectors = read(root / "ios/Godstone/Tests/GodstoneMeshTests/PortVectorTests.swift")
    kotlin_vectors = read(root / "android/mesh/src/test/java/io/godstone/mesh/PortVectorTest.kt")
    for label, src in (("ios", swift_vectors), ("android", kotlin_vectors)):
        if "69217a3079908094" not in src or "508c5e8c327c14e2" not in src:
            bad.append(f"I {label}: shipping BLAKE2s port has no RFC/generated-vector test")
        if not all(size in src for size in ("32", "96", "64")):
            bad.append(f"I {label}: Noise XX port test does not assert canonical message sizes")

    # -- J: unfinished radio stacks must remain mechanically fail-closed -------
    # ADR-001/002 are accepted but M1-wire/M2-link are not implemented. The UI
    # and service must therefore keep the radio feature flag false. This check
    # prevents a future cosmetic flip from re-enabling plaintext/dead transports.
    android_node = code(root / "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt")
    ios_node = code(root / "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift")
    android_ready = bool(re.search(r"LINK_LAYER_READY\s*=\s*true", android_node))
    ios_ready = bool(re.search(r"linkLayerReady\s*=\s*true", ios_node))
    if (android_ready or ios_ready) and not implemented:
        bad.append("J mesh link was enabled before both routers use the canonical frame type")
    if android_ready != ios_ready:
        bad.append("J mesh availability differs across platforms; one UI would claim a link the other disables")

    # -- K: model acquisition must be lockfile-driven and fail closed ---------
    lock_path = root / "docs/packaging/MODELS.lock.json"
    fetch_path = root / "scripts/fetch_models.sh"
    if not lock_path.exists():
        bad.append("K model lock is missing")
    else:
        import json
        try:
            lock = json.loads(read(lock_path))
        except Exception as exc:
            bad.append(f"K model lock is invalid JSON: {exc}")
        else:
            status = lock.get("status")
            if status not in {"UNPINNED", "PINNED"}:
                bad.append(f"K model lock has invalid status {status!r}")
            artifacts = lock.get("artifacts")
            if not isinstance(artifacts, list) or not artifacts:
                bad.append("K model lock contains no artifacts")
            elif status == "PINNED":
                if not lock.get("verified_on") or not lock.get("verified_by"):
                    bad.append("K PINNED model lock lacks verifier metadata")
                for item in artifacts:
                    sha = item.get("sha256") if isinstance(item, dict) else None
                    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
                        bad.append(f"K PINNED model artifact lacks a valid sha256: {item}")
                        break
            elif any(isinstance(item, dict) and item.get("sha256") for item in artifacts):
                bad.append("K UNPINNED model lock contains checksum-looking values; "
                           "either verify all artifacts and mark PINNED or leave them null")

    fetch = code(fetch_path)
    if 'lock.get("status") != "PINNED"' not in fetch and "status') != 'PINNED'" not in fetch:
        bad.append("K fetch_models.sh does not refuse an unpinned lock")
    if "MODELS=(" in fetch:
        bad.append("K fetch_models.sh still hard-codes model coordinates/hashes outside the lock")

    return bad


def warnings(root: Path) -> list[str]:
    """Genuinely-absent artefacts, never a gate failure: a check that cries wolf
    is a check people learn to ignore."""
    out = []
    if not (root / "android/gradle/wrapper/gradle-wrapper.jar").exists():
        out.append("gradle-wrapper.jar absent (binary; see gradle/wrapper/README.md)")
    if not (root / "third_party/llama.cpp").exists():
        out.append("third_party/llama.cpp absent and unpinned")
    if not (root / ".gitmodules").exists():
        out.append("native dependency has no .gitmodules gitlink or verified archive lock")
    return out


def selftest(root: Path) -> int:
    """Delegates to the mutation corpus, which is the real negative control."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("mut", root / "ci" / "mutations.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.run(report_only=False)


def main() -> int:
    ap = argparse.ArgumentParser(description="Invariant G: integration reachability")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest(ROOT)
    bad = check(ROOT)
    for w in warnings(ROOT):
        print("  warn  " + w)
    for b in bad:
        print("  ORPHANED  " + b)
    print(f"integration checks: {len(bad)} finding(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
