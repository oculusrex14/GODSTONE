#! /usr/bin/env python3
"""The EXTERNAL-INPUT LANE's own court.

The objective requireth that the parallel external-input lane be prepared **"with exact requests, owners and
immutable acceptance requirements"**, and that **"acquisition never closes a gate and no self-generated
fixture may substitute for an approval"**. Until this court, every one of those requirements lived in
`docs/remediation/EXTERNAL_INPUT_REQUESTS.md` as PROSE: a reader could see it, and NOTHING could fail if a
later round quietly thinned it -- by dropping the "Who alone can approve it" row, by writing a DATE where the
document's own law requireth an EVENT, by recording closure evidence that no external party ever sent, or by
leaving one of the outstanding tasks unrequested.

The existing court (`test_remediation.py`, W09) checketh the LANE's JSON and not the document; this one
checketh the document itself, and it is written as a PURE FUNCTION over the text so that the negative cases
can REFUTE it:

  W01 the real document and the real lane carrieth NO defect
  W02 EVERY externally-blocked task of the objective is named by some request's Blocks row
  W03 each request carrieth every required row, and each nameth a SOLE APPROVER
  W04 the recheck trigger is an EVENT and NEVER A DATE (the document's own law)
  W05 closure evidence is `None` for every request: NOTHING hath been acquired
  W06 the lane's three constants hold, and NO gate carrieth closure evidence
  W07 the document explicitly DENIETH being acquisition, an approval or a status change
  W08/W09/W10/W11 NEGATIVE: a dropped approver row, a dated trigger, fabricated closure evidence and an
      unrequested task are EACH reported -- so this court judgeth rather than merely agreeing
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
DOC = ROOT / "docs" / "remediation" / "EXTERNAL_INPUT_REQUESTS.md"

# The five requests, and the rows each MUST carry. The labels are the document's own, verbatim.
REQUIRED_ROWS = ("Blocks (still unfinished)", "The artifact required", "Who alone can approve it",
                 "How it is verified on receipt", "Recheck trigger (an EVENT, never a date)",
                 "Closure evidence today", "Internal prerequisites")
# THE OBJECTIVE'S OWN EXTERNAL TASKS: T73-T75 (hardware scheduling), T76 (signing inputs), T79 (independent
# fixtures), T80 (approved content), T81 (native/model artifacts). Every one must be REQUESTED of somebody.
REQUIRED_TASKS = ("T73", "T74", "T75", "T76", "T79", "T80", "T81")
DATE_PATTERNS = (r"\b\d{4}-\d{2}-\d{2}\b", r"\b\d{1,2}/\d{1,2}/\d{2,4}\b",
                 r"\b(January|February|March|April|May|June|July|August|September|October|November|December)\b",
                 r"\b(Q[1-4]|20\d{2})\b")


def requests_of(text: str) -> dict:
    """The document's requests, as {name: {label: value}} -- read from its own `### NAME -- kind` headings
    and their two-column tables. A parser, not a guess: every heading and every row is taken verbatim."""
    out, current = {}, None
    for line in text.split("\n"):
        if line.startswith("### "):
            current = line[4:].split("—")[0].strip()
            out[current] = {}
            continue
        if line.startswith("## "):
            current = None
            continue
        if current and line.startswith("| **"):
            parts = [p.strip() for p in line.strip("|").split("|")]
            if len(parts) >= 2:
                out[current][parts[0].strip("* ")] = parts[1]
    return out


def lane_defects(state: dict) -> list[str]:
    lane = state.get("external_input_lane") or {}
    problems = []
    if lane.get("audit_has_contacted_external_parties") is not False:
        problems.append("the lane must RECORD that no external party hath been contacted")
    if lane.get("acquisition_closes_nothing") is not True:
        problems.append("the lane must RECORD that acquisition closes nothing")
    if lane.get("no_self_generated_fixture_may_substitute_for_an_approval") is not True:
        problems.append("the lane must RECORD that no self-generated fixture substituteth for an approval")
    for gate in lane.get("gates") or []:
        if str(gate.get("closure_evidence", "")).strip().upper() not in ("NONE", ""):
            problems.append("gate %s carrieth closure evidence (%r): ACQUISITION CLOSES NOTHING"
                            % (gate.get("id"), gate.get("closure_evidence")))
    return problems


def document_defects(text: str, tasks=REQUIRED_TASKS) -> list[str]:
    """Every defect of the external-input document, NAMED. Pure: the negative cases feed it mutated text."""
    problems = []
    reqs = requests_of(text)
    if len(reqs) < 5:
        problems.append("the document must carry the five requests; it carrieth %d" % len(reqs))
    for name, rows in reqs.items():
        for label in REQUIRED_ROWS:
            if label not in rows:
                problems.append("%s carrieth no %r row" % (name, label))
            elif not rows[label].strip():
                problems.append("%s carrieth an EMPTY %r row" % (name, label))
        approver = rows.get("Who alone can approve it", "")
        if approver and len(approver.split()) < 1:
            # THIS LINE WAS VACUOUS AND IS KEPT ONLY AS A MARKER OF THE LESSON: a non-empty string ALWAYS
            # hath one word, so the condition could never fire. THE REAL CHECK IS THAT THE ROW EXISTETH AND
            # IS NOT EMPTY, which the required-row loop above maketh.
            problems.append("%s nameth no sole approver" % name)
        verification = rows.get("How it is verified on receipt", "")
        if verification and "`" not in verification:
            problems.append("%s carrieth no RECEIPT COMMAND: 'how it is verified on receipt' must name a "
                            "command that can actually be run, and this row is prose alone (%r)"
                            % (name, verification[:60]))
        trigger = rows.get("Recheck trigger (an EVENT, never a date)", "")
        for pattern in DATE_PATTERNS:
            if re.search(pattern, trigger):
                problems.append("%s's recheck trigger carrieth a DATE (%r): the document's own law requireth "
                                "an EVENT, never a date" % (name, trigger))
        closure = rows.get("Closure evidence today", "")
        if closure and "none" not in closure.lower():
            problems.append("%s carrieth CLOSURE EVIDENCE (%r): nothing hath been acquired, so no request "
                            "may claim any" % (name, closure))
    # EVERY EXTERNALLY-BLOCKED TASK MUST BE REQUESTED OF SOMEBODY
    asked = " ".join(" ".join(rows.get("Blocks (still unfinished)", "") for rows in reqs.values()).split())
    for task in tasks:
        if not re.search(r"\b" + re.escape(task) + r"\b", asked):
            problems.append("%s is externally blocked and NO request nameth it" % task)
    # AND THE DOCUMENT MUST DENY BEING ACQUISITION
    flat = " ".join(text.split()).lower()
    if "not acquisition" not in flat:
        problems.append("the document must SAY it is not acquisition")
    if "no external party has been contacted" not in flat:
        problems.append("the document must SAY no external party hath been contacted")
    return problems


class ExternalInputRequestsTest(unittest.TestCase):
    def setUp(self):
        self.text = DOC.read_text(encoding="utf-8")
        self.state = json.loads(LEDGER.read_text(encoding="utf-8"))

    def test_w01_the_real_document_and_lane_carrieth_no_defect(self):
        problems = document_defects(self.text) + lane_defects(self.state)
        self.assertEqual([], problems, "the external-input lane is defective: " + " | ".join(problems))

    def test_w02_every_externally_blocked_task_is_requested_of_somebody(self):
        asked = " ".join(r.get("Blocks (still unfinished)", "")
                         for r in requests_of(self.text).values())
        for task in REQUIRED_TASKS:
            self.assertRegex(asked, r"\b" + re.escape(task) + r"\b",
                             "%s is externally blocked and no request nameth it" % task)

    def test_w03_each_request_nameth_its_sole_approver_and_its_artifact(self):
        for name, rows in requests_of(self.text).items():
            self.assertTrue(rows.get("Who alone can approve it", "").strip(), name)
            self.assertTrue(rows.get("The artifact required", "").strip(), name)
            self.assertTrue(rows.get("How it is verified on receipt", "").strip(), name)

    def test_w04_the_recheck_trigger_is_an_event_never_a_date(self):
        for name, rows in requests_of(self.text).items():
            trigger = rows.get("Recheck trigger (an EVENT, never a date)", "")
            for pattern in DATE_PATTERNS:
                self.assertIsNone(re.search(pattern, trigger),
                                  "%s's trigger carrieth a date: %r" % (name, trigger))

    def test_w05_nothing_hath_been_acquired(self):
        for name, rows in requests_of(self.text).items():
            self.assertIn("none", rows.get("Closure evidence today", "").lower(),
                          "%s claimeth closure evidence, and nothing hath been acquired" % name)
        self.assertFalse(self.state["external_input_lane"]["audit_has_contacted_external_parties"])

    def test_w06_the_lanes_constants_hold_and_no_gate_carrieth_closure_evidence(self):
        self.assertEqual([], lane_defects(self.state), lane_defects(self.state))

    def test_w07b_negative_a_prose_only_verification_row_is_reported(self):
        text = self.text.replace(
            "| **How it is verified on receipt** | `python3 -m tools.readiness.run task T74 --stage narrow` ; `python3 ci/check_release_gates_status.py` |",
            "| **How it is verified on receipt** | by inspection |")
        self.assertNotEqual(text, self.text, "the negative case did not mutate the document")
        problems = document_defects(text)
        self.assertTrue(any("RECEIPT COMMAND" in p for p in problems),
                        "a prose-only verification row MUST be reported: " + " | ".join(problems))

    def test_w07_the_document_denieth_being_acquisition(self):
        flat = " ".join(self.text.split()).lower()
        for denial in ("not acquisition", "no external party has been contacted"):
            self.assertIn(denial, flat, "the document must SAY %r" % denial)

    def test_w08_negative_a_dropped_approver_row_is_reported(self):
        text = self.text.replace("| **Who alone can approve it** | device lab |",
                                 "| **Not the approver** | device lab |")
        self.assertNotEqual(text, self.text, "the negative case did not mutate the document")
        problems = document_defects(text)
        self.assertTrue(any("Who alone can approve it" in p for p in problems),
                        "a dropped approver row MUST be reported: " + " | ".join(problems))

    def test_w09_negative_a_dated_trigger_is_reported(self):
        text = self.text.replace("| **Recheck trigger (an EVENT, never a date)** | device access established |",
                                 "| **Recheck trigger (an EVENT, never a date)** | 2026-10-01 |")
        self.assertNotEqual(text, self.text, "the negative case did not mutate the document")
        problems = document_defects(text)
        self.assertTrue(any("DATE" in p for p in problems),
                        "a dated trigger MUST be reported: " + " | ".join(problems))

    def test_w10_negative_fabricated_closure_evidence_is_reported(self):
        text = self.text.replace("| **Closure evidence today** | `None` — NONE. This work never writes one. |",
                                 "| **Closure evidence today** | received from the vendor |", 1)
        self.assertNotEqual(text, self.text, "the negative case did not mutate the document")
        problems = document_defects(text)
        self.assertTrue(any("CLOSURE EVIDENCE" in p for p in problems),
                        "fabricated closure evidence MUST be reported: " + " | ".join(problems))

    def test_w11_negative_an_unrequested_task_is_reported(self):
        problems = document_defects(self.text, tasks=REQUIRED_TASKS + ("T99",))
        self.assertTrue(any("T99" in p for p in problems),
                        "a task that no request nameth MUST be reported: " + " | ".join(problems))


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
