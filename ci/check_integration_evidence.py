#!/usr/bin/env python3
"""*** THE BOARD1 INTEGRATION-EVIDENCE GATE: JUDGE THE CROSS-PLATFORM / PROCESS-DEATH EVIDENCE BY CONTENT. ***

    python3 ci/check_integration_evidence.py --report <dir-or-json> [--require-mode all] [--json]
    python3 ci/check_integration_evidence.py --selftest

*** WHY THIS EXISTS, AND THE DEFECT IT CLOSES. *** *The Board 1 terminal job downloads the `board1-integration-
evidence` artifact and a closure claim is built over it. **BUT NOTHING INDEPENDENTLY JUDGED THAT EVIDENCE**: the
coordinator (`tools/readiness/run_board1_integration.py`) WRITETH an `integration-report.json` and a separate
`manifest.json`/`transcript.bin`, and the only party asserting anything about them was the coordinator itself -- which
is the "a run reported its own success" shape this programme keeps removing. The FROZEN fixtures under
`tools/integration-fixtures/` are committed and could be COPIED in place of this run's own output, and a copied
historical report would read EXACTLY like a fresh one: the coordinator mints a fresh `run_id`, but a copy carrieth the
OLD one and nothing compared it to the run.*

THE LAW THIS GATE ENFORCES -- EACH CLAUSE IS A MEASURED DEFECT CLASS FROM ELSEWHERE IN THIS REPOSITORY:

  1. THE REQUIRED POPULATION. *An `all` run carrieth EXACTLY the eight cross-platform rows (two directions x four
     controls: honest/altered/mismatched/replay) AND the two crash rows (`outboundEnqueue`, `inboundCommit`).* **A
     MISSING row, or a run that judged only HALF the matrix, is refused** -- the same "a required test omitted by
     configuration" clause the lane control carrieth.
  2. THE EXACT ARMS. *For each `(direction, control)` the OUTCOME and the DURABLE-ROW/DELIVERY/REFUSAL shape are
     pinned:* honest -> ACCEPTED with a present row and DELIVERED and NO refusal; altered/mismatched/replay -> REFUSED
     with NO committed row and NO delivery and a non-empty refusal. *The crash rows -> RECOVERED with a present durable
     row.* **A row whose shape disagreeth is refused BY NAME** -- outcome is not a count.
  3. THE DIGESTS ARE RE-COMPUTED FROM THE BYTES, NOT TRUSTED. *The report's `transcript.sha256` must equal the
     sha256 of `transcript.bin`; its `manifest.sha256` the sha256 of `manifest.json`; and the manifest's own
     `transcript.sha256` must AGREE with the report's `record_count` and `length`.* **A report whose bytes were
     swapped, truncated or re-pointed to the committed fixtures is refused** -- because the digest it carrieth would
     no longer match the file beside it.
  4. THE INPUTS ARE BOUND TO THE LIVE TREE. *The report's `input_files` map is re-hashed against the CURRENT sources*
     (`run_board1_integration.py`, the two rigs, the worker tests, `build.gradle.kts`) *and the recomputed
     `input_digest` must equal the report's.* **A digest naming a revision nobody can date -- or a copy of a tree that
     has since moved -- is refused**, the same content-not-mtime rule the lane runners carry.
  5. THE RUN IS ONE RUN, NOT A COPY OF A HISTORICAL FIXTURE. *A `run_id` that already existeth under
     `tools/integration-fixtures/` is a COPIED FIXTURE, refused BY NAME.* **This is the clause that maketh a fresh
     run distinguishable from a re-committed old one.**
  6. NO FABRICATED GREEN. *A report claiming a mode it did not run, a `schema_version`/`protocol_version` it does not
     carry, or a transcript whose framing the report cannot describe, is refused.*

*THE GATE PRODUCETH A VERDICT AND NAMETH EVERY CLAUSE IT REFUSED; IT NEVER EDITS THE EVIDENCE. The coordinator
PRODUCETH; this JUDGETH.*
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

SCHEMA_VERSION = 1
PROTOCOL_VERSION = 1

#: The two live foreign-platform directions and the four controls, exactly as the coordinator's own constants name
#: them. *A run of `mode=all` carrieth every `(direction, control)` pair below.*
DIRECTIONS = ("ios->android", "android->ios")
CONTROLS = ("honest", "altered", "mismatched", "replay")
#: The two durable boundaries the crash campaign walketh.
CRASH_BOUNDARIES = ("outboundEnqueue", "inboundCommit")

#: *** THE ANDROID PREPARE JVM'S HALT STATUS, AND THE COORDINATOR-KILL REASONS THAT ARE NEVER CRASH PROOF. ***
#:
#: *`Runtime.halt(137)` terminateth the forked Gradle test-executor JVM with 137; **Gradle does NOT propagate it** --
#: the wrapper exiteth 1. So the gate requirith the ACTUAL executor's abrupt 137, bound to an actual PID, and refuses
#: any termination the coordinator's own cleanup supplied.* **This is the clause that maketh "a HUNG worker, a worker
#: the coordinator killed, and a real abrupt halt" three distinguishable outcomes rather than one.**
CRASH_EXECUTOR_ABRUPT_STATUS = 137
COORDINATOR_KILL_REASONS = ("coordinator-sigterm", "coordinator-sigkill")
#: A termination reason that is NOT a death at all. *A worker that never exited (or never started) cannot stand as
#: crash proof, and `None`/`hung` are exactly the two shapes the coordinator previously ACCEPTED.*
NON_DEATH_REASONS = ("hung", "still-running", "never-started")
#: The pid a Robolectric-shadows context reporteth for `Process.myPid()` -- NOT a real OS pid. *A crash bound to
#: it, to a non-positive value, or to the gradlew wrapper's own pid is bound to no observed process.*
ROBOLECTRIC_SHADOW_PID = 10000

#: *** THE EXACT OUTCOME SHAPE PER CONTROL -- the arms, pinned BY NAME rather than by count. ***
#:
#: honest            -> ACCEPTED, a durable row PRESENT, DELIVERED, and NO refusal;
#: altered/mismatched/replay -> REFUSED, NO committed row, NO delivery, and a NON-EMPTY refusal naming a boundary;
#: crash boundaries  -> RECOVERED, a durable row PRESENT.
HONEST_SHAPE = {"outcome": "ACCEPTED", "durable_row": "present", "delivery": "DELIVERED", "refusal": None}
REFUSED_SHAPE = {"outcome": "REFUSED", "durable_row": "absent", "delivery": None}
CRASH_SHAPE = {"outcome": "RECOVERED", "durable_row": "present"}

#: The inputs whose bytes the report claims to describe, re-hashed here against the LIVE tree.
#:
#: *** THIS LIST MUST BE THE COORDINATOR'S OWN `INPUT_FILES_DEFAULT`, OR THE LIVE-TREE RE-HASH WOULD REFUSE EVERY
#: RUN FOR AN INPUT THE COORDINATOR NEVER CLAIMED.*** *It is kept as a literal rather than imported, so this gate
#: remaineth runnable without importing the coordinator; the coordinator's set is the authority, and the terminal
#: job's report must recompute.* **A subset here would make the gate check FEWER sources than the run bound, which is
#: exactly the "controls omitted by configuration" class this programme refuses.**
INPUT_FILES_DEFAULT = (
    "tools/readiness/run_board1_integration.py",
    "ci/check_integration_evidence.py",
    "ci/check_lane_results.py",
    "tools/readiness/run_ios_lane.sh",
    "tools/readiness/run_ios_simulator_lane.sh",
    "tools/readiness/run_android_lanes.sh",
    "docs/supplychain/SQLCIPHER.pins.json",
    "tools/supplychain/build_sqlcipher_simulator.sh",
    "tools/supplychain/verify_sqlcipher_artifact.py",
    "tools/readiness/build_provenance.py",
    "ios/Godstone/Sources/GodstoneMesh/SQLCipherTrustedExpectation.swift",
    "ios/Godstone/Sources/GodstoneMesh/SqlCipherDylibEngine.swift",
    "ios/Godstone/Sources/GodstoneMesh/SQLiteFunctionTable.swift",
    "ios/Godstone/Sources/GodstoneMesh/OwnedVerifiedConnection.swift",
    "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift",
    "ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift",
    "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift",
    "ios/Godstone/Sources/GodstoneMesh/RealTransportHostRig.swift",
    "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001CrossPlatformWorkerTests.swift",
    "ios/Godstone/Tests/GodstoneMeshTests/GsIntegration001ProcessTests.swift",
    "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt",
    "android/mesh/src/main/java/io/godstone/mesh/identity/WipeJournalDurabilityAdapter.kt",
    "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt",
    "android/mesh/src/test/java/io/godstone/mesh/rig/RealTransportHostRig.kt",
    "android/mesh/src/test/java/io/godstone/mesh/rig/RealTransportHostRigWorkerTest.kt",
    "android/mesh/build.gradle.kts",
)

#: *** THE HISTORICAL FIXTURE ARCHIVE, WHOSE AUTHORED `run_id`s MUST NOT APPEAR IN A FRESH RUN'S REPORT. ***
#:
#: *This directory is HISTORICAL ONLY: the controlled archived bases (the frozen Sept-29 fixtures) committed as test
#: inputs. **A CURRENT run never persists into it** -- the coordinator writeth its producer binding inside its own
#: evidence dir -- so a fresh run's `run_id` is absent from this namespace by construction and is accepted.*
#:
#: *** THE READ ROOT IS OVERRIDABLE, BECAUSE A STANDALONE REPLAY MUST JUDGE THE DOWNLOADED BYTES. *** *A fresh reader
#: re-executing the hosted run downloads `board1-integration-evidence` (which carrieth `tools/integration-fixtures/**`)
#: OUTSIDE the checkout, and this tree's copy may be absent or stale. So the fixture-input reads
#: (`_fixture_run_ids`, the collision refusal's path text, and the `selftest` base) all resolve through
#: `resolve_fixtures_root()` -- supplied `--fixtures-root` (or the `GODSTONE_BOARD1_INTEGRATION_FIXTURES_ROOT` env the hosted
#: caller exports) FIRST, and the in-checkout directory otherwise. **The SOURCE (which fixtures the candidate
#: committed) is never rebased: only these evidence READS move.***
FIXTURES_ROOT = REPO / "tools" / "integration-fixtures"
FIXTURES_ROOT_ENV = "GODSTONE_BOARD1_INTEGRATION_FIXTURES_ROOT"


class FixturesAbsent(RuntimeError):
    """*** A MISSING FIXTURE ROOT IS A NAMED REFUSAL, NOT A RAW `FileNotFoundError`. *** *A reader that supplied a
    download root and got a bare traceback cannot tell "the artifact was not downloaded" from "the gate is broken".*"""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def recompute_input_digest(files: dict[str, str]) -> str:
    """The SAME digest expression the coordinator useth (`input_digest`), so the recomputation is comparable."""
    h = hashlib.sha256()
    for rel in sorted(files):
        h.update(rel.encode())
        h.update(b"\0")
        h.update(files[rel].encode())
        h.update(b"\0")
    return h.hexdigest()


def resolve_fixtures_root(supplied: Path | str | None = None) -> Path:
    """*** RESOLVE THE FIXTURE-INPUT ROOT: supplied argument, then env, then the in-checkout directory. ***

    *No assumption is made that the checkout's ignored directory is the right one: a standalone/hosted replay passes
    the DOWNLOADED root, and its bytes are what get judged. **An explicitly supplied root that is ABSENT REFUSES BY
    NAME** (the `env`/in-checkout fallback is only consulted when NOTHING was supplied), so a reader who named a
    download root is told that it was not there rather than silently judging some other directory.*
    """
    if supplied not in (None, ""):
        root = Path(supplied)
        if not root.is_dir():
            raise FixturesAbsent(
                f"the supplied fixture root {root} is not a directory -- *a download root that was never obtained "
                f"cannot judge which run_ids are committed fixtures; obtain the board1-integration-evidence artifact "
                f"or omit --fixtures-root to fall back to the in-checkout {FIXTURES_ROOT.relative_to(REPO)}*")
        return root
    env = os.environ.get(FIXTURES_ROOT_ENV, "")
    if env:
        root = Path(env)
        if root.is_dir():
            return root
        raise FixturesAbsent(
            f"${FIXTURES_ROOT_ENV} names {root}, which is not a directory -- *the caller exported a fixture root "
            f"that does not exist, so the collision check cannot be silently skipped*")
    return FIXTURES_ROOT


def _fixture_run_ids(fixtures_root_arg: Path | str | None = None) -> set[str]:
    """*** THE HISTORICAL FIXTURE IDENTITIES, READ FROM EACH FIXTURE'S *AUTHORED* `run_id` FIELD. ***

    *THE DEFECT THIS CLOSES, MEASURED: the collision clause compared the report's `run_id` against fixture DIRECTORY
    BASENAMES, so renaming a historical fixture directory (or dropping a byte-identical copy into a differently-named
    directory) would evade it. **The identity that musters is the one the report AUTHORED, not the folder it sits in:**
    the set is read from each fixture report's own `run_id`, so a renamed directory still carrieth its historical id
    and a copy carrieth the id it copied. No hash and no basename is consulted here.*
    """
    root = resolve_fixtures_root(fixtures_root_arg)
    if not root.is_dir():
        return set()
    ids: set[str] = set()
    for d in sorted(root.iterdir()):
        if not d.is_dir():
            continue
        rep_path = d / "integration-report.json"
        if not rep_path.is_file():
            continue
        try:
            rid = json.loads(rep_path.read_text(encoding="utf-8")).get("run_id")
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(rid, str) and rid:
            ids.add(rid)
    return ids


def _report_covers_cross(rep: dict) -> bool:
    pairs = {(r.get("direction"), r.get("control")) for r in (rep.get("results") or []) if isinstance(r, dict)}
    return {(d, c) for d in DIRECTIONS for c in CONTROLS} <= pairs


def _report_covers_crash(rep: dict) -> bool:
    pairs = {(r.get("direction"), r.get("control")) for r in (rep.get("results") or []) if isinstance(r, dict)}
    return {("android-crash", b) for b in CRASH_BOUNDARIES} <= pairs


def select_selftest_base(root: Path) -> tuple[Path, Path | None] | None:
    """*** SELECT A VALID SELFTEST BASE FROM THE SUPPLIED ROOT -- NEVER A HARDCODED FIXTURE NAME. ***

    *THE DEFECT THIS CLOSES, AND IT IS A REAL HOSTED FAILURE: the selftest named two committed fixtures by their
    literal `run_id`s (one cross-platform, one crash). Those dirs are GITIGNORED and absent from a clean checkout,
    and a freshly-built run persisteth ONE all-mode fixture under its OWN `run_id` -- so
    `--selftest --fixtures-root <downloaded root>` REFUSED for a fixture name that was never going to be there.
    **A base is therefore SELECTED by CONTENT: a single `mode=all` fixture (both families in one report) is ideal,
    and otherwise a cross-platform fixture plus the crash fixture are composed. A root that carrieth no such pair is
    a NAMED refusal, never a vacuous green.***
    """
    if not root.is_dir():
        return None
    complete: list[Path] = []
    cross_only: list[Path] = []
    crash_only: list[Path] = []
    for d in sorted(root.iterdir()):
        if not d.is_dir():
            continue
        if not ((d / "integration-report.json").is_file() and (d / "transcript.bin").is_file()
                and (d / "manifest.json").is_file()):
            continue
        try:
            rep = json.loads((d / "integration-report.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        cross, crash = _report_covers_cross(rep), _report_covers_crash(rep)
        if cross and crash:
            complete.append(d)
        elif cross:
            cross_only.append(d)
        elif crash:
            crash_only.append(d)
    if complete:
        return complete[0], None
    if cross_only and crash_only:
        return cross_only[0], crash_only[0]
    return None


def fixture_collision_problems(report: dict, fixtures_root: Path | str | None = None) -> list[str]:
    """*** THE PURE FRESH-VS-COPIED IDENTITY PREDICATE -- NO OTHER CLAUSE MIXED IN. ***

    *THE DEFECT THIS CLOSES IN THE COURT: a control that exercised the WHOLE `check_report` could not tell "the
    collision clause bit" from "an old fixture failed schema/attestation/termination/reopened/cancel". **This returns
    ONLY the historical-identity decision**, so a changed fresh `run_id` yields NO problems here (while the report
    may still legitimately fail other, unrelated clauses), and a historical authored id yields exactly the
    COMMITTED-FIXTURE identity problem. The overall report validation is UNCHANGED: `check_report` still call-eth
    this and every other clause at full strength.*

    *THE IDENTITY MUSTERED IS THE *AUTHORED* `run_id`, NOT THE DIRECTORY NAME AND NOT A HASH: (a) basename matching
    let a renamed directory evade the control; (b) a hash-provenance exemption was SELF-AUTHORED -- a bit-identical
    copy carrieth its own `producers.json.evidence_binding` and would have been pardoned. **So every historical
    authored `run_id` is refused for a fresh report, with NO hash self-exemption; the CURRENT run's id is absent from
    the historical namespace by construction and is accepted.***
    """
    run_id = report.get("run_id")
    if not run_id:
        return []
    try:
        fixture_ids = _fixture_run_ids(fixtures_root)
    except FixturesAbsent as exc:
        # *** A SUPPLIED/ABSENT FIXTURE ROOT IS A NAMED REFUSAL, NOT A RAW `FileNotFoundError`. *** *The reader named
        # the bytes to judge; failing loudly keeps a fresh-vs-copied decision from being silently skipped.*
        return [f"integration evidence: the fixture-input root could not be resolved: {exc}"]
    if run_id not in fixture_ids:
        return []
    # *** THE REFUSAL NAMES A PATH THAT MAY LIVE OUTSIDE THE REPO, SO IT IS ABSOLUTE, NEVER `relative_to`. ***
    root = resolve_fixtures_root(fixtures_root)
    where = (str(root.relative_to(REPO)) if root.is_relative_to(REPO) else str(root))
    return [f"integration evidence: run_id {run_id!r} is a COMMITTED FIXTURE identity under `{where}` -- *a fresh "
            f"report AUTHORING a historical fixture's run_id is a COPIED historical report, not this run's output; "
            f"the identity is the report's own authored `run_id`, so a renamed directory or a byte-identical copy "
            f"cannot evade this*"]


def resolve_report_dir(arg: str) -> Path:
    """Accept a directory (carrying `integration-report.json`) OR the json path itself."""
    p = Path(arg)
    if p.is_dir():
        return p
    return p.parent


def _shape_problems(prefix: str, row: dict, want: dict) -> list[str]:
    problems: list[str] = []
    for key, expected in want.items():
        got = row.get(key)
        if key == "refusal":
            # The two shapes agree on NOTHING about `refusal`, so it is handled by the caller.
            continue
        if got != expected:
            problems.append(f"{prefix}: `{key}` is {got!r}, expected {expected!r}")
    return problems


# ---------------------------------------------------------------------------------------------------------------
# *** THE TERMINATION CLAUSE: HOW EACH WORKER ENDED, AND WHETHER THE COORDINATOR SUPPLIED THE END. ***
# ---------------------------------------------------------------------------------------------------------------


def _termination_problems(tag: str, term: dict) -> list[str]:
    """Judge ONE observed termination. **A DEATH THE COORDINATOR SUPPLIED IS NEVER A WORKER'S DEATH.**

    *This is the RECOVERY-role and WITNESS clause: was the end observed, real, and the worker's own? **The
    ABRUPTNESS of an Android crash is judged by `_crash_termination_problems` instead** -- it binds the actual Gradle
    executor child's non-zero status to a real PID and a pre-halt stage declaration, which is a strictly stronger
    claim than "the wrapper's terminal record was non-zero". So there is no `must_be_abrupt` knob here: the crash
    proof never rides this function, and a caller could only ever have passed `False`.*
    """
    problems: list[str] = []
    reason = str(term.get("termination_reason", ""))
    status = term.get("exit_status")
    if term.get("forced_kill"):
        problems.append(f"{tag}: the termination was FORCED BY THE COORDINATOR's own kill "
                        f"(forced_kill=true) -- *a worker the coordinator ended cannot stand as the worker's own "
                        f"abrupt halt*")
    if reason in COORDINATOR_KILL_REASONS:
        problems.append(f"{tag}: the termination reason is {reason!r} -- *the coordinator's own SIGTERM/SIGKILL, "
                        f"never the worker's death*")
    if reason in NON_DEATH_REASONS or status is None:
        problems.append(f"{tag}: the worker did not die on its own ({reason!r}, status={status!r}) -- *a HUNG, "
                        f"still-running or never-started worker is NOT a death, and `None` must never be accepted "
                        f"as one*")
    if not term.get("observed_before_cleanup"):
        problems.append(f"{tag}: the termination was observed ONLY during cleanup (observed_before_cleanup=false) "
                        f"-- *the death must be seen before the coordinator can supply one*")
    if not term.get("pid"):
        problems.append(f"{tag}: the termination carrieth NO PID -- *an abrupt halt that cannot be bound to a real "
                        f"process is not evidence about one*")
    return problems


def _crash_termination_problems(tag: str, term: dict) -> list[str]:
    """*** THE ANDROID CRASH PROOF: THE ACTUAL GRADLE EXECUTOR CHILD DYING ABRUPTLY, BOUND TO ITS PID AND STAGE. ***

    *THE FACT THAT MAKETH DEMANDING `wrapper_rc == 137` WRONG: Gradle reapit its forked executor and reporteth the
    BUILD as `rc=1`; it does NOT re-exit with 137. **So the proof requirith the executor's own abrupt 137, an actual
    PID, and the pre-halt declaration -- never the wrapper's rc.** The value checks below are the SECOND half of
    that law: a pid that is a shadow constant or the wrapper itself, and a declaration that names no stage or no
    code, bindeth the death to nothing.*
    """
    problems: list[str] = []
    abrupt = term.get("executor_abrupt_status")
    if abrupt != CRASH_EXECUTOR_ABRUPT_STATUS:
        problems.append(f"{tag}: the ACTUAL Gradle executor did not die with status {CRASH_EXECUTOR_ABRUPT_STATUS} "
                        f"(observed {abrupt!r}) -- *the wrapper's exit code is NOT the executor's, so neither the "
                        f"wrapper rc nor a missing child status can stand as the abrupt halt*")
    executor_pid = term.get("executor_pid")
    if not executor_pid:
        problems.append(f"{tag}: the crash proof names NO executor PID -- *the abrupt status is not bound to a real "
                        f"process*")
    else:
        # *A real OS pid only. The Robolectric shadow (`10000`) is the CONSTANT a simulated context reporteth,
        # and a pid EQUAL to the wrapper's is the gradlew process -- which observably exiteth cooperatively at
        # rc=1, so it cannot also be the child that died abruptly.*
        if executor_pid <= 0 or executor_pid == ROBOLECTRIC_SHADOW_PID:
            problems.append(f"{tag}: the executor pid is {executor_pid}, which is not a real OS pid "
                            f"(non-positive or the Robolectric shadow) -- *a death bound to a simulated process "
                            f"is bound to no process*")
        if executor_pid == term.get("wrapper_pid"):
            problems.append(f"{tag}: the 'executor' pid EQUALS the wrapper pid ({executor_pid}) -- *the forked "
                            f"executor child was never observed as a DISTINCT process*")
    if not term.get("about_to_halt_seen"):
        problems.append(f"{tag}: the crash proof carrieth NO pre-halt DECLARATION -- *the death is not bound to the "
                        f"durable checkpoint it was supposed to follow*")
    if str(term.get("about_to_halt_boundary", "")) != str(term.get("boundary", "")):
        problems.append(f"{tag}: the pre-halt declaration names boundary {term.get('about_to_halt_boundary')!r} "
                        f"for the {term.get('boundary')!r} row -- *a marker about some other stage is not this "
                        f"stage's death*")
    if term.get("about_to_halt_code") != CRASH_EXECUTOR_ABRUPT_STATUS:
        problems.append(f"{tag}: the pre-halt declaration does not declare the halt code "
                        f"{CRASH_EXECUTOR_ABRUPT_STATUS} (observed {term.get('about_to_halt_code')!r}) -- *the "
                        f"worker must predict the very death Gradle then observeth*")
    if term.get("forced_kill"):
        problems.append(f"{tag}: the prepare was FORCED BY THE COORDINATOR (forced_kill=true) -- *the death must be "
                        f"the worker's own, observed before any coordinator kill*")
    wrapper_reason = str(term.get("wrapper_termination_reason", ""))
    if wrapper_reason in COORDINATOR_KILL_REASONS:
        problems.append(f"{tag}: the wrapper's termination reason is the coordinator's own kill")
    if wrapper_reason in NON_DEATH_REASONS or term.get("wrapper_exit_status") is None:
        problems.append(f"{tag}: the prepare never exited on its own (reason={wrapper_reason!r}, "
                        f"wrapper_exit_status={term.get('wrapper_exit_status')!r}) -- *a HUNG prepare is NOT a crash, "
                        f"and `None` must never be accepted as one*")
    if term.get("wrapper_exit_status") == 0:
        problems.append(f"{tag}: the prepare's wrapper exited 0 -- *a cooperative exit is not crash proof*")
    if not term.get("observed_before_cleanup"):
        problems.append(f"{tag}: the wrapper's termination was observed only during cleanup")
    return problems


def check_reopened_estate_proofs(report: dict) -> list[str]:
    """*** AN HONEST ROW MUST HAVE BEEN RE-READ FROM THE *REOPENED* ESTATE, NOT THE RUNNING STORE. ***

    *THE DEFECT THIS CLOSES: the coordinator's `durable_row: present` and `delivery: DELIVERED` were read from LIVE
    stores, so a reader could not tell a surviving row from a running object's own state -- the self-attestation the
    plan forbids. **A fresh run's honest rows must now carry the reopened-estate proof in their DETAIL/BOUNDARY, and
    the eight combos must each be backed by one.***
    """
    problems: list[str] = []
    for row in report.get("results") or []:
        if not isinstance(row, dict) or row.get("control") != "honest":
            continue
        boundary = str(row.get("boundary", ""))
        detail = str(row.get("detail", ""))
        if "reopened" not in boundary.lower() and "reopened" not in detail.lower():
            problems.append(f"integration evidence: {row.get('direction')}/honest: the durable claim names NO "
                            f"REOPENED estate in its boundary/detail -- *a row read from a live store is not bound to "
                            f"surviving bytes*")
    return problems


def check_cancellation_negative(report: dict) -> list[str]:
    """*** EACH HONEST COMBO MUST CARRY THE CANCELLATION NEGATIVE'S OWN PROOF. ***

    *THE GAP THIS CLOSES: the eight combos proved an honest DELIVERED transition but nothing about the tracker's OTHER
    terminal move. **A `cancel` that silently did nothing, or moved the wrong row, was invisible; each honest row must
    now carry the frame it moved and the state it moved it to, re-read from the reopened estate.***
    """
    problems: list[str] = []
    for row in report.get("results") or []:
        if not isinstance(row, dict) or row.get("control") != "honest":
            continue
        if not row.get("cancellation_msg_id"):
            problems.append(f"integration evidence: {row.get('direction')}/honest: NO cancellation negative msgId -- "
                            f"*the tracker's cancel road was never exercised for this direction*")
        state = str(row.get("cancellation_state", ""))
        if "cancel" not in state.lower():
            problems.append(f"integration evidence: {row.get('direction')}/honest: the cancellation state is "
                            f"{state!r}, which is not a cancelled state")
    return problems


def check_build_attestation(report: dict, *, recompute: bool = False) -> list[str]:
    """*** THE BUILT FIXTURE MUST BE IDENTITY-BOUND, NOT ASSUMED, AND NOT SELF-DECLARED. ***

    *THE DEFECT THIS CLOSES, AND IT HAS TWO HALVES. First, `--skip-build` once assumed an artifact and a caller
    could name a digest that agreed with NOTHING. Second, and subtler: the first hardening answereth by RECORDING
    booleans IN THE ATTESTATION ITSELF (`library_agrees_with_register`, `pinned_source_commit_matches_register`) --
    **a sidecar self-claim is still a claim**, and a gate that consulteth them merely judgeeth whether the report
    SAID the bytes agree. The recorded values are therefore NOT consulted here; the REGISTER is the authority and
    the attestation's pinned values are compared against it, field by field, and (when `recompute` is on, as the
    terminal job runneth it) the digests are RE-HASHED from the bytes on disk. A caller hash or boolean proves
    nothing; a recomputed hash is a fact.***
    """
    problems: list[str] = []
    att = report.get("build_attestation")
    if report.get("skip_build"):
        if not report.get("build_attestation_verified"):
            problems.append("integration evidence: `skip_build` is true but NO VERIFIED build attestation is recorded "
                            "-- *an assumed build that is not verified against a real build's record is not bound to "
                            "any candidate*")
    if not isinstance(att, dict) or not att:
        problems.append("integration evidence: NO `build_attestation` -- *the built fixture is not identity-bound to "
                        "the artifact/source/recipe/candidate that produced it*")
        return problems
    # *** A SELF-DECLARED ATTESTATION IS REFUSED OUTRIGHT. ***
    #
    # *The real producer (`build_provenance.record_build` -> `verify_image`) emiteth schema 2 WITHOUT any
    # agreement booleans -- agreement is COMPUTED here from the register and the bytes. A report carryeth those
    # keys only if a writer manufactured them, which is the exact forgery class this clause existeth to catch.*
    for self_claim in ("library_agrees_with_register", "pinned_source_commit_matches_register",
                        "register_expected_sha256"):
        if self_claim in att:
            problems.append(f"integration evidence: the build attestation carrieth the self-claim field "
                            f"`{self_claim}` -- *the schema-2 producer never emitseth agreement booleans; a report "
                            f"that ASSERTS its own agreement is not the record this gate trusteth*")
    if att.get("schema_version") != 2:
        problems.append(f"integration evidence: the build attestation schema is {att.get('schema_version')!r}, "
                        f"expected 2 -- *schema 1 was the self-claim shape this clause replaced*")
    if att.get("producer") != "tools/readiness/build_provenance.py":
        problems.append(f"integration evidence: the build attestation producer is {att.get('producer')!r}, "
                        f"expected 'tools/readiness/build_provenance.py' -- *only the building runner attesteth*")
    for key in ("producer_attempt", "mode", "candidate_sha", "candidate_tree", "whole_source_digest",
                "recipe_digest", "bundle_digest", "source_digest", "library_name", "library_sha256",
                "library_bytes", "library_path", "descriptor_sha256", "descriptor_path",
                "pinned_source_commit", "pinned_source_tag", "pinned_source_repo", "pinned_platform",
                "pinned_arch", "pinned_cipher_version_major", "approved_toolchain", "expected_source_sha256"):
        if not att.get(key):
            problems.append(f"integration evidence: the build attestation carrieth NO `{key}`")
    # *** THE REGISTER, NOT THE SIDECAR, IS THE SUPPLY AUTHORITY. ***
    register_ok = False
    try:
        sys.path.insert(0, str(REPO / "tools" / "readiness"))
        import build_provenance
        register, source, entry = build_provenance._register_entry(str(att.get("mode", "")))
        register_ok = True
        want = {
            "library_name": register.get("library_name"),
            "pinned_source_commit": source.get("commit"),
            "pinned_source_tag": source.get("tag"),
            "pinned_source_repo": source.get("repo"),
            "pinned_platform": entry.get("platform"),
            "pinned_arch": entry.get("arch"),
            "pinned_cipher_version_major": register.get("cipher_version_major"),
            "approved_toolchain": entry.get("toolchain"),
            "library_sha256": (entry.get("expected_output") or {}).get("sha256"),
            "library_bytes": (entry.get("expected_output") or {}).get("bytes"),
        }
        for key, authority in want.items():
            if att.get(key) in (None, "") or att.get(key) != authority:
                problems.append(f"integration evidence: the build attestation's {key} is "
                                f"{att.get(key)!r}, but the REGISTER authoriseth {authority!r} -- *the image the "
                                f"native road dlopeneth must be the one the register named; agreement is computed "
                                f"here, never claimed by the report*")
        # The report's OWN top-level identity (the coordinator embeds the candidate identity) must be the
        # attestation's -- otherwise the verdict row and the build record describe different revisions.
        for key in ("candidate_sha", "candidate_tree", "whole_source_digest"):
            if report.get(key) != att.get(key):
                problems.append(f"integration evidence: report {key}={str(report.get(key))[:16]}… vs attestation "
                                f"{str(att.get(key))[:16]}… -- *the run and its build record name different bytes*")
    except (ValueError, OSError, KeyError, ImportError) as exc:
        problems.append(f"integration evidence: the attestation cannot be checked against the live register: {exc}")
    if recompute and register_ok:
        # *** FRESHNESS: EVERY DIGEST RECOMPUTED FROM THE BYTES ON DISK. ***
        # *A recorded digest is a CLAIM about a past build; only a hash taken NOW from the live tree, the live
        # bundle and the staged image proves this candidate is STILL what was attested. The caller's hashes and
        # booleans authorise nothing by themselves.*
        try:
            live_identity = build_provenance.source_identity(report.get("candidate_sha"))
        except (ValueError, OSError, subprocess.CalledProcessError) as exc:
            live_identity = None
            problems.append(f"integration evidence: candidate identity re-derivation REFUSED: {exc} -- *the "
                            f"attested candidate is not the clean current HEAD, so the run is not bound to a "
                            f"fresh revision*")
        if live_identity is not None:
            for key in ("candidate_sha", "candidate_tree", "whole_source_digest"):
                if att.get(key) != live_identity.get(key):
                    problems.append(f"integration evidence: attestation {key} is stale -- the live tree hash eth "
                                    f"{str(live_identity.get(key))[:16]}…, attestation says {str(att.get(key))[:16]}…")
        if att.get("recipe_digest") != build_provenance.recipe_digest():
            problems.append("integration evidence: the recipe_digest does not recompute from the live builder/"
                            "verifier/register/expectation bytes -- *the build was not made by THIS recipe*")
        bundle = report.get("bundle_path") or att.get("bundle_path")
        if bundle:
            bundle_path = Path(bundle)
            if not bundle_path.is_absolute():
                bundle_path = REPO / bundle_path
            try:
                if att.get("bundle_digest") != build_provenance.tree_digest(bundle_path):
                    problems.append(f"integration evidence: the bundle at {bundle} does not hash to the attested "
                                    f"bundle_digest -- *the tested fixture is not the attested bytes*")
            except ValueError as exc:
                problems.append(f"integration evidence: the attested bundle is unreadable: {exc}")
        else:
            problems.append("integration evidence: no `bundle_path` travelseth with the report, so the bundle "
                            "digest CANNOT be recomputed -- *a recorded hash with no bytes to check is a claim*")
        for path_key, digest_key, label in (("library_path", "library_sha256", "staged image"),
                                              ("descriptor_path", "descriptor_sha256", "descriptor")):
            target = att.get(path_key)
            if not target:
                continue
            target_path = Path(target)
            if target_path.is_file():
                if att.get(digest_key) != sha256_file(target_path):
                    problems.append(f"integration evidence: the {label} at {target} does not hash to the "
                                    f"attested {digest_key} -- *the sidecar is a self-report; the bytes are the "
                                    f"fact*")
            elif label == "staged image":
                problems.append(f"integration evidence: the attested staged image {target} is ABSENT -- *the run "
                                f"claims a dlopen target that is not on disk*")
        expectation = REPO / "ios/Godstone/Sources/GodstoneMesh/SQLCipherTrustedExpectation.swift"
        if expectation.is_file() and att.get("expected_source_sha256") != sha256_file(expectation):
            problems.append("integration evidence: the tracked compiled-in SQLCipher expectation does not hash to "
                            "the attested expected_source_sha256 -- *the compiled bytes no longer describe the "
                            "register's image*")
    return problems


def check_terminations(report: dict, totals: dict) -> list[str]:
    """*** BIND THE OBSERVED DEATHS INTO THE VERDICT. ***

    *THE DEFECT THIS CLOSES: the report carrieth each worker's VERDICT and nothing about HOW IT ENDED, so a crash row
    could be earned by a HUNG worker or by the coordinator's own SIGTERM/SIGKILL. **Every crash row must now be
    backed by an observed termination that the coordinator did not supply, and every cross-platform row's witnesses
    must have exited 0 (or by a verified typed intentional halt) rather than by a cleanup kill.**
    """
    problems: list[str] = []
    terminations = report.get("worker_terminations")
    crash_terms = report.get("crash_terminations")
    mode = report.get("mode")

    if mode in ("all", "crash"):
        # (A) THE ANDROID CRASH PROOF ITSELF.
        if not isinstance(crash_terms, list) or not crash_terms:
            problems.append("integration evidence: a crash-mode report carrieth NO `crash_terminations` map -- "
                            "*the crash verdict is not bound to any observed executor death*")
        else:
            by_boundary = {t.get("boundary"): t for t in crash_terms if isinstance(t, dict)}
            for boundary in CRASH_BOUNDARIES:
                term = by_boundary.get(boundary)
                if term is None:
                    problems.append(f"integration evidence: android-crash/{boundary}: NO observed crash termination "
                                    f"was recorded for this boundary")
                    continue
                totals["crash_terminations"] = totals.get("crash_terminations", 0) + 1
                for p in _crash_termination_problems(f"android-crash/{boundary}", term):
                    problems.append("integration evidence: " + p)
        # (B) EVERY WORKER'S OBSERVED END.
        if not isinstance(terminations, list) or not terminations:
            problems.append("integration evidence: a crash-mode report carrieth NO `worker_terminations` -- *the "
                            "report claims a crash campaign without observing how any worker ended*")
        else:
            # *The recovery role must have exited on its OWN and successfully -- never by a cleanup kill.*
            for term in terminations:
                if not isinstance(term, dict):
                    continue
                if str(term.get("role")) == "crash-recover":
                    for p in _termination_problems(
                            f"android-crash/{term.get('name')}", term):
                        problems.append("integration evidence: " + p)
                    status = term.get("exit_status")
                    if status not in (0, None):
                        problems.append(f"integration evidence: android-crash/{term.get('name')}: the recovery role "
                                        f"exited {status!r}, which is neither 0 nor a verified intentional halt")

    if mode in ("all", "cross-platform") and isinstance(terminations, list):
        # *** NO CROSS-PLATFORM WITNESS MAY HAVE BEEN KILLED BY THE COORDINATOR. ***
        seen_witnesses = 0
        for term in terminations:
            if not isinstance(term, dict):
                continue
            role = str(term.get("role"))
            if role not in ("sender", "recipient"):
                continue
            seen_witnesses += 1
            if term.get("forced_kill"):
                problems.append(f"integration evidence: {term.get('name')}: a cross-platform {role} was killed by "
                                f"the coordinator's own cleanup -- *the coordinator must never supply the death of a "
                                f"worker whose verdict it reports*")
            if str(term.get("termination_reason")) in COORDINATOR_KILL_REASONS:
                problems.append(f"integration evidence: {term.get('name')}: a cross-platform {role} ended by the "
                                f"coordinator's {term.get('termination_reason')}")
            if str(term.get("termination_reason")) in NON_DEATH_REASONS:
                problems.append(f"integration evidence: {term.get('name')}: a cross-platform {role} never exited on "
                                f"its own ({term.get('termination_reason')!r}) -- *a witness that had to be killed is "
                                f"not a witness that finished*")
            # *** THE NORMAL EXIT: 0 AFTER THE ACK, OR THE WORKER'S OWN VERIFIED TYPED INTENTIONAL HALT. ***
            # *The coordinator accepteth a non-zero witness exit only when the worker's RETAINED LOG carrieth the
            # marker line; the gate here refuseth the FLAG unless its EVIDENCE names the very status the process
            # returneth. An `intentional_halt: true` with no marker text is a claim; the marker line is the fact.*
            status = term.get("exit_status")
            if status == 0:
                continue
            if not term.get("intentional_halt"):
                problems.append(f"integration evidence: {term.get('name')}: a cross-platform {role} exited "
                                f"{status!r}, which is neither 0 nor a verified typed intentional halt")
                continue
            marker = str(term.get("intentional_halt_marker", ""))
            if re.search(rf"GS_INTEGRATION_INTENTIONAL_HALT status={re.escape(str(status))}(?:\b|$)",
                          marker) is None:
                problems.append(f"integration evidence: {term.get('name')}: claims a typed intentional halt at "
                                f"status {status!r} but the log marker {marker[:80]!r} does not NAME that status "
                                f"-- *the claim must quote the line the worker printed before halting*")
            if not term.get("pid"):
                problems.append(f"integration evidence: {term.get('name')}: an intentional-halt claim with NO pid "
                                f"binds the halt to no process")
        if seen_witnesses == 0:
            problems.append("integration evidence: a cross-platform report carrieth NO observed witness terminations "
                            "-- *the eight combos are not bound to how any of their witnesses ended*")
    return problems


def check_report(report_dir: Path, *, require_mode: str | None = None,
                 check_inputs: bool = True, check_fixture_collision: bool = True,
                 check_fresh_run_proofs: bool = True,
                 fixtures_root: Path | str | None = None) -> tuple[list[str], dict]:
    """Judge ONE report directory. Returns `(problems, totals)`; an EMPTY problem list means the evidence held."""
    problems: list[str] = []
    totals: dict = {"rows": 0, "cross": 0, "crash": 0}
    report_path = report_dir / "integration-report.json"
    if not report_path.is_file():
        return ([f"integration evidence: no `integration-report.json` under {report_dir} -- **AN ABSENT REPORT IS NOT "
                 f"A PASS**, and the coordinator has not run or its output was not retained"], totals)
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return ([f"integration evidence: `{report_path.name}` is not valid JSON: {exc}"], totals)

    #: The report's authored identity, used below for the manifest/run_id agreement (the collision clause readeth it
    #: through its OWN pure predicate, so it is not consumed from here).
    run_id = report.get("run_id")

    # (1) THE VERSIONS.
    if report.get("schema_version") != SCHEMA_VERSION:
        problems.append(f"integration evidence: schema_version is {report.get('schema_version')!r}, expected "
                        f"{SCHEMA_VERSION}")
    if report.get("mode") not in ("all", "crash", "cross-platform"):
        problems.append(f"integration evidence: mode is {report.get('mode')!r} -- *not one the coordinator emiteth*")
    if require_mode and report.get("mode") != require_mode:
        problems.append(f"integration evidence: mode is {report.get('mode')!r} but this gate requirith {require_mode!r} "
                        f"-- *a run that judged only part of the matrix is not the whole matrix*")

    # (5) THE RUN IS FRESH, NOT A COPIED HISTORICAL FIXTURE.
    if check_fixture_collision:
        problems.extend(fixture_collision_problems(report, fixtures_root))

    # (3) THE DIGESTS ARE RE-COMPUTED FROM THE BYTES BESIDE THE REPORT.
    blob = report_dir / "transcript.bin"
    manp = report_dir / "manifest.json"
    rep_transcript = (report.get("transcript") or {})
    rep_manifest = (report.get("manifest") or {})
    manifest_obj: dict = {}
    if not blob.is_file():
        problems.append("integration evidence: `transcript.bin` is absent -- *the report names a transcript that is "
                        "not beside it*")
    else:
        actual = sha256_file(blob)
        if rep_transcript.get("sha256") != actual:
            problems.append(f"integration evidence: transcript.sha256 is {str(rep_transcript.get('sha256'))[:16]}… but "
                            f"`transcript.bin` hash eth to {actual[:16]}… -- *the bytes were swapped, truncated or "
                            f"re-pointed*")
        if rep_transcript.get("length") != blob.stat().st_size:
            problems.append(f"integration evidence: transcript.length is {rep_transcript.get('length')!r} but "
                            f"`transcript.bin` is {blob.stat().st_size} bytes")
    if not manp.is_file():
        problems.append("integration evidence: `manifest.json` is absent")
    else:
        actual_m = sha256_file(manp)
        if rep_manifest.get("sha256") != actual_m:
            problems.append(f"integration evidence: manifest.sha256 is {str(rep_manifest.get('sha256'))[:16]}… but "
                            f"`manifest.json` hash eth to {actual_m[:16]}…")
        try:
            manifest_obj = json.loads(manp.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            problems.append(f"integration evidence: `manifest.json` is not valid JSON: {exc}")
    if manifest_obj:
        # THE TWO FILES MUST AGREE ON THE TRANSCRIPT AND THE POPULATION.
        m_t = manifest_obj.get("transcript") or {}
        if blob.is_file() and m_t.get("sha256") != rep_transcript.get("sha256"):
            problems.append("integration evidence: the manifest's transcript sha256 disagreeth with the report's -- "
                            "*two files describing two different transcripts*")
        if m_t.get("length") is not None and m_t.get("length") != rep_transcript.get("length"):
            problems.append("integration evidence: the manifest's transcript length disagreeth with the report's")
        if rep_manifest.get("record_count") != manifest_obj.get("record_count"):
            problems.append(f"integration evidence: the report's record_count "
                            f"({rep_manifest.get('record_count')!r}) disagreeth with the manifest's "
                            f"({manifest_obj.get('record_count')!r})")
        if manifest_obj.get("protocol_version") != PROTOCOL_VERSION:
            problems.append(f"integration evidence: manifest protocol_version is "
                            f"{manifest_obj.get('protocol_version')!r}, expected {PROTOCOL_VERSION}")
        if manifest_obj.get("run_id") != run_id:
            problems.append("integration evidence: the manifest's run_id disagreeth with the report's")

    # (4) THE INPUTS ARE BOUND TO THE LIVE TREE.
    if check_inputs:
        claimed = report.get("input_files") or {}
        if not claimed:
            problems.append("integration evidence: no `input_files` map -- *a report that nameth no inputs cannot be "
                            "bound to a revision*")
        else:
            live: dict[str, str] = {}
            for rel in claimed:
                p = REPO / rel
                live[rel] = sha256_file(p) if p.is_file() else "absent"
            drifted = sorted(rel for rel in claimed if claimed[rel] != live[rel])
            if drifted:
                problems.append(f"integration evidence: the report's input digests do NOT match the live tree for "
                                f"{drifted[:4]} -- *the report describeth a revision this tree is not, so it is not "
                                f"evidence about these sources*")
            # *** A CLAIMED INPUT THAT IS ABSENT IN THIS TREE IS REFUSED BY NAME. ***
            #
            # *THE DEFECT THIS CLOSES, AND IT IS A GAP IN THIS GATE RATHER THAN THE COORDINATOR: the coordinator's own
            # `input_digest` writeth the literal string `"absent"` in the map AND hashes that same literal into the
            # digest, so a claimed path that is absent IN BOTH the report and the live tree re-hasheth IDENTICALLY and
            # the `drifted` check above passeth it silently.* **AN INPUT THAT DOES NOT EXIST CANNOT BIND A RESULT TO A
            # REVISION** -- *the report would be evidence about a tree missing a file it claims to depend on.*
            absent = sorted(rel for rel in claimed if claimed[rel] == "absent" or live[rel] == "absent")
            if absent:
                problems.append(f"integration evidence: {len(absent)} claimed INPUT FILE(S) are ABSENT from this tree: "
                                f"{absent[:4]} -- *a report cannot be bound to a revision that lacketh a file it "
                                f"claims to depend on, and `\"absent\"` hashing equal to `\"absent\"` is exactly the "
                                f"hole this check existeth to close*")
            recomputed = recompute_input_digest(claimed)
            if recomputed != report.get("input_digest"):
                problems.append(f"integration evidence: input_digest {str(report.get('input_digest'))[:16]}… does not "
                                f"recompute from the report's own `input_files` ({recomputed[:16]}…) -- *the digest "
                                f"and the file map describe different sets*")

    # (2) THE REQUIRED POPULATION AND THE EXACT ARMS.
    results = report.get("results") or []
    if not isinstance(results, list):
        problems.append("integration evidence: `results` is not a list")
        results = []
    totals["rows"] = len(results)
    by_pair = {(r.get("direction"), r.get("control")): r for r in results if isinstance(r, dict)}

    def judge_row(tag: str, row: dict, want: dict, *, refusal_expected: bool) -> None:
        for p in _shape_problems(tag, row, want):
            problems.append("integration evidence: " + p)
        if refusal_expected:
            if not row.get("refusal"):
                problems.append(f"integration evidence: {tag}: a REFUSED row carrieth an EMPTY refusal -- *a refusal "
                                f"with no reason is not a refusal*")
            if not row.get("boundary"):
                problems.append(f"integration evidence: {tag}: a REFUSED row nameth no boundary")
        else:
            if row.get("refusal") not in (None, ""):
                problems.append(f"integration evidence: {tag}: an ACCEPTED/RECOVERED row carrieth a refusal "
                                f"({row.get('refusal')!r})")
            if not row.get("msg_id"):
                problems.append(f"integration evidence: {tag}: a passing row carrieth no msg_id")

    mode = report.get("mode")
    if mode in ("all", "cross-platform"):
        for direction in DIRECTIONS:
            for control in CONTROLS:
                pair = (direction, control)
                row = by_pair.get(pair)
                tag = f"{direction}/{control}"
                if row is None:
                    problems.append(f"integration evidence: *** REQUIRED ROW ABSENT: {tag} *** *the eight-combo matrix "
                                    f"is not the eight-combo matrix when a combo is missing*")
                    continue
                totals["cross"] += 1
                if control == "honest":
                    judge_row(tag, row, HONEST_SHAPE, refusal_expected=False)
                    if row.get("delivery") != "DELIVERED":
                        problems.append(f"integration evidence: {tag}: an honest row must reach DELIVERED")
                else:
                    judge_row(tag, row, REFUSED_SHAPE, refusal_expected=True)
    if mode in ("all", "crash"):
        for boundary in CRASH_BOUNDARIES:
            row = by_pair.get(("android-crash", boundary))
            tag = f"android-crash/{boundary}"
            if row is None:
                problems.append(f"integration evidence: *** REQUIRED CRASH ROW ABSENT: {tag} *** *the process-death "
                                f"campaign must prove a surviving durable row at {boundary}*")
                continue
            totals["crash"] += 1
            judge_row(tag, row, CRASH_SHAPE, refusal_expected=False)
    # ANY ROW THE MATRIX DOES NOT DECLARE IS UNEXPECTED.
    declared = {(d, c) for d in DIRECTIONS for c in CONTROLS} | {("android-crash", b) for b in CRASH_BOUNDARIES}
    for r in results:
        if isinstance(r, dict) and (r.get("direction"), r.get("control")) not in declared:
            problems.append(f"integration evidence: UNEXPECTED row {r.get('direction')!r}/{r.get('control')!r} -- "
                            f"*a row the matrix does not declare inflates the report*")

    # (7) *** THE OBSERVED TERMINATIONS: A CRASH VERDICT MUST BE BACKED BY A DEATH THE COORDINATOR DID NOT SUPPLY. ***
    # *THE HISTORICAL FIXTURES PREDATE THIS CLAUSE -- they were produced by a coordinator that recorded no
    # termination at all -- so the age-insensitive fixture court turneth it OFF to judge the POPULATION, and the
    # gate's own selftest turneth it ON to prove it BITES. A FRESH run has no such exemption: `check_report`'s
    # default is ON, and the terminal job calls it with the default.*
    if check_fresh_run_proofs:
        problems.extend(check_build_attestation(report, recompute=check_inputs))
        problems.extend(check_terminations(report, totals))
        problems.extend(check_reopened_estate_proofs(report))
        problems.extend(check_cancellation_negative(report))
    return problems, totals


def selftest(fixtures_root: Path | str | None = None) -> int:
    """*** ADVERSARIAL MUTATIONS: EACH MUST BE REFUSED. ***

    *The base is a SYNTHETIC `mode=all` report: the cross-platform fixture's eight rows AND the crash fixture's two,
    all referencing the cross-platform fixture's real `transcript.bin`/`manifest.json` bytes* -- **so the digest,
    population and arm clauses are all exercised against a report whose MODE requirith both families, which the
    terminal job's `--require-mode all` also doeth.** *A `cross-platform`-only base could not exercise the crash
    clauses, which is exactly the vacuous-fixture trap this selftest existeth to avoid.*

    *** THE BASE FIXTURE BYTES COME FROM THE SAME OVERRIDABLE ROOT AS THE COLLISION CHECK. *** *A standalone replay
    passeth the DOWNLOADED fixture root, so the selftest exercises the very bytes it was handed; when a root was
    explicitly supplied but carrieth no cross-platform/crash fixture, this REFUSES BY NAME rather than producing a
    green table over nothing.*
    """
    import tempfile

    # *** THE SELFTEST BASE MUST SPEAK THE REGISTER'S OWN WORDS. ***
    #
    # *The attestation clause computeTH agreement from the LIVE register rather than consulting any recorded
    # boolean, so the synthetic base is built FROM that register (the same `_register_entry` the build itself
    # reads, strict) and from the live recipe. Anything the base does not forge is the truth; the mutation cases
    # forge exactly one field each.*
    sys.path.insert(0, str(REPO / "tools" / "readiness"))
    import build_provenance
    st_register, st_source, st_entry = build_provenance._register_entry("macos")
    st_expected = st_entry["expected_output"]
    st_recipe = build_provenance.recipe_digest()
    # This metadata-only selftest does not build or claim a native expectation.
    st_expectation = REPO / build_provenance.EXPECTED_SOURCE
    st_expectation_sha = (sha256_file(st_expectation) if st_expectation.is_file()
                          else hashlib.sha256(b"selftest expectation:" + st_recipe.encode()).hexdigest())

    # *** THE FIXTURE ROOT IS RESOLVED ONCE, LOUDLY. *** *An absent supplied root is a typed refusal, not a raw
    # `FileNotFoundError` from a later `read_bytes()`.*
    try:
        root = resolve_fixtures_root(fixtures_root)
    except FixturesAbsent as exc:
        print(f"integration-evidence selftest REFUSED: {exc}", file=sys.stderr)
        return 1
    # *** THE BASE IS SELECTED BY CONTENT, NOT BY A HARDCODED FIXTURE NAME. *** *A freshly-persisted all-mode
    # fixture carrieth both families in one report; a checkout may instead carry the two separate fixtures. The
    # selection never names a `run_id`, so a downloaded root with a different namespace still yields a base.*
    selection = select_selftest_base(root)
    if selection is None:
        print(f"integration-evidence selftest REFUSED: the fixture root {root} carrieth no VALID all-mode (or "
              f"cross-platform + crash) fixture report -- *the selftest base is built FROM those bytes, so a root "
              f"that lacketh a complete pair cannot exercise the clauses*", file=sys.stderr)
        return 1
    cross, crash_or_none = selection
    crash = crash_or_none if crash_or_none is not None else cross
    failures = 0
    total = 0
    results: list[tuple[str, str, str, str]] = []

    def synthetic_terminations() -> list[dict]:
        """The observed ends a REAL `all` run carrieth: two cross-platform witnesses per direction and both crash
        roles per boundary. **The base report must carry them, or every case would trip the new termination clause
        for a reason that has nothing to do with the mutation under test.**"""
        out: list[dict] = []
        for direction in DIRECTIONS:
            for control in CONTROLS:
                for role in ("sender", "recipient"):
                    out.append({
                        "name": f"{'swift' if (role == 'sender') == (direction == DIRECTIONS[0]) else 'android'}-{control}",
                        "platform": "ios", "role": role, "variant": "honest", "attempt": 1,
                        "pid": 4242, "exit_status": 0, "termination_reason": "cooperative-exit",
                        "forced_kill": False, "observed_before_cleanup": True,
                        "log_path": f"{role}-{control}-{direction}.log", "log_sha256": "0" * 64,
                        "direction": direction,
                    })
        for boundary in CRASH_BOUNDARIES:
            out.append({"name": f"android-prepare-{boundary}", "platform": "android", "role": "crash-prepare",
                        "variant": boundary, "attempt": 1, "pid": 5001, "exit_status": 1,
                        "termination_reason": "cooperative-exit", "forced_kill": False,
                        "observed_before_cleanup": True, "log_path": f"prepare-{boundary}.log",
                        "log_sha256": "1" * 64})
            out.append({"name": f"android-recover-{boundary}", "platform": "android", "role": "crash-recover",
                        "variant": boundary, "attempt": 1, "pid": 5002, "exit_status": 0,
                        "termination_reason": "cooperative-exit", "forced_kill": False,
                        "observed_before_cleanup": True, "log_path": f"recover-{boundary}.log",
                        "log_sha256": "2" * 64})
        return out

    def synthetic_crash_terms() -> list[dict]:
        return [{
            "boundary": boundary, "wrapper_pid": 5001, "wrapper_exit_status": 1,
            "wrapper_termination_reason": "cooperative-exit", "forced_kill": False,
            "observed_before_cleanup": True, "executor_pid": 6000 + i,
            "executor_abrupt_status": CRASH_EXECUTOR_ABRUPT_STATUS, "about_to_halt_seen": True,
            # *The declaration is BOUND: it names this stage and declares the very code the executor dies with.*
            "about_to_halt_boundary": boundary, "about_to_halt_code": CRASH_EXECUTOR_ABRUPT_STATUS,
            "log_path": f"prepare-{boundary}.log", "log_sha256": "3" * 64,
        } for i, boundary in enumerate(CRASH_BOUNDARIES)]

    def base_report(d: Path) -> dict:
        """A synthetic `all` report over the COPIED fixture transcript/manifest bytes."""
        for fname in ("transcript.bin", "manifest.json"):
            (d / fname).write_bytes((cross / fname).read_bytes())
        man = json.loads((cross / "manifest.json").read_text(encoding="utf-8"))
        rep = json.loads((cross / "integration-report.json").read_text(encoding="utf-8"))
        rep["mode"] = "all"
        # *** A COMPLETE all-mode BASE ALREADY CARRIETH BOTH FAMILIES -- DO NOT DOUBLE-APPEND ITS OWN ROWS. ***
        # *When the selector returned one all-mode fixture, `crash is cross`; concatenating would duplicate every
        # row. Only a cross-platform-ONLY base needeth the separate crash fixture's rows added.*
        if crash != cross:
            crash_rep = json.loads((crash / "integration-report.json").read_text(encoding="utf-8"))
            rep["results"] = list(rep["results"]) + list(crash_rep["results"])
        # *** AND THE FRESH-RUN PROOFS THE NEW CLAUSES JUDGE. ***
        rep["worker_terminations"] = synthetic_terminations()
        rep["crash_terminations"] = synthetic_crash_terms()
        identity = {"candidate_sha": "c" * 40, "candidate_tree": "b" * 40,
                    "whole_source_digest": "d" * 64}
        for _key, _value in identity.items():
            rep[_key] = _value
        rep["bundle_path"] = "ios/Packages/GodstoneFoundation/.build/debug/GodstoneMeshTests.xctest"
        rep["build_attestation"] = {
            # *** SCHEMA 2: the producer's shape -- recorded facts, NO agreement booleans. ***
            "schema_version": 2, "producer": "tools/readiness/build_provenance.py",
            "producer_attempt": rep.get("run_id") or "selftest-attempt", "mode": "macos",
            **identity, "source_digest": rep.get("input_digest", "0" * 64),
            "recipe_digest": st_recipe, "bundle_digest": "f" * 64,
            "library_name": st_register["library_name"],
            "library_sha256": st_expected["sha256"], "library_bytes": st_expected["bytes"],
            "library_path": f"/tmp/gs-selftest-{rep.get('run_id')}/libsqlcipher.0.dylib",
            "descriptor_sha256": "b" * 64,
            "descriptor_path": f"/tmp/gs-selftest-{rep.get('run_id')}/libsqlcipher.0.dylib.artifact.json",
            "pinned_source_commit": st_source["commit"], "pinned_source_tag": st_source["tag"],
            "pinned_source_repo": st_source["repo"], "pinned_platform": st_entry["platform"],
            "pinned_arch": st_entry["arch"],
            "pinned_cipher_version_major": st_register["cipher_version_major"],
            "approved_toolchain": st_entry["toolchain"],
            "expected_source_sha256": st_expectation_sha,
        }
        rep["build_attestation_verified"] = False
        rep["skip_build"] = False
        for row in rep["results"]:
            if isinstance(row, dict) and row.get("control") == "honest":
                row["boundary"] = "inbox commit + delivery tracker CAS (reopened estate)"
                row["cancellation_msg_id"] = "c0ffee" + row["direction"].replace("->", "")
                row["cancellation_state"] = "cancelledLocally"
        # Re-point the digest fields at the bytes now beside the report.
        blob = (d / "transcript.bin").read_bytes()
        rep["transcript"]["sha256"] = hashlib.sha256(blob).hexdigest()
        rep["transcript"]["length"] = len(blob)
        rep["manifest"]["sha256"] = sha256_file(d / "manifest.json")
        rep["manifest"]["record_count"] = man["record_count"]
        return rep

    def run_case(name: str, mutate, expect: str, *, check_inputs: bool = False,
                 check_fixture_collision: bool = False) -> None:
        nonlocal failures, total
        total += 1
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            report = base_report(d)
            mutate(report, d)
            (d / "integration-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            probs, _tot = check_report(d, check_inputs=check_inputs,
                                       check_fixture_collision=check_fixture_collision,
                                       fixtures_root=fixtures_root)
        got = "red" if probs else "green"
        verdict = "KILLED" if got == expect else "ESCAPED"
        if verdict == "ESCAPED":
            failures += 1
        results.append((name, expect, got, verdict))

    # *** CLAUSE-PINNED CASES: EACH FORGERY MUST BE REFUSED FOR ITS OWN REASON. ***
    #
    # *A whole-report `run_case` proveTH only that SOMETHING refused; these three helpers invoke ONE clause with a
    # base that is otherwise intact and demand the named problem text, so a mutation cannot pass for the wrong
    # reason and a clause cannot bite vacuously.*
    def _assert_case(name: str, expect: str, probs: list[str], needle: str = "") -> None:
        nonlocal failures, total
        total += 1
        if expect == "red":
            got = "red" if (any(needle in p for p in probs) if needle else bool(probs)) else "missed"
        else:
            got = "green" if (not probs or (needle and not any(needle in p for p in probs))) else "red"
        verdict = "KILLED" if got == expect else "ESCAPED"
        if verdict == "ESCAPED":
            failures += 1
        results.append((name, expect, got, verdict))

    def att_case(name: str, mutate, needle: str, *, recompute: bool = False) -> None:
        with tempfile.TemporaryDirectory() as td:
            report = base_report(Path(td))
        mutate(report, None)
        _assert_case(name, "red", check_build_attestation(report, recompute=recompute), needle)

    def crash_case(name: str, mutate, needle: str) -> None:
        term = synthetic_crash_terms()[0]
        mutate(term, None)
        _assert_case(name, "red", _crash_termination_problems("android-crash/selftest", term), needle)

    def halt_case(name: str, *, status: int, claimed: bool = True, marker: str = "",
                  expect: str, needle: str = "") -> None:
        term = {"name": "swift-honest", "platform": "ios", "role": "sender", "variant": "honest",
                "attempt": 1, "pid": 4242, "exit_status": status, "termination_reason": "cooperative-exit",
                "forced_kill": False, "observed_before_cleanup": True,
                "log_path": "swift-honest.log", "log_sha256": "0" * 64,
                "intentional_halt": claimed, "intentional_halt_marker": marker}
        probs = check_terminations({"mode": "cross-platform", "worker_terminations": [term]}, {})
        _assert_case(name, expect, probs, needle)

    # 0. the synthetic all-mode base, with the two clauses its AGE must trip neutralised, MUST be accepted.
    run_case("0. the intact all-mode report -- MUST be accepted", lambda r, d: None, "green")

    # 1. a required cross-platform row removed.
    def drop_row(r, d):
        r["results"] = [x for x in r["results"] if not (x["direction"] == "ios->android" and x["control"] == "replay")]
    run_case("1. a required cross-platform row removed", drop_row, "red")

    # 2. a required crash row removed.
    def drop_crash(r, d):
        r["results"] = [x for x in r["results"] if x["control"] != "inboundCommit"]
    run_case("2. a required crash row removed", drop_crash, "red")

    # 3. the transcript bytes swapped (digest no longer matches the file).
    def swap_bytes(r, d):
        (d / "transcript.bin").write_bytes((d / "transcript.bin").read_bytes() + b"\x00")
    run_case("3. transcript bytes appended (digest mismatch)", swap_bytes, "red")

    # 4. an honest row's outcome changed to ACCEPTED-with-a-refusal or REFUSED.
    def flip_honest(r, d):
        for x in r["results"]:
            if x["control"] == "honest":
                x["outcome"] = "REFUSED"
                x["refusal"] = "shouldNotBeRefused"
                break
    run_case("4. an honest row flipped to REFUSED", flip_honest, "red")

    # 5. a refused row made to claim a committed row (a fabricated green).
    def fabricate(r, d):
        for x in r["results"]:
            if x["control"] == "altered":
                x["durable_row"] = "present"
                break
    run_case("5. a refused row claims a committed durable row", fabricate, "red")

    # 6. a refused row with an EMPTY refusal reason.
    def empty_refusal(r, d):
        for x in r["results"]:
            if x["control"] == "mismatched":
                x["refusal"] = ""
                break
    run_case("6. a refused row with an empty refusal", empty_refusal, "red")

    # 7. the manifest's record_count made to disagree with the report's.
    def count_drift(r, d):
        man = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
        man["record_count"] = man["record_count"] + 1
        (d / "manifest.json").write_text(json.dumps(man, indent=2) + "\n", encoding="utf-8")
    run_case("7. manifest record_count disagrees with the report", count_drift, "red")

    # 8. *** THE COLLISION CLAUSE, JUDGED IN ISOLATION: a historical AUTHORED identity must be refused. ***
    # *The base report authors the SELECTED fixture's run_id, so the PURE predicate yields exactly the committed
    # identity problem -- no other clause can contribute, so a red here IS the collision clause biting.*
    def collision_case() -> list[str]:
        with tempfile.TemporaryDirectory() as td:
            rep = base_report(Path(td))
        return fixture_collision_problems(rep, fixtures_root)
    _assert_case("8. a historical authored run_id is refused by the collision identity predicate",
                 "red", collision_case(), "COMMITTED FIXTURE identity")

    # 8a. *** THE PURE PREDICATE YIELDS NO COLLISION FOR A CHANGED FRESH ID. *** *The base is the (old) fixture
    # report but the ID is synthetic-fresh, so the collision predicate must be SILENT -- proving the clause keys on
    # the AUTHORED id, NOT on the bytes. **This is asserted on the PURE predicate, so the report's known old-schema
    # defects CANNOT make this control red.***
    def collision_fresh_case() -> list[str]:
        with tempfile.TemporaryDirectory() as td:
            rep = base_report(Path(td))
        rep["run_id"] = "20990101T000000Z-ffffff"
        return fixture_collision_problems(rep, fixtures_root)
    _assert_case("8a. clause-control: a SYNTHETIC fresh run_id yieldeth NO collision problem (authored id)",
                 "green", collision_fresh_case(), "COMMITTED FIXTURE identity")

    # 8b. *** A RENAMED historical DIRECTORY still musters its AUTHORED id: the identity is the report's own
    # `run_id`, so a folder rename cannot evade the collision clause. ***
    def renamed_dir_case() -> list[str]:
        authored = json.loads((cross / "integration-report.json").read_text(encoding="utf-8")).get("run_id")
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "renamed-directory").mkdir()
            (root / "renamed-directory" / "integration-report.json").write_text(
                json.dumps({"run_id": authored}), encoding="utf-8")
            ids = _fixture_run_ids(root)
        return [] if authored in ids else [f"renamed directory lost its authored id {authored!r}"]
    _assert_case("8b. a renamed fixture directory still musters its authored run_id",
                 "green", renamed_dir_case(), "lost its authored id")

    # 8c. *** THE REQUIRED NEGATIVE: a GENUINE historical fixture copied BYTE-IDENTICALLY into a DIFFERENT fresh
    # directory must be refused, and the refusal must NAME the committed-fixture identity. *** *The copy carries the
    # historical authored `run_id` (id and bytes unmodified), so the collision clause must bite and the specific
    # "COMMITTED FIXTURE identity" problem must be present -- not merely some other refusal.*
    def bit_identical_copy_case() -> list[str]:
        with tempfile.TemporaryDirectory() as td:
            fresh = Path(td) / "freshly-copied-elsewhere"
            fresh.mkdir()
            for name in ("integration-report.json", "manifest.json", "transcript.bin", "producers.json"):
                (fresh / name).write_bytes((cross / name).read_bytes())  # byte-identical, id unmodified
            probs, _t = check_report(fresh, check_inputs=False, check_fixture_collision=True,
                                     check_fresh_run_proofs=False, fixtures_root=fixtures_root)
        return probs
    _assert_case("8c. a byte-identical historical fixture copied to a fresh directory is refused by identity",
                 "red", bit_identical_copy_case(), "COMMITTED FIXTURE identity")

    # 9. the input digest does not recompute from the report's own input_files (the input clause ON).
    def bad_digest(r, d):
        r["input_digest"] = "0" * 64
    run_case("9. input_digest does not recompute from input_files (input clause ON)",
             bad_digest, "red", check_inputs=True)

    # 10. an UNEXPECTED row added.
    def add_row(r, d):
        r["results"].append({"direction": "ios->android", "control": "invented", "outcome": "ACCEPTED",
                             "durable_row": "present", "delivery": "DELIVERED", "msg_id": "x", "refusal": None,
                             "boundary": "b"})
    run_case("10. an unexpected row added", add_row, "red")

    # 11. a crash row whose durable row is ABSENT (the recovery proved nothing).
    def crash_absent(r, d):
        for x in r["results"]:
            if x["control"] == "outboundEnqueue":
                x["durable_row"] = "absent"
                break
    run_case("11. a crash row with NO surviving durable row", crash_absent, "red")

    # 12. *** A CLAIMED INPUT THAT IS ABSENT IN BOTH THE REPORT AND THE TREE MUST BE REFUSED. *** *The coordinator
    #     writeth the literal `"absent"` for a missing file AND hasheth it, so claimed==live==`"absent"` re-hasheth
    #     identically and the drift check passeth it; the digest is RECOMPUTED here so ONLY the absent-input check can
    #     see it -- which is what makes this case the negative control for that guard rather than for the drift one.*
    def absent_input(r, d):
        r["input_files"]["does/not/exist.py"] = "absent"
        r["input_digest"] = recompute_input_digest(r["input_files"])
    run_case("12. a claimed input absent from the tree (hashes as \"absent\"==\"absent\")",
             absent_input, "red", check_inputs=True)

    # 13. *** A CRASH WHOSE PREPARE WAS NEVER OBSERVED TO DIE: `exit_status: None` (HUNG). *** *This is the exact
    #     shape the coordinator used to ACCEPT as an abrupt halt.*
    def hung_crash(r, d):
        r["crash_terminations"][0]["wrapper_exit_status"] = None
        r["crash_terminations"][0]["wrapper_termination_reason"] = "hung"
        for t in r["worker_terminations"]:
            if t["name"] == "android-prepare-outboundEnqueue":
                t["exit_status"] = None
                t["termination_reason"] = "hung"
    run_case("13. the crash prepare was HUNG (None accepted as a crash)", hung_crash, "red")

    # 14. *** A CRASH THE COORDINATOR'S OWN SIGKILL SUPPLIED. ***
    def coordinator_killed(r, d):
        r["crash_terminations"][0]["forced_kill"] = True
        r["crash_terminations"][0]["wrapper_termination_reason"] = "coordinator-sigkill"
    run_case("14. the crash prepare was killed by the coordinator (SIGKILL)", coordinator_killed, "red")

    # 15. *** THE EXECUTOR'S ABRUPT STATUS REMOVED: the wrapper rc alone is presented as the crash. ***
    def no_executor_status(r, d):
        r["crash_terminations"][0]["executor_abrupt_status"] = None
    run_case("15. the executor's abrupt 137 was never observed", no_executor_status, "red")

    # 16. *** THE CRASH PROOF BOUND TO NO PROCESS. ***
    def no_executor_pid(r, d):
        r["crash_terminations"][1]["executor_pid"] = None
    run_case("16. the crash executor PID is absent", no_executor_pid, "red")

    # 17. *** THE PRE-HALT STAGE MARKER REMOVED (no durable boundary binding). ***
    def no_stage_marker(r, d):
        r["crash_terminations"][1]["about_to_halt_seen"] = False
    run_case("17. the pre-halt stage marker is absent", no_stage_marker, "red")

    # 18. *** A CROSS-PLATFORM WITNESS THE COORDINATOR KILLED. ***
    def killed_witness(r, d):
        for t in r["worker_terminations"]:
            if t["role"] == "sender":
                t["forced_kill"] = True
                t["termination_reason"] = "coordinator-sigterm"
                break
    run_case("18. a cross-platform witness ended by the coordinator's SIGTERM", killed_witness, "red")

    # 19. *** THE CRASH TERMINATION MAP ENTIRELY ABSENT: a crash verdict not bound to any observed death. ***
    def no_crash_terms(r, d):
        r.pop("crash_terminations", None)
    run_case("19. the crash termination map is absent", no_crash_terms, "red")

    # 20. *** A CROSS-PLATFORM WITNESS THAT EXITED NON-ZERO (not 0, not a typed intentional halt). ***
    def witness_nonzero(r, d):
        for t in r["worker_terminations"]:
            if t["role"] == "recipient":
                t["exit_status"] = 1
                break
    run_case("20. a cross-platform witness exited non-zero", witness_nonzero, "red")

    # 21. *** A CROSS-PLATFORM REPORT WITH NO WITNESS TERMINATIONS AT ALL. ***
    def drop_witnesses(r, d):
        r["worker_terminations"] = [t for t in r["worker_terminations"]
                                    if t["role"] not in ("sender", "recipient")]
    run_case("21. no witness terminations recorded", drop_witnesses, "red")

    # 22. *** AN HONEST ROW WHOSE DURABLE CLAIM NAMES NO REOPENED ESTATE (read from the live store). ***
    def live_store_row(r, d):
        for x in r["results"]:
            if x.get("control") == "honest":
                x["boundary"] = "inbox commit + delivery tracker CAS"
                x["detail"] = "the recipient committed the exact msgId"
    run_case("22. an honest row was not re-read from a reopened estate", live_store_row, "red")

    # 23. *** AN HONEST ROW WITH NO CANCELLATION NEGATIVE. ***
    def no_cancel(r, d):
        for x in r["results"]:
            if x.get("control") == "honest":
                x["cancellation_msg_id"] = None
    run_case("23. an honest row carries no cancellation negative", no_cancel, "red")

    # 25. *** THE ATTESTATION'S LIBRARY DIGEST IS A FOREIGN VALUE, NOT THE REGISTER'S. ***
    #
    # *THE DEFECT THIS CLOSES IN THE SELFTEST ITSELF: the original case set `library_agrees_with_register=False`, a
    # SELF-CLAIM key -- so it was refused by the "self-claim field is present" rule and would have ESCAPED unchanged
    # if the REGISTER-truth comparison (`att["library_sha256"] != register`) were deleted. The mutation now forges the
    # pinned VALUE so the refusal can only come from the register comparison, pinned by its own message text.*
    att_case("25. the attestation's library digest is not the register's",
             lambda r, d: r["build_attestation"].__setitem__("library_sha256", "0" * 64),
             "library_sha256", recompute=False)

    # 26. *** A `--skip-build` RUN WITH NO VERIFIED ATTESTATION. ***
    def skip_unverified(r, d):
        r["skip_build"] = True
        r["build_attestation_verified"] = False
    run_case("26. skip-build without a verified attestation", skip_unverified, "red")

    # 27. *** THE ATTESTATION ENTIRELY ABSENT. ***
    def no_attestation(r, d):
        r.pop("build_attestation", None)
    run_case("27. no build attestation at all", no_attestation, "red")

    # 28. *** THE ATTESTATION'S PINNED SOURCE COMMIT IS NOT THE REGISTER'S. ***
    # *See case 25: the original mutated the self-claim boolean; this forges the VALUE the register owneth.*
    att_case("28. the pinned source commit is not the register's",
             lambda r, d: r["build_attestation"].__setitem__("pinned_source_commit", "f" * 40),
             "pinned_source_commit", recompute=False)

    # 28a-c. *** THE OTHER REGISTER-OWNED FIELDS, EACH FORGED IN TURN. *** *A register comparison that checked only
    # one field would let the others pass; these prove each is compared, pinned by its own key name.*
    att_case("28a. the approved toolchain is not the register's",
             lambda r, d: r["build_attestation"].__setitem__("approved_toolchain", "foreign-toolchain"),
             "approved_toolchain", recompute=False)
    att_case("28b. the pinned arch is not the register's",
             lambda r, d: r["build_attestation"].__setitem__("pinned_arch", "x86_64"),
             "pinned_arch", recompute=False)
    att_case("28c. the pinned library byte count is not the register's",
             lambda r, d: r["build_attestation"].__setitem__("library_bytes", 1),
             "library_bytes", recompute=False)

    # 29. *** A CROSS-PLATFORM WITNESS THAT CLAIMS A TYPED INTENTIONAL HALT BUT CARRIES NO MARKER TEXT. ***
    # *The coordinator accepteth a non-zero witness exit only when the RETAINED LOG quotes the marker line; a bare
    # `intentional_halt: true` is a claim, so the clause must refuse it -- pinned by the "does not NAME that status"
    # message rather than by "exited non-zero".*
    halt_case("29. a witness claims a typed halt with no marker text", status=97, claimed=True, marker="",
              expect="red", needle="does not NAME that status")
    # 29a. *** A WITNESS THAT EXITED NON-ZERO WITH NO HALT CLAIM AT ALL. ***
    halt_case("29a. a witness exited non-zero with no halt claim", status=1, claimed=False,
              expect="red", needle="neither 0 nor a verified typed intentional halt")
    # 29b. *** A REAL TYPED HALT: the marker quotes the very status the process returned -- ACCEPTED. ***
    #
    # *The positive half of the clause: a worker that ends by its own typed halt WITH the matching marker line is the
    # one accepted non-zero exit, so this case MUST come back green or the clause would refuse the honest shape it
    # existeth to admit.*
    halt_case("29b. a witness with a matching typed-halt marker is accepted", status=97, claimed=True,
              marker="GS_INTEGRATION_INTENTIONAL_HALT status=97", expect="green")

    # 30. *** A CRASH WHOSE EXECUTOR PID IS THE GRADLE WRAPPER'S OWN. ***
    # *`_crash_termination_problems` already refuseth it, but no case pinned it: the wrapper observably exiteth
    # cooperatively, so a pid EQUAL to the wrapper's is the parent, not the forked executor that died abruptly.*
    crash_case("30. the crash 'executor' pid equals the wrapper pid",
               lambda t, d: t.__setitem__("executor_pid", t["wrapper_pid"]),
               "EQUALS the wrapper pid")
    # 30a. *** THE EXECUTOR PID IS THE ROBOLECTRIC SHADOW CONSTANT. ***
    crash_case("30a. the crash executor pid is the Robolectric shadow",
               lambda t, d: t.__setitem__("executor_pid", ROBOLECTRIC_SHADOW_PID),
               "not a real OS pid")
    # 30b. *** THE PRE-HALT DECLARATION NAMES A DIFFERENT STAGE. ***
    crash_case("30b. the pre-halt declaration names another stage",
               lambda t, d: t.__setitem__("about_to_halt_boundary", "someOtherBoundary"),
               "names boundary")
    # 30c. *** THE PRE-HALT DECLARATION DOES NOT DECLARE THE OBSERVED HALT CODE. ***
    crash_case("30c. the pre-halt declaration does not declare the halt code",
               lambda t, d: t.__setitem__("about_to_halt_code", 0),
               "declare the halt code")

    width = max(len(c[0]) for c in results)
    print("\n== integration-evidence selftest: mutation | expected | observed | verdict ==")
    for name, expect, got, verdict in results:
        print(f"   {name:<{width}}  {expect:6s} {got:6s} {verdict}")
    print(f"\nintegration-evidence selftest: {total - failures}/{total} mutations caught")
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Judge the Board1 integration evidence by content")
    ap.add_argument("--report", help="the evidence directory (carrying integration-report.json) or the json path")
    ap.add_argument("--require-mode", choices=("all", "crash", "cross-platform"),
                    help="require the report's mode to be exactly this (the terminal job useth `all`)")
    # *** THE TWO PUBLIC ESCAPES ARE GONE: THE CLI ALWAYS BINDS INPUTS AND ALWAYS CHECKS THE FIXTURE NAMESPACE. ***
    #
    # *`--no-input-check` / `--no-fixture-collision-check` were a caller-controlled path around the live-tree
    # binding and the fresh-vs-copied authority -- the exact "a required control omitted by configuration" class this
    # programme refuses, and NOTHING invoked them. The only legitimate uses of the weaker modes are INTERNAL: the
    # `--skip-build` prior-BUILD record binding (`run_board1_integration.py`, where the copied-fixture namespace is
    # irrelevant to a record/digest-equality judgement) and the out-of-tree static fixture courts
    # (`tests/test_integration_evidence.py`). **Those stay as keyword arguments with defaults ON; no caller of the
    # FRESH pipeline may pass False, and the CLI cannot.**
    ap.add_argument("--fixtures-root", default=None,
                    help="the root holding the committed integration fixtures (the collision namespace and the "
                         "selftest base); absolute or repository-relative. Defaults to the "
                         f"`{FIXTURES_ROOT_ENV}` environment variable, then the in-checkout "
                         f"`{FIXTURES_ROOT.relative_to(REPO)}`. A standalone replay passeth the DOWNLOADED root so "
                         "the collision check and the selftest judge the bytes it was handed; a supplied root that "
                         "is absent REFUSES BY NAME.")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest(args.fixtures_root)
    if not args.report:
        ap.error("--report is required (or pass --selftest)")

    d = resolve_report_dir(args.report)
    problems, totals = check_report(d, require_mode=args.require_mode,
                                    fixtures_root=args.fixtures_root)
    if args.json:
        print(json.dumps({"report": str(d), "problems": problems, "totals": totals}, indent=2))
    else:
        print(f"INTEGRATION EVIDENCE ({d}): rows={totals['rows']} cross={totals['cross']} crash={totals['crash']}")
        if problems:
            print("\nFAIL:")
            for p in problems:
                print("  - " + p)
        else:
            print("\nintegration evidence: PASSED (required population present, arms exact, digests and inputs bound)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
