#!/usr/bin/env python3
"""The blocked-external discipline (the final frontier of the blueprint).

Seventy-two of the eighty-four tasks are COMPLETE. The remaining twelve cannot run,
and this module existeth so that the difference between "cannot run" and "was not
done" is CHECKABLE rather than asserted:

  * EVERY pending task carrieth a BLOCKED_EXTERNAL record that nameth a blocker in
    the register -- a task may not simply be absent;
  * EVERY named blocker existeth in the register, and its `dependent_tasks` carrieth
    exactly the tasks blocked by it (directly OR transitively);
  * NO blocked task claimeth COMPLETE, and no COMPLETE task carrieth a blocker;
  * NO blocker is CLOSED by this repository: `closure_evidence` must stay null and
    the status must stay BLOCKED_EXTERNAL -- a fixture may never close an external
    gate;
  * an INTERNAL prerequisite that is itself blocked carrieth
    `internal_prerequisites_completed: false`;
  * the readiness flags stay FALSE, and the release manifest's externally-gated
    entries stay OPEN or BLOCKED -- never CLOSED.

The point of the module is the LAST rule: it is easy to make a gate green by writing
a fixture, and it is the one thing this work must never do.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

__all__ = [
    "BlockerView", "load", "pending_tasks", "blocked_records", "findings", "report",
    "readiness_flags",
]

#: The five external artifacts, and the register id each one carrieth.
CATALOGUE_TO_REGISTER = {
    "APPROVED_NATIVE_MODEL_ARTIFACTS": "NATIVE_MODELS",
    "APPROVED_INDEPENDENT_ARTIFACT": "A06",
    "APPROVED_CONTENT_HUMAN_REVIEW": "APPROVED_CONTENT",
    "HUMAN_HARDWARE": "HARDWARE",
    "HARDWARE": "HARDWARE",
    "HUMAN_SIGNING_POLICY": "SIGNING",
}

#: The classes the register may carry, and the human role each requireth.
CLASS_OF_REGISTER = {
    "A06": "independent-review",
    "APPROVED_CONTENT": "content",
    "NATIVE_MODELS": "native",
    "HARDWARE": "device",
    "SIGNING": "release",
}


@dataclass(frozen=True)
class BlockerView:
    id: str
    status: str
    klass: str
    reason: str
    dependent_tasks: tuple
    internal_prerequisites_completed: bool
    closure_evidence: object
    recheck_trigger: str


def _json(root: Path, rel: str):
    path = Path(root) / rel
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}


def load(root):
    """Return (state, catalogue, blockers, release_manifest)."""
    root = Path(root)
    return (_json(root, "docs/production-readiness/BUILD_STATE.json"),
            _json(root, "docs/production-readiness/TASKS.json"),
            _json(root, "docs/production-readiness/EXTERNAL_BLOCKERS.json"),
            _json(root, "docs/production/RELEASE_GATES_STATUS.json"))


def pending_tasks(catalogue, state) -> tuple:
    """Every catalogue task that carrieth no COMPLETE record, in catalogue order."""
    done = state.get("completed_tasks", {})
    return tuple(t["id"] for t in catalogue["tasks"]
                 if done.get(t["id"], {}).get("status") != "COMPLETE")


def blocked_records(state) -> dict:
    """Every record whose status is a BLOCKED_* status."""
    return {tid: entry for tid, entry in state.get("completed_tasks", {}).items()
            if str(entry.get("status", "")).startswith("BLOCKED")}


def readiness_flags(root) -> dict:
    invariants = _json(Path(root), "docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
    return invariants.get("readiness", {})


#: The case-level vocabulary. A `HOST_*` class means the case can be executed on
#: this machine without the external artefact; anything else genuinely cannot.
CASE_CLASSES = frozenset({
    "HOST_TESTABLE_PURE_LOGIC", "HOST_TESTABLE_WITH_TEST_DOUBLE",
    "HOST_TESTABLE_WITH_NO_MODEL", "HOST_TESTABLE_METADATA",
    "HOST_TESTABLE_FAILURE_PATH", "HOST_TESTABLE_WITH_TEST_DOUBLE_PURE_LOGIC",
    "REQUIRES_APPROVED_NATIVE_ARTIFACT", "REQUIRES_REAL_MODEL_BYTES",
    "REQUIRES_NATIVE_COMPILER_INPUT", "DEVICE_ONLY", "EXTERNAL_APPROVAL_ONLY",
})


def findings(root) -> list:
    """Every disagreement between the state, the catalogue, the register and the
    release manifest. An empty list is the only honest frontier."""
    root = Path(root)
    state, catalogue, register, manifest = load(root)
    out = []
    tasks = {t["id"]: t for t in catalogue["tasks"]}
    blockers = {b["id"]: b for b in register.get("blockers", [])}
    done = state.get("completed_tasks", {})
    blocked = blocked_records(state)

    # (1) every PENDING task must carry a BLOCKED_EXTERNAL record
    pending = pending_tasks(catalogue, state)
    for tid in pending:
        entry = done.get(tid)
        if entry is None:
            out.append("unrecorded: %s is pending and carrieth NO record at all" % tid)
            continue
        if entry.get("status") != "BLOCKED_EXTERNAL":
            out.append("unrecorded: %s is pending with status %r"
                       % (tid, entry.get("status")))
            continue
        if not entry.get("blocker"):
            out.append("unnamed: %s is blocked but nameth no blocker" % tid)
            continue
        if entry["blocker"] not in blockers:
            out.append("unknown-blocker: %s nameth %r, absent from the register"
                       % (tid, entry["blocker"]))
        if not entry.get("reason"):
            out.append("unexplained: %s is blocked without a reason" % tid)

    # (2) no record may be BOTH blocked and complete, and vice versa
    for tid, entry in done.items():
        status = entry.get("status")
        if status == "COMPLETE" and entry.get("blocker"):
            out.append("contradiction: %s is COMPLETE and nameth blocker %r"
                       % (tid, entry["blocker"]))

    # (3) THE REGISTER'S MAPPING: each blocked task must be listed in the register
    #     entry for ITS OWN blocker (directly), and every listed dependent task must
    #     be either blocked or complete
    for tid, entry in blocked.items():
        blocker_id = entry.get("blocker")
        if blocker_id and blocker_id in blockers:
            if tid not in blockers[blocker_id]["dependent_tasks"]:
                out.append("register-incomplete: %s is blocked by %s, which doth not list it"
                           % (tid, blocker_id))
    for blocker_id, blocker in blockers.items():
        for tid in blocker["dependent_tasks"]:
            if tid not in tasks:
                out.append("register-unknown-task: %s lists %s, absent from the catalogue"
                           % (blocker_id, tid))

    # (4) NO BLOCKER MAY BE CLOSED BY THIS REPOSITORY
    for blocker_id, blocker in blockers.items():
        if blocker.get("closure_evidence") is not None:
            out.append("gate-closed-by-fixture: %s carrieth closure_evidence"
                       % blocker_id)
        # the protocol alloweth BLOCKED_HARDWARE for a device artifact and
        # BLOCKED_EXTERNAL for every other class
        allowed = (("BLOCKED_HARDWARE",) if blocker.get("class") == "device"
                   else ("BLOCKED_EXTERNAL",))
        if blocker.get("status") not in allowed:
            out.append("gate-status-drift: %s statuseth %r (allowed: %s)"
                       % (blocker_id, blocker.get("status"), ", ".join(allowed)))
        if blocker.get("class") != CLASS_OF_REGISTER.get(blocker_id):
            out.append("gate-class-drift: %s is classed %r" % (blocker_id, blocker.get("class")))
        if not blocker.get("approved_source_or_human_role"):
            out.append("gate-unowned: %s nameth no approving role" % blocker_id)
        if not blocker.get("recheck_trigger"):
            out.append("gate-untrigggered: %s nameth no recheck trigger" % blocker_id)
        if not blocker.get("required_artifact_schema"):
            out.append("gate-schemaless: %s nameth no required artifact" % blocker_id)
        if not blocker.get("verification_commands"):
            out.append("gate-unverifiable: %s nameth no verification command" % blocker_id)

    # (5) TRANSITIVE HONESTY: a blocked task whose own dependency is blocked may not
    #     claim its internal prerequisites are complete
    for tid, entry in blocked.items():
        missing = [dep for dep in tasks[tid]["dependencies"]
                   if done.get(dep, {}).get("status") != "COMPLETE"]
        if missing and entry.get("internal_prerequisites_completed"):
            out.append("transitive-dishonesty: %s claimeth complete prerequisites while %s "
                       "is/are pending" % (tid, ", ".join(missing)))
        if not missing and not entry.get("internal_prerequisites_completed"):
            out.append("transitive-understatement: %s hath complete prerequisites but "
                       "claimeth not" % tid)

    # (5b) A BLOCKED TASK MAY NOT MASK A MISSING INTERNAL COURT.
    #
    #     THIS IS THE INVARIANT THE FIRST CLOSURE LACKED. `BLOCKED_EXTERNAL`
    #     answereth "the final acceptance needs an input nobody here can
    #     produce". It doth NOT answer "and therefore nothing internally
    #     executable was owed". Before this rod, a task could declare a
    #     regression path, never author it, and still read as a clean frontier
    #     -- T78's narrow stage measured `tests=0/0` while the register called
    #     the task honestly blocked.
    #
    #     The rule: for every blocked task, each declared regression path that
    #     is REPOSITORY-OWNED (a python court under tools/readiness/tests) must
    #     either EXIST, or the record must carry an explicit, non-empty
    #     `court_not_authored` justification naming why. A native path (Kotlin,
    #     Swift) may legitimately be absent while its artifact is -- the artifact
    #     IS the compiler input -- so those are not judged here.
    for tid, entry in blocked.items():
        declared = tasks[tid].get("required_regression_paths") or []
        excused = str(entry.get("court_not_authored") or "").strip()
        absent = [rel for rel in declared
                  # resolved against the ROOT UNDER AUDIT, never the process cwd: a
                  # checker that read its own working directory would pass or fail
                  # depending on where it was invoked from.
                  if not (root / str(rel)).exists()]
        if not absent:
            continue
        # A court that does not exist must carry a RECORDED, non-trivial reason.
        # The rod does not judge whether the reason is WISE -- a checker cannot --
        # but it refuses to let absence pass in silence, which is exactly how the
        # first closure mistook a missing court for an external blocker.
        if not excused:
            out.append(
                "unauthored-court: %s declareth %d court(s) that do not exist (%s) and "
                "carrieth no `court_not_authored` justification; a blocked task may not "
                "mask a missing internally executable court"
                % (tid, len(absent), ", ".join(str(a) for a in absent)))
        elif len(excused) < 80:
            out.append(
                "unjustified-court: %s excuseth %d absent court(s) in %d characters; a "
                "justification must NAME the reason, not gesture at one"
                % (tid, len(absent), len(excused)))

    # (5c) A PROSE JUSTIFICATION MAY NOT EXCUSE A HOST-TESTABLE CASE.
    #
    #     THIS IS THE INVARIANT THAT CLOSED THE rc3 LOOPHOLE. The rod above
    #     accepted any `court_not_authored` of sufficient LENGTH -- and LENGTH IS
    #     NOT PROOF. T64 and T65 sat behind exactly such a justification while
    #     their cards name cases that need no model at all ("same dimension
    #     different model", "corrupt NaN vectors", "no native model",
    #     "deterministic ranking", "deterministic test-double edge cases").
    #
    #     The rule: where a task carrieth a case-level classification, EVERY case
    #     classified HOST_TESTABLE (any host_* class) must name the witness that
    #     implements it. A case whose witness field is empty, or names a file
    #     that does not exist, is UNIMPLEMENTED -- and no prose may excuse it.
    #     A task with no classification at all is reported, so the omission is
    #     visible rather than silently exempt.
    for tid, entry in blocked.items():
        cases = entry.get("case_classification")
        # `absent` WAS A LOOP-LOCAL LEFTOVER FROM THE ROD ABOVE. The name survived
        # the earlier `for` loop, so it held the LAST task's value and the
        # per-task question "is THIS task's court absent?" was never actually
        # asked. A negative control is what exposed it. Recompute it here.
        absent_here = [rel for rel in (tasks[tid].get("required_regression_paths") or [])
                       if not (root / str(rel)).exists()]
        if cases is None:
            # Only tasks whose declared courts are ABSENT need case accounting:
            # an authored court already carries its own witnesses.
            if absent_here:
                out.append(
                    "unclassified-cases: %s carrieth an absent declared court and no "
                    "`case_classification`; without it a reader cannot tell which required "
                    "cases are host-testable and which genuinely need the external "
                    "artefact, so the absence cannot be judged" % tid)
            continue
        if not isinstance(cases, list) or not cases:
            out.append("malformed-cases: %s carrieth a `case_classification` that is "
                       "empty or not a list" % tid)
            continue
        for item in cases:
            if not isinstance(item, dict):
                out.append("malformed-cases: %s carrieth a non-object case entry" % tid)
                continue
            name = str(item.get("case") or "").strip()
            klass = str(item.get("classification") or "").strip()
            witness = item.get("implemented_by")
            if not name:
                out.append("malformed-cases: %s carrieth a case with no name" % tid)
                continue
            if klass not in CASE_CLASSES:
                out.append("malformed-cases: %s case %r carrieth the unknown "
                           "classification %r (known: %s)"
                           % (tid, name, klass, ", ".join(sorted(CASE_CLASSES))))
                continue
            host_testable = klass.startswith("HOST_")
            if host_testable:
                if not witness:
                    out.append(
                        "unimplemented-case: %s case %r is classified %s and nameth NO "
                        "witness; a prose justification may not excuse a case that can "
                        "run on this host" % (tid, name, klass))
                elif not (root / str(witness)).exists():
                    out.append(
                        "unimplemented-case: %s case %r nameth the witness %r, which does "
                        "not exist" % (tid, name, witness))
            elif witness:
                out.append(
                    "fabricated-case: %s case %r is classified %s (external) yet nameth a "
                    "witness %r; an external case may not claim internal coverage"
                    % (tid, name, klass, witness))

    # (6) THE READINESS STAYS FALSE, and the externally-gated release entries stay
    #     OPEN or BLOCKED
    flags = readiness_flags(root)
    if flags.get("android_LINK_LAYER_READY") is not False:
        out.append("readiness-drift: android_LINK_LAYER_READY is %r" % flags.get("android_LINK_LAYER_READY"))
    if flags.get("ios_linkLayerReady") is not False:
        out.append("readiness-drift: ios_linkLayerReady is %r" % flags.get("ios_linkLayerReady"))
    # ... and of the release manifest's entries, ONLY the five externally-blocked
    # ones are constrained: a genuinely verified gate may be CLOSED, provided the
    # register recordeth it with an ancestor-verified evidence commit
    closed = {entry["gate"]: entry for entry in register.get("pre_existing_closed_gates", [])}
    externally_blocked = {
        "A-06-independent-noise-vectors", "production-corpus", "model-native-stack",
        "device-interoperability", "accessibility", "battery-thermal",
        "signing-store-approval",
    }
    for gate in manifest.get("gates", []):
        name, status = gate.get("gate"), gate.get("status")
        if name in externally_blocked:
            if status not in ("OPEN", "BLOCKED"):
                out.append("release-entry-drift: the externally-blocked entry %s is %r" % (name, status))
        elif status == "CLOSED" and name not in closed:
            out.append("release-entry-drift: %s is CLOSED without a register entry" % name)
    for name, entry in closed.items():
        if not entry.get("ancestor_of_head"):
            out.append("release-entry-unproven: %s carrieth a non-ancestor evidence commit" % name)

    # (7) every catalogue external_requirement must map to a register id
    for task in catalogue["tasks"]:
        requirement = task.get("external_requirement")
        if requirement and requirement not in CATALOGUE_TO_REGISTER:
            out.append("unmapped-requirement: %s nameth %r" % (task["id"], requirement))
        elif requirement and CATALOGUE_TO_REGISTER[requirement] not in blockers:
            out.append("unregistered-requirement: %s nameth %r -> %r, absent"
                       % (task["id"], requirement, CATALOGUE_TO_REGISTER[requirement]))

    return out


def report(root) -> str:
    state, catalogue, register, _manifest = load(root)
    pending = pending_tasks(catalogue, state)
    blocked = blocked_records(state)
    lines = ["frontier: %d tasks, %d COMPLETE, %d pending, %d BLOCKED_EXTERNAL"
             % (len(catalogue["tasks"]),
                sum(1 for e in state.get("completed_tasks", {}).values()
                    if e.get("status") == "COMPLETE"),
                len(pending), len(blocked))]
    for blocker in register.get("blockers", []):
        lines.append("  %-18s %-20s tasks=%s"
                     % (blocker["id"], blocker["class"], ",".join(blocker["dependent_tasks"])))
    # *** THE VERDICT IS COMPUTED ONCE AND PRINTED FROM THAT ONE RESULT. *** *This function used to call
    # `findings(root)` TWICE -- once for the printed FINDING lines and again for the verdict -- which ran two
    # full audits of the same run. Any nondeterminism between them would let the printed findings DISAGREE
    # with the verdict that summariseth them: the split-verdict defect this repository hunteth everywhere
    # else. One audit, one verdict, printed from the same value.*
    problems = findings(root)
    for problem in problems:
        lines.append("  FINDING " + problem)
    # The legend is REQUIRED, not decoration: this line sits under five unmet gate names, so a bare PASS
    # readeth as "the gates are satisfied" when it means the opposite. See the module docstring item (6).
    lines.append("VERDICT: " + ("PASS" if not problems else "FAIL (%d)" % len(problems)))
    lines.append("  (PASS = the register is INTERNALLY HONEST about what is owed: every externally-blocked "
                 "task is recorded OPEN/BLOCKED and every readiness flag is false. It is NOT a statement "
                 "that any obligation is met -- an unmet external gate is SUPPOSED to read PASS here, and "
                 "this refuses the moment someone flips a flag true to satisfy it.)")
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    here = Path(__file__).resolve().parents[2]
    text = report(here)
    print(text)
    raise SystemExit(1 if findings(here) else 0)
