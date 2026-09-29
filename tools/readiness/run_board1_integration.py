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
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

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

SWIFT_WORKER_SELECTOR = "GodstoneMeshTests.GsIntegration001CrossPlatformWorkerTests/testGSINT001CrossPlatformWorker"
SWIFT_CRASH_SELECTOR = "GodstoneMeshTests.GsIntegration001ProcessTests/testGSINT001ProcessCrashCampaign"
SWIFT_BUNDLE_NAME = "GodstoneMeshTests.xctest"
ANDROID_WORKER_TASK = ":mesh:board1IntegrationWorker"
ANDROID_WORKER_CLASS = "io.godstone.mesh.rig.RealTransportHostRigWorkerTest"

# *** THE CRASH ROLES MAY LIVE IN A DIFFERENT TASK/CLASS, NAMED BY THE ENVIRONMENT. ***
#
# *THE PLAN PUT THE ANDROID DURABLE-BOUNDARY MIRROR IN THE SAME SLICE AS THIS COORDINATOR, BUT IT BELONGETH TO A
# SEPARATE WORKER (`AndroidCrashMirror`'s `Board1DurableBoundaryWorkerTest` + `board1DurableBoundaryWorker`), WHICH
# DRIVETH THE BOUNDARY WITH A PARENT-OWNED KILL RATHER THAN A SELF-HALT.* **So the task and class for the CRASH roles
# alone are overridable -- the cross-platform roles keep the committed defaults -- and the coordinator reacheth either
# worker with no edit:**
#
#   GS_ANDROID_CRASH_TASK=:mesh:board1DurableBoundaryWorker \
#   GS_ANDROID_CRASH_CLASS=io.godstone.mesh.rig.Board1DurableBoundaryWorkerTest \
#     python3 tools/readiness/run_board1_integration.py --mode crash --evidence-dir PATH
ANDROID_CRASH_TASK = os.environ.get("GS_ANDROID_CRASH_TASK", ANDROID_WORKER_TASK)
ANDROID_CRASH_CLASS = os.environ.get("GS_ANDROID_CRASH_CLASS", ANDROID_WORKER_CLASS)

# The seeds the two workers mint their identities from. **The coordinator re-mints until the production role
# election seats the SENDER as the initiator** -- see `seat_pair` -- because only the initiator is reachable in the
# route-eligible view, which is a production fact and not a convenience.
IOS_SEED = 0xC1
ANDROID_SEED = 0xD1


class Refused(RuntimeError):
    """A named refusal. **NEVER a bare exception: every refusal carrieth the reason a reader needeth.**"""


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


# *** THE INPUT DIGEST: THE BYTES THIS RUN IS A CLAIM ABOUT. ***
#
# *Taken BEFORE the workers launch and AFTER they finish, and the two must agree -- the same contract every other
# lane runner in `tools/readiness/` carrieth. An explicit file list rather than a directory walk, so the digest names
# exactly what the claim depends on and nothing else.*
INPUT_FILES_DEFAULT = (
    "tools/readiness/run_board1_integration.py",
    "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001CrossPlatformWorkerTests.swift",
    "ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift",
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
        try:
            os.close(self.fd)
        except OSError:
            pass


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
        self.log_path = runtime_dir / f"{spec.name}.worker.log"
        self._log_fh = None
        self.process: Optional[subprocess.Popen] = None
        self._reader: Optional[threading.Thread] = None

    def start(self) -> None:
        env = dict(os.environ)
        env.update(self.spec.env)
        self._log_fh = self.log_path.open("wb")
        self.process = subprocess.Popen(  # noqa: S603 -- argv is constructed here, never a shell string
            self.spec.argv,
            cwd=str(self.spec.cwd) if self.spec.cwd else str(REPO),
            env=env,
            stdout=self._log_fh,
            stderr=subprocess.STDOUT,
        )
        self._reader = threading.Thread(target=self._drain, name=f"drain-{self.spec.name}", daemon=True)
        self._reader.start()

    # ---- the reader -----------------------------------------------------------------------------------------

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
            self._reader and self._reader.join(timeout=2)
            self.from_worker.close()
            return
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=15)
        if self._reader:
            self._reader.join(timeout=10)
        try:
            self.from_worker.close()
        except Exception:  # noqa: BLE001
            pass
        if self._log_fh:
            self._log_fh.close()
        # *** THE WORKER'S OWN STDOUT/STDERR IS EVIDENCE AND TRAVELS WITH THE RUN. ***
        try:
            shutil.copy2(self.log_path, self.runtime_dir.parent / self.log_path.name)
        except Exception:  # noqa: BLE001
            pass

    @property
    def status(self) -> Optional[int]:
        return None if self.process is None else self.process.poll()


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
                    argv: list[str], estate: str) -> None:
        self.launches.append({"name": name, "platform": platform, "role": role, "variant": variant,
                              "argv": argv, "estate": estate})

    def append(self, rec: Record, *, direction: str, producer: str, target: str,
               characteristic: str = "", epoch: Any = None, note: str = "",
               platform: str = "") -> dict[str, Any]:
        framed = rec.framed()
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
            "payload_offset": self.offset,
            "payload_length": len(rec.payload),
            "payload_sha256": sha256_bytes(rec.payload),
            "frame_length": len(framed),
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


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
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
        self.fixtures_root = REPO / "tools" / "integration-fixtures"
        self.deadline_s = float(args.timeout)
        self.workers: list[Worker] = []
        self._swift_bundle: Optional[Path] = None
        self._android_ready = False

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

        *The macOS test bundle is built by SwiftPM; the Android worker classes are compiled by the Gradle invocation
        the `board1IntegrationWorker` task performs. This step is what maketh "the built macOS test bundle" a fact
        rather than an assumption.*
        """
        if self.args.skip_build:
            self.log("*** --skip-build: the host fixtures are assumed already built ***")
            return
        self.log("*** building the host fixtures ONCE (SwiftPM macOS test bundle) ***")
        result = subprocess.run(
            ["swift", "build", "--package-path", str(REPO / "ios" / "Packages" / "GodstoneFoundation"),
             "--build-tests"],
            cwd=str(REPO), capture_output=True, text=True, timeout=7200)
        (self.runtime_dir / "swift-build.log").write_text(result.stdout + result.stderr)
        if result.returncode != 0:
            raise Refused(f"*** THE macOS FIXTURE BUILD FAILED (rc={result.returncode}); see "
                          f"{self.runtime_dir / 'swift-build.log'} ***")
        self.log(f"  swift build --build-tests: rc={result.returncode}")
        for name in ("compileDebugUnitTestKotlin", "compileDebugUnitTestJavaWithJavac"):
            pass  # the Android side is compiled by the worker task's own invocation

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
        bundle = REPO / "ios" / "Packages" / "GodstoneFoundation" / ".build" / "debug" / SWIFT_BUNDLE_NAME
        if not bundle.exists():
            raise Refused(
                f"*** THE macOS TEST BUNDLE {bundle} IS ABSENT: the coordinator must build it before launching a "
                "worker. *** Run without `--skip-build`, or build it once with `swift build --build-tests`.")
        self._swift_bundle = bundle
        return bundle

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
        self.evidence.note_launch(name, "ios", role, variant, spec.argv, str(estate))
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
            f"-D{ANDROID_ROLE_PROP}={role}",
            f"-D{ANDROID_VARIANT_PROP}={variant}",
            f"-D{ANDROID_ROOT_PROP}={estate}",
            f"-D{ANDROID_DEADLINE_PROP}={timeout_s}",
            f"-D{ANDROID_IN_PROP}={worker.to_worker.path}",
            f"-D{ANDROID_OUT_PROP}={worker.from_worker.path}",
        ]
        worker.spec.argv = argv
        worker.launch = {"executable": str(gradlew), "task": task,
                         "test_class": klass,
                         "jvm_args": [a for a in argv if a.startswith("-D")],
                         "env_keys": ["JAVA_HOME", "ANDROID_HOME"]}
        worker.start()
        self.workers.append(worker)
        self.evidence.note_launch(name, "android", role, variant, argv, str(estate))
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
                     f"seeds 0x{sender_seed:02x}/0x{receiver_seed:02x}")
            sender.send("mint", b"", seed=sender_seed)
            receiver.send("mint", b"", seed=receiver_seed)
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
        for me, them in ((sender, receiver_hello), (receiver, sender_hello)):
            me.send("peer", b"", **{k: them.header.get(k, "") for k in
                                    ("node_id", "node_hint", "static_dh_pub", "binding")})
        for me in (sender, receiver):
            me.send("setup", b"", seat="initiator" if me is sender else "responder")
        for me in (sender, receiver):
            ready = me.wait(lambda r: r.kind in ("ready", "refuse"), timeout_s, "its `ready` marker")
            if ready.kind == "refuse":
                raise Refused(f"*** THE {me.name} WORKER REFUSED AT ITS SEAT: "
                              f"{ready.header.get('reason', 'no reason given')} ***")
            self.log(f"  {me.name} seated: {dict(ready.header)}")

    # ---- the relay --------------------------------------------------------------------------------------------

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

    # ---- observation helpers ----------------------------------------------------------------------------------

    @staticmethod
    def durable_of(worker: Worker) -> Optional[Record]:
        return worker.observe(lambda r: r.kind == "observe" and r.header.get("durable_row") == "present")

    @staticmethod
    def refusal_of(worker: Worker) -> Optional[Record]:
        return worker.observe(lambda r: r.kind == "observe"
                              and r.header.get("durable_row") == "absent"
                              and bool(r.header.get("refusal")))

    @staticmethod
    def delivered_of(worker: Worker) -> Optional[Record]:
        return worker.observe(lambda r: r.kind == "observe" and r.header.get("delivery") == "DELIVERED")

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
            result = self.judge(direction, control, sender, receiver, msg_id)
            for w in (sender, receiver):
                w.send("bye")
            return result
        finally:
            for w in (sender, receiver):
                w.close()
                self.workers = [x for x in self.workers if x is not w]

    def judge(self, direction: str, control: str, sender: Worker, receiver: Worker,
              msg_id: str) -> Result:
        """*** THE VERDICT IS READ FROM EACH SIDE'S OWN OWNER, NEVER FROM A BYTES-CROSSED CLAIM. ***"""
        if control == "honest":
            durable = self.durable_of(receiver)
            delivered = self.delivered_of(sender)
            if durable is None:
                raise Refused(f"*** {direction} ({control}): THE RECIPIENT NEVER PROVED ITS DURABLE ROW. *** "
                              f"receiver said: {self.summary(receiver)}")
            if delivered is None:
                raise Refused(f"*** {direction} ({control}): THE SENDER NEVER PROVED ITS DELIVERY TRANSITION. *** "
                              f"sender said: {self.summary(sender)}")
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
            return Result(direction=direction, control=control, outcome="ACCEPTED",
                          detail="the recipient committed the exact msgId and the sender reached DELIVERED after "
                                 "the recipient's canonical ACK crossed the return leg",
                          durable_row="present", delivery="DELIVERED", msg_id=msg_id,
                          boundary="inbox commit + delivery tracker CAS")

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
        replays = [(blob[e["payload_offset"]:e["payload_offset"] + e["payload_length"]],
                    e["characteristic"], e["epoch"]) for e in captured]
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
            prepare = self.launch_android(f"android-prepare-{boundary}", "crash-prepare", boundary, estate,
                                          self.deadline_s)
            try:
                marker = prepare.wait(lambda r: r.kind in ("at_boundary", "refuse"), self.deadline_s,
                                      f"its AT_BOUNDARY marker for {boundary}")
                if marker.kind == "refuse":
                    raise Refused(f"*** THE ANDROID WORKER REFUSED THE {boundary} CHECKPOINT: "
                                  f"{marker.header.get('reason')} ***")
                self.log(f"  {boundary}: {dict(marker.header)}")
            finally:
                prepare.close()
                self.workers = [x for x in self.workers if x is not prepare]
            # *** THE JVM MUST HAVE DIED ABRUPTLY. *** *A halt carrieth its own status; a clean exit would mean the
            # worker cooperated, which is not a crash proof.*
            if prepare.status in (0, None):
                raise Refused(f"*** THE ANDROID PREPARE JVM FOR {boundary} EXITED {prepare.status}: A COOPERATIVE "
                              "EXIT IS NOT A CRASH. ***")

            recover = self.launch_android(f"android-recover-{boundary}", "crash-recover", boundary, estate,
                                          self.deadline_s)
            try:
                outcome = recover.wait(lambda r: r.kind in ("complete", "refuse"), self.deadline_s,
                                       f"its COMPLETE marker for {boundary}")
                if outcome.kind == "refuse":
                    raise Refused(f"*** THE ANDROID RECOVERY FOR {boundary} FAILED: "
                                  f"{outcome.header.get('reason')} ***")
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
            finally:
                rc = recover.status
                recover.close()
                self.workers = [x for x in self.workers if x is not recover]
            if rc not in (0, None):
                raise Refused(f"*** THE ANDROID RECOVERY JVM FOR {boundary} EXITED {rc}. ***")

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
            "input_digest": self.digest,
            "input_files": self.input_files,
            "toolchain": self.toolchains,
            "results": [
                {"direction": r.direction, "control": r.control, "outcome": r.outcome,
                 "durable_row": r.durable_row, "delivery": r.delivery, "msg_id": r.msg_id,
                 "refusal": r.refusal, "boundary": r.boundary, "detail": r.detail}
                for r in self.results
            ],
            "manifest": {"path": manifest["transcript"]["path"],
                         "sha256": sha256_file(self.evidence.manifest_path),
                         "record_count": manifest["record_count"]},
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

    # ---- fixtures ---------------------------------------------------------------------------------------------

    def persist_fixtures(self, mode: str) -> None:
        """*** "Persist these generated transcripts under `tools/integration-fixtures/` with their producer
        identities and an evidence binding." ***"""
        target = self.fixtures_root / self.run_id
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.evidence.blob, target / "transcript.bin")
        shutil.copy2(self.evidence.manifest_path, target / "manifest.json")
        shutil.copy2(self.evidence_dir / "integration-report.json", target / "integration-report.json")
        (target / "producers.json").write_text(json.dumps({
            "schema_version": SCHEMA_VERSION,
            "run_id": self.run_id,
            "mode": mode,
            "input_digest": self.digest,
            "input_files": self.input_files,
            "toolchain": self.toolchains,
            "worker_launches": self.evidence.launches,
            "evidence_binding": {
                "transcript": {"path": "transcript.bin",
                               "sha256": sha256_file(target / "transcript.bin")},
                "manifest": {"path": "manifest.json",
                             "sha256": sha256_file(target / "manifest.json")},
                "report": {"path": "integration-report.json",
                           "sha256": sha256_file(target / "integration-report.json")},
            },
            "producers": [
                {"sequence": e["sequence"], "platform": e["platform"], "producer": e["producer"],
                 "target": e["target"], "direction": e["direction"], "kind": e["kind"],
                 "characteristic": e["characteristic"], "epoch": e["epoch"],
                 "payload_sha256": e["payload_sha256"], "source_digest": e["source_digest"]}
                for e in self.evidence.records
            ],
        }, indent=2) + "\n")
        self.log(f"  fixtures persisted under {target.relative_to(REPO)}")
        return target

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

        post_digest, _ = input_digest(tuple(self.args.extra_input or ()))
        if post_digest != self.digest:
            self.log(f"*** REFUSED: an input changed WHILE the run executed ***\n"
                     f"    pre ={self.digest}\n    post={post_digest}")
            return 3

        manifest = self.evidence.close()
        if failure is None:
            self.write_report(mode, manifest)
            self.persist_fixtures(mode)
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
                    help="assume the macOS test bundle is already built")
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
