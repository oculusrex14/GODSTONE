#!/usr/bin/env python3
"""GS-INTEGRATION-001 `real-adapters` (step 5.5/5.6): THE CROSS-PLATFORM INTEGRATION COORDINATOR.

    tools/readiness/run_board1_integration.py --mode all|crash|cross-platform --evidence-dir PATH

*** THE CLAUSE THIS FILE ANSWERETH, IN THE PLAN'S OWN WORDS: "launches Swift/macOS and Android/Robolectric
workers, relays exact characteristic bytes between their OS facades, and records a length-delimited binary
transcript plus a separate metadata manifest." ***

WHY A COORDINATOR IS NECESSARY, RATHER THAN A THIRD TEST. The two real-transport rigs
(`ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift` and
`android/mesh/src/test/java/io/godstone/mesh/rig/RealTransportHostRig.kt`) each substitute exactly ONE thing -- the
radio -- and re-enter the OTHER side's REAL CoreBluetooth / Android-OS entry points. **PROVING THAT AN iOS OS FACADE
AND AN ANDROID OS FACADE CAN CARRY ONE ANOTHER'S BYTES REQUIRES TWO PROCESSES AND A REAL WIRE BETWEEN THEM**, and
the wire has to carry the *exact* bytes each facade handed its stack -- never a re-serialised or re-encoded copy.

*** THE ONE LAW THIS COORDINATOR OBEYS, NAMED BECAUSE IT IS THE WHOLE POINT: ***
    **IT NEVER DECODES, INTERPRETS OR RE-ENCODES A PROTOCOL PAYLOAD.**
*A payload crosses this process as an opaque octet string. The coordinator frames it with a length prefix, records
its bytes verbatim, and hands them on untouched.* The only bytes it ever alters are the deliberately-tampered control
records, and even there it flips ONE octet at an offset derived from the LENGTH -- it never reads the payload's
meaning. **A coordinator that could parse a frame would be able to manufacture one.**

THE PROTOCOL (both directions of every pipe, identical framing):

    u32be header_length | header_length octets of canonical JSON | u32be payload_length | payload

*The header carrieth the versioned metadata (`v`, `kind`, `platform`, `role`, `variant`, plus per-kind keys); the
payload carrieth the uninterpreted bytes.* **A reader that does not know the header's keys can still frame the
stream**, which is exactly why the framing is length-delimited rather than newline-delimited: a protocol payload may
contain any octet, including newlines and NULs.

THE MODES:

  * `cross-platform` -- the two live foreign-platform directions:
        iOS sender     -> Android recipient -> iOS ACK
        Android sender -> iOS recipient     -> Android ACK
    Each receiver must prove its DURABLE row (the exact `msgId`, read from its own on-disk store); each sender must
    prove its DELIVERY transition (DELIVERED), not merely that bytes crossed.
  * `crash` -- the durable-boundary recovery campaign: the macOS child-process SIGKILL campaign (the authoritative
    abrupt-death proof) plus the Android durable-boundary recovery worker, which halts its own JVM immediately after
    a durable owner returns and proves the surviving state from a FRESH JVM over the same estate.
  * `all` -- both.

THE CONTROLS, PER DIRECTION (each must be REFUSED at the actual handshake/record boundary, with no extra committed
inbox row and no false DELIVERED):

  (a) honest control;
  (b) an ALTERED authenticated DATA record -- one octet flipped;
  (c) a MISMATCHED advertised identity -- the sender advertises a well-formed hint that is NOT its own;
  (d) an OLD-SESSION record after a reconnect -- bytes captured from a PRIOR session, replayed into a LIVE, FRESHLY
      NEGOTIATED one over a FRESH estate. **Ciphertext from an unrelated Noise session is not an interchangeable
      fixture, and a replay into the session it came from would prove nothing at all.**

REFUSALS ARE FIRST-CLASS OUTCOMES: a missing worker, a missing marker, a timeout or an early exit ends the run with
a non-zero status and a NAMED reason. **A run that could not execute its workers is never reported as a pass.**
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform as platform_module
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_provenance

REPO = Path(__file__).resolve().parents[2]

SCHEMA_VERSION = 1
PROTOCOL_VERSION = 1

# ---------------------------------------------------------------------------------------------------------------
# The worker contract. ONE key space for both platforms, so a manifest row never needs a platform-specific reader.
# ---------------------------------------------------------------------------------------------------------------

ROLE_ENV = "GS_INTEGRATION_ROLE"
IN_ENV = "GS_INTEGRATION_IN"
OUT_ENV = "GS_INTEGRATION_OUT"
ROOT_ENV = "GS_INTEGRATION_ROOT"
VARIANT_ENV = "GS_INTEGRATION_VARIANT"
DEADLINE_ENV = "GS_INTEGRATION_DEADLINE_S"
PROP_PREFIX = "godstone.integration."

ANDROID_ROLE_PROP = PROP_PREFIX + "role"
ANDROID_VARIANT_PROP = PROP_PREFIX + "variant"
ANDROID_ROOT_PROP = PROP_PREFIX + "root"
ANDROID_DEADLINE_PROP = PROP_PREFIX + "deadlineSeconds"
ANDROID_IN_PROP = PROP_PREFIX + "in"
ANDROID_OUT_PROP = PROP_PREFIX + "out"

IOS_TO_ANDROID = "ios->android"
ANDROID_TO_IOS = "android->ios"


def flip_direction(direction: str) -> str:
    """THE OPPOSITE DIRECTION. *The relay pump driveth BOTH ways, so it needeth the reverse of whichever it was
    given -- and the expression that computed it was DEGENERATE (`ANDROID_TO_IOS if x == IOS_TO_ANDROID else
    ANDROID_TO_IOS`, both arms the same), so an `android->ios` run pumpeth `android->ios` in both slots and the
    reverse leg never carried anything. It is one function now, so the two call sites cannot drift apart again.*"""
    return ANDROID_TO_IOS if direction == IOS_TO_ANDROID else IOS_TO_ANDROID

CONTROLS = ("honest", "altered", "mismatched", "replay")
# *** THE BOUNDARIES THE ANDROID MIRROR WALKETH. *** *The macOS isle's child-process campaign walketh the plan's full
# step-6 table (`outboundEnqueue`, `inboundCommit`, `ackCreate`, `ackCommit`, `senderAckRetire`, `preSend`,
# `handshake`), and the Android mirror walks the two the host store's own roads reach directly -- `outboundEnqueue`
# (the atomic held+delivery enqueue) and `inboundCommit` (the atomic held+obligation pair). **`ackCommit` and
# `senderAckRetire` are NOT claimed here: they are reached by the macOS campaign, and pretending otherwise would be
# a boundary that never fired.***
CRASH_BOUNDARIES = ("outboundEnqueue", "inboundCommit")

#: The crash roles the committed Android worker dispatch eth to `CrashRoles` by the RAW role name, and whose own
#: `Marker` (below) is the only party that speaketh them. **The coordinator's requested role and the worker's
#: reported role are therefore the SAME string, and `require_reported_identity` compareth them directly rather than
#: through a translation that could hide a substitution.**

# *** THE ANDROID PREPARE JVM'S OWN HALT STATUS, WHICH IS *NOT* THE GRADLE WRAPPER'S EXIT CODE. ***
#
# *`Runtime.getRuntime().halt(137)` terminateth the forked test-executor JVM with status 137. **Gradle DOES NOT
# PROPAGATE THAT CODE**: the build fail-eth with wrapper `rc=1` ("Process 'Gradle Test Executor N' finished with
# non-zero exit value 137") -- MEASURED on this host. **So demanding `wrapper_rc == 137` would make every honest
# crash arm fail; what must be proven is that the ACTUAL EXECUTOR CHILD died abruptly with 137, bound to its actual
# PID, and that the coordinator never supplied the death.***
GRADLE_EXECUTOR_ABRUPT_STATUS = 137
GRADLE_EXECUTOR_PID_MARKER = "GS_INTEGRATION_EXECUTOR_PID="
GRADLE_EXECUTOR_HALT_LINE = "GS_INTEGRATION_ABOUT_TO_HALT"
#: *** THE MARKER IS A DECLARATION WITH A SHAPE, NOT A WORD ON A LINE. *** *The committed worker prints
#: `GS_INTEGRATION_ABOUT_TO_HALT boundary=<stage> code=<haltStatus>` from the real JDK `ProcessHandle` pid
#: immediately BEFORE `Runtime.halt`; a line that merely CONTAINETH the word is a print, not the declaration, and
#: the parser refuseth it.*
EXECUTOR_HALT_MARKER_RE = re.compile(
    r"GS_INTEGRATION_ABOUT_TO_HALT boundary=(\S+) code=(\d+)")
#: Gradle's own reporting of the abrupt child, as `-i` printeth it. *Named so the log proof is a FACT about the
#: executor, not a guess about the wrapper.*
GRADLE_EXECUTOR_ABRUPT_RE = re.compile(
    r"Gradle Test Executor \d+.*?finished with non-zero exit value (\d+)")

EXECUTOR_STATUS_RE = re.compile(r"GS_INTEGRATION_HALT_STATUS=(\d+)")
#: The pid `Process.myPid()` returneth under a Robolectric shadow -- NOT a real OS pid. *A marker bound to it
#: describeth a simulated context, so the coordinator treateth it as the absence of a pid.*
ROBOLECTRIC_SHADOW_PID = 10000
INTENTIONAL_HALT_RE = re.compile(r"GS_INTEGRATION_INTENTIONAL_HALT status=(\d+)")

#: *** THE ONLY ACCEPTED NON-ZERO WITNESS EXIT, AND IT IS EVIDENCE-BOUNDED. *** *A worker may end a cross-platform
#: run with exit 0 after its verdict, or with its OWN typed intentional halt -- which must LEAVE A TRACE in the
#: worker's retained log: the marker line naming the very status the process then returneth. The finder returneth
#: the full marker line (so the report carrieth the text), or None when no such line binds the observed death.*
def _find_intentional_halt(log_path: Path, status: int) -> Optional[str]:
    if status == 0:
        return None
    try:
        text = Path(log_path).read_text(errors="replace")
    except OSError:
        return None
    for match in INTENTIONAL_HALT_RE.finditer(text):
        if int(match.group(1)) != status:
            continue
        line_start = text.rfind("\n", 0, match.start()) + 1
        line_end = text.find("\n", match.end())
        return text[line_start:len(text) if line_end == -1 else line_end].strip()
    return None

SWIFT_WORKER_SELECTOR = "GodstoneMeshTests.GsIntegration001CrossPlatformWorkerTests/testGSINT001CrossPlatformWorker"
SWIFT_CRASH_SELECTOR = "GodstoneMeshTests.GsIntegration001ProcessTests/testGSINT001ProcessCrashCampaign"
SWIFT_BUNDLE_NAME = "GodstoneMeshTests.xctest"
ANDROID_WORKER_TASK = ":mesh:board1IntegrationWorker"
ANDROID_WORKER_CLASS = "io.godstone.mesh.rig.RealTransportHostRigWorkerTest"

# *** THE CRASH ROLES RUN THROUGH THE SAME COMMITTED WORKER TASK AND CLASS AS EVERY OTHER ROLE. ***
#
# *THE DEFECT THIS CLOSES: the crash roles were NAMED BY ENVIRONMENT (`GS_ANDROID_CRASH_TASK` /
# `GS_ANDROID_CRASH_CLASS`), so an ARBITRARY worker could be substituted for the one the plan names WITHOUT anything
# in the evidence recording it -- and the manifest's `worker_launches` would carry whichever task the environment
# chose, unverified against the committed one.* **`RealTransportHostRigWorkerTest` (the committed
# `:mesh:board1IntegrationWorker`) ALREADY carrieth the `crash-prepare` / `crash-recover` roles** (`WorkerFraming
# .validateLaunch` accepteth them and `CrashRoles` driveth the boundary), *so the separate-worker override was never
# needed for the coordinator's crash arm.* **THE TASK AND CLASS ARE NOW FIXED CONSTANTS, and the environment can no
# longer re-point them.** *The standalone `:mesh:board1DurableBoundaryWorker` Gradle task and its worker test remain
# for direct invocation, but the coordinator no longer reach eth them by an unvalidated name.*
ANDROID_CRASH_TASK = ANDROID_WORKER_TASK
ANDROID_CRASH_CLASS = ANDROID_WORKER_CLASS

# The seeds the two workers mint their identities from. **The coordinator re-mints until the production role
# election seats the SENDER as the initiator** -- see `seat_pair` -- because only the initiator is reachable in the
# route-eligible view, which is a production fact and not a convenience.
IOS_SEED = 0xC1
ANDROID_SEED = 0xD1


class Refused(RuntimeError):
    """A named refusal. **NEVER a bare exception: every refusal carrieth the reason a reader needeth.**"""


@dataclass
class Termination:
    """*** THE OBSERVED END OF ONE WORKER PROCESS, BOUND BEFORE ANY CLEANUP CAN SUPPLY ONE. ***

    *THE DEFECT THIS CLOSES, AND IT IS THE COORDINATOR'S OWN: a worker's end was read from `subprocess.Popen.poll()`
    -- or not read at all -- and NOTHING carried the actual PID, the actual exit status, WHY it ended, or whether the
    COORDINATOR's own SIGTERM/SIGKILL was what ended it.* **So a HUNG worker, a worker the coordinator killed, and a
    worker that deliberately halted all looked the same in the report, and the crash verdict could be earned by the
    coordinator's own cleanup.** *This dataclass is the observed answer, and `Worker.observe_termination` must be
    called BEFORE `close()` for `observed_before_cleanup` to be true; a termination that `close()` supplied carrieth
    `forced_kill` and is REFUSED as crash proof.*
    """

    pid: Optional[int]
    exit_status: Optional[int]
    termination_reason: str
    forced_kill: bool
    observed_before_cleanup: bool
    log_path: str
    #: *** THE ONLY NON-ZERO EXIT A CROSS-PLATFORM WITNESS MAY PRESENT: the worker's OWN typed intentional halt,
    #: verified by its marker line (`GS_INTEGRATION_INTENTIONAL_HALT status=<n>`) in the worker's retained log. ***
    #: *A claim without the marker text is not a halt; it is a failed launch.*
    intentional_halt: bool = False
    intentional_halt_marker: str = ""

    def as_dict(self, *, log_sha256: str = "") -> dict[str, Any]:
        return {
            "pid": self.pid,
            "exit_status": self.exit_status,
            "termination_reason": self.termination_reason,
            "forced_kill": self.forced_kill,
            "observed_before_cleanup": self.observed_before_cleanup,
            "log_path": self.log_path,
            "log_sha256": log_sha256 or sha256_file(Path(self.log_path)) if Path(self.log_path).is_file() else "",
            "intentional_halt": self.intentional_halt,
            "intentional_halt_marker": self.intentional_halt_marker,
        }

    def is_coordinator_kill(self) -> bool:
        """*** A DEATH THE COORDINATOR SUPPLIED IS NEVER THE WORKER'S DEATH. ***"""
        return self.forced_kill or self.termination_reason in ("coordinator-sigterm", "coordinator-sigkill")

    def describe(self) -> str:
        return (f"pid={self.pid} status={self.exit_status} reason={self.termination_reason} "
                f"forced_kill={self.forced_kill} observed_before_cleanup={self.observed_before_cleanup} "
                f"log={self.log_path}")


# ---------------------------------------------------------------------------------------------------------------
# digests and toolchain
# ---------------------------------------------------------------------------------------------------------------


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def bundle_digest(bundle: Path) -> tuple[str, dict[str, str]]:
    """*** THE CONTENT DIGEST OF A BUILT `.xctest` BUNDLE, OVER EVERY FILE INSIDE IT. ***

    *`--skip-build` assumeth an already-built fixture; **an assumption is only evidence when it is bound to the
    exact bundle it assumes**, and a bundle is a DIRECTORY of files (the executable, its Info.plist, any embedded
    frameworks), so the digest is over the tree: every regular file's relative path and its sha256, in sorted order.*
    **A rebuild that changed one byte of the executable therefore produceth a different digest, and a stale bundle
    cannot be passed off as the candidate's.**
    """
    files: dict[str, str] = {}
    if bundle.is_dir():
        for path in sorted(bundle.rglob("*")):
            if path.is_file():
                files[path.relative_to(bundle).as_posix()] = sha256_file(path)
    elif bundle.is_file():
        files[bundle.name] = sha256_file(bundle)
    h = hashlib.sha256()
    for rel in sorted(files):
        h.update(rel.encode())
        h.update(b"\0")
        h.update(files[rel].encode())
        h.update(b"\0")
    return h.hexdigest(), files


def _run(argv: list[str]) -> str:
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=180)
        return (out.stdout + out.stderr).strip().replace("\n", " ")
    except Exception as exc:  # noqa: BLE001 -- a missing toolchain entry must be REPORTED, not raised
        return f"unavailable({exc})"


def toolchain_versions() -> dict[str, str]:
    """*** RECORDED IN EVERY MANIFEST, because a cross-platform claim that does not name its toolchains cannot be
    re-executed. ***"""
    java_home = os.environ.get("JAVA_HOME", "")
    java = os.path.join(java_home, "bin", "java") if java_home else "java"
    gradlew = REPO / "android" / "gradlew"
    out = {
        "swift": _run(["swift", "--version"]),
        "xcodebuild": _run(["xcodebuild", "-version"]),
        "java": _run([java, "-version"]) + (f" [JAVA_HOME={java_home}]" if java_home else ""),
        "python": sys.version.split()[0] + f" ({platform_module.platform()})",
        "host": platform_module.platform(),
    }
    if gradlew.exists():
        version = _run([str(gradlew), "--version", "-q"])
        for line in version.split("  "):
            if line.startswith("Gradle "):
                version = line
                break
        out["gradle"] = version[:200]
    else:
        out["gradle"] = "unavailable(no committed wrapper)"
    out["android_sdk"] = os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", "unset"))
    return out


#: *** THE INPUT DIGEST: THE BYTES THIS RUN IS A CLAIM ABOUT. ***
#
# *Taken BEFORE the workers launch and AFTER they finish, and the two must agree -- the same contract every other
# lane runner in `tools/readiness/` carrieth. An explicit file list rather than a directory walk, so the digest names
# exactly what the claim depends on and nothing else.*
#
# *** THE SET IS THE EXACT TWENTY-SIX SOURCES THIS RUN EXERCISES -- NO MORE, NO LESS. ***
#
# *THE DEFECT THIS CLOSES, AND IT IS `Main`'S FINDING + THE CUTOVER AUDIT: the set must NAME every runner whose
# provisioning the run rides, the FULL pinned SQLCipher supply -- the PIN REGISTER, the BUILDER, the
# GENERATOR/VERIFIER, the shared build-provenance recorder whose attestation binds them, AND the PINNED TRUSTED
# EXPECTATION ITSELF (`SQLCipherTrustedExpectation.swift`, the generated compile input the engine compareth the
# loaded bytes against) -- the ENGINE LOADER and function-table that bind the dlopened image, the native
# store/wire sources BOTH isles' workers re-enter, and the workers themselves.*
# **A digest that omiteth them cannot bind the run to the revision it exercised; a set that PADDETH with courts it
# never executeth diluteth the claim the gate re-hashes.** The named expectation is GENERATED, and its generatedness
# is what maketh naming it HONEST rather than redundant: `build_provenance.verify_image` regenerates it from the
# verified image OUTSIDE the repo and compareth the bytes against the tracked copy (the generator is dual-mode and
# deterministic), the attestation carrieth `expected_source_sha256`, and NO code path here re-writeth a tracked
# source after a build -- a drift of the compiled expectation from the register is therefore BOTH a manifest-drift
# refusal (this list) AND an attestation refusal (`expected_source_sha256`).*
# *Two exclusions are deliberate and each remaineth BOUND by another road: the schema-control court and the UI-lane
# runner / lanes' own digest helper are judged by their OWN controls; their bytes are bound by the candidate's
# `whole_source_digest` (every tracked file) and by the attested recipe.*
# *The Foundation MIRROR under `ios/Packages/…` is generated (`sync_ios_foundation_package.py`); its CANONICAL
# sources under `ios/Godstone/Sources/GodstoneMesh/` and `ios/Godstone/Tests/GodstoneMeshTests/` are the authority,
# and the coordinator re-checks the mirror (`--check`) before building -- so the canonical files are what the
# digest names here.*
INPUT_FILES_DEFAULT = (
    # the coordinator itself, and the evidence gate + lane control that judge its output
    "tools/readiness/run_board1_integration.py",
    "ci/check_integration_evidence.py",
    "ci/check_lane_results.py",
    # the provisioning lanes whose staged images and digests this run's claim rides (the UI lane runneth no
    # provisioning this claim depends on; its own control judgeth it)
    "tools/readiness/run_ios_lane.sh",
    "tools/readiness/run_ios_simulator_lane.sh",
    "tools/readiness/run_android_lanes.sh",
    # the pinned SQLCipher supply IN FULL: register, builder, the GENERATOR/VERIFIER, the attestation recorder,
    # and the PINNED TRUSTED EXPECTATION the engine compares the dlopened bytes against
    "docs/supplychain/SQLCIPHER.pins.json",
    "tools/supplychain/build_sqlcipher_simulator.sh",
    "tools/supplychain/verify_sqlcipher_artifact.py",
    "tools/readiness/build_provenance.py",
    "ios/Godstone/Sources/GodstoneMesh/SQLCipherTrustedExpectation.swift",
    # the engine loader + function table that bind the dlopened image
    "ios/Godstone/Sources/GodstoneMesh/SqlCipherDylibEngine.swift",
    "ios/Godstone/Sources/GodstoneMesh/SQLiteFunctionTable.swift",
    "ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift",
    # the iOS native store + the wire the worker re-enters
    "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift",
    "ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift",
    "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift",
    "ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift",
    "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001CrossPlatformWorkerTests.swift",
    "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001ProcessTests.swift",
    # the Android native store/journal + the wire and the worker
    "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt",
    "android/mesh/src/main/java/io/godstone/mesh/identity/WipeJournalDurabilityAdapter.kt",
    "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt",
    "android/mesh/src/test/java/io/godstone/mesh/rig/RealTransportHostRig.kt",
    "android/mesh/src/test/java/io/godstone/mesh/rig/RealTransportHostRigWorkerTest.kt",
    "android/mesh/build.gradle.kts",
)
INPUT_FILES = INPUT_FILES_DEFAULT


def input_digest(extra: tuple[str, ...] = ()) -> tuple[str, dict[str, str]]:
    files: dict[str, str] = {}
    for rel in tuple(INPUT_FILES) + tuple(extra):
        path = REPO / rel
        files[rel] = sha256_file(path) if path.exists() else "absent"
    h = hashlib.sha256()
    for rel in sorted(files):
        h.update(rel.encode())
        h.update(b"\0")
        h.update(files[rel].encode())
        h.update(b"\0")
    return h.hexdigest(), files


# ---------------------------------------------------------------------------------------------------------------
# the framing
# ---------------------------------------------------------------------------------------------------------------


@dataclass
class Record:
    header: dict[str, Any]
    payload: bytes

    @property
    def kind(self) -> str:
        return str(self.header.get("kind", ""))

    def framed(self) -> bytes:
        head = json.dumps(self.header, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return struct.pack(">I", len(head)) + head + struct.pack(">I", len(self.payload)) + self.payload


def parse_records(buffer: bytes) -> tuple[list[Record], bytes]:
    """Parse every COMPLETE record out of `buffer`; return the records and the unconsumed tail."""
    out: list[Record] = []
    pos = 0
    while True:
        if len(buffer) - pos < 4:
            break
        (head_len,) = struct.unpack_from(">I", buffer, pos)
        if head_len > 1 << 22:
            raise Refused(f"a framed header declared {head_len} octets, which is not a header a worker can send")
        if len(buffer) - pos - 4 < head_len:
            break
        head = buffer[pos + 4:pos + 4 + head_len]
        after_head = pos + 4 + head_len
        if len(buffer) - after_head < 4:
            break
        (payload_len,) = struct.unpack_from(">I", buffer, after_head)
        if payload_len > 1 << 24:
            raise Refused(f"a framed payload declared {payload_len} octets, which is not a payload a worker can send")
        start = after_head + 4
        if len(buffer) - start < payload_len:
            break
        payload = buffer[start:start + payload_len]
        try:
            header = json.loads(head.decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            raise Refused(f"a framed metadata header was not canonical JSON: {exc}") from exc
        if not isinstance(header, dict):
            raise Refused("a framed metadata header was not a JSON object")
        out.append(Record(header=header, payload=payload))
        pos = start + payload_len
    return out, buffer[pos:]


# ---------------------------------------------------------------------------------------------------------------
# FIFOs
# ---------------------------------------------------------------------------------------------------------------


class Fifo:
    """One end of a named pipe, opened RDWR so neither side blocks on the other's open.

    *The RDWR trick is the portable one: `open(path, O_RDONLY)` blocks until a writer appears, and a coordinator that
    blocked there could not bound its own wait. Opened RDWR the pipe always has a reader and a writer, so every read
    is bounded by `select` rather than by the peer's liveness.*
    """

    def __init__(self, path: Path):
        self.path = path
        # *** A REUSED PIPE NAME IS REPLACED, NOT REFUSED. ***
        #
        # *THE DEFECT THIS CLOSES, MEASURED: the `replay` control's PHASE A re-driveth the honest direction, which
        # relauncheth workers under the SAME names ("swift-honest"/"android-honest") in the SAME runtime dir -- and
        # `close()` closeth the descriptor but LEAVETH THE NODE, so a bare `os.mkfifo` raised `FileExistsError` and
        # the replay control could never run.* **A previous phase's pipe is closed by the time its name is reused
        # (each `run_direction` closeth its workers in a `finally`), so the stale node is dead and replacing it is
        # the correct act rather than a hazard.** *`lexists` rather than `exists`: a dangling symlink at the path is
        # still something `mkfifo` would refuse.*
        if os.path.lexists(path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        os.mkfifo(path)
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self._closed = False
        self._lock = threading.Lock()
        self._tail = b""

    def send(self, record: Record) -> None:
        data = record.framed()
        with self._lock:
            view = memoryview(data)
            while view:
                _, writable, _ = select.select([], [self.fd], [], 60.0)
                if not writable:
                    raise Refused(f"the pipe {self.path.name} accepted no bytes within 60s")
                written = os.write(self.fd, view)
                view = view[written:]

    def recv(self, timeout: float) -> list[Record]:
        out: list[Record] = []
        deadline = time.monotonic() + max(0.0, timeout)
        while True:
            parsed, self._tail = parse_records(self._tail)
            if parsed:
                return out + parsed
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return out
            readable, _, _ = select.select([self.fd], [], [], min(remaining, 0.2))
            if not readable:
                continue
            try:
                chunk = os.read(self.fd, 1 << 16)
            except BlockingIOError:
                continue
            if chunk:
                self._tail += chunk

    def close(self) -> None:
        with self._lock:
            if self._closed:
                self.fd = None
                return
            self._closed = True
            if self.fd is not None:
                try:
                    os.close(self.fd)
                except OSError:
                    pass
                self.fd = None


# ---------------------------------------------------------------------------------------------------------------
# workers
# ---------------------------------------------------------------------------------------------------------------


@dataclass
class WorkerSpec:
    name: str
    platform: str
    role: str
    variant: str
    argv: list[str]
    env: dict[str, str]
    cwd: Optional[Path] = None


class Worker:
    """A launched worker: its process, its two pipes, and its transcript of everything it said.

    *** THE FIFOs ARE CREATED IN THE CONSTRUCTOR AND THE PROCESS IS STARTED BY `start()`, SEPARATELY, AND THAT
    ORDER IS LOAD-BEARING. *** *The Android worker is launched *through Gradle*, whose JVM argument list must carry
    the pipe paths -- and a path cannot be carried before the pipe exists. So the pipes are made first (both ends
    RDWR by the coordinator), the paths are handed to the launch spec, and only then is the process started.*
    """

    def __init__(self, spec: WorkerSpec, runtime_dir: Path, log: Callable[[str], None], launch: dict[str, Any]):
        self.spec = spec
        self.name = spec.name
        self.platform = spec.platform
        self.role = spec.role
        self.launch = launch
        self.runtime_dir = runtime_dir
        self.log = log
        self.to_worker = Fifo(runtime_dir / f"{spec.name}.in")
        self.from_worker = Fifo(runtime_dir / f"{spec.name}.out")
        self.transcript: list[Record] = []
        self.notes: list[str] = []
        self._lock = threading.Lock()
        self._queue: list[Record] = []
        # *** THE WAIT CURSOR IS PERSISTENT, BECAUSE `wait` IS CALLED MORE THAN ONCE IN ONE RUN. ***
        #
        # *THE DEFECT THIS CLOSES, MEASURED: `wait` scanned `self._queue` from index 0 on EVERY call, so once a
        # `hello` had matched, EVERY SUBSEQUENT `wait` -- including one for the RE-MINT's own `hello` -- re-matched
        # the FIRST `hello` and its stale hint. The re-mint path (never reached before the cross-platform run got
        # this far) therefore looped 16 times reporting the SAME old hint (`d72ffe42 does not open against
        # 0bb99473`) while the worker had in fact re-minted each time, and the run refused with `THE SENDER COULD NOT
        # BE SEATED AS THE INITIATOR IN 16 RE-MINTS`.* **A consumer of a stream must advance, exactly as the
        # worker-side `nextRecord` does; a local cursor that resetteth per call turneth every repeated `wait` into a
        # read of history.** `observe`/`all_of`/`take` are the HISTORY readers and keep their whole-transcript view;
        # only `wait` -- the forward consumer -- advanceth.
        self._wait_cursor = 0
        self._stop = threading.Event()
        # *** THE EVIDENCE LOG IS UNIQUE PER ATTEMPT, NOT PER ROLE. ***
        #
        # *THE DEFECT THIS CLOSES, MEASURED: `run_direction` launch eth `swift-honest` in EVERY direction and the
        # replay control's phase A RE-DRIVETH the honest direction, so `swift-honest.worker.log` was opened `"wb"`
        # TWO TO THREE TIMES IN ONE RUN and each launch OVERWROTE the previous attempt's log -- the failures of the
        # earlier attempt were destroyed by the later one. **The evidence root must retain EVERY attempt's log, so the
        # name carrieth a monotonic attempt index as well as the role.*** *(`run_direction` already names the ESTATE
        # this way for the same reason; the log name is the other half.)*
        self.attempt = Worker._claim_attempt(spec.name)
        self.log_path = runtime_dir / f"{spec.name}.{self.attempt:03d}.worker.log"
        self._log_fh = None
        self.process: Optional[subprocess.Popen] = None
        self._reader: Optional[threading.Thread] = None
        # *** THE OBSERVED END OF THIS WORKER, AND WHETHER THE COORDINATOR SUPPLIED IT. ***
        self.termination: Optional[Termination] = None
        self._child_pgids: set[int] = set()
        # *** A FAILED LOG RETENTION IS AN EVIDENCE FAULT AND MUST REFUSE, NOT PASS SILENTLY. ***
        self.retention_error: Optional[str] = None

    _attempt_lock = threading.Lock()
    _attempts: dict[str, int] = {}

    @classmethod
    def _claim_attempt(cls, name: str) -> int:
        with cls._attempt_lock:
            n = cls._attempts.get(name, 0) + 1
            cls._attempts[name] = n
            return n

    def start(self) -> None:
        env = dict(os.environ)
        env.update(self.spec.env)
        self._log_fh = self.log_path.open("wb")
        # *** EACH WORKER GETS ITS OWN PROCESS GROUP, SO A KILL REACHETH ITS GRANDCHILDREN. ***
        #
        # *THE DEFECT THIS CLOSES, MEASURED: a hosted coordinator run can leave an ORPHANED child behind -- an
        # `xctest` cross-platform worker, PPID 1, ZERO CPU for 2h15m, blocked on a FIFO whose coordinator was gone.
        # `start_new_session=True` putteth the worker in its own session/group, so `close()`'s group-kill reacheth
        # every process the worker spawned (a Gradle wrapper's Java, that JVM's `xctest` child) rather than only the
        # process this object directly holds -- **the Swift worker IS `xctest` itself, and the Android worker's tree
        # is Gradle -> java -> child, so terminating only `self.process` leaveth its descendants alive.*** *A worker
        # that outlives its coordinator holdeth the shared `.build` bundle and the FIFOs, wedging the next run.*
        self.process = subprocess.Popen(  # noqa: S603 -- argv is constructed here, never a shell string
            self.spec.argv,
            cwd=str(self.spec.cwd) if self.spec.cwd else str(REPO),
            env=env,
            stdout=self._log_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        # *** THE GROUP ID IS CAPTURED NOW, BECAUSE AFTER `wait()` REAPS THE LEADER `os.getpgid(pid)` FAILETH. ***
        # *A group whose leader is gone can still hold living descendants; signalling by the pid we saved (rather than
        # re-deriving it from a reaped pid) is what reacheth them.*
        try:
            self._pgid: Optional[int] = os.getpgid(self.process.pid)
        except OSError:
            self._pgid = None
        # *** THE ACTUAL PID OF THE PROCESS THIS OBJECT HOLDS IS EVIDENCE, SO IT IS RECORDED AT LAUNCH. ***
        # *For the Swift worker this IS the `xctest` process; for the Android worker it is the `gradlew` wrapper,
        # whose own executor CHILD is a grandchild the log names. Both are recorded so a reader can bind the
        # observed termination to a real process rather than to a role's name.*
        self.launch = dict(self.launch or {})
        self.launch["pid"] = self.process.pid
        self.launch["pgid"] = self._pgid
        self.log(f"  [{self.name}] launched pid={self.process.pid} pgid={self._pgid} "
                 f"attempt={self.attempt} log={self.log_path.name}")
        self._reader = threading.Thread(target=self._drain, name=f"drain-{self.spec.name}", daemon=True)
        self._reader.start()

    # ---- evidence retention ---------------------------------------------------------------------------------

    def _retain_log(self) -> None:
        """*** COPY THE WORKER'S OWN STDOUT/STDERR BESIDE THE EVIDENCE, AND REFUSE IF THE COPY FAILS. ***

        *THE DEFECT THIS CLOSES: the copy was wrapped in a bare `except: pass`, so a worker whose log could not be
        retained looked exactly like one that was — the evidence existed only inside the transient runtime dir and
        the failure was INVISIBLE. **A run whose log proof cannot be retained cannot support its verdict, so the
        failure is recorded (`retention_error`) and the runner REFUSETH it after the workers are closed.***
        """
        try:
            target = self.runtime_dir.parent / self.log_path.name
            shutil.copy2(self.log_path, target)
            # *** AND THE COPY IS VERIFIED, SO A TRUNCATED/SHORT COPY IS NOT MISTAKEN FOR RETENTION. ***
            if sha256_file(target) != sha256_file(self.log_path):
                self.retention_error = f"the retained log {target.name} does not hash to the worker log"
        except Exception as exc:  # noqa: BLE001 -- the failure is RECORDED, never swallowed
            self.retention_error = f"could not retain worker log {self.log_path.name}: {exc!r}"

    def observe_termination(self, *, forced_kill: bool = False) -> Termination:
        """*** THE OBSERVED END OF THE WORKER, TAKEN BEFORE (OR WITHOUT) THE COORDINATOR'S OWN CLEANUP. ***

        *A bounded wait for the process itself; `None` from the wait is a HUNG worker, and a HUNG worker is NOT a
        death. **A negative status is a SIGNAL death; the coordinator's own group-kill is booked separately by
        `close()` and is REFUSED as crash proof.*** The caller decides the bound; this method never supplies a death.
        """
        if self.termination is not None:
            return self.termination
        if self.process is None:
            self.termination = Termination(pid=None, exit_status=None, termination_reason="never-started",
                                           forced_kill=False, observed_before_cleanup=True,
                                           log_path=str(self.log_path))
            return self.termination
        status = self.process.poll()
        if status is None:
            self.termination = Termination(pid=self.process.pid, exit_status=None,
                                           termination_reason="still-running", forced_kill=False,
                                           observed_before_cleanup=True, log_path=str(self.log_path))
        else:
            reason = "signal" if status < 0 else "cooperative-exit"
            self.termination = Termination(pid=self.process.pid, exit_status=status,
                                           termination_reason=reason, forced_kill=forced_kill,
                                           observed_before_cleanup=True, log_path=str(self.log_path))
        return self.termination

    def wait_exit(self, timeout: float) -> Optional[int]:
        """*** BOUNDED WAIT FOR THE PROCESS ITSELF TO EXIT -- return its status, or `None` if still running. ***

        *THE DEFECT THIS CLOSES: `run_crash` read `prepare.status` AFTER `prepare.close()`, and `close()` sendeth the
        coordinator's OWN SIGTERM/SIGKILL -- so the status observed was frequently the COORDINATOR'S kill, presented
        as the worker's own abrupt halt.* **THE DEATH MUST BE OBSERVED BEFORE THE COORDINATOR CAN SUPPLY ONE.** *A
        worker that never exits is HUNG and is refused, never booked as a crash.*
        """
        if self.process is None:
            return None
        try:
            status = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.termination = Termination(pid=self.process.pid, exit_status=None, termination_reason="hung",
                                           forced_kill=False, observed_before_cleanup=True,
                                           log_path=str(self.log_path))
            return None
        reason = "signal" if status < 0 else "cooperative-exit"
        self.termination = Termination(pid=self.process.pid, exit_status=status, termination_reason=reason,
                                       forced_kill=False, observed_before_cleanup=True,
                                       log_path=str(self.log_path))
        return status

    def tail_log(self, lines: int = 80) -> str:
        try:
            data = self.log_path.read_text(errors="replace").splitlines()
        except OSError:
            return ""
        return "\n".join(data[-lines:])

    def executor_termination(self) -> dict[str, Any]:
        """*** THE ACTUAL GRADLE TEST-EXECUTOR CHILD'S TERMINATION, READ FROM THE WORKER'S OWN LOG. ***

        *THE FACT THAT MAKETH DEMANDING `wrapper_rc == 137` WRONG: Gradle reapit its forked executor, observeth the
        abrupt status, and then REPORTS THE BUILD as `rc=1` -- it does NOT re-exit with 137. **So the honest crash
        proof is: the wrapper's own rc is recorded (and may be 1/None), AND the log carrieth Gradle's own report of
        the executor's actual non-zero abrupt status (`Process 'Gradle Test Executor N' finished with non-zero exit
        value 137`), AND the worker wrote a pre-halt marker (`GS_INTEGRATION_ABOUT_TO_HALT`) and its own PID
        (`GS_INTEGRATION_EXECUTOR_PID=`) so the death is bound to a real process and a named stage.** A wrapper rc
        alone proves nothing about the child; a child status with no PID or no pre-halt marker proves nothing about
        WHICH process died WHERE.*
        """
        text = ""
        try:
            text = self.log_path.read_text(errors="replace")
        except OSError:
            pass
        pids = [int(m) for m in re.findall(re.escape(GRADLE_EXECUTOR_PID_MARKER) + r"(\d+)", text)]
        # *** THE PRE-HALT MARKER IS A BOUND DECLARATION, NOT A PRINT. ***
        #
        # *THE DEFECT THIS CLOSES: the clause was a bare `in text` substring test on the marker's NAME, so ANY print
        # of that word -- by any code path, with no stage and no code -- satisfied it. The worker's committed
        # `markAboutToHalt` prints `GS_INTEGRATION_ABOUT_TO_HALT boundary=<stage> code=<haltStatus>` from the REAL
        # JDK `ProcessHandle.current().pid()` immediately BEFORE `Runtime.halt`, so the parser here demanbeth the
        # SAME shape: a named boundary and a declared code, which the crash arm binds to THIS boundary and to the
        # executor's observed abrupt status.*
        halt_pairs = EXECUTOR_HALT_MARKER_RE.findall(text)
        halt_boundaries = [b for b, _ in halt_pairs]
        halt_codes = [int(c) for _, c in halt_pairs]
        about_to_halt = bool(halt_pairs)
        statuses = [int(m) for m in EXECUTOR_STATUS_RE.findall(text)]
        abrupt = [int(m) for m in GRADLE_EXECUTOR_ABRUPT_RE.findall(text)]
        # *** THE WORKER'S OWN JVM PID, WRITTEN BY THE WORKER ITSELF BEFORE IT HALTED. *** *The committed marker
        # resolvesth the real OS pid through the PUBLIC `java.lang.ProcessHandle` interface -- no Robolectric
        # shadow (the Android `10000`), no hidden JDK internals -- and `check(pid > 0)` maketh a bogus pid a
        # worker-side failure, not a silent number. The coordinator side valideth the value again.*
        self_pids = [int(m) for m in re.findall(r"GS_INTEGRATION_SELF_PID=(\d+)", text)]
        # *** AND WHETHER THE WORKER'S OWN TEST METHOD ACTUALLY COMPLETED. ***
        #
        # *MEASURED IN THE FROZEN RC11 LOGS: the prepare JVM's halt leaveth Gradle unable to report a result, so it
        # recordeth the method `SKIPPED`; the recover JVM returneth normally and Gradle recordeth `PASSED`. **So a
        # recovery that exited 0 WITHOUT running the worker** (an empty selection, a stale class, a filtered run)
        # would be indistinguishable from a real one unless the log's own per-method verdict is read.* This is that
        # reading, and it is a FACT about the worker rather than about the wrapper's status.
        test_completed = bool(re.search(
            r"RealTransportHostRigWorkerTest > testGSINT001CrossPlatformWorker PASSED", text))
        return {
            "executor_pids": pids or self_pids,
            "executor_pid": (pids or self_pids or [None])[-1],
            "about_to_halt_seen": about_to_halt,
            "about_to_halt_boundaries": halt_boundaries,
            "about_to_halt_codes": halt_codes,
            "declared_halt_statuses": statuses,
            "gradle_reported_abrupt_statuses": abrupt,
            "worker_self_pids": self_pids,
            "worker_test_completed": test_completed,
        }

    # ---- the reader -----------------------------------------------------------------------------------------

    def _signal_group(self, sig: int) -> None:
        """Signal the WHOLE process group of the worker, ignoring the case where it is already gone.

        *`start_new_session=True` made `self.process.pid` the group leader, so `os.killpg(pid, sig)` reacheth every
        descendant the worker spawned. The calls are BEST-EFFORT: a group that already exited raiseth `ProcessLookupError`
        (or `PermissionError` for a group this user no longer owns), and neither is an error here -- the goal is to
        leave nothing alive, and a group that is gone is exactly that.*
        """
        if self.process is None:
            return
        pgid = getattr(self, "_pgid", None)
        if pgid is None:
            try:
                pgid = os.getpgid(self.process.pid)
            except OSError:
                return
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError, OSError):
            pass

    def _drain(self) -> None:
        while not self._stop.is_set():
            try:
                records = self.from_worker.recv(0.2)
            except Refused as exc:
                with self._lock:
                    self.notes.append(f"protocol refusal: {exc}")
                return
            if records:
                with self._lock:
                    self.transcript.extend(records)
                    self._queue.extend(records)
                for rec in records:
                    self.log(f"  [{self.name}] <- {rec.kind} "
                             f"{rec.header.get('label', '')} payload={len(rec.payload)}B")

    # ---- the verbs ------------------------------------------------------------------------------------------

    def send(self, kind: str, payload: bytes = b"", **header: Any) -> None:
        head = {"v": PROTOCOL_VERSION, "kind": kind, "platform": self.platform, "role": self.role,
                "variant": self.spec.variant}
        head.update(header)
        self.to_worker.send(Record(header=head, payload=payload))
        self.log(f"  [{self.name}] -> {kind} {header.get('label', '')} payload={len(payload)}B")
        # *** `bye` IS THE PROTOCOL'S LAST COMMAND, SO IT CARRIETH THE COMMAND CHANNEL'S EOF WITH IT. ***
        # *THE DEFECT THIS CLOSES, MEASURED IN THE LIVE `--mode all` RUN (ios->android honest): the coordinator
        # holdeth the command pipe `O_RDWR`, so its WRITE half stayed OPEN after `bye`; the worker's blocked
        # `FileInputStream.read()` therefore never reached EOF, and its CROSS-THREAD `close()` -- JVM-synchronised
        # against the fd's own read lock because the reader thread sat in `read()` -- BLOCKED for the whole 120s
        # grace (Gradle's own XML: `testGSINT001CrossPlatformWorker time="123.062"` against a 4s exchange; reproduced:
        # a read-blocked `close()` hangeth while a writer standeth and returneth in 0ms once the writer half closeth).
        # **Closing the command fd once the `bye` frame is flushed is the honest "the command stream is complete" --
        # EOF, not a kill.** The worker's REPLY travels the SEPARATE `from_worker`/`.out` pipe, which is untouched, so
        # this is a HALF-close of the pipe pair; `wait_exit`/grace bookkeeping and every timeout are unchanged, and the
        # fd is NOT reopened (a reopen would race the worker's reader for the EOF and could re-block it).*
        if kind == "bye":
            self.to_worker.close()

    def wait(self, predicate: Callable[[Record], bool], timeout: float, what: str) -> Record:
        """*** BOUNDED. A missing marker, a timeout or an early exit is a NAMED REFUSAL, never a skip. ***"""
        if self.process is None:
            raise Refused(f"*** THE {self.name} WORKER WAS NEVER STARTED, so {what} cannot be awaited. ***")
        deadline = time.monotonic() + timeout
        while True:
            with self._lock:
                while self._wait_cursor < len(self._queue):
                    rec = self._queue[self._wait_cursor]
                    self._wait_cursor += 1
                    if predicate(rec):
                        return rec
            if self.process.poll() is not None:
                # Give the reader a moment to deliver the tail before concluding the worker is gone.
                time.sleep(0.3)
                with self._lock:
                    pending = self._queue[self._wait_cursor:]
                    self._wait_cursor = len(self._queue)
                    notes = list(self.notes)
                    transcript = [r.kind for r in self.transcript]
                for rec in pending:
                    if predicate(rec):
                        return rec
                raise Refused(
                    f"*** THE {self.name} WORKER EXITED (status={self.process.returncode}) BEFORE {what}. *** "
                    f"A missing marker, an early exit and a timeout are all FAILED WORKER LAUNCHES. "
                    f"Said: {transcript} notes={notes} log={self.log_path}")
            if time.monotonic() >= deadline:
                with self._lock:
                    transcript = [r.kind for r in self.transcript]
                    notes = list(self.notes)
                raise Refused(
                    f"*** THE {self.name} WORKER NEVER REACHED {what} WITHIN {timeout:.0f}s. *** "
                    f"Said: {transcript} notes={notes} log={self.log_path}")
            time.sleep(0.02)

    def take(self) -> list[Record]:
        with self._lock:
            out = self._queue
            self._queue = []
            # *** `take` EMPTIETH THE QUEUE, SO THE FORWARD CURSOR RESTARTETH WITH IT. *** *The cursor indexeth
            # `_queue`; leaving it pointing past a queue that was just replaced with a new one would SKIP the next
            # record(s) until the new queue outgrew the stale index. The two must move together.*
            self._wait_cursor = 0
        return out

    def observe(self, predicate: Callable[[Record], bool]) -> Optional[Record]:
        with self._lock:
            for rec in self.transcript:
                if predicate(rec):
                    return rec
        return None

    def all_of(self, kind: str) -> list[Record]:
        with self._lock:
            return [r for r in self.transcript if r.kind == kind]

    def close(self) -> None:
        self._stop.set()
        try:
            self.to_worker.close()
        except Exception:  # noqa: BLE001
            pass
        if self.process is None:
            # *** A WORKER THAT WAS NEVER STARTED IS STILL CLOSED: its pipes must not leak, and its absence is not
            # an error here -- the caller that declined to start it already refused.***
            if self._reader:
                self._reader.join(timeout=2)
            self.from_worker.close()
            if self.termination is None:
                self.termination = Termination(pid=None, exit_status=None, termination_reason="never-started",
                                               forced_kill=False, observed_before_cleanup=False,
                                               log_path=str(self.log_path))
            self._retain_log()
            return
        forced_kill = False
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                # *** THE COORDINATOR NOW SUPPLIES THE DEATH: BOOK IT AS SUCH. *** *A termination observed after this
                # point is the COORDINATOR'S, and both the crash verdict and the report refuse it as worker proof.*
                forced_kill = True
                self._signal_group(signal.SIGTERM)
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self._signal_group(signal.SIGKILL)
                    self.process.wait(timeout=15)
        # *** AND EVEN A WORKER THAT EXITED ITSELF MAY HAVE LEFT DESCENDANTS: reap the WHOLE GROUP once more. ***
        # *The Swift worker IS the `xctest` process; the Android worker is `gradlew` -> its own JVM -> a Gradle
        # daemon-less build's children. A parent that exited is not proof its tree did, and the leaked `xctest` this
        # close() repair existeth for was exactly such a grandchild.*
        self._signal_group(signal.SIGKILL)
        if self._reader:
            self._reader.join(timeout=10)
        try:
            self.from_worker.close()
        except Exception:  # noqa: BLE001
            pass
        if self._log_fh:
            self._log_fh.close()
        # *** THE TERMINATION IS BOOKED HERE IF IT WAS NOT OBSERVED BEFORE CLEANUP. ***
        status = self.process.poll()
        if self.termination is None:
            reason = ("coordinator-sigkill" if forced_kill and status == -signal.SIGKILL
                      else "coordinator-sigterm" if forced_kill
                      else "signal" if (status is not None and status < 0)
                      else "cooperative-exit" if status is not None else "still-running")
            self.termination = Termination(pid=self.process.pid, exit_status=status, termination_reason=reason,
                                           forced_kill=forced_kill, observed_before_cleanup=False,
                                           log_path=str(self.log_path))
        elif forced_kill:
            # observed earlier but the coordinator then had to kill it: keep the earlier observation, mark the force.
            self.termination.forced_kill = True
        # *** THE WORKER'S OWN STDOUT/STDERR IS EVIDENCE AND TRAVELS WITH THE RUN. ***
        self._retain_log()


# ---------------------------------------------------------------------------------------------------------------
# the transcript and the manifest
# ---------------------------------------------------------------------------------------------------------------


class Evidence:
    """*** THE LENGTH-DELIMITED BINARY TRANSCRIPT, AND THE SEPARATE METADATA MANIFEST. ***

    *The transcript is the framed records EXACTLY as they crossed (or were observed), concatenated -- so a reader can
    re-frame it with the same four-octet lengths the protocol used. The manifest is a JSON sidecar naming, for every
    recorded payload, where it lives in the transcript, what it hashes to, and who produced it. **Neither file
    interprets a payload.***
    """

    def __init__(self, evidence_dir: Path, run_id: str, digest: str, toolchains: dict[str, str]):
        self.evidence_dir = evidence_dir
        self.run_id = run_id
        self.digest = digest
        self.toolchains = toolchains
        evidence_dir.mkdir(parents=True, exist_ok=True)
        self.blob = evidence_dir / "transcript.bin"
        self.manifest_path = evidence_dir / "manifest.json"
        self._fh = self.blob.open("wb")
        self.records: list[dict[str, Any]] = []
        self.sequence = 0
        self.offset = 0
        self.launches: list[dict[str, Any]] = []

    def note_launch(self, name: str, platform: str, role: str, variant: str,
                    argv: list[str], estate: str, launch: Optional[dict[str, Any]] = None) -> None:
        """*** WHAT WAS LAUNCHED, AND THE ACTUAL PID IT WAS LAUNCHED AS. ***

        *`launch` carrieth the OBSERVED facts (`pid`, `pgid`, the requested vs reported role vocabulary, whether the
        crash roles ran with `-i`), so the manifest bindeth a role name to a real process rather than to a string.*
        """
        self.launches.append({"name": name, "platform": platform, "role": role, "variant": variant,
                              "argv": argv, "estate": estate, **(launch or {})})

    def append(self, rec: Record, *, direction: str, producer: str, target: str,
               characteristic: str = "", epoch: Any = None, note: str = "",
               platform: str = "") -> dict[str, Any]:
        framed = rec.framed()
        # *** THE PAYLOAD'S TRUE OFFSET INSIDE THE TRANSCRIPT, NOT THE FRAME'S. ***
        #
        # *THE DEFECT THIS CLOSES, AND IT IS A MEASURED ONE: the entry's `payload_offset` was set to `self.offset`
        # -- the offset of the FRAMED RECORD'S FIRST OCTET -- and the replay control then sliced
        # `blob[payload_offset : payload_offset + payload_length]`. **That slice began at the `u32be header_len`, so
        # what got "replayed" was the FRAME PREAMBLE AND HEADER BYTES, not the session's ciphertext** -- a truncated
        # payload prefixed with framing metadata, which the receiver would refuse for a reason that had NOTHING to do
        # with an old-session replay.* **The real payload beginneth after `4 + header_len + 4` octets of preamble, so
        # that arithmetic is done ONCE, HERE, where the header is in hand.** *`frame_offset` keepeth the old meaning
        # for a reader that wanteth the whole record.*
        head = json.dumps(rec.header, sort_keys=True, separators=(",", ":")).encode("utf-8")
        payload_offset = self.offset + 4 + len(head) + 4
        self.sequence += 1
        entry = {
            "sequence": self.sequence,
            "platform": platform or rec.header.get("platform", ""),
            "producer": producer,
            "target": target,
            "direction": direction,
            "characteristic": characteristic or rec.header.get("characteristic", ""),
            "kind": rec.kind,
            "epoch": epoch if epoch is not None else rec.header.get("epoch"),
            "frame_offset": self.offset,
            "frame_length": len(framed),
            "payload_offset": payload_offset,
            "payload_length": len(rec.payload),
            "payload_sha256": sha256_bytes(rec.payload),
            "source_digest": self.digest,
            "note": note,
        }
        self._fh.write(framed)
        self._fh.flush()
        self.offset += len(framed)
        self.records.append(entry)
        return entry

    def close(self) -> dict[str, Any]:
        self._fh.close()
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "run_id": self.run_id,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "input_digest": self.digest,
            "toolchain": self.toolchains,
            "worker_launches": self.launches,
            "transcript": {
                "path": self.blob.name,
                "length": self.offset,
                "sha256": sha256_file(self.blob),
                "framing": "u32be header_len | header(json,utf8) | u32be payload_len | payload",
            },
            "record_count": len(self.records),
            "records": self.records,
        }
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest


# ---------------------------------------------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------------------------------------------


@dataclass
class Result:
    direction: str
    control: str
    outcome: str
    detail: str
    durable_row: Optional[str] = None
    delivery: Optional[str] = None
    msg_id: Optional[str] = None
    refusal: Optional[str] = None
    boundary: Optional[str] = None
    #: *** THE CANCELLATION NEGATIVE'S OWN PROOF: the frame the tracker moved, and the state it moved it to,
    #: re-read from the REOPENED estate. *** *Carried so the report bindeth the negative to the same run rather than
    #: to a claim.*
    cancellation_msg_id: Optional[str] = None
    cancellation_state: Optional[str] = None


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        try:
            self.identity = build_provenance.source_identity(args.candidate_sha)
        except (ValueError, OSError, subprocess.CalledProcessError) as exc:
            raise Refused(f"candidate identity REFUSED: {exc}") from exc
        args.candidate_sha = self.identity["candidate_sha"]
        self.evidence_dir = Path(args.evidence_dir).resolve()
        self.evidence_dir.mkdir(parents=True, exist_ok=True)
        self.log_fh = (self.evidence_dir / "run.log").open("w")
        self.run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + os.urandom(3).hex()
        self.digest, self.input_files = input_digest(tuple(args.extra_input or ()))
        self.toolchains = toolchain_versions()
        self.runtime_dir = Path(tempfile.mkdtemp(prefix="gs_int_coord_", dir=str(self.evidence_dir)))
        self.evidence = Evidence(self.evidence_dir, self.run_id, self.digest, self.toolchains)
        self.results: list[Result] = []
        # *** A MONOTONIC PER-INVOCATION COUNTER, BECAUSE `control` ALONE IS NOT UNIQUE ACROSS A PHASE RE-RUN. ***
        # *The `replay` control's phase A re-driveth the honest direction, so `(direction, "honest")` occurreth
        # TWICE in one run; an estate named by control alone is therefore shared between the control and the phase.*
        self._invocation = 0
        self.deadline_s = float(args.timeout)
        self.workers: list[Worker] = []
        # *** EVERY WORKER EVER LAUNCHED, IN LAUNCH ORDER: the log-retention check runs over ALL of them, including
        # the ones already closed and dropped from `self.workers`. ***
        self.all_workers: list[Worker] = []
        # *** THE OBSERVED ANDROID CRASH TERMINATIONS, BOUND INTO THE REPORT SO THE GATE CAN REFUSE A FAKE CRASH. ***
        self.crash_terminations: list[dict[str, Any]] = []
        self._swift_bundle: Optional[Path] = None
        self._android_ready = False
        # *** THE DIGEST OF THE BUNDLE THIS RUN ACTUALLY USED, RECORDED WHETHER IT WAS BUILT HERE OR ASSUMED. ***
        self.bundle_digest_value: Optional[str] = None
        # *** THE BUILD ATTESTATION: what was built, from which sources, by which recipe, where. ***
        self.build_attestation_value: Optional[dict[str, Any]] = None
        self.attestation_verified = False

    # ---- plumbing -------------------------------------------------------------------------------------------

    def log(self, message: str) -> None:
        line = f"[{time.strftime('%H:%M:%S')}] {message}"
        print(line, flush=True)
        self.log_fh.write(line + "\n")
        self.log_fh.flush()

    def fresh_estate(self, name: str) -> Path:
        root = self.runtime_dir / f"estate-{name}"
        root.mkdir(parents=True, exist_ok=True)
        return root

    # ---- building the fixtures once ---------------------------------------------------------------------------

    def build_fixtures(self) -> None:
        """*** "It builds the host fixtures once." ***

        *The macOS test bundle is built by SwiftPM; the Android worker classes are compiled by the `board1Integration
        Worker` task's own classpath, so BOTH host fixtures stand as facts rather than assumptions.*
        """
        if self.args.skip_build:
            # *** `--skip-build` IS ONLY HONEST WHEN THE BUNDLE IT ASSUMES IS BOUND TO THIS CANDIDATE AND SOURCE. ***
            #
            # *THE DEFECT THIS CLOSES: `--skip-build` returned immediately and `resolve_swift_bundle()` accepted
            # whatever `.xctest` happened to be on disk, so a STALE bundle built from a DIFFERENT candidate -- or a
            # bundle whose sources had since changed -- could produce a green cross-platform run. **An assumed build
            # is only evidence if it is bound; so the assumption must be NAMED by digest and REFUSED when it does not
            # hold.***
            self._require_skip_build_binding()
            return
        self.log("*** building the host fixtures ONCE (SwiftPM macOS test bundle) ***")
        # *** THE PINNED IMAGE IS STAGED AND THE TRUST EXPECTATION GENERATED *BEFORE* THE BUILD, so the compiled
        # binary carrieth the expectation that describes the image this host will actually load. ***
        self.provision_sqlcipher()
        # A candidate run checks its committed mirror; generation belongs before C.
        sync = subprocess.run(
            [sys.executable, str(REPO / "scripts" / "sync_ios_foundation_package.py"), "--check"],
            cwd=str(REPO), capture_output=True, text=True, timeout=600)
        (self.runtime_dir / "swift-sync.log").write_text(sync.stdout + sync.stderr)
        if sync.returncode != 0:
            raise Refused(f"*** THE FOUNDATION MIRROR SYNC FAILED (rc={sync.returncode}); see "
                          f"{self.runtime_dir / 'swift-sync.log'} ***")
        result = subprocess.run(
            ["swift", "build", "--package-path", str(REPO / "ios" / "Packages" / "GodstoneFoundation"),
             "--build-tests"],
            cwd=str(REPO), capture_output=True, text=True, timeout=7200)
        (self.runtime_dir / "swift-build.log").write_text(result.stdout + result.stderr)
        if result.returncode != 0:
            raise Refused(f"*** THE macOS FIXTURE BUILD FAILED (rc={result.returncode}); see "
                          f"{self.runtime_dir / 'swift-build.log'} ***")
        self.log(f"  swift build --build-tests: rc={result.returncode}")
        # *** AND THE ANDROID HALF IS REALLY BUILT HERE, ONCE, RATHER THAN BY A DEAD `pass` LOOP. ***
        #
        # *THE DEFECT THIS CLOSES: the loop over `compileDebugUnitTestKotlin`/`compileDebugUnitTestJavaWithJavac`
        # contained ONLY `pass`, so "it builds the host fixtures once" was true of Swift and FALSE of Android -- the
        # Android side was compiled only inside the first worker's TIMED window, where a cold compile is charged
        # against the worker's own bound.* **So the compile now happens HERE, before any worker is launched: a
        # failure REFUSETH the run by name, and `_android_ready` is a real observation rather than a constant.**
        self._compile_android_fixtures()
        # *** THE BUILT BUNDLE'S DIGEST IS RECORDED, SO A LATER `--skip-build` RUN CAN BE BOUND TO IT. ***
        self.bundle_digest_value = bundle_digest(self.resolve_swift_bundle())[0]
        self.log(f"  built macOS test bundle digest = {self.bundle_digest_value}")
        # *** AND THE BUILD'S ATTESTATION IS WRITTEN, SO AN ASSUMED BUILD CAN BE VERIFIED AGAINST WHAT WAS BUILT. ***
        # *** THE ACTUAL TESTED BYTES ARE RETAINED FIRST, BESIDE THE RECORD, SO THE RECORD IS RE-READABLE WITHOUT
        # THE LOCAL `.build` BUNDLE OR THE STAGED IMAGE PATH SURVIVING. *** *An initial build is the ONLY caller of
        # `retain_tested_bytes`: every later consumer re-reads this archive, never regenerates it.*
        self.build_attestation_value = self.make_build_attestation("macos", evidence_dir=self.evidence_dir, retain=True)
        attestation_path = self.evidence_dir / "build-attestation.json"
        attestation_path.write_text(json.dumps(self.build_attestation_value, indent=2) + "\n")
        self.log(f"  build attestation = {attestation_path.name} "
                 f"(library_present={self.build_attestation_value.get('library_present')}) "
                 f"tested_bytes={(self.build_attestation_value.get('tested_bytes') or {}).get('bytes')}")

    def _require_skip_build_binding(self) -> None:
        """*** `--skip-build` REQUIRES THE REAL BUILD'S ATTESTATION **AND** AN EXACT CANDIDATE SHA. ***"""
        # *** THE ATTESTATION IS THE PRIMARY BINDING: it carrieth the artifact digest + platform/arch/cipher/source
        # commit (sourced from the register), the pinned source commit, the recipe digest, the candidate SHA, the
        # source digest AND the bundle digest -- all produced by the BUILDING runner. ***
        if not self.args.candidate_sha:
            raise Refused("*** `--skip-build` REQUIRES `--candidate-sha <sha>`: an assumed build must be bound to an "
                          "EXACT candidate, not merely to a self-consistent hash set. *** *The candidate is the "
                          "commit/tree the bundle is claimed to be built at; without it the attestation cannot be "
                          "checked against a named object.*")
        self._require_build_attestation_binding()
        self.bundle_digest_value = bundle_digest(self.resolve_swift_bundle())[0]
        self.log(f"*** --skip-build: ATTESTED bundle digest {self.bundle_digest_value[:16]}… candidate "
                 f"{self.args.candidate_sha[:16]}… ***")


    def make_build_attestation(self, mode: str, *, evidence_dir: Path,
                               retain: bool = False) -> dict[str, Any]:
        """*** `record_build` IS READ-ONLY: it re-derives the EXISTING tested-bytes archive under `evidence_dir`.
        Only an INITIAL actual build passeth `retain=True`, which captures the bytes ONCE; every other caller (the
        `--skip-build` live comparison) must already find the archive it verifies a previous run recorded. ***"""
        try:
            stage = Path(os.environ["GODSTONE_SQLCIPHER_ARTIFACT_DIR"])
            bundle = self.resolve_swift_bundle()
            if retain:
                build_provenance.retain_tested_bytes(
                    bundle, build_provenance.verify_image(mode, stage), evidence_dir)
            value = build_provenance.record_build(mode, stage, bundle, self.identity, self.run_id, evidence_dir)
            value["source_digest"] = self.digest
            return value
        except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as exc:
            raise Refused(f"actual build attestation REFUSED: {exc}") from exc

    def provision_sqlcipher(self) -> None:
        stage = Path(tempfile.mkdtemp(prefix="gs-int-sqlcipher-macos-"))
        builder = REPO / "tools/supplychain/build_sqlcipher_simulator.sh"
        built = subprocess.run(["/bin/bash", str(builder), "--mode", "macos", "--out", str(stage)],
                               cwd=str(REPO), capture_output=True, text=True, timeout=7200)
        (self.runtime_dir / "sqlcipher-build.log").write_text(built.stdout + built.stderr)
        if built.returncode:
            raise Refused(f"pinned macOS image build failed ({built.returncode}); see sqlcipher-build.log")
        try:
            build_provenance.verify_image("macos", stage)
        except (ValueError, OSError, subprocess.CalledProcessError) as exc:
            raise Refused(f"pinned macOS image verification refused: {exc}") from exc
        os.environ["GODSTONE_SQLCIPHER_ARTIFACT_DIR"] = str(stage)
        os.environ["DYLD_LIBRARY_PATH"] = str(stage)

    def _require_build_attestation_binding(self) -> None:
        path = self.args.expect_build_attestation
        if not path:
            raise Refused("--skip-build requires a previous completed coordinator build record")
        try:
            record_path = Path(path).resolve()
            recorded = json.loads(record_path.read_text())
            previous = json.loads((record_path.parent / "integration-report.json").read_text())
            if previous.get("skip_build") or previous.get("build_attestation") != recorded:
                raise ValueError("record was not produced by a completed actual-building coordinator")
            if recorded.get("producer_attempt") != previous.get("run_id"):
                raise ValueError("build producer attempt is not the completed run")
            if previous.get("producer_sha256") != sha256_file(Path(__file__)):
                raise ValueError("build producer source is not the current coordinator")
            sys.path.insert(0, str(REPO / "ci"))
            from check_integration_evidence import check_report
            problems, _ = check_report(record_path.parent, check_fixture_collision=False)
            if problems:
                raise ValueError("previous build evidence refused: " + "; ".join(problems))
            # *** THE LIVE INPUTS MUST STILL PRODUCE THE RECORDED FACTS, AND THE PREVIOUS RUN'S *EXISTING*
            # TESTED-BYTES ARCHIVE IS THE ONE COMPARED -- `record_build` is READ-ONLY and NEVER regenerates it, so a
            # wrong previous run/source/bundle/image/archive REFUSETH here instead of self-healing. ***
            live = self.make_build_attestation("macos", evidence_dir=record_path.parent)
            live["producer_attempt"] = recorded.get("producer_attempt")
            if live.get("tested_bytes") != recorded.get("tested_bytes"):
                raise ValueError("tested-bytes archive is absent or differs from the completed run's")
            live.pop("tested_bytes")
            recorded_facts = dict(recorded)
            recorded_facts.pop("tested_bytes", None)
            if live != recorded_facts:
                raise ValueError("candidate/tree/whole source/recipe/bundle/image/expected source differs")
            # *** AND THE VERIFIED ORIGINAL ARCHIVE IS COPIED INTO THIS RUN'S EVIDENCE DIR, SO `--skip-build` DOES NOT
            # REBUILD AN ARCHIVAL PROOF OF A PREVIOUS RUN -- IT CARRIES THE PREVIOUS RUN'S VERIFIED BYTES FORWARD. ***
            source = record_path.parent / build_provenance.TESTED_BYTES_ARCHIVE
            destination = self.evidence_dir / build_provenance.TESTED_BYTES_ARCHIVE
            if source.resolve() != destination.resolve():
                shutil.copyfile(source, destination)
            expected_archive = recorded.get("tested_bytes") or {}
            if (not destination.is_file() or destination.stat().st_size != expected_archive.get("bytes")
                    or sha256_file(destination) != expected_archive.get("sha256")):
                raise ValueError("the archival proof carried forward does not match the completed run's record")
        except (ValueError, OSError, subprocess.CalledProcessError) as exc:
            raise Refused(f"--skip-build attestation REFUSED: {exc}") from exc
        self._compile_android_fixtures()
        self.attestation_verified = True
        self.build_attestation_value = recorded

    def _compile_android_fixtures(self) -> None:
        java_home = os.environ.get("JAVA_HOME", "/opt/homebrew/opt/openjdk@17")
        android_home = os.environ.get("ANDROID_HOME", str(Path.home() / "Library" / "Android" / "sdk"))
        gradlew = REPO / "android" / "gradlew"
        if not gradlew.exists():
            raise Refused("*** NO COMMITTED GRADLE WRAPPER: android/gradlew is absent. ***")
        argv = [
            str(gradlew), "-p", str(REPO / "android"),
            ":mesh:compileDebugUnitTestKotlin", ":mesh:compileDebugUnitTestJavaWithJavac",
            "--no-daemon", "--console=plain",
        ]
        env = dict(os.environ)
        env.update({"JAVA_HOME": java_home, "ANDROID_HOME": android_home})
        self.log("*** compiling the Android worker's own test classpath ONCE ***")
        try:
            result = subprocess.run(argv, cwd=str(REPO), env=env, capture_output=True, text=True, timeout=7200)
        except subprocess.TimeoutExpired:
            raise Refused("*** THE ANDROID FIXTURE COMPILE DID NOT FINISH WITHIN ITS BOUND. ***")
        (self.runtime_dir / "android-compile.log").write_text(result.stdout + result.stderr)
        if result.returncode != 0:
            raise Refused(f"*** THE ANDROID FIXTURE COMPILE FAILED (rc={result.returncode}); see "
                          f"{self.runtime_dir / 'android-compile.log'} ***")
        self._android_ready = True
        self.log(f"  gradle compileDebugUnitTest: rc={result.returncode}, android_ready={self._android_ready}")

    # ---- the worker launches ----------------------------------------------------------------------------------

    def resolve_xctest(self) -> str:
        try:
            out = subprocess.run(["/usr/bin/xcrun", "--find", "xctest"], capture_output=True, text=True, timeout=60)
            path = out.stdout.strip()
            if path and Path(path).exists():
                return path
        except Exception:  # noqa: BLE001
            pass
        for candidate in ("/Applications/Xcode.app/Contents/Developer/usr/bin/xctest", "/usr/bin/xctest"):
            if Path(candidate).exists():
                return candidate
        raise Refused("*** NO `xctest` EXECUTABLE WAS FOUND, so the macOS worker cannot be launched. *** "
                      "Install Xcode or set PATH.")

    def resolve_swift_bundle(self) -> Path:
        if self._swift_bundle:
            return self._swift_bundle
        debug_dir = REPO / "ios" / "Packages" / "GodstoneFoundation" / ".build" / "debug"
        # Xcode 27 / Swift 6.4 builds per-target bundles; Xcode 16 / Swift 6.1 builds a merged package bundle.
        candidates = [
            debug_dir / SWIFT_BUNDLE_NAME,
            debug_dir / "GodstoneFoundationPackageTests.xctest",
        ]
        tried: list[str] = []
        for candidate in candidates:
            tried.append(str(candidate))
            if candidate.exists():
                self._swift_bundle = candidate
                return candidate
        raise Refused(
            f"*** THE macOS TEST BUNDLE IS ABSENT under {debug_dir}: tried {tried}. *** "
            "Run without `--skip-build`, or build it once with `swift build --build-tests`.")

    def launch_swift(self, name: str, role: str, variant: str, estate: Path, timeout_s: float) -> Worker:
        bundle = self.resolve_swift_bundle()
        xctest = self.resolve_xctest()
        spec = WorkerSpec(
            name=name, platform="ios", role=role, variant=variant, argv=[],
            env={ROLE_ENV: role, VARIANT_ENV: variant, ROOT_ENV: str(estate), DEADLINE_ENV: str(timeout_s)},
        )
        worker = Worker(spec, self.runtime_dir, self.log, {})   # creates the two FIFOs
        # *** THE macOS WORKER READS ITS PIPE PATHS FROM THE ENVIRONMENT (it inheriteth the parent's), WHICH IS THE
        # SIMPLEST THING THAT WORKS: `xcrun xctest` is launched directly here, with no intervening toolchain whose
        # argument list must carry them.***
        spec.env[IN_ENV] = str(worker.to_worker.path)
        spec.env[OUT_ENV] = str(worker.from_worker.path)
        spec.argv = [xctest, "-XCTest", SWIFT_WORKER_SELECTOR, str(bundle)]
        worker.launch = {"executable": xctest, "selector": SWIFT_WORKER_SELECTOR, "bundle": str(bundle),
                         "env_keys": [ROLE_ENV, VARIANT_ENV, ROOT_ENV, DEADLINE_ENV, IN_ENV, OUT_ENV]}
        worker.start()
        self.workers.append(worker)
        self.all_workers.append(worker)
        self.evidence.note_launch(name, "ios", role, variant, spec.argv, str(estate), worker.launch)
        return worker

    def launch_android(self, name: str, role: str, variant: str, estate: Path, timeout_s: float) -> Worker:
        # *** THE CRASH ROLES USE THE OVERRIDABLE TASK/CLASS; EVERY OTHER ROLE USES THE COMMITTED DEFAULTS. ***
        is_crash = role in ("crash-prepare", "crash-recover")
        task = ANDROID_CRASH_TASK if is_crash else ANDROID_WORKER_TASK
        klass = ANDROID_CRASH_CLASS if is_crash else ANDROID_WORKER_CLASS
        java_home = os.environ.get("JAVA_HOME", "/opt/homebrew/opt/openjdk@17")
        android_home = os.environ.get("ANDROID_HOME", str(Path.home() / "Library" / "Android" / "sdk"))
        gradlew = REPO / "android" / "gradlew"
        if not gradlew.exists():
            raise Refused("*** NO COMMITTED GRADLE WRAPPER: android/gradlew is absent. ***")
        # *** THE ANDROID CRASH ROLES KEEP THE COORDINATOR'S OWN ROLE NAME. *** *The worker's dispatch (`when (role)`)
        # and its crash `Marker` both speak `crash-prepare`/`crash-recover` verbatim, so the requested and reported
        # roles are the same string and the identity comparison is direct -- **no translation stands between the
        # coordinator's request and the worker's own record.***
        # *** THE FIFOs ARE CREATED BEFORE THE TASK IS LAUNCHED, AND THEIR PATHS TRAVEL AS SYSTEM PROPERTIES. ***
        spec = WorkerSpec(
            name=name, platform="android", role=role, variant=variant, argv=[],
            env={"JAVA_HOME": java_home, "ANDROID_HOME": android_home,
                 ROLE_ENV: role, VARIANT_ENV: variant, ROOT_ENV: str(estate), DEADLINE_ENV: str(timeout_s)},
        )
        worker = Worker(spec, self.runtime_dir, self.log, {})   # creates the two FIFOs
        argv = [
            str(gradlew), "-p", str(REPO / "android"), task,
            "--no-daemon", "--console=plain", "--rerun-tasks",
            # *** THE LAUNCH IS NARROWED TO THE WORKER CLASS ITSELF. ***
            #
            # *THE DEFECT THIS CLOSES: the committed task's filter is `*RealTransportHostRig*`, so EVERY worker launch
            # ALSO ran `RealTransportHostRigTests` -- the rig's own court -- and a red arm THERE made the Gradle build
            # exit non-zero. **The worker's own exit code therefore did not describe the worker**: a passing worker
            # behind a failing sibling court read as a failed launch, and the coordinator could neither require a
            # clean exit nor trust one.* **`--tests` narrows this launch to the exact worker class, so the process
            # status IS the worker's own -- which is what maketh "the worker exited 0 after ACK" a checkable fact
            # rather than a coincidence.** *The rig court still runs in its own right in the default suite and in the
            # crash lane; it is simply no longer charged to the worker's exit.*
            "--tests", klass,
        ]
        argv += [
            f"-D{ANDROID_ROLE_PROP}={role}",
            f"-D{ANDROID_VARIANT_PROP}={variant}",
            f"-D{ANDROID_ROOT_PROP}={estate}",
            f"-D{ANDROID_DEADLINE_PROP}={timeout_s}",
            f"-D{ANDROID_IN_PROP}={worker.to_worker.path}",
            f"-D{ANDROID_OUT_PROP}={worker.from_worker.path}",
        ]
        worker.spec.argv = argv
        worker.launch = {"executable": str(gradlew), "task": task,
                         "requested_role": role, "reported_role": role,
                         "test_class": klass,
                         "jvm_args": [a for a in argv if a.startswith("-D")],
                         "env_keys": ["JAVA_HOME", "ANDROID_HOME"], "info_log": is_crash}
        worker.start()
        self.workers.append(worker)
        self.all_workers.append(worker)
        self.evidence.note_launch(name, "android", role, variant, argv, str(estate), worker.launch)
        return worker

    # ---- the election and the seat ----------------------------------------------------------------------------

    @staticmethod
    def elect(hint_hex_a: str, hint_hex_b: str) -> str:
        """*** THE PRODUCTION ELECTION, BY NAME: the smaller unsigned four-octet hint is the INITIATOR. ***
        *Equal-length lowercase hex compares exactly as the unsigned bytes do, so this is the same answer
        `BleRoleElection.elect` giveth -- and the coordinator ASKS the workers' own hints rather than assuming.*"""
        if len(hint_hex_a) != len(hint_hex_b):
            raise Refused("the two workers' hints are not the same width; refusing to guess an election")
        if hint_hex_a == hint_hex_b:
            raise Refused("*** THE TWO NODES MINTED THE SAME HINT: a tie is not an election. ***")
        return "initiator" if hint_hex_a < hint_hex_b else "responder"

    def seat_pair(self, sender: Worker, receiver: Worker, seed_attr: str,
                  sender_seed: int, receiver_seed: int, timeout_s: float) -> None:
        """*** RE-MINT UNTIL THE PRODUCTION ELECTION SEATS THE SENDER AS THE INITIATOR. ***

        *THE FACT THAT MAKETH THIS NECESSARY IS PRODUCTION'S, AND IT IS NAMED RATHER THAN WORKED AROUND:* a node is
        reachable in the route-eligible view only through `trustedPeerDidConnect`, which production reacheth only
        from `publishApplicationLinkReadyOnce`, which is reached only from `takeInboundKeyConfirmation`'s RESPONSE
        branch -- **and only the party that ISSUES the challenge receives that echo, which is the election's
        INITIATOR.** *So a sender seated as the responder would dispatch to nobody and the egress window would read
        zero for a reason that had nothing to do with the cross-platform wire.*

        **NOTHING HAS HAPPENED YET when a re-mint is asked for** -- no link, no session, no store row -- *so a fresh
        identity over a fresh estate is a DIFFERENT HONEST ELECTION rather than a role forced against the election.
        The election is decided on the REAL hints, and the advertised pair is required to elect the same way, so the
        mismatch control cannot move the role by accident.*
        """
        sender_hello = sender.wait(lambda r: r.kind == "hello", timeout_s, "its startup `hello` identity")
        receiver_hello = receiver.wait(lambda r: r.kind == "hello", timeout_s, "its startup `hello` identity")
        # *** AND THE WORKER'S OWN RECORD MUST CONFIRM THE IDENTITY THE COORDINATOR ASKED FOR. ***
        self.require_reported_identity(sender, sender_hello)
        self.require_reported_identity(receiver, receiver_hello)
        attempts = 0
        while attempts <= 16:
            sender_real = str(sender_hello.header.get("real_hint", ""))
            receiver_real = str(receiver_hello.header.get("real_hint", ""))
            if sender_real and receiver_real and self.elect(sender_real, receiver_real) == "initiator":
                break
            attempts += 1
            # *** BOTH SIDES ARE RE-MINTED, NOT THE SENDER ALONE -- THE SENDER ALONE IS NOT ENOUGH. ***
            #
            # *THE DEFECT THIS CLOSES, MEASURED: only the SENDER was re-minted, so the receiver's hint stood FIXED
            # for all 16 attempts. When that fixed hint is very small -- the live run's receiver held `0bb99473`,
            # first octet 0x0b -- a random sender hint is below it only ~4.3% of the time, so 16 attempts failed
            # about half the time and the run refused with `THE SENDER COULD NOT BE SEATED AS THE INITIATOR IN 16
            # RE-MINTS` (observed: ALL SEVENTEEN sender hints were above `0bb99473`).* **Re-minting BOTH maketh each
            # attempt a fresh draw of the ORDER, which the election is a function of, so the pair convergeth in a
            # handful of rounds rather than depending on the receiver's hint happening to be large.** *And it is
            # equally honest by the same law the single-side re-mint relied on: nothing has happened yet -- no link,
            # no session, no store row -- so BOTH are fresh identities over fresh estates rather than either side
            # forced against the production election.*
            sender_seed += 1
            receiver_seed += 1
            self.log(f"  re-mint: sender hint {sender_real} does not open against {receiver_real}; asking BOTH for "
                     f"seeds 0x{sender_seed & 0xFF:02x}/0x{receiver_seed & 0xFF:02x}")
            sender.send("mint", b"", seed=sender_seed & 0xFF)
            receiver.send("mint", b"", seed=receiver_seed & 0xFF)
            sender_hello = sender.wait(lambda r: r.kind == "hello", timeout_s, "its re-minted `hello`")
            receiver_hello = receiver.wait(lambda r: r.kind == "hello", timeout_s,
                                           "its re-minted `hello`")
        else:
            raise Refused("*** THE SENDER COULD NOT BE SEATED AS THE INITIATOR IN 16 RE-MINTS. *** *Refusing rather "
                          "than grinding: a hint collision this persistent is a defect, not bad luck.*")
        setattr(self, seed_attr, sender_seed)
        if "sender" in seed_attr:
            setattr(self, seed_attr.replace("sender", "receiver"), receiver_seed)
        self.log(f"  seat: sender real_hint={sender_real} receiver real_hint={receiver_real} -> the sender is the "
                 f"production election's INITIATOR (re-mints={attempts})")

        # *** THE ADVERTISED HINTS MUST STILL ELECT THE SAME WAY, OR THE MISMATCH CONTROL WOULD BE MEASURING THE
        # ROLE ELECTION RATHER THAN THE BINDING. ***
        sender_adv = str(sender_hello.header.get("node_hint", ""))
        receiver_adv = str(receiver_hello.header.get("node_hint", ""))
        if self.elect(sender_adv, receiver_adv) != "initiator":
            raise Refused(
                f"*** THE ADVERTISED HINTS ELECT AGAINST THE REAL ONES (sender {sender_adv} vs {receiver_adv}). *** "
                "A hint that moves the election would refuse the mismatched control for the WRONG REASON.")

        # *** THE IDENTITIES CROSS, AND EACH IS LEARNT FROM THE OTHER'S `hello` (NO PRE-TRUST IS WRITTEN). ***
        #
        # *** AND `real_hint` CROSSETH TOO, WHICH IS WHAT MAKETH THE MISMATCHED CONTROL MEASURE THE RIGHT BOUNDARY. ***
        # *THE DEFECT THIS CLOSES, MEASURED: only `("node_id", "node_hint", "static_dh_pub", "binding")` were
        # forwarded. `node_hint` IS the ADVERTISED hint -- the `mismatched` control lies there BY DESIGN -- so the iOS
        # worker (which VALIDATES the peer's binding at its pin, `acceptPeer`) fell back to the LIE for the hint it
        # authenticated against and refused the pin with `IdentityBindingValidator` BEFORE any session existed. That
        # is a refusal at the PIN, not at the sealed-handshake boundary the control is about.* **The peer's REAL hint
        # (`real_hint` on the same `hello`) is what the TOFU pin must authenticate against; the advertised hint is
        # what the SEALED ROUND must later contradict.** *The Android worker does not pre-pin, which is why
        # ios->android mismatched passed while android->ios could not: the fix maketh the two directions symmetric
        # rather than changing what any control measures.*
        for me, them in ((sender, receiver_hello), (receiver, sender_hello)):
            me.send("peer", b"", **{k: them.header.get(k, "") for k in
                                    ("node_id", "node_hint", "real_hint", "static_dh_pub", "binding")})
        for me in (sender, receiver):
            me.send("setup", b"", seat="initiator" if me is sender else "responder")
        for me in (sender, receiver):
            ready = me.wait(lambda r: r.kind in ("ready", "refuse"), timeout_s, "its `ready` marker")
            if ready.kind == "refuse":
                raise Refused(f"*** THE {me.name} WORKER REFUSED AT ITS SEAT: "
                              f"{ready.header.get('reason', 'no reason given')} ***")
            self.log(f"  {me.name} seated: {dict(ready.header)}")

    # ---- the relay --------------------------------------------------------------------------------------------

    def require_reported_identity(self, worker: Worker, rec: Record) -> None:
        """*** THE WORKER'S OWN RECORD MUST CONFIRM THE ROLE, VARIANT AND PLATFORM THE COORDINATOR ASKED FOR. ***

        *THE DEFECT THIS CLOSES, AND IT IS THE COORDINATOR'S HALF OF `Main`'s FINDING: the coordinator PASSED a role
        and variant to each worker (`launch_swift`/`launch_android`) and recorded what it REQUESTED, but **NEVER
        COMPARED THE WORKER'S OWN REPORTED `role`/`variant`/`platform` HEADERS AGAINST THAT REQUEST** -- so a worker
        that silently downgraded an unknown variant (the iOS `?? .honest` path) or a substituted worker that reported a
        different identity would be recorded as the requested one.* **A REQUESTED-vs-REPORTED MISMATCH IS REFUSED BY
        NAME.** *The workers now also refuse an unknown variant at their own root, so this is defence in depth: the
        control the manifest claims to have run is the control the worker says it ran.*
        """
        rrole = str(rec.header.get("role", ""))
        rvar = str(rec.header.get("variant", ""))
        rplat = str(rec.header.get("platform", ""))
        mismatches: list[str] = []
        if rrole != worker.spec.role:
            mismatches.append(f"role requested={worker.spec.role!r} reported={rrole!r}")
        if rvar != worker.spec.variant:
            mismatches.append(f"variant requested={worker.spec.variant!r} reported={rvar!r}")
        if rplat and worker.spec.platform and rplat != worker.spec.platform:
            mismatches.append(f"platform requested={worker.spec.platform!r} reported={rplat!r}")
        if mismatches:
            raise Refused(
                f"*** THE {worker.name} WORKER'S OWN RECORD DOES NOT MATCH WHAT WAS REQUESTED: "
                f"{'; '.join(mismatches)}. *** *A worker that is not the one the coordinator asked for (a downgraded "
                f"variant, a substituted identity) cannot stand as the witness for the requested control.*")

    def relay(self, source: Worker, target: Worker, direction: str, *, control: str,
              mutate: Optional[Callable[[bytes], bytes]] = None, note: str = "",
              replay: bool = False, origin_epoch: Any = None,
              tamper_after_authored: bool = False, authored_seen: Optional[Callable[[], bool]] = None,
              ) -> list[dict[str, Any]]:
        """*** THE WIRE. EXACT BYTES, UNINTERPRETED. ***

        *** `tamper_after_authored` IS THE METADATA-ONLY DISCRIMINATOR FOR THE ALTERED-RECORD CONTROL. *** *The
        coordinator cannot decode a payload -- it does not know whether a record is a handshake counsel or a sealed
        DATA record. **What it CAN know is ORDER: the producer emitted `authored` at the instant the DATA frame stood
        in memory and BEFORE it went on the wire, so every byte that crosseth after that marker is the record the
        control is about, and every byte before it belongeth to the handshake.*** *So the mutation is applied only
        once `authored_seen()` answereth true, and the handshake is left byte-perfect -- otherwise the altered control
        would corrupt the handshake and measure a refusal for the wrong reason.*

        *Every `frame` record `source` emitted is framed into the transcript, then written to `target` as an
        `inject` record carrying the SAME payload octet-for-octet -- except where a control deliberately flips one.
        The coordinator reads only the length prefixes and the routing keys of the metadata header; **it never reads
        the payload's meaning.***
        """
        entries: list[dict[str, Any]] = []
        for rec in source.take():
            if rec.kind != "frame":
                continue
            payload = rec.payload
            mutated = False
            may_mutate = mutate is not None and (not tamper_after_authored
                                                 or (authored_seen is not None and authored_seen()))
            if may_mutate:
                altered = mutate(payload)
                mutated = altered != payload
                payload = altered
            entry = self.evidence.append(
                rec, direction=direction, producer=source.name, target=target.name,
                characteristic=str(rec.header.get("characteristic", "")), epoch=rec.header.get("epoch"),
                platform=source.platform,
                note=(note or control) + (" [+1 octet flipped by the coordinator]" if mutated else ""))
            entries.append(entry)
            target.send("inject", payload,
                        characteristic=str(rec.header.get("characteristic", "")),
                        sequence=entry["sequence"], epoch=rec.header.get("epoch", 0),
                        source_producer=source.name, control=control, replay=replay,
                        origin_epoch=(origin_epoch if origin_epoch is not None else rec.header.get("epoch")))
        return entries

    def pump(self, a: Worker, b: Worker, direction: str, *, control: str, until: Callable[[], bool],
             timeout: float, mutate_from: Optional[str] = None,
             mutate: Optional[Callable[[bytes], bytes]] = None,
             tamper_after_authored: bool = False,
             authored_seen: Optional[Callable[[], bool]] = None,
             release: Optional[Callable[[], None]] = None) -> None:
        """Relay both ways until `until()` or the deadline. Bounded, always."""
        deadline = time.monotonic() + timeout
        flip = flip_direction(direction)
        while time.monotonic() < deadline:
            if until():
                return
            if release is not None:
                release()
                release = None
            self.relay(a, b, direction, control=control,
                       mutate=mutate if mutate_from == a.name else None,
                       tamper_after_authored=tamper_after_authored, authored_seen=authored_seen)
            self.relay(b, a, flip, control=control,
                       mutate=mutate if mutate_from == b.name else None,
                       tamper_after_authored=tamper_after_authored, authored_seen=authored_seen)
            time.sleep(0.02)
        if not until():
            raise Refused(f"*** {direction} ({control}): THE RELAY DID NOT REACH ITS COMPLETION WITHIN "
                          f"{timeout:.0f}s. *** receiver={self.summary(b)} sender={self.summary(a)}")

    def record_observation(self, worker: Worker, direction: str, control: str) -> list[dict[str, Any]]:
        """*** THE WORKERS' OWN VERDICT RECORDS GO INTO THE SAME TRANSCRIPT. ***

        *The wire records carrieth the exact bytes that crossed; the `observe`/`ack` records carrieth the owners' own
        answers -- **the recipient's durable row, the sender's DELIVERY transition, and every refusal read from a
        rejection ring.*** **Both halves are evidence, and neither interprets a payload: the payload field of an
        observation is EMPTY, and only its metadata header (which names a msgId or a refusal SITE) is ever read.**
        """
        entries: list[dict[str, Any]] = []
        for rec in worker.take():
            if rec.kind not in ("observe", "ack", "ready", "authored"):
                continue
            entry = self.evidence.append(
                rec, direction=direction, producer=worker.name, target=worker.name,
                characteristic="control", epoch=rec.header.get("epoch"), platform=worker.platform,
                note=f"{control}: {rec.kind} recorded from the worker's own owner observations")
            entries.append(entry)
        return entries

    def summary(self, worker: Worker) -> str:
        return str([r.header for r in worker.all_of("observe")][-3:])

    def _settle_pair(self, sender: Worker, receiver: Worker, direction: str, control: str) -> None:
        """*** THE WITNESSES' OWN EXIT IS OBSERVED BEFORE THE CLEANUP CAN SUPPLY ONE. ***

        *THE DEFECT THIS CLOSES: `run_direction` sent `bye` and went STRAIGHT to `close()`, which sendeth the
        coordinator's own SIGTERM/SIGKILL to anything still running -- **so the worker's recorded termination was
        always the COORDINATOR'S kill, and a cross-platform witness that actually hung would look exactly like one
        that exited cleanly.*** **Here each witness is given a bounded chance to exit on its OWN after `bye`; the
        termination is observed, recorded, and -- for a witness -- REQUIRED to be a real exit rather than a cleanup
        kill.** *The plan's law: a cross-platform worker must exit 0 after ACK (or by a typed intentional halt), never
        by the coordinator's cleanup.*
        """
        for w in (sender, receiver):
            status = w.wait_exit(min(self.deadline_s, 120.0))
            term = w.observe_termination()
            if term.forced_kill or term.termination_reason.startswith("coordinator-"):
                raise Refused(
                    f"*** {direction} ({control}): THE {w.name} WITNESS ENDED BY THE COORDINATOR'S OWN CLEANUP "
                    f"({term.describe()}). *** *A worker must exit 0 after its verdict -- or by a TYPED INTENTIONAL "
                    f"halt -- rather than being killed by the coordinator whose verdict it witnesses.*")
            if status is None:
                raise Refused(
                    f"*** {direction} ({control}): THE {w.name} WITNESS WAS STILL RUNNING AFTER `bye` AND ITS "
                    f"{min(self.deadline_s, 120.0):.0f}s GRACE. *** *A hung witness is not a clean exit; refusing "
                    f"rather than letting `close()` supply the death.* log={w.log_path}")
            if status != 0:
                # *** THE ONE ACCEPTED NON-ZERO WITNESS EXIT: the worker's OWN typed intentional halt. ***
                #
                # *The plan's law alloweth "exit 0 after ACK **or** a verified typed intentional halt". VERIFIED
                # means the worker's retained log carrieth the marker line
                # `GS_INTEGRATION_INTENTIONAL_HALT status=<n>` and `<n>` EQUALS the observed process status --
                # a claim without the marker text, or a marker that does not name the observed death, is a failed
                # launch, not a halt.*
                marker = _find_intentional_halt(w.log_path, status)
                if marker is None:
                    raise Refused(
                        f"*** {direction} ({control}): THE {w.name} WITNESS EXITED {status} AFTER ITS VERDICT "
                        f"WITH NO TYPED INTENTIONAL-HALT EVIDENCE IN ITS OWN LOG. *** *The normal path is exit 0; "
                        f"a non-zero status is a failed worker launch, not a verdict.* log={w.log_path}")
                term.intentional_halt = True
                term.intentional_halt_marker = marker
                self.log(f"  {w.name}: typed intentional halt accepted "
                        f"(marker {marker!r}, status={status}, pid={term.pid})")

    # ---- observation helpers ----------------------------------------------------------------------------------

    @staticmethod
    def durable_of(worker: Worker) -> Optional[Record]:
        """*** THE DURABLE ROW, PREFERRING THE ONE READ FROM THE REOPENED ESTATE. ***

        *`observe` returneth the FIRST match, and the live-store observations are emitted BEFORE the reopened ones --
        so a plain first-match would hand the verdict the RUNNING store's claim. **The reopened record is the durable
        proof, so it is selected explicitly when it existeth.***
        """
        reopened = worker.observe(lambda r: r.kind == "observe" and r.header.get("reopened") is True
                                  and r.header.get("durable_row") == "present")
        if reopened is not None:
            return reopened
        return worker.observe(lambda r: r.kind == "observe" and r.header.get("durable_row") == "present")

    @staticmethod
    def refusal_of(worker: Worker) -> Optional[Record]:
        return worker.observe(lambda r: r.kind == "observe"
                              and r.header.get("durable_row") == "absent"
                              and bool(r.header.get("refusal")))

    @staticmethod
    def delivered_of(worker: Worker) -> Optional[Record]:
        """*** THE DELIVERY TRANSITION, PREFERRING THE ONE READ FROM THE REOPENED ESTATE. *** *See `durable_of`.*"""
        reopened = worker.observe(lambda r: r.kind == "observe" and r.header.get("reopened") is True
                                  and r.header.get("delivery") == "DELIVERED")
        if reopened is not None:
            return reopened
        return worker.observe(lambda r: r.kind == "observe" and r.header.get("delivery") == "DELIVERED")

    @staticmethod
    def reopened_of(worker: Worker) -> Optional[Record]:
        return worker.observe(lambda r: r.kind == "observe" and r.header.get("reopened") is True)

    def _reprove_from_reopened_estate(self, sender: Worker, receiver: Worker, direction: str,
                                       control: str) -> tuple[str, str]:
        """*** RE-QUERY EACH SIDE'S DURABLE ESTATE AFTER IT HATH BEEN CLOSED AND REOPENED, AND DRIVE THE
        CANCELLATION NEGATIVE. ***

        *The live-store answers are what the exchange produced; **the durable PROOF must come from the estate the
        process REACHETH AFTER RELEASING ITS HANDLES, or a `present` row echoeth a running object rather than a
        surviving one.*** *Both seats are asked because the sender proveth its DELIVERY transition and the recipient
        its INBOX ROW, and each is re-read from the reopened store of ITS OWN estate.* **AND the cancellation negative
        is driven on the SAME reopened estate: a fresh frame is committed and cancelled through the owners' own roads,
        then re-read after a SECOND reopen -- so a cancel that silently did nothing, or moved the wrong row, is
        observable rather than assumed.**
        """
        # *** (1) THE CANCELLATION NEGATIVE IS COMMITTED BEFORE THE FIRST REOPEN. ***
        sender.send("cancel")
        cancel_rec = sender.wait(lambda r: r.kind == "observe" and "cancel" in r.header,
                                 min(self.deadline_s, 120.0), f"its cancellation negative for {control}")
        self.record_observation(sender, direction, control)
        cancel_msg_id = str(cancel_rec.header.get("msg_id", ""))
        state = str(cancel_rec.header.get("state", ""))
        self.log(f"  {sender.name} cancellation: verdict={cancel_rec.header.get('cancel')} "
                 f"msg_id={cancel_msg_id} state={state}")
        if not cancel_msg_id:
            raise Refused(f"*** {direction} ({control}): THE CANCELLATION NEGATIVE REPORTED NO msgId. ***")
        if "cancel" not in state.lower():
            raise Refused(f"*** {direction} ({control}): THE TRACKER'S OWN `cancel` DID NOT MOVE THE ROW TO A "
                          f"CANCELLED STATE (observed {state!r}). *** *A cancel that left the row queued is not a "
                          f"cancellation.*")

        # *** (2) THE DURABLE ROW/DELIVERY ARE RE-PROVEN FROM THE REOPENED ESTATE. ***
        for w in (sender, receiver):
            w.send("reopen")
        reopened: dict[str, Record] = {}
        for w in (sender, receiver):
            rec = w.wait(lambda r: r.kind == "observe" and r.header.get("reopened") is True,
                         min(self.deadline_s, 120.0), f"its REOPENED-estate proof for {control}")
            reopened[w.name] = rec
            self.record_observation(w, direction, control)
            self.log(f"  {w.name} reopened estate: row={rec.header.get('durable_row')} "
                     f"msg_id={rec.header.get('msg_id')} delivery={rec.header.get('delivery')} "
                     f"cancellation={rec.header.get('cancellation_state')}")
        # *** THE REOPENED STORE MUST CORROBORATE THE LIVE ANSWER, NOT CONTRADICT IT. ***
        rec_row, send_row = reopened[receiver.name], reopened[sender.name]
        if rec_row.header.get("durable_row") != "present":
            raise Refused(f"*** {direction} ({control}): THE RECIPIENT'S REOPENED ESTATE HOLDS NO DURABLE ROW. *** "
                          f"*The row did not survive the close/reopen, so the live-store claim was not durable.* "
                          f"reopened={dict(rec_row.header)}")
        if send_row.header.get("delivery") != "DELIVERED":
            raise Refused(f"*** {direction} ({control}): THE SENDER'S REOPENED ESTATE SHOWS DELIVERY "
                          f"{send_row.header.get('delivery')!r}, NOT DELIVERED. *** *A delivery transition that is "
                          f"not re-readable from the reopened store is not durable.* "
                          f"reopened={dict(send_row.header)}")
        # *** (3) AND THE CANCELLED ROW SURVIVED THE REOPEN IN ITS CANCELLED STATE. ***
        reopened_cancel_state = str(send_row.header.get("cancellation_state", ""))
        reopened_cancel_id = str(send_row.header.get("cancellation_msg_id", ""))
        if reopened_cancel_id and reopened_cancel_id != cancel_msg_id:
            raise Refused(f"*** {direction} ({control}): THE REOPENED ESTATE NAMES A DIFFERENT CANCELLATION FRAME "
                          f"({reopened_cancel_id} vs {cancel_msg_id}). ***")
        if "cancel" not in reopened_cancel_state.lower():
            raise Refused(f"*** {direction} ({control}): THE CANCELLED ROW DID NOT SURVIVE THE REOPEN (state="
                          f"{reopened_cancel_state!r}). *** *A cancellation that is not re-readable from the reopened "
                          f"store is not a durable cancellation.*")
        return cancel_msg_id, reopened_cancel_state

    # ---- one cross-platform direction -------------------------------------------------------------------------

    def run_direction(self, direction: str, control: str) -> Result:
        """*** ONE FOREIGN-PLATFORM DIRECTION, ONE CONTROL. ***

        *The sender authors and drives its OWN real transport, so the bytes that cross are whatever its OS facade
        handed its stack; the receiver re-enters them at its OWN OS ingress. Each side then readeth its OWN durable
        owner -- the receiver its store's row, the sender its delivery tracker.*
        """
        self.log(f"--- direction {direction} control={control} ---")
        ios_is_sender = direction == IOS_TO_ANDROID
        # *** THE ESTATE IS NAMED PER INVOCATION, NOT PER (direction, control). ***
        #
        # *THE DEFECT THIS CLOSES, MEASURED: the `replay` control's PHASE A re-driveth the honest direction
        # (`run_replay` -> `run_direction(direction, "honest")`), and the name `estate-ios_android-honest` had
        # ALREADY been used by the honest control's own run -- so the re-driven receiver reopened a store that
        # still held the FIRST run's durable row. Its `refreshReports` then never re-emitted `observe` (the row
        # predated the seat, so the row token never changed), and the coordinator read the STALE row: measured as
        # `THE RECIPIENT'S ROW NAMES A DIFFERENT MESSAGE (ef806bc4… vs 7b9974fa…)`, where the sender had just
        # authored 7b9974fa and the store answered a previous message's id.* **A phase that re-runs a control must
        # not inherit that control's estate, or the control's own store answereth for a session it never ran.** *So
        # every invocation carrieth its own suffix; a re-run getteth a fresh estate by construction rather than by
        # the caller remembering to differ the name.*
        invocation = f"{control}-{self.run_id}-{self._invocation}"
        self._invocation += 1
        estate = self.fresh_estate(f"{direction.replace('->', '_')}-{invocation}")
        ios_estate = estate / "ios"
        android_estate = estate / "android"
        ios_estate.mkdir(parents=True, exist_ok=True)
        android_estate.mkdir(parents=True, exist_ok=True)

        sender_variant = "mismatched" if control == "mismatched" else "honest"
        swift = self.launch_swift(f"swift-{control}", "sender" if ios_is_sender else "recipient",
                                  sender_variant if ios_is_sender else "honest", ios_estate, self.deadline_s)
        android = self.launch_android(f"android-{control}", "sender" if not ios_is_sender else "recipient",
                                      sender_variant if not ios_is_sender else "honest",
                                      android_estate, self.deadline_s)
        sender = swift if ios_is_sender else android
        receiver = android if ios_is_sender else swift
        try:
            self.seat_pair(sender, receiver, seed_attr="sender_seed",
                           sender_seed=IOS_SEED if ios_is_sender else ANDROID_SEED,
                           receiver_seed=ANDROID_SEED if ios_is_sender else IOS_SEED,
                           timeout_s=self.deadline_s)
            # *** THE COORDINATOR MUST NOT BLOCK ON `authored` HERE, AND THAT IS A MEASURED DEADLOCK REPAIR. ***
            #
            # *`authored` is emitted only once the producer's `isReady()` standeth -- **and readiness requireth the
            # RELAYED sealed handshake.*** When the coordinator waited for `authored` BEFORE relaying, it waited for
            # the very thing only the relay could produce: deadlock, measured as
            # `THE swift-honest WORKER NEVER REACHED its `authored` marker WITHIN 150s`. **So the message id is read
            # AFTER the exchange, from the producer's own `observe`/`authored` record.**
            msg_id = ""

            # *** THE TAMPER CONTROL FLIPS ONE OCTET AT AN OFFSET DERIVED FROM THE LENGTH. *** *It never reads the
            # payload: that is adversarial tampering, not decoding -- a coordinator that could parse a frame could
            # manufacture one.*
            def tamper(payload: bytes) -> bytes:
                if len(payload) < 4:
                    return payload
                out = bytearray(payload)
                out[len(out) - 1] ^= 0x01
                return bytes(out)

            mutate = tamper if control == "altered" else None

            def authored_seen() -> bool:
                return sender.observe(lambda r: r.kind == "authored") is not None

            # *** THE CANCELLATION NEGATIVE'S OWN PROOF, SET BY THE REOPEN PROOF ON THE HONEST ARM. ***
            cancel_proof: Optional[tuple[str, str]] = None

            if control == "honest":
                # *The honest control runneth the WHOLE handshake and the DATA record; no release is needed because
                # nothing is held back.* **`go` is sent anyway, so the producer's DATA dispatch is never gated on a
                # message the honest path forgot.**
                sender.send("go")
                self.pump(sender, receiver, direction, control=control, timeout=self.deadline_s,
                          until=lambda: (self.durable_of(receiver) is not None
                                         and self.delivered_of(sender) is not None),
                          mutate_from=sender.name, mutate=mutate)
                # *** THE MESSAGE ID IS RESOLVED FROM THE EXCHANGE'S OWN EVIDENCE, NOT WAITED FOR BEFORE IT. ***
                authored = sender.observe(lambda r: r.kind == "authored")
                msg_id = str(authored.header.get("msg_id", "")) if authored else ""
                self.log(f"  authored msg_id={msg_id or '(none reported)'}")
                # *** THE DURABLE ROW IS RE-PROVEN FROM THE REOPENED ESTATE, NOT MERELY FROM THE RUNNING STORE. ***
                #
                # *THE DEFECT THIS CLOSES: `durable_row: present`/`delivery: DELIVERED` were read from the LIVE
                # stores, so a reader could not distinguish a surviving row from a running object's own state -- the
                # self-attestation the plan forbids. **Each side is now told to stop its owner, release its handles,
                # and re-read the SAME on-disk estate; the row/delivery the verdict useth is the one the REOPENED
                # store answereth.*** *This is the "each direction must independently query the reopened durable
                # estate" clause.*
                cancel_proof = self._reprove_from_reopened_estate(sender, receiver, direction, control)
            elif control == "mismatched":
                sender.send("go")
                self.pump(sender, receiver, direction, control=control, timeout=min(self.deadline_s, 120.0),
                          until=lambda: (self.refusal_of(receiver) is not None
                                         or self.refusal_of(sender) is not None
                                         or self.durable_of(receiver) is not None),
                          mutate_from=sender.name, mutate=mutate)
            else:  # altered
                # *** THE DATA RECORD IS NOT RELEASED UNTIL THE COORDINATOR MARKETH THE BOUNDARY. ***
                #
                # *The handshake is carried byte-perfect first; when the producer announceth `authored` -- the instant
                # the sealed frame stand eth in memory and before any of its bytes exist -- the coordinator send eth
                # `go` and turn eth tampering ON. **So the ONLY mutated record is the sealed DATA record, which is
                # exactly the "ALTERED authenticated DATA record" the plan nameth.***
                deadline = time.monotonic() + min(self.deadline_s, 120.0)
                while time.monotonic() < deadline and not authored_seen():
                    self.relay(sender, receiver, direction, control=control)
                    self.relay(receiver, sender, flip_direction(direction), control=control)
                    time.sleep(0.02)
                if not authored_seen():
                    raise Refused(f"*** {direction} ({control}): THE PRODUCER NEVER ANNOUNCED ITS AUTHORED FRAME, so "
                                  f"the DATA record could not be isolated for tampering. ***")
                self.log("  the producer announced `authored`; releasing the DATA record WITH the tamper enabled")
                sender.send("go")
                self.pump(sender, receiver, direction, control=control, timeout=min(self.deadline_s, 120.0),
                          until=lambda: (self.refusal_of(receiver) is not None
                                         or self.durable_of(receiver) is not None),
                          mutate_from=sender.name, mutate=mutate,
                          tamper_after_authored=True, authored_seen=authored_seen)

            # *** THE WORKERS' OWN OBSERVATIONS ENTER THE TRANSCRIPT BEFORE THE VERDICT IS READ. *** *The wire
            # records carrieth the bytes; these carrieth the owners' answers, and the manifest's per-record digest
            # chain covers both.*
            for w in (sender, receiver):
                self.record_observation(w, direction, control)
            result = self.judge(direction, control, sender, receiver, msg_id,
                                cancellation=(cancel_proof if control == "honest" else None))
            for w in (sender, receiver):
                w.send("bye")
            self._settle_pair(sender, receiver, direction, control)
            return result
        finally:
            for w in (sender, receiver):
                w.close()
                self.workers = [x for x in self.workers if x is not w]

    def judge(self, direction: str, control: str, sender: Worker, receiver: Worker,
              msg_id: str, cancellation: Optional[tuple[str, str]] = None) -> Result:
        """*** THE VERDICT IS READ FROM EACH SIDE'S OWN OWNER, NEVER FROM A BYTES-CROSSED CLAIM. ***"""
        if control == "honest":
            durable = self.durable_of(receiver)
            delivered = self.delivered_of(sender)
            # *** AND THE REOPENED-ESTATE PROOF *AND* THE CANCELLATION NEGATIVE MUST HAVE STOOD. ***
            #
            # *THE DEFECT THIS CLOSES: a `present`/`DELIVERED` claim read from the LIVE stores could not be told from
            # a running object's own state, and the tracker's OTHER terminal move (cancel) was never exercised at all.
            # **Both are now REQUIRED before an honest row may be ACCEPTED.***
            if cancellation is None:
                raise Refused(f"*** {direction} ({control}): NO REOPENED-ESTATE / CANCELLATION PROOF WAS TAKEN. *** "
                              f"*An honest row that never re-read the reopened estate and never drove the cancellation "
                              f"negative is not durable evidence.*")
            if durable is None:
                raise Refused(f"*** {direction} ({control}): THE RECIPIENT NEVER PROVED ITS DURABLE ROW. *** "
                              f"receiver said: {self.summary(receiver)}")
            if delivered is None:
                raise Refused(f"*** {direction} ({control}): THE SENDER NEVER PROVED ITS DELIVERY TRANSITION. *** "
                              f"sender said: {self.summary(sender)}")
            if durable.header.get("reopened") is not True:
                raise Refused(f"*** {direction} ({control}): THE RECIPIENT'S DURABLE ROW WAS READ FROM A LIVE STORE, "
                              f"NOT A REOPENED ESTATE. *** *A row that was never re-read after the owner released its "
                              f"handles is a running object's claim, not a surviving row.*")
            if str(durable.header.get("msg_id")) != msg_id:
                raise Refused(f"*** {direction} ({control}): THE RECIPIENT'S ROW NAMES A DIFFERENT MESSAGE "
                              f"({durable.header.get('msg_id')} vs {msg_id}). ***")
            if str(delivered.header.get("msg_id")) != msg_id:
                raise Refused(f"*** {direction} ({control}): THE SENDER'S DELIVERY NAMES A DIFFERENT MESSAGE. ***")
            ack = receiver.observe(lambda r: r.kind == "ack" and r.header.get("msg_id") == msg_id)
            if ack is None:
                raise Refused(f"*** {direction} ({control}): THE RECIPIENT NEVER ISSUED ITS CANONICAL ACK FOR THIS "
                              f"FRAME. *** *The ACK is drained from production's own outbox; a run whose ACK never "
                              f"left cannot show the return leg.* receiver said: {self.summary(receiver)}")
            cancel_msg_id, cancel_state = cancellation
            return Result(direction=direction, control=control, outcome="ACCEPTED",
                          detail="the recipient committed the exact msgId and the sender reached DELIVERED after "
                                 "the recipient's canonical ACK crossed the return leg; both the durable row and "
                                 "DELIVERY were re-read from the REOPENED estate, and the cancellation negative "
                                 f"moved a queued frame to {cancel_state} and survived a reopen",
                          durable_row="present", delivery="DELIVERED", msg_id=msg_id,
                          boundary="inbox commit + delivery tracker CAS (reopened estate)",
                          cancellation_msg_id=cancel_msg_id, cancellation_state=cancel_state)

        # ---- the refusal controls ----------------------------------------------------------------------
        durable = self.durable_of(receiver)
        delivered = self.delivered_of(sender)
        if delivered is not None:
            raise Refused(f"*** {direction} ({control}): THE SENDER FALSELY REPORTED DELIVERED FOR A REFUSED "
                          f"RECORD. *** A false DELIVERED is exactly what this control exists to forbid.")
        if control == "mismatched":
            # *** THE MISMATCH REFUSAL IS READ FROM THE SIDE THAT BOUND THE FOREIGN HINT (THE INITIATOR'S SEAT),
            # NOT NECESSARILY FROM THE RECEIVER. ***
            #
            # *The `mismatched` control advertises a well-formed hint that is NOT the identity's own; **the seat which
            # binds it is whichever side is the production election's INITIATOR**, and it refuseth inside the sealed
            # handshake's own identity validation -- `TrustedHandshakeController` -> `IdentityBindingValidator` against
            # the authenticated remote static key.* **So the coordinator asketh BOTH seats for the refusal, and requires
            # that no row was committed anywhere.***
            refusal = self.refusal_of(sender) or self.refusal_of(receiver)
            if refusal is None:
                raise Refused(f"*** {direction} ({control}): THE MISMATCHED IDENTITY WAS NOT REFUSED AT ANY "
                              f"BOUNDARY. *** sender={self.summary(sender)} receiver={self.summary(receiver)}")
            holder = sender if self.refusal_of(sender) is not None else receiver
            if self.durable_of(sender) is not None or self.durable_of(receiver) is not None:
                raise Refused(f"*** {direction} ({control}): THE REFUSED MISMATCH STILL COMMITTED AN INBOX ROW. ***")
            return Result(direction=direction, control=control, outcome="REFUSED",
                          detail=f"the advertised hint did not match the binding proved by the sealed handshake; "
                                 f"refused at the {holder.name} seat's identity binding",
                          durable_row="absent", refusal=str(refusal.header.get("refusal")),
                          msg_id=msg_id, boundary="the sealed handshake's binding validation (authenticated static key)")

        refusal = self.refusal_of(receiver)
        if refusal is None:
            raise Refused(f"*** {direction} ({control}): THE CONTROL WAS NOT REFUSED AT THE RECORD BOUNDARY. *** "
                          f"*A control that is not refused is not a control.* receiver={self.summary(receiver)}")
        if durable is not None:
            raise Refused(f"*** {direction} ({control}): THE REFUSED CONTROL STILL COMMITTED AN INBOX ROW. ***")
        return Result(direction=direction, control=control, outcome="REFUSED",
                      detail="refused at the record boundary, with no committed inbox row and no DELIVERED",
                      durable_row="absent", refusal=str(refusal.header.get("refusal")),
                      msg_id=msg_id,
                      boundary=("authenticated-record open (altered AEAD)" if control == "altered"
                                else "authenticated-record open (old-session ciphertext)"))

    # ---- the replay control -----------------------------------------------------------------------------------

    def run_replay(self, direction: str) -> Result:
        """*** THE OLD-SESSION CONTROL, WITH A CAPTURE RUN AND A FRESH SESSION FOR THE REPLAY. ***

        *Phase A establishes a REAL session and carries an honest message to completion, so the coordinator holds the
        exact DATA bytes that session put on the wire. Phase B is a SECOND pair of workers over a FRESH estate: a
        freshly negotiated session, and a store that holds nothing. Replaying phase A's ciphertext into phase B must
        be REFUSED at the record boundary -- **and phase B's empty store is what maketh "no extra committed inbox
        row" a discriminator rather than a coincidence, since the same bytes in the same session would have
        deduplicated to the row phase A already wrote.***
        """
        self.log(f"--- direction {direction} control=replay: phase A (capture) ---")
        # *** THE CAPTURE IS SCOPED TO PHASE A'S OWN RECORDS, NOT THE WHOLE RUN'S ACCUMULATOR. ***
        #
        # *THE DEFECT THIS CLOSES: `self.evidence.records` is the RUN's accumulator, and `replay` runneth LAST, so by
        # phase A it already held the honest control's records AND the `altered` control's octet-tampered DATA frames
        # AND the `mismatched` control's -- all under the same `direction` label. A capture filtered only on
        # direction/kind/characteristic would replay a MIXTURE, so phase B's `refused, no committed row` verdict could
        # be earned by feeding a tampered or cross-session frame, and the control would pass for the WRONG reason.*
        # **So the index of the first record is taken BEFORE phase A and only the records phase A appends are
        # captured: the bytes replayed are provably the ones PHASE A's OWN session put on the wire.***
        capture_start = len(self.evidence.records)
        capture = self.run_direction(direction, "honest")
        captured = [e for e in self.evidence.records[capture_start:]
                    if e["direction"] == direction and e["kind"] == "frame"
                    and e["characteristic"] == "inbox" and e["payload_length"] > 0]
        if not captured:
            raise Refused(f"*** {direction} (replay): PHASE A CAPTURED NO INBOX RECORD TO REPLAY. ***")
        blob = (self.evidence_dir / "transcript.bin").read_bytes()
        # *** THE SLICE IS THE RECORD'S TRUE PAYLOAD, AND IT IS VERIFIED AGAINST THE MANIFEST'S OWN DIGEST. ***
        #
        # *THE DEFECT THIS CLOSES: `payload_offset` used to point at the FRAME, so the slice carrieth the framing
        # preamble and a truncated body -- `Evidence.append` now putteth the payload's real offset in, and this
        # assertion proveth the two agree rather than trusting the arithmetic.* **A slice that does not hash to the
        # payload the manifest named is a REFUSAL, not a replay of something else.**
        replays: list[tuple[bytes, str, Any]] = []
        for e in captured:
            start = e["payload_offset"]
            payload = blob[start:start + e["payload_length"]]
            got = sha256_bytes(payload)
            if got != e["payload_sha256"]:
                raise Refused(f"*** {direction} (replay): THE CAPTURED PAYLOAD SLICE DOES NOT HASH TO WHAT THE "
                              f"MANIFEST RECORDED ({got[:16]}… vs {e['payload_sha256'][:16]}…). *** *The offset "
                              f"arithmetic and the written bytes disagree, so what would be replayed is not the "
                              f"session's own ciphertext.*")
            replays.append((payload, str(e["characteristic"]), e["epoch"]))
        self.log(f"  captured {len(replays)} inbox record(s) from the honest session")

        self.log(f"--- direction {direction} control=replay: phase B (fresh session, fresh estate) ---")
        ios_is_sender = direction == IOS_TO_ANDROID
        estate = self.fresh_estate(f"{direction.replace('->', '_')}-replay-fresh")
        ios_estate = estate / "ios"
        android_estate = estate / "android"
        ios_estate.mkdir(parents=True, exist_ok=True)
        android_estate.mkdir(parents=True, exist_ok=True)
        swift = self.launch_swift(f"swift-replay-fresh", "sender" if ios_is_sender else "recipient",
                                  "honest", ios_estate, self.deadline_s)
        android = self.launch_android(f"android-replay-fresh", "sender" if not ios_is_sender else "recipient",
                                      "honest", android_estate, self.deadline_s)
        sender = swift if ios_is_sender else android
        receiver = android if ios_is_sender else swift
        try:
            self.seat_pair(sender, receiver, seed_attr="replay_seed",
                           sender_seed=(IOS_SEED if ios_is_sender else ANDROID_SEED) + 0x40,
                           receiver_seed=(ANDROID_SEED if ios_is_sender else IOS_SEED) + 0x40,
                           timeout_s=self.deadline_s)
            # Let the FRESH handshake complete across the pipe before the replay: a replay into a half-negotiated
            # session would refuse for the wrong reason.
            self.log("  negotiating the fresh session across the pipe")
            self.pump(sender, receiver, direction, control="replay-handshake",
                      timeout=min(self.deadline_s, 120.0),
                      until=lambda: bool(sender.observe(lambda r: r.kind == "authored")))
            self.log("  replaying the captured old-session records into the live fresh session")
            replayed = 0
            for payload, characteristic, epoch in replays:
                self.evidence.append(
                    Record(header={"v": PROTOCOL_VERSION, "kind": "replay", "platform": sender.platform,
                                   "characteristic": characteristic, "epoch": epoch}, payload=payload),
                    direction=direction, producer="coordinator", target=receiver.name,
                    characteristic=characteristic, epoch=epoch, platform=sender.platform,
                    note="old-session replay: a VERBATIM record captured from the PREVIOUS session, injected into a "
                         "freshly negotiated one over a fresh estate")
                receiver.send("inject", payload, characteristic=characteristic, epoch=epoch,
                              source_producer="coordinator", control="replay", replay=True, origin_epoch=epoch)
                replayed += 1
            self.log(f"  replayed {replayed} record(s)")
            self.pump(sender, receiver, direction, control="replay",
                      timeout=min(self.deadline_s, 120.0),
                      until=lambda: self.refusal_of(receiver) is not None)
            for w in (sender, receiver):
                self.record_observation(w, direction, "replay")
            result = self.judge(direction, "replay", sender, receiver,
                                str(sender.observe(lambda r: r.kind == "authored").header.get("msg_id", "")
                                    if sender.observe(lambda r: r.kind == "authored") else ""))
            final = Result(direction=direction, control="replay", outcome=result.outcome,
                           detail="phase A captured a real session's ciphertext; phase B negotiated a FRESH session "
                                  "over a FRESH estate and refused the replayed record at the record boundary with an "
                                  "empty store",
                           durable_row=result.durable_row, refusal=result.refusal,
                           delivery=result.delivery, msg_id=result.msg_id,
                           boundary="authenticated-record open (old-session ciphertext, fresh session)")
            if capture.outcome != "ACCEPTED":
                raise Refused(f"*** {direction} (replay): PHASE A DID NOT ESTABLISH A REAL SESSION. ***")
            for w in (sender, receiver):
                w.send("bye")
            return final
        finally:
            for w in (sender, receiver):
                w.close()
                self.workers = [x for x in self.workers if x is not w]

    # ---- the crash campaign -----------------------------------------------------------------------------------

    def run_crash(self) -> None:
        """*** `--mode crash`: THE DURABLE-BOUNDARY RECOVERY CAMPAIGN. ***

        *The macOS half is the authoritative ABRUPT-DEATH proof -- the child-process SIGKILL campaign, launched
        through the SAME built bundle this coordinator uses for its endpoints. The Android half mirrors it on the real
        host store: a JVM halteth immediately after a durable owner returns, and a FRESH JVM proveth the surviving
        state from the same estate.* **A halt is only accepted when it really was a halt: the macOS campaign checketh
        `.uncaughtSignal`/SIGKILL itself, and the Android worker useth `Runtime.halt`, whose non-zero status is
        required here -- a cooperative exit is not crash proof.**
        """
        self.log("*** crash mode: the macOS child-process SIGKILL campaign ***")
        bundle = self.resolve_swift_bundle()
        xctest = self.resolve_xctest()
        log_path = self.evidence_dir / "swift-crash-campaign.log"
        with log_path.open("wb") as fh:
            proc = subprocess.Popen([xctest, "-XCTest", SWIFT_CRASH_SELECTOR, str(bundle)],
                                    cwd=str(REPO), stdout=fh, stderr=subprocess.STDOUT)
            try:
                rc = proc.wait(timeout=max(self.deadline_s * 4, 1800.0))
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=30)
                raise Refused(f"*** THE macOS CRASH CAMPAIGN NEVER FINISHED WITHIN ITS BOUND. *** log={log_path}")
        self.log(f"  macOS crash campaign rc={rc} log={log_path}")
        if rc != 0:
            raise Refused(f"*** THE macOS CRASH CAMPAIGN FAILED (rc={rc}); a failed checkpoint blocks the mode. *** "
                          f"log={log_path}")

        self.log("*** crash mode: the Android durable-boundary recovery worker ***")
        for boundary in CRASH_BOUNDARIES:
            estate = self.fresh_estate(f"crash-{boundary}")
            # *** THE COORDINATOR'S REQUESTED ROLE IS RECORDED BESIDE THE WORKER'S OWN VOCABULARY. ***
            prepare = self.launch_android(f"android-prepare-{boundary}", "crash-prepare", boundary, estate,
                                          self.deadline_s)
            prepare_rc: Optional[int] = None
            prepare_term: Optional[Termination] = None
            try:
                marker = prepare.wait(lambda r: r.kind in ("at_boundary", "refuse"), self.deadline_s,
                                      f"its AT_BOUNDARY marker for {boundary}")
                if marker.kind == "refuse":
                    raise Refused(f"*** THE ANDROID WORKER REFUSED THE {boundary} CHECKPOINT: "
                                  f"{marker.header.get('reason')} ***")
                # *** THE WORKER'S OWN RECORD MUST CONFIRM THE ROLE/VARIANT/PLATFORM THAT WAS REQUESTED. *** *The
                # alias bridgeth the crash vocabulary to the worker's own; an unknown variant is refused at the
                # worker's root, and this comparison is the coordinator's half of that contract.*
                self.require_reported_identity(prepare, marker)
                if str(marker.header.get("boundary", boundary)) != boundary:
                    raise Refused(f"*** THE ANDROID PREPARE MARKER FOR {boundary} NAMES A DIFFERENT BOUNDARY: "
                                  f"{marker.header.get('boundary')!r}. ***")
                self.log(f"  {boundary}: {dict(marker.header)}")
                # *** THE DEATH IS OBSERVED *BEFORE* THE COORDINATOR CAN SUPPLY ONE. ***
                #
                # *THE DEFECT THIS CLOSES: `prepare.status` was read AFTER `prepare.close()` -- and `close()` sendeth
                # the coordinator's OWN SIGTERM/SIGKILL -- so the status observed could be the COORDINATOR'S kill, and
                # `None` (still running) was ACCEPTED as a crash. Both let a HUNG worker, or a worker the coordinator
                # itself killed, masquerade as an abrupt halt.* **HERE THE CHILD EXITS ON ITS OWN FIRST (`wait_exit`),
                # inside the guard; only then (in `finally`) is it reaped.**
                prepare_rc = prepare.wait_exit(self.deadline_s)
            finally:
                prepare_term = prepare.observe_termination()
                prepare.close()
                self.workers = [x for x in self.workers if x is not prepare]
            if prepare_term.forced_kill or prepare_term.termination_reason.startswith("coordinator-"):
                raise Refused(f"*** THE ANDROID PREPARE JVM FOR {boundary} WAS KILLED BY THE COORDINATOR, NOT BY "
                              f"ITSELF: {prepare_term.describe()} *** *The death proof must be the worker's, observed "
                              f"before any coordinator kill.*")
            if prepare_rc is None:
                raise Refused(f"*** THE ANDROID PREPARE JVM FOR {boundary} WAS HUNG -- it did not exit on its own "
                              f"within {self.deadline_s:.0f}s. *** *A HUNG WORKER IS NOT A CRASH, and the coordinator "
                              f"must never supply the death it then reports.*")
            if prepare_rc == 0:
                raise Refused(f"*** THE ANDROID PREPARE JVM FOR {boundary} EXITED 0: A COOPERATIVE EXIT IS NOT A "
                              f"CRASH. ***")
            if prepare_rc < 0:
                raise Refused(f"*** THE ANDROID PREPARE JVM FOR {boundary} EXITED {prepare_rc} -- a SIGNAL death "
                              f"(SIGTERM -15 / SIGKILL -9) is the COORDINATOR'S OWN CLEANUP, not the worker's abrupt "
                              f"halt. *** *The death proof must be the worker's, observed before any coordinator kill.*")
            # *** THE WRAPPER'S RC IS NOT THE PROOF, AND DEMANDING 137 FROM IT IS WRONG. ***
            #
            # *`Runtime.halt(137)` terminateth the FORKED EXECUTOR JVM; Gradle reapit it, reporteth "finished with
            # non-zero exit value 137", and then exits the BUILD with `rc=1` -- it does NOT propagate 137. **So the
            # proof demanded here is the ACTUAL EXECUTOR CHILD's abrupt status, bound to its actual PID and to the
            # worker's own `GS_INTEGRATION_ABOUT_TO_HALT` marker, READ FROM THE WORKER'S OWN RETAINED LOG.** A wrapper
            # rc of 1 is therefore RECORDED (and may be 1 or None), never required to equal 137.*
            exec_info = prepare.executor_termination()
            if not exec_info["about_to_halt_seen"]:
                raise Refused(f"*** THE ANDROID PREPARE LOG FOR {boundary} CARRIES NO BOUND "
                              f"`{GRADLE_EXECUTOR_HALT_LINE} boundary=<stage> code=<n>` DECLARATION: the executor's "
                              f"death cannot be bound to a stage. *** log={prepare.log_path}")
            # *** THE DECLARATION BELONGS TO THIS BOUNDARY AND DECLARES THE DEATH IT PREDICTS. ***
            #
            # *THE DEFECT THIS CLOSES: `about_to_halt_seen` was a substring test on the marker's NAME, so a print of
            # the word from ANY code path -- wrong stage, wrong code, even a different JVM's log -- satisfied it. The
            # committed worker's `markAboutToHalt` printseth the boundary it is about to halt AT and the code it will
            # halt WITH, so both must name THIS boundary and the executor's observed abrupt status.*
            if boundary not in exec_info["about_to_halt_boundaries"]:
                raise Refused(f"*** THE ANDROID PREPARE LOG FOR {boundary} CARRIES NO PRE-HALT DECLARATION FOR THIS "
                              f"STAGE: boundaries={exec_info['about_to_halt_boundaries']}. *** "
                              f"log={prepare.log_path}")
            abrupt = [s for s in exec_info["gradle_reported_abrupt_statuses"]
                      if s == GRADLE_EXECUTOR_ABRUPT_STATUS]
            if not abrupt:
                raise Refused(f"*** THE ANDROID PREPARE LOG FOR {boundary} DOES NOT REPORT THE FORKED EXECUTOR "
                              f"DYING WITH STATUS {GRADLE_EXECUTOR_ABRUPT_STATUS}: "
                              f"gradle_abrupt={exec_info['gradle_reported_abrupt_statuses']} "
                              f"declared={exec_info['declared_halt_statuses']}. *** *A wrapper `rc` alone proves "
                              f"nothing about the child; the abrupt status of the ACTUAL executor is the crash.*")
            if GRADLE_EXECUTOR_ABRUPT_STATUS not in exec_info["about_to_halt_codes"]:
                raise Refused(f"*** THE PRE-HALT DECLARATION FOR {boundary} DOES NOT DECLARE THE HALT CODE "
                              f"{GRADLE_EXECUTOR_ABRUPT_STATUS}: codes={exec_info['about_to_halt_codes']}. *** "
                              f"*The worker must predict the death Gradle then observeth; a declaration about some "
                              f"other code binds the stage to no observed event.*")
            executor_pid = exec_info["executor_pid"]
            if executor_pid is None:
                raise Refused(f"*** THE ANDROID PREPARE LOG FOR {boundary} NAMES NO EXECUTOR PID, so the abrupt "
                              f"status cannot be bound to a real process. *** log={prepare.log_path}")
            # *** THE PID IS A REAL OS PROCESS, NOT A SHADOW AND NOT THE WRAPPER. ***
            #
            # *The committed worker resolvesthe pid through the PUBLIC `java.lang.ProcessHandle` interface and
            # `check(pid > 0)`. A Robolectric-shadowed context reporteth the constant `10000` -- that is a SIMULATED
            # pid, which is the absence of a real one -- and a pid EQUAL to the wrapper's is the gradlew process
            # itself, not the forked executor: the death would be bound to a process that observably did not die the
            # observed death.*
            if executor_pid <= 0 or executor_pid == ROBOLECTRIC_SHADOW_PID:
                raise Refused(f"*** THE ANDROID PREPARE FOR {boundary} BOUND ITS DEATH TO pid={executor_pid}, which "
                              f"is not a real OS pid (non-positive, or the Robolectric shadow). *** "
                              f"*A death bound to a simulated process is bound to no process.*")
            if prepare_term.pid is not None and executor_pid == prepare_term.pid:
                raise Refused(f"*** THE 'EXECUTOR' PID FOR {boundary} EQUALS THE GRADLE WRAPPER ({executor_pid}): "
                              f"the forked executor child was never observed as a DISTINCT process. ***")
            self.log(f"  {boundary}: prepare exited on its own with wrapper rc={prepare_rc}; the ACTUAL Gradle Test "
                     f"Executor pid={executor_pid} (distinct of wrapper={prepare_term.pid}) died abruptly with "
                     f"status {abrupt[-1]} (pre-halt declaration bound to this stage and code)")
            crash_termination = {
                "boundary": boundary,
                "wrapper_pid": prepare_term.pid,
                "wrapper_exit_status": prepare_term.exit_status,
                "wrapper_termination_reason": prepare_term.termination_reason,
                "forced_kill": prepare_term.forced_kill,
                "observed_before_cleanup": prepare_term.observed_before_cleanup,
                "executor_pid": executor_pid,
                "executor_abrupt_status": abrupt[-1],
                "about_to_halt_seen": exec_info["about_to_halt_seen"],
                "about_to_halt_boundary": boundary,
                "about_to_halt_code": GRADLE_EXECUTOR_ABRUPT_STATUS,
                "log_path": prepare.log_path.name,
                "log_sha256": sha256_file(prepare.log_path) if prepare.log_path.is_file() else "",
            }
            self.evidence.append(
                Record(header={"v": PROTOCOL_VERSION, "kind": "termination", "platform": "android",
                               "role": "crash-prepare", "boundary": boundary}, payload=b""),
                direction="android-crash", producer=prepare.name, target="coordinator", characteristic="control",
                epoch=None, platform="android",
                note=f"crash proof for {boundary}: " + json.dumps(crash_termination, sort_keys=True))
            self.crash_terminations.append(crash_termination)

            recover = self.launch_android(f"android-recover-{boundary}", "crash-recover", boundary, estate,
                                          self.deadline_s)
            recover_term: Optional[Termination] = None
            try:
                outcome = recover.wait(lambda r: r.kind in ("complete", "refuse"), self.deadline_s,
                                       f"its COMPLETE marker for {boundary}")
                if outcome.kind == "refuse":
                    raise Refused(f"*** THE ANDROID RECOVERY FOR {boundary} FAILED: "
                                  f"{outcome.header.get('reason')} ***")
                self.require_reported_identity(recover, outcome)
                if outcome.header.get("durable_row") != "present":
                    raise Refused(f"*** THE ANDROID RECOVERY FOR {boundary} FOUND NO SURVIVING ROW. *** "
                                  f"outcome={dict(outcome.header)}")
                self.evidence.append(outcome, direction="android-crash", producer=recover.name, target="store",
                                     characteristic="", epoch=None, platform="android",
                                     note=f"durable-boundary recovery for {boundary} in a fresh JVM")
                self.results.append(Result(
                    direction="android-crash", control=boundary, outcome="RECOVERED",
                    detail=str(outcome.header.get("detail", "")),
                    durable_row=str(outcome.header.get("durable_row", "")),
                    delivery=str(outcome.header.get("delivery", "")),
                    msg_id=str(outcome.header.get("msg_id", "")),
                    boundary=f"durable owner commit at {boundary}"))
                recover.send("bye")
                # *** THE RECOVERY'S OWN EXIT IS OBSERVED BEFORE THE CLEANUP SUPPLIES ONE. ***
                recover.wait_exit(self.deadline_s)
            finally:
                recover_term = recover.observe_termination()
                recover.close()
                self.workers = [x for x in self.workers if x is not recover]
            self.evidence.append(
                Record(header={"v": PROTOCOL_VERSION, "kind": "termination", "platform": "android",
                               "role": "crash-recover", "boundary": boundary}, payload=b""),
                direction="android-crash", producer=recover.name, target="coordinator", characteristic="control",
                epoch=None, platform="android",
                note="recovery termination: " + json.dumps(recover_term.as_dict(
                    log_sha256=sha256_file(recover.log_path) if recover.log_path.is_file() else ""),
                    sort_keys=True))
            if recover_term.forced_kill or recover_term.termination_reason.startswith("coordinator-"):
                raise Refused(f"*** THE ANDROID RECOVERY JVM FOR {boundary} WAS KILLED BY THE COORDINATOR: "
                              f"{recover_term.describe()} *** *A recovery whose own exit was never observed is not "
                              f"proof it finished.*")
            if recover_term.exit_status != 0:
                raise Refused(f"*** THE ANDROID RECOVERY JVM FOR {boundary} EXITED {recover_term.exit_status}. ***")

    def _require_retained_logs(self) -> None:
        """*** EVERY WORKER'S LOG MUST HAVE BEEN RETAINED, OR THE RUN CARRIES NO LOG PROOF. ***"""
        missing = [w for w in self.all_workers if w.retention_error]
        if missing:
            raise Refused("*** THE EVIDENCE ROOT COULD NOT RETAIN " + f"{len(missing)}" + " WORKER LOG(S): " +
                          "; ".join(f"{w.name}: {w.retention_error}" for w in missing[:4]) + " *** "
                          "*A worker's own stdout/stderr is its log proof; a run that could not retain it cannot "
                          "support the verdict it claims.*")

    # ---- the report -------------------------------------------------------------------------------------------

    def write_report(self, mode: str, manifest: dict[str, Any]) -> None:
        # *** THE FIRST OCTETS OF THE TRANSCRIPT, RENDERED IN THE REPORT. ***
        #
        # *A reader must be able to SEE the length-delimited framing without a hex tool: the first record's
        # `u32be header_len`, its canonical-JSON header, its `u32be payload_len` and the first octets of the payload
        # are dumped here. **This is a rendering of the bytes, not an interpretation of them: the payload is shown as
        # octets and never decoded.***
        blob = (self.evidence_dir / "transcript.bin").read_bytes()
        head = blob[:128]
        framing_dump = " ".join(f"{b:02x}" for b in head)
        if len(blob) >= 8:
            first_head_len = struct.unpack_from(">I", blob, 0)[0]
            first_header_end = 4 + first_head_len
            first_header_text = blob[4:first_header_end].decode("utf-8", errors="replace")
            first_payload_len = struct.unpack_from(">I", blob, first_header_end)[0] if len(blob) >= first_header_end + 4 else None
        else:
            first_head_len, first_header_text, first_payload_len = None, "", None
        report = {
            "schema_version": SCHEMA_VERSION,
            "mode": mode,
            "run_id": self.run_id,
            **self.identity,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "producer": "tools/readiness/run_board1_integration.py",
            "producer_sha256": sha256_file(Path(__file__)),
            "input_digest": self.digest,
            "input_files": self.input_files,
            "toolchain": self.toolchains,
            # *** THE BUILT FIXTURE'S OWN DIGEST, SO A READER CAN BIND THE RUN TO THE EXACT BUNDLE IT EXERCISED. ***
            # *The path records where workers ran. The served archive carries these exact bytes, revalidated
            # against the live bundle and image after the workers finish, before any PASS report is published.*
            "bundle_digest": self.bundle_digest_value,
            "bundle_path": (str(self._swift_bundle.relative_to(REPO)) if self._swift_bundle
                            and self._swift_bundle.is_relative_to(REPO) else
                            (str(self._swift_bundle) if self._swift_bundle else None)),
            "android_fixture_ready": self._android_ready,
            # *** AND THE BUILD ATTESTATION: the artifact, its descriptor-verified identity, the recipe and the
            # candidate/source digests -- PRODUCED BY THIS BUILD, or VERIFIED against the build that produced it. ***
            "build_attestation": self.build_attestation_value,
            "build_attestation_verified": self.attestation_verified,
            "skip_build": bool(self.args.skip_build),
            "results": [
                {"direction": r.direction, "control": r.control, "outcome": r.outcome,
                 "durable_row": r.durable_row, "delivery": r.delivery, "msg_id": r.msg_id,
                 "refusal": r.refusal, "boundary": r.boundary, "detail": r.detail,
                 "cancellation_msg_id": r.cancellation_msg_id,
                 "cancellation_state": r.cancellation_state}
                for r in self.results
            ],
            "manifest": {"path": manifest["transcript"]["path"],
                         "sha256": sha256_file(self.evidence.manifest_path),
                         "record_count": manifest["record_count"]},
            # *** THE OBSERVED TERMINATION OF EVERY WORKER THIS RUN LAUNCHED. ***
            #
            # *THE DEFECT THIS CLOSES: the report carrieth each worker's VERDICT but nothing about HOW IT ENDED, so
            # a crash row could be earned by a HUNG worker or by the coordinator's own SIGTERM/SIGKILL -- the two
            # things the plan's own termination clause forbids.* **Every entry carrieth the actual PID, the actual
            # exit status, WHY it ended, the forced-kill flag, whether the observation preceded cleanup, and the
            # retained log's sha256; the gate REFUSETH a crash row whose termination was supplied or never
            # observed.**
            "worker_terminations": [
                {"name": w.name, "platform": w.platform, "role": w.role, "variant": w.spec.variant,
                 "attempt": w.attempt,
                 **w.termination.as_dict()}
                for w in self.all_workers if w.termination is not None
            ],
            # *** AND THE ANDROID CRASH PROOF ITSELF: the ACTUAL executor child's abrupt status, bound to its PID. ***
            "crash_terminations": self.crash_terminations,
            "worker_launches": self.evidence.launches,
            "transcript": {"path": manifest["transcript"]["path"],
                           "sha256": manifest["transcript"]["sha256"],
                           "length": manifest["transcript"]["length"],
                           "framing": manifest["transcript"]["framing"],
                           "first_128_octets_hex": framing_dump,
                           "first_record": {"header_length": first_head_len,
                                            "header_json": first_header_text,
                                            "payload_length": first_payload_len}},
        }
        (self.evidence_dir / "integration-report.json").write_text(json.dumps(report, indent=2) + "\n")
        self.log("*** results ***")
        for row in report["results"]:
            self.log(f"  {row['direction']:14s} {row['control']:11s} {row['outcome']:8s} "
                     f"row={row['durable_row']} delivery={row['delivery']} "
                     f"refusal={(row['refusal'] or '-')[:90]}")
        self.log(f"  transcript framing (first 128 octets): {framing_dump}")

    # ---- the producer binding (current run, inside its evidence dir) ------------------------------------------

    def write_producer_binding(self, mode: str) -> None:
        """*** WRITE THE RUN'S PRODUCER IDENTITIES AND EVIDENCE BINDING INTO ITS OWN EVIDENCE DIR. ***

        *THE DEFECT THIS CLOSES, MEASURED ON THE AUTHENTICATED C14 ARTIFACT: this method copied the fresh run's
        transcript/manifest/report INTO `tools/integration-fixtures/<run_id>/` -- the HISTORICAL ARCHIVE namespace --
        so the run's OWN `run_id` became an archived fixture identity and the terminal gate then refused the run's
        genuine report as a COPIED historical fixture. **`tools/integration-fixtures/` is HISTORICAL ONLY; a CURRENT
        run's transcript/manifest/report ALREADY live complete in its evidence dir, so the only thing not already
        there is this producer-identity + evidence-binding sidecar -- and it is written once, in that dir, NEVER into
        the archive namespace and never as a duplicate copy of the three outputs.** *No tracked path is written.*
        """
        (self.evidence_dir / "producers.json").write_text(json.dumps({
            "schema_version": SCHEMA_VERSION,
            "run_id": self.run_id,
            "mode": mode,
            "input_digest": self.digest,
            "input_files": self.input_files,
            "toolchain": self.toolchains,
            "worker_launches": self.evidence.launches,
            "evidence_binding": {
                "transcript": {"path": "transcript.bin",
                               "sha256": sha256_file(self.evidence.blob)},
                "manifest": {"path": "manifest.json",
                             "sha256": sha256_file(self.evidence.manifest_path)},
                "report": {"path": "integration-report.json",
                           "sha256": sha256_file(self.evidence_dir / "integration-report.json")},
            },
            "producers": [
                {"sequence": e["sequence"], "platform": e["platform"], "producer": e["producer"],
                 "target": e["target"], "direction": e["direction"], "kind": e["kind"],
                 "characteristic": e["characteristic"], "epoch": e["epoch"],
                 "payload_sha256": e["payload_sha256"], "source_digest": e["source_digest"]}
                for e in self.evidence.records
            ],
        }, indent=2) + "\n")
        self.log("  producer identities + evidence binding written to producers.json "
                 "(HISTORICAL archive namespace untouched)")
        return self.evidence_dir / "producers.json"

    # ---- the entry point --------------------------------------------------------------------------------------

    def run(self) -> int:
        mode = self.args.mode
        self.log(f"=== GS-INTEGRATION-001 cross-platform coordinator: mode={mode} run={self.run_id} ===")
        self.log(f"    repo={REPO} evidence={self.evidence_dir}")
        self.log(f"    input digest (pre) = {self.digest}")
        for key, value in self.toolchains.items():
            self.log(f"    toolchain {key}: {value}")
        failure: Optional[str] = None
        try:
            # *** THE HOST FIXTURES ARE BUILT ONCE, BEFORE EITHER MODE -- the macOS child-process crash campaign
            # launch eth the SAME bundle the cross-platform worker useth, so one build serveth both. ***
            if mode in ("all", "crash", "cross-platform"):
                self.build_fixtures()
            if mode in ("all", "crash"):
                self.run_crash()
            if mode in ("all", "cross-platform"):
                for direction in (IOS_TO_ANDROID, ANDROID_TO_IOS):
                    for control in CONTROLS:
                        self.results.append(self.run_replay(direction) if control == "replay"
                                            else self.run_direction(direction, control))
        except Refused as exc:
            failure = str(exc)
            self.log(f"*** REFUSED: {failure} ***")
        finally:
            for worker in list(self.workers):
                worker.close()

        # *** EVERY LAUNCHED WORKER'S LOG MUST HAVE BEEN RETAINED, EVEN ON A RED RUN. ***
        # *The copy failure was silently swallowed before; now a run whose log proof could not be retained REFUSETH
        # rather than presenting a verdict it cannot support. Checked AFTER the closes, because that is when every
        # retained copy is written.*
        if failure is None:
            try:
                self._require_retained_logs()
                live_build = self.make_build_attestation("macos", evidence_dir=self.evidence_dir)
                live_build["producer_attempt"] = self.build_attestation_value["producer_attempt"]
                if live_build != self.build_attestation_value:
                    raise Refused("tested bundle/image/archive changed while integration workers executed")
            except Refused as exc:
                failure = str(exc)
                self.log(f"*** REFUSED: {failure} ***")

        post_digest, _ = input_digest(tuple(self.args.extra_input or ()))
        try:
            current_identity = build_provenance.source_identity(self.identity["candidate_sha"])
        except (ValueError, OSError, subprocess.CalledProcessError) as exc:
            self.log(f"*** REFUSED: candidate source drift: {exc} ***")
            return 3
        if post_digest != self.digest or current_identity != self.identity:
            self.log("*** REFUSED: an input changed WHILE the run executed ***")
            return 3

        manifest = self.evidence.close()
        if failure is None:
            self.write_report(mode, manifest)
            self.write_producer_binding(mode)
        self.log(f"    input digest (post) = {post_digest} (agrees)")
        if failure is not None:
            self.log("*** FAIL ***")
            return 2
        self.log("*** PASS ***")
        return 0


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="GS-INTEGRATION-001 cross-platform coordinator")
    ap.add_argument("--mode", required=True, choices=("all", "crash", "cross-platform"))
    ap.add_argument("--evidence-dir", required=True)
    ap.add_argument("--timeout", type=float, default=300.0,
                    help="bound, in seconds, on every single worker wait and relay phase")
    ap.add_argument("--skip-build", action="store_true",
                    help="assume the macOS test bundle is already built; REQUIRES --expect-build-attestation and "
                         "--candidate-sha, so the assumption is verified against a real build's record")
    ap.add_argument("--expect-build-attestation",
                    help="with --skip-build: the path to a build-attestation.json a REAL BUILD produced; the run "
                         "VERIFIES bundle/source/recipe/candidate/library digests against it and REFUSES a mismatch")
    ap.add_argument("--candidate-sha",
                    help="the exact candidate commit/tree SHA this run is a claim about; REQUIRED with --skip-build")
    ap.add_argument("--extra-input", action="append", default=[],
                    help="extra repo-relative input file to bind into the digest")
    args = ap.parse_args(argv)
    try:
        return Runner(args).run()
    except Refused as exc:
        print(f"*** REFUSED: {exc} ***", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
