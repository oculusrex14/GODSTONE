#!/usr/bin/env python3
"""The mutation-controls ledger of this repository, reformed per master blueprint section 21.

Two lineages, kept apart on the page and in the tally:

  STRUCTURAL  text-scan controls of Invariant G (the legacy registry below).
              Their oracle is ci/integration.check: a finding must appear or
              the control is not doing its work. These are name/shape/gate
              checks. They are not semantics, are never reported as such, and
              are recorded with category="structural".

  SEMANTIC    meaning-breaking mutations of the production files, each run in
              a DISPOSABLE worktree at a pinned head - the live tree is never
              touched - with a BEHAVIORAL oracle: the named witness cases of
              the readiness suites. Honesty rules, per section 21:

                KILLED    the baseline passed unmutated, the mutation applied
                          exactly (anchor seen once), the mutant compiled, and
                          the intended witness assertion failed.
                INVALID the mutant did not compile - or the baseline itself
                          did not pass. Never counted as a catch.
                SKIPPED the anchor was not seen exactly once - the needle moved
                          on. Recorded, and NEVER counted as a catch. (This is
                          the reform's central honesty fix: the old ledger let
                          a missing anchor fall through to the caught tally.)
                TIMEOUT the harness did not settle inside the bound.
                ESCAPED the mutant compiled and the witness stayed green - a
                          real finding: strengthen the witness or revert the
                          production change that let it live.

    python3 ci/mutations.py                 # structural lineage (fast, default)
    python3 ci/mutations.py --semantic      # semantic lineage (runs harnesses)
    python3 ci/mutations.py --all           # both, reported separately
    python3 ci/mutations.py --report        # do not fail on findings
    python3 ci/mutations.py --emit-dir DIR  # write logs/ beside the manifest
    python3 ci/mutations.py --baseline SHA  # pin the audited head for a run

No aggregate is ever printed as a single killed percentage. The two lineages
are never summed. Every result row carries the section 21 schema fields
verbatim: id, baseline_sha, mutant_patch_sha, category, anchor_count,
build_exit, target_tests, tests_run, outcome, failed_assertion, log_sha.

A control that has never been observed failing is not a control.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCHEMA_FIELDS = ("id", "baseline_sha", "mutant_patch_sha", "category",
                 "anchor_count", "build_exit", "target_tests", "tests_run",
                 "outcome", "failed_assertion", "log_sha")


def _load_checker():
    spec = importlib.util.spec_from_file_location("integ", os.path.join(ROOT, "ci", "integration.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.check


def _sha_text(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _sha_file(path):
    if not path or not os.path.exists(path):
        return None
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def _now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _row(entry, baseline_sha, category, anchor_count, build_exit, target_tests,
         tests_run, outcome, failed_assertion, log_path):
    return {"id": entry["id"], "baseline_sha": baseline_sha,
            "mutant_patch_sha": entry["patch_sha"], "category": category,
            "anchor_count": anchor_count, "build_exit": build_exit,
            "target_tests": list(target_tests), "tests_run": tests_run,
            "outcome": outcome, "failed_assertion": failed_assertion,
            "log_sha": _sha_file(log_path), "log_path": log_path,
            "started_utc": entry.get("started_utc"), "ended_utc": entry.get("ended_utc")}


# --------------------------------------------------------------------------
# The structural lineage: the legacy Invariant G registry. The oracle is the
# text checker; these controls are shape gates and stay recorded as such.
# --------------------------------------------------------------------------
# (id, file, find, replace, invariant, why, expect_escape)
#
# expect_escape=True marks a KNOWN CEILING of text-based analysis, not a bug
# to be tuned away. M2 keeps SealedSender.seal( textually present inside a
# dead if (false) branch. A regex can tell a MENTION from a CALL; it cannot
# tell a LIVE call from a DEAD one, because that is reachability analysis and
# it needs a compiler or a call graph. It is recorded as the boundary, and
# closing it is a stated reason ./gradlew build is the real exit gate.
G_STRUCTURAL = [
    ("M1-gate-comment-only",
     "android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt",
     "val verdict = io.godstone.llm.safety.SafetyGate.evaluate(query, fused, corpusIndex)",
     "val verdict: io.godstone.llm.safety.SafetyGate.Result? = null  // SafetyGate.evaluate",
     "G4",
     "the call becomes a comment; V3 passed on exactly this", False),

    ("M2-sealed-sender-orphan",
     "android/mesh/src/main/java/io/godstone/mesh/router/Router.kt",
     "val sealed = io.godstone.mesh.seal.SealedSender.seal(",
     "val sealed = ByteArray(0); if (false) io.godstone.mesh.seal.SealedSender.seal(",
     "G7",
     "call kept alive textually inside if (false) -- CEILING, needs a compiler", True),

    ("M3-handshake-removed",
     "android/mesh/src/main/java/io/godstone/mesh/crypto/SessionManager.kt",
     # re-anchored at the T20 reform: the T-era registry had been silently
     # counting this entry while its anchor had drifted (the function's
     # return type moved on to ByteArray?). The old ledger called that
     # "caught"; the reform's SKIPPED verdict is what honesty looks like.
     "fun beginInitiator(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =",
     "// fun beginInitiator REMOVED\n    private fun _unused_beginInitiator(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =",
     "G3",
     "sessions.seal survives; nothing can establish a session", False),

    ("M4-wrong-sqlcipher-package",
     "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt",
     "import net.zetetic.database.sqlcipher.SQLiteDatabase",
     "import net.sqlcipher.database.SQLiteDatabase",
     "G8",
     "legacy package contains the substring V3 checked for", False),

    ("M5-codec-orphaned",
     "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
     'val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID',
     'val SERVICE_UUID: UUID = UUID.fromString("67640001-1000-8000-00805f9b34fb")',
     "G2",
     "generated codec still present, runtime uses a legacy literal", False),

    ("M6-idf-formula-drift",
     "ios/Godstone/Sources/GodstoneCore/SafetyGate.swift",
     "idf[t] = log((Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0)",
     "idf[t] = log(Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0",
     "G6",
     "the real iOS defect: constants agree, the equation does not", False),
]


def run_structural(report_only, emit_dir, baseline_sha):
    check = _load_checker()
    root_path = pathlib.Path(ROOT)
    baseline = check(root_path)
    rows = []
    tally = {k: 0 for k in ("KILLED", "SKIPPED", "ESCAPED", "INVALID", "TIMEOUT")}
    print("STRUCTURAL lineage (oracle: ci/integration.check text scan; "
          "these are shape gates, not semantics)")
    for mid, rel, find, repl, inv, why, expect_escape in G_STRUCTURAL:
        entry = {"id": mid, "patch_sha": _sha_text(find + "\n==\n" + repl)}
        target = os.path.join(ROOT, rel)
        if not os.path.exists(target):
            tally["SKIPPED"] += 1
            rows.append(_row(entry, baseline_sha, "structural", 0, None, [inv], None,
                            "SKIPPED", "file absent: " + rel, None))
            print("  SKIPPED %s: %s absent -- not counted as a catch" % (mid, rel))
            continue
        original = open(target, encoding="utf-8").read()
        anchor_count = original.count(find)
        if anchor_count != 1:
            tally["SKIPPED"] += 1
            rows.append(_row(entry, baseline_sha, "structural", anchor_count, None,
                            [inv], None, "SKIPPED", "anchor count %d != 1" % anchor_count, None))
            print("  SKIPPED %s: anchor seen %d times -- not counted as a catch"
                  % (mid, anchor_count))
            continue
        log_bytes = []
        caught = False
        try:
            open(target, "w", encoding="utf-8").write(original.replace(find, repl, 1))
            found = check(root_path)
            new = [f for f in found if f not in baseline]
            log_bytes.append(("new findings: " + json.dumps(new) + "\n").encode("utf-8"))
            caught = any(f.startswith(inv) for f in new)
        finally:
            open(target, "w", encoding="utf-8").write(original)
            back = open(target, encoding="utf-8").read()
            assert back == original, "restoration of " + rel + " failed; halt"
        if caught:
            outcome = "KILLED"
            status = "CLOSED " if expect_escape else "caught "
        elif expect_escape:
            outcome = "ESCAPED"
            status = "ceiling"
        else:
            outcome = "ESCAPED"
            status = "ESCAPED"
        tally[outcome] += 1
        log_path = None
        if emit_dir:
            log_path = os.path.join(emit_dir, "logs", mid + ".structural.log")
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
            open(log_path, "wb").write(b"".join(log_bytes))
        rows.append(_row(entry, baseline_sha, "structural", anchor_count, None, [inv], None,
                        outcome, None if caught else "the text checker stayed silent", log_path))
        print("  %s %-28s [%s] %s" % (status, mid, inv, why))
    print("  per outcome: " + ", ".join("%s=%d" % (k, tally[k]) for k in
          ("KILLED", "SKIPPED", "ESCAPED", "INVALID", "TIMEOUT")))
    escapes = [r["id"] for r in rows if r["outcome"] == "ESCAPED"
               and not any(r["id"] == m[0] and m[6] for m in G_STRUCTURAL)]
    if escapes:
        print("  :: the text checker missed: " + ", ".join(escapes) +
              " -- this is why ./gradlew build is the exit gate, not this script.")
    bad = [r["id"] for r in rows if r["outcome"] in ("SKIPPED", "INVALID", "TIMEOUT")] + escapes
    if bad and not report_only:
        print("::error::structural controls regressed: " + ", ".join(bad), file=sys.stderr)
        return 1
    return 0


# --------------------------------------------------------------------------
# The semantic lineage. Every mutation runs in a DISPOSABLE worktree at a
# pinned head; the oracle is the named witness case of the readiness suites.
# --------------------------------------------------------------------------
SEMANTIC = [
    {
        "id": "T20-SM1-android-token-bypass",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
        "find": "        if (client.clientToken != clientToken || client.gattGeneration != gattGen) {",
        "replace": "        if (false && (client.clientToken != clientToken || client.gattGeneration != gattGen)) {",
        "why": "the token validation of the central's disconnect arm is short-circuited: a stale event falls where a fresh one belonged, with every symbol and test present",
        "witness": "testTheCrossedTraceFromAForeignManagerIsRefusedAndTheWrongTokenDiscarded",
        "gradle_filter": "*ReadinessT20Test*",
    },
    {
        "id": "T20-SM2-android-advance-forever",
        "platform": "jvm",
        "file": "android/mesh/src/main/java/io/godstone/mesh/transport/BleRecord.kt",
        "find": "nowSec >= asm.lease.deadlineMono",
        "replace": "nowSec >= asm.lastActivityTimeSec + AssemblyLease.LEASE_SECONDS",
        "why": "the absolute term rides the refreshed activity stamp: a dribbling peer advances the deadline forever and the relation never falls through its owner",
        "witness": "testTheAbsoluteTermExpiresTheDribbledAssemblyThoughTheSlidingWindowIsRefreshed",
        "gradle_filter": "*ReadinessT20Test*",
    },
    {
        "id": "T20-SM3-ios-epoch-bypass",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": "        guard sourceEpoch == context.epoch, context.epoch == currentTransportEpoch else { return false }",
        "replace": "        guard true, context.epoch == currentTransportEpoch else { return false }",
        "why": "the epoch revalidation of the threefold authenticator is short-circuited: a misrepresented epoch is admitted, with every symbol and test present",
        "witness": "GodstoneMeshTests.ReadinessT20Tests/testTheCrossedTraceFromAForeignManagerIsRefusedAndTheWrongTokenDiscarded",
    },
    {
        "id": "T20-SM4-ios-sender-bypass",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift",
        "find": "        guard sender === expectedManager else { return false }",
        "replace": "        guard true || sender === expectedManager else { return false }",
        "why": "the source-instance identity of the threefold authenticator is short-circuited: a foreign manager speaks, with every symbol and test present",
        "witness": "GodstoneMeshTests.ReadinessT20Tests/testTheCrossedTraceFromAForeignManagerIsRefusedAndTheWrongTokenDiscarded",
    },
    {
        "id": "T20-SM5-ios-advance-forever",
        "platform": "swift",
        "file": "ios/Godstone/Sources/GodstoneMesh/BleRecord.swift",
        "find": "            if now >= asm.lease.deadlineMono {",
        "replace": "            if now >= asm.lastActivityTime + AssemblyLease.leaseSeconds {",
        "why": "the absolute term rides the refreshed activity stamp: a dribbling peer advances the deadline forever and the relation never falls through its owner",
        "witness": "GodstoneMeshTests.ReadinessT20Tests/testTheAbsoluteTermExpiresTheDribbledAssemblyThoughTheSlidingWindowIsRefreshed",
    },
]

EXEC_RE = re.compile(r"Executed ([0-9]+) tests, with ([0-9]+) failures")
CASE_RE = re.compile(r"Test Case '-\[([^\]]+)\]' (passed|failed)")
SWIFT_COMPILE_RE = re.compile(r"\.swift:[0-9]+:[0-9]+: error:")
KT_COMPILE_RE = re.compile(r"^e: ", re.M)


def _worktree_add(head, wt_path):
    subprocess.run(["git", "worktree", "add", "--force", "--detach", wt_path, head],
                   cwd=ROOT, check=True, capture_output=True, timeout=300)
    subprocess.run(["git", "checkout", "--force", head], cwd=wt_path, check=True,
                   capture_output=True, timeout=300)
    st = subprocess.run(["git", "status", "--porcelain"], cwd=wt_path, check=True,
                        capture_output=True, timeout=120).stdout.decode("utf-8", "replace")
    assert st.strip() == "", "the worktree is not pristine:\n" + st


def _worktree_remove(wt_path):
    subprocess.run(["git", "worktree", "remove", "--force", wt_path], cwd=ROOT,
                   capture_output=True, timeout=300)
    subprocess.run(["git", "worktree", "prune"], cwd=ROOT, capture_output=True, timeout=300)


def _run_harness(entry, wt_path, timeout=2400):
    """Run the witness set once. Returns (build_exit, tests_run, failed_set, blob)."""
    if entry["platform"] == "jvm":
        proc = subprocess.run(
            ["./gradlew", ":mesh:testDebugUnitTest", "--no-daemon", "-q",
             "--tests", entry["gradle_filter"]],
            cwd=os.path.join(wt_path, "android"), capture_output=True, text=True,
            timeout=timeout)
        blob = (proc.stdout or "") + (proc.stderr or "")
        build_exit = 1 if KT_COMPILE_RE.search(blob) else 0
        xml_dir = os.path.join(wt_path, "android", "mesh", "build", "test-results",
                               "testDebugUnitTest")
        run = 0
        fails = 0
        failed = set()
        if os.path.isdir(xml_dir):
            for name in sorted(os.listdir(xml_dir)):
                if not (name.startswith("TEST-") and name.endswith(".xml")):
                    continue
                t = open(os.path.join(xml_dir, name), encoding="utf-8").read()
                m = re.search(r'tests="([0-9]+)" skipped="[0-9]+" failures="([0-9]+)" errors="([0-9]+)"', t)
                if not m:
                    continue
                run += int(m.group(1))
                fails += int(m.group(2)) + int(m.group(3))
                for cn, _det in re.findall(
                        r'<testcase name="([^"]+)"[^>]*>\s*<(?:failure|error)[^>]*message="', t):
                    failed.add(cn)
        return build_exit, (run if run else None), failed, blob
    proc = subprocess.run(
        ["swift", "test", "--package-path", "ios/Packages/GodstoneFoundation",
         "--filter", entry["witness"]],
        cwd=wt_path, capture_output=True, text=True, timeout=timeout)
    blob = (proc.stdout or "") + (proc.stderr or "")
    build_exit = 1 if SWIFT_COMPILE_RE.search(blob) else 0
    totals = [int(a) for a, b in EXEC_RE.findall(blob) if int(a) >= 1]
    run = max(totals) if totals else None
    failed = set()
    for name, verdict in CASE_RE.findall(blob):
        if verdict == "failed":
            tail = name.rpartition(" ")[2]
            failed.add(tail.rpartition("]")[0])
    return build_exit, run, failed, blob


def _classify(entry, build_exit, run, failed, baseline_ok):
    if not baseline_ok:
        return "INVALID", "the baseline itself did not pass unmutated"
    if build_exit != 0:
        return "INVALID", "the mutant did not compile"
    witness_tail = entry["witness"].rpartition("/")[2].rpartition(".")[2]
    hit = any(witness_tail in f or f == witness_tail for f in failed)
    if hit:
        return "KILLED", "witness %s failed as intended (%d failed case(s))" % (
            witness_tail, len(failed))
    if run is None or run == 0:
        return "INVALID", "the harness executed nothing"
    if failed:
        return "ESCAPED", ("the named witness stayed green; other cases failed (" +
                           ", ".join(sorted(failed))[:180] + ") - inspect")
    return "ESCAPED", "the witness stayed green against the mutant"


def run_semantic(report_only, emit_dir, baseline_sha, work_parent):
    head = baseline_sha or subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
        text=True).stdout.strip()
    rows = []
    tally = {k: 0 for k in ("KILLED", "SKIPPED", "INVALID", "TIMEOUT", "ESCAPED")}
    print("SEMANTIC lineage (oracle: the readiness suites' named witnesses; "
          "disposable worktrees; the live tree is never touched)")
    for spec in SEMANTIC:
        entry = dict(spec)
        entry["patch_sha"] = _sha_text(entry["find"] + "\n==\n" + entry["replace"])
        entry["started_utc"] = _now_utc()
        entry["ended_utc"] = None
        wt_path = os.path.join(work_parent, "wt_" + entry["id"])
        if os.path.exists(wt_path):
            _worktree_remove(wt_path)
        try:
            _worktree_add(head, wt_path)
            # the mirrored package is the compiler's true input on the swift
            # side; regenerate it in the lab so the run reads the very sources
            # under audit, and let any drift show rather than be hidden
            subprocess.run([sys.executable, "scripts/sync_ios_foundation_package.py"],
                           cwd=wt_path, capture_output=True, timeout=300)
            target = os.path.join(wt_path, entry["file"])
            text = open(target, encoding="utf-8").read()
            anchor_count = text.count(entry["find"])
            if anchor_count != 1:
                tally["SKIPPED"] += 1
                rows.append(_row(entry, head, "semantic", anchor_count, None,
                                [entry["witness"]], None, "SKIPPED",
                                "anchor seen %d times; never counted as a catch" % anchor_count,
                                None))
                print("  SKIPPED  %-34s anchor %d -- the needle moved on"
                      % (entry["id"], anchor_count))
                continue
            # 1. the baseline must pass unmutated, or nothing below may claim a kill
            be0, run0, failed0, blob0 = _run_harness(entry, wt_path)
            baseline_ok = be0 == 0 and run0 not in (None, 0) and not failed0
            # 2. install the mutant, exactly once
            open(target, "w", encoding="utf-8").write(
                text.replace(entry["find"], entry["replace"], 1))
            post = open(target, encoding="utf-8").read()
            assert post.count(entry["replace"]) == 1 and post.count(entry["find"]) == 0, \
                "the mutation did not install cleanly"
            # 3. run the witnesses against the mutant
            try:
                be, run, failed, blob = _run_harness(entry, wt_path)
            except subprocess.TimeoutExpired:
                tally["TIMEOUT"] += 1
                rows.append(_row(entry, head, "semantic", anchor_count, None,
                                [entry["witness"]], None, "TIMEOUT",
                                "the harness did not settle inside the bound", None))
                print("  TIMEOUT  %s" % entry["id"])
                continue
            outcome, note = _classify(entry, be, run, failed, baseline_ok)
            tally[outcome] += 1
            entry["ended_utc"] = _now_utc()
            log_path = None
            if emit_dir:
                log_path = os.path.join(emit_dir, "logs", entry["id"] + ".semantic.log")
                os.makedirs(os.path.dirname(log_path), exist_ok=True)
                open(log_path, "w", encoding="utf-8").write(
                    "== baseline ==\n" + blob0[-4000:] + "\n== mutant ==\n" + blob[-12000:])
            rows.append(_row(entry, head, "semantic", anchor_count, be, [entry["witness"]],
                            run, outcome, note, log_path))
            print("  %-8s %-34s run=%s failed=%d :: %s"
                  % (outcome, entry["id"], run, len(failed), note[:140]))
        finally:
            _worktree_remove(wt_path)
    print("  per outcome: " + ", ".join("%s=%d" % (k, tally[k]) for k in
          ("KILLED", "SKIPPED", "INVALID", "TIMEOUT", "ESCAPED")))
    if emit_dir:
        os.makedirs(emit_dir, exist_ok=True)
        open(os.path.join(emit_dir, "manifest.json"), "w", encoding="utf-8").write(
            json.dumps(rows, indent=1) + "\n")
    bad = [r["id"] for r in rows if r["outcome"] != "KILLED"]
    if bad and not report_only:
        print("::error::semantic controls not killed: " + ", ".join(bad), file=sys.stderr)
        return 1
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="do not fail on findings")
    ap.add_argument("--semantic", action="store_true", help="run the semantic lineage")
    ap.add_argument("--all", action="store_true", help="run both lineages")
    ap.add_argument("--emit-dir", default=None, help="write logs/ (and the semantic manifest) here")
    ap.add_argument("--baseline", default=None, help="pin the audited head sha for the run")
    ap.add_argument("--work-parent", default=os.path.join(
        os.path.expanduser("~"), ".cache", "godstone-mutation-worktrees"),
        help="parent directory for the disposable worktrees")
    a = ap.parse_args(argv)
    rc = 0
    if a.all or not a.semantic:
        rc |= run_structural(a.report, a.emit_dir, a.baseline or "live-tree")
    if a.semantic or a.all:
        os.makedirs(a.work_parent, exist_ok=True)
        rc |= run_semantic(a.report, a.emit_dir, a.baseline, a.work_parent)
    print("NO AGGREGATE: the two lineages are never summed; no run of this "
          "script may be quoted as a single killed percentage.")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
