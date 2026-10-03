#!/usr/bin/env python3
"""*** FOCUSED SELFTEST FOR THE BOARD 1 SECURITY-CRITICAL SURFACE MUTATION GROUP. ***

*The group `board1-trust-surface` (see `ci/mutations.py`) registers the mutation rods that
strike the four surfaces the audit names as last lines of defence: the TRUST-HANDSHAKE
controls, the PEER-IDENTITY store, the BOUND RECIPIENT key resolver and the STORE-SCHEMA/
quota controls. Each rod MUTATES the production control and the guard's own committed
checker is RUN against the mutant as the oracle.*

**THIS COURT PROVES THE GROUP IN FOUR WAYS, AND THE THIRD IS THE ONE THAT MATTERS.**
  1. it REGISTERS: `_group_ids('board1-trust-surface')` resolves to the source set, an
     unknown group name is refused by name, and a group entry naming a rod the ledger does
     not carry is a HOLE refused rather than skipped;
  2. every mutation TARGET MAPS TO A REAL GUARD: the rod's anchor is present exactly once
     in the live tree, its `refusal_line` is a sentence the named guard's OWN source
     prints, and the refusal lines are DISTINCT, so a kill is attributable by name rather
     than by a co-reddening exit code;
  3. NEGATIVE CONTROLS ARE KILLED AND POSITIVES KEPT -- EXECUTED, not asserted: for every
     rod, in a disposable worktree, the guard is green on the pristine tree, RUNS NON-ZERO
     and prints the rod's OWN refusal against the mutant, and is green again on the
     restored tree. A rod whose refusal is mis-aimed, whose guard is absent, or whose
     survivor reddens a co-invariant is shown to be EXEC_INVALID/ESCAPED, never a catch;
  4. the harness's own classifier is not fooled: a survivor is booked non-KILLED under the
     honest rules, and a broken policy that would book it KILLED is caught.

Run: `python3 -m pytest ci/test_mutation_board1_group.py -q`
"""
from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: The four guards the group's rods are aimed at. A rod naming any other guard is a
#: stranger that would launder its kill through a control the group never claimed.
THE_FOUR_GUARDS = {
    "ci/check_trusted_handshake_controls.py",
    "ci/check_peer_identity_store_controls.py",
    "ci/check_bound_recipient_key_resolver_controls.py",
    "ci/check_store_schema_controls.py",
}

GROUP = "board1-trust-surface"


def _load_mutations():
    spec = importlib.util.spec_from_file_location(
        "board1_group_mutations", os.path.join(ROOT, "ci", "mutations.py"))
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


M = _load_mutations()
SPEC = {s["id"]: s for s in M.SEMANTIC}
RODS = list(M.TRUST_SURFACE_REQUIRED_IDS)


def _norm(text: str) -> str:
    """Collapse all whitespace, so a multi-line refusal sentence compares equal to its source."""
    return re.sub(r"\s+", " ", text)


def _attribution(rod: dict) -> str:
    """A rod's FULL normalized refusal line -- the attributable identity of its kill."""
    return _norm(rod["refusal_line"])


def _tail(rod: dict) -> str:
    """The invariant-naming tail of a refusal, matched against a guard's own source."""
    return _norm(rod["refusal_line"])[-45:]


def _head() -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                          capture_output=True, text=True).stdout.strip()


# ==========================================================================
# 1. REGISTRATION -- the group is a named set in the source, and a hole is refused.
# ==========================================================================

def test_the_group_registers_to_the_source_set():
    assert M._group_ids(GROUP) == RODS, "the group must select exactly the source tuple"
    assert len(RODS) == 15, "the group's population moved; re-derive the plan"


def test_an_unknown_group_name_is_refused_by_name():
    with pytest.raises(SystemExit) as exc:
        M._group_ids("board1-trust-surface-typo")
    assert "unknown group" in str(exc.value)


def test_a_group_entry_absent_from_the_ledger_is_refused_not_skipped(monkeypatch):
    """*** A group entry with no rod is a HOLE that reads as a pass; it MUST be refused. ***"""
    holed = tuple(RODS) + ("TH-99-a-rod-the-ledger-never-carried",)
    monkeypatch.setattr(M, "TRUST_SURFACE_REQUIRED_IDS", holed)
    with pytest.raises(SystemExit) as exc:
        M._group_ids(GROUP)
    assert "TH-99-a-rod-the-ledger-never-carried" in str(exc.value)


def test_every_rod_id_is_unique_in_the_ledger():
    ids = [s["id"] for s in M.SEMANTIC]
    assert len(ids) == len(set(ids)), "a duplicated rod id makes the population ambiguous"


def test_the_group_is_registered_outside_the_board1_required_population():
    """*** THE GROUP IS A SUBSET THE PLAN RUNS ON ITS OWN; it must not silently redefine
    `board1`'s required set (which Main's serialized campaign validates). ***"""
    assert not (set(RODS) & set(M.BOARD1_REQUIRED_IDS)), \
        "a trust-surface rod leaked into the board1 required population"


# ==========================================================================
# 2. EVERY TARGET MAPS TO A REAL GUARD -- anchor, guard, and an attributable refusal.
# ==========================================================================

def test_every_rod_names_one_of_the_four_guards():
    named = {SPEC[r]["guard_file"] for r in RODS}
    assert named == THE_FOUR_GUARDS, f"a rod aims at a stranger guard: {named - THE_FOUR_GUARDS}"


def test_every_rod_anchor_is_present_exactly_once_in_the_live_tree():
    for rid in RODS:
        rod = SPEC[rid]
        text = open(os.path.join(ROOT, rod["file"]), encoding="utf-8").read()
        assert text.count(rod["find"]) == 1, f"{rid}: the anchor is not seen exactly once"
        assert rod["replace"] != rod["find"], f"{rid}: the mutant is a no-op"
        # an insertion rod must not re-contain its own anchor, or the install proof fails
        assert rod["replace"].count(rod["find"]) == 0 or rod["replace"].startswith(rod["find"]), \
            f"{rid}: the replacement re-contains its anchor in a way the install proof rejects"


def test_every_rod_guard_file_exists_and_is_executable_python():
    for rid in RODS:
        path = os.path.join(ROOT, SPEC[rid]["guard_file"])
        assert os.path.isfile(path), f"{rid}: guard {path} is absent"
        compile(open(path, encoding="utf-8").read(), path, "exec")


def test_every_refusal_line_is_a_sentence_the_named_guard_actually_prints():
    """*** THE MAPPING PROOF: the refusal is not invented -- the guard's own source contains it. ***"""
    for rid in RODS:
        rod = SPEC[rid]
        src = _norm(open(os.path.join(ROOT, rod["guard_file"]), encoding="utf-8").read())
        tail = _tail(rod)
        assert tail in src, f"{rid}: {tail!r} is not a refusal the guard can print"


def test_refusal_lines_are_distinct_so_a_kill_is_attributable():
    """*** ATTRIBUTION BY NAME: if two rods named one refusal, an escape could hide behind a
    co-reddening sibling. Every rod's attribution tail must be unique. ***"""
    tails = [_attribution(SPEC[r]) for r in RODS]
    assert len(tails) == len(set(tails)), f"two rods share a refusal: {tails}"


def test_the_group_carries_at_least_one_rod_per_guard():
    per = {}
    for rid in RODS:
        per.setdefault(SPEC[rid]["guard_file"], 0)
        per[SPEC[rid]["guard_file"]] += 1
    assert set(per) == THE_FOUR_GUARDS and all(v >= 1 for v in per.values()), per


def test_every_rod_declares_a_negative_expectation_and_a_witness():
    """A rod without a refusal has no negative control; without a witness it has no attribution."""
    for rid in RODS:
        rod = SPEC[rid]
        assert rod.get("refusal_line") and rod.get("witness"), rid
        assert rod["witness"].startswith(os.path.basename(rod["guard_file"]).replace(".py", "")), \
            f"{rid}: the witness must name the guard the rod aims at"


# ==========================================================================
# 3. NEGATIVE CONTROLS KILLED, POSITIVES KEPT -- EXECUTED in a disposable worktree.
# ==========================================================================

@pytest.fixture(scope="module")
def worktree():
    """A disposable worktree at the audited head, removed afterwards. The live tree is untouched."""
    head = _head()
    parent = tempfile.mkdtemp(prefix="board1-trust-surface-selftest-")
    wt = os.path.join(parent, "probe")
    M._worktree_add(head, wt)
    try:
        yield wt
    finally:
        M._worktree_remove(wt)
        shutil.rmtree(parent, ignore_errors=True)


def _run_with_mutant(rod, wt, mutate=True, override_refusal=None):
    """Install the rod's mutant (or a decoy), run the guard, then restore. Returns (mutant, restored)."""
    path = os.path.join(wt, rod["file"])
    original = open(path, encoding="utf-8").read()
    entry = dict(rod)
    if override_refusal is not None:
        entry["refusal_line"] = override_refusal
    try:
        if mutate:
            open(path, "w", encoding="utf-8").write(
                original.replace(rod["find"], rod["replace"], 1))
        mutant = M._run_harness(entry, wt)
    finally:
        open(path, "w", encoding="utf-8").write(original)
    restored = M._run_harness(entry, wt)
    return mutant, restored


def test_every_rod_kills_its_guard_and_the_restored_tree_stays_green(worktree):
    """*** THE AUTHENTICITY PROOF: pristine green -> mutant reddens THE ROD'S OWN invariant ->
    restored green again, for every rod. A rod here that escaped would be a false assurance. ***"""
    for rid in RODS:
        rod = SPEC[rid]
        # positive control: the guard accepts the pristine tree (no kill fabricated from nothing)
        pristine = M._run_harness(rod, worktree)
        assert pristine["failed"] == set(), f"{rid}: the guard reddened on the UNMUTATED tree"
        mutant, restored = _run_with_mutant(rod, worktree)
        assert mutant["failed"] == {rod["witness"]}, \
            f"{rid}: the guard did not redden against the mutant (failed={mutant['failed']})"
        assert _tail(rod) in _norm(mutant["blob"]), \
            f"{rid}: the kill is not attributable to the rod's own refusal"
        assert restored["failed"] == set(), f"{rid}: the restored tree did not stay green"


def test_a_benign_decoy_is_never_counted_as_a_kill(worktree):
    """*** THE SURVIVOR NEGATIVE CONTROL: a comment-only change that leaves every invariant
    intact MUST NOT be booked a catch, so the group cannot claim a kill it did not earn. ***"""
    rod = SPEC[RODS[0]]
    path = os.path.join(worktree, rod["file"])
    original = open(path, encoding="utf-8").read()
    try:
        open(path, "w", encoding="utf-8").write(
            original.replace(rod["find"], "// (decoy) comment only, no behaviour change\n" + rod["find"], 1))
        survivor = M._run_harness(rod, worktree)
    finally:
        open(path, "w", encoding="utf-8").write(original)
    assert survivor["failed"] == set(), "a benign decoy was counted as a kill"
    verdict, _note = M._classify(rod, survivor["build_exit"], survivor["run"],
                                 survivor["failed"], baseline_ok=True)
    assert verdict == "ESCAPED", f"a survivor must be ESCAPED, got {verdict}"


def test_a_mis_aimed_refusal_is_not_a_catch(worktree):
    """*** AN UNATTRIBUTED FAILURE IS NOT A KILL: if the mutant reddens an invariant the rod did
    not aim at, the named refusal is absent and the rod must NOT be booked a catch. ***"""
    rod = SPEC["BR-02-android-node-id-boundary-guard-removed"]
    mutant, restored = _run_with_mutant(
        rod, worktree, override_refusal="an invariant this guard never prints (ZZ99)")
    assert mutant["failed"] == set(), "a mis-aimed refusal was accepted as a catch"
    verdict, _note = M._classify(rod, mutant["build_exit"], mutant["run"],
                                 mutant["failed"], baseline_ok=True)
    assert verdict == "ESCAPED", f"a mis-aimed refusal must be ESCAPED, got {verdict}"


def test_a_missing_guard_is_not_a_catch(worktree):
    """*** FAIL CLOSED: a rod whose guard is absent cannot be aimed, so it is EXEC_INVALID. ***"""
    rod = dict(SPEC["PI-01-first-seen-becometh-insert-or-ignore"])
    rod["guard_file"] = "ci/check_this_guard_does_not_exist.py"
    result = M._run_harness(rod, worktree)
    assert result["failed"] == set() and result["run"] is None
    verdict, _note = M._classify(rod, result["build_exit"], result["run"],
                                 result["failed"], baseline_ok=True)
    assert verdict == "EXEC_INVALID", f"a missing guard must be EXEC_INVALID, got {verdict}"


# ==========================================================================
# 4. THE HARNESS'S OWN CLASSIFIER IS NOT FOOLED.
# ==========================================================================

def test_the_honest_classifier_booketh_a_survivor_non_killed():
    rod = SPEC[RODS[0]]
    verdict, _note = M._classify(rod, 0, 1, set(), baseline_ok=True)
    assert verdict == "ESCAPED"


def test_a_broken_policy_that_would_book_a_survivor_killed_is_caught():
    """*** THE NEGATIVE CONTROL FOR THE JUDGE ITSELF: the module's own selftest must SEE a policy
    that counts an escape as a kill, or the group's 'kills' would be unverifiable. ***"""
    mismatch, _checks = M.classify_selftest()
    assert mismatch == [], f"the honest known-answer table misclassified: {mismatch}"
    caught = []
    for name, policy in M.BROKEN_POLICIES:
        for (scenario, anchors, build_exit, run, failed, baseline_ok, skipped,
             restored_green, expected) in M.KNOWN_ANSWER_CASES:
            verdict, _note = M._classify_with(policy, M._selftest_entry(), build_exit, run,
                                              failed, baseline_ok, anchors, skipped, restored_green)
            if verdict != expected:
                caught.append(name)
                break
    assert set(caught) == {name for name, _ in M.BROKEN_POLICIES}, \
        "a broken policy escaped the known-answer table"


# ==========================================================================
# 5. THE GROUP RUNS END TO END (the campaign's own selection + verdict).
# ==========================================================================

def test_the_group_runs_through_run_semantic_and_every_rod_is_killed():
    """*** THE CAMPAIGN-SHAPED ACCEPTANCE: `--group board1-trust-surface` selects exactly the
    source rods, all of them KILLED with restorations, and returns 0. ***"""
    with tempfile.TemporaryDirectory(prefix="board1-trust-surface-campaign-") as emit_dir, \
            tempfile.TemporaryDirectory(prefix="board1-trust-surface-work-") as work_parent:
        rc = M.run_semantic(False, emit_dir, _head(), work_parent, group=GROUP)
        assert rc == 0, "the trust-surface group did not run green"
        import json
        env = json.load(open(os.path.join(emit_dir, "manifest.json"), encoding="utf-8"))
        assert env["group"] == GROUP
        assert set(env["selected_ids"]) == set(RODS)
        outcomes = {r["id"]: r["outcome"] for r in env["rows"]}
        assert set(outcomes) == set(RODS), "a rod was dropped from the manifest"
        assert all(o == "KILLED" for o in outcomes.values()), outcomes
        assert all(r.get("restored_green", {}).get("ok") for r in env["rows"]), \
            "a kill without its restored-green companion is not provable"


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__, "-q"]))
