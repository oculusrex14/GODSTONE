#! /usr/bin/env python3
"""T71 readiness court: bounded diagnostics without private telemetry.

The card's law, one witness each where the rule speaketh:

  W01 the recorder is OPT-IN: OFF counteth nothing, ringeth nothing and rendereth
      a truthful "mode=off"
  W02 THE NAMED NEGATIVE, first limb: a MESSAGE BODY offered as a metric name, or a
      KEY offered as a value, is REFUSED by name -- never logged
  W03 THE NAMED NEGATIVE, second limb: the ring is BOUNDED under a flood, drop-oldest
      is counted, and the loss is visible rather than silent
  W04 counters are BOUNDED (saturating at the ceiling) and gauges never go negative
  W05 durations are MONOTONIC microseconds: no wall-clock timestamp is ever recorded
  W06 relation ids are EPHEMERAL, per-process and opaque: a peer key never reacheth
      the output, and a reset restarteth the ordinals
  W07 the FIVE scenarios run against a live recorder: tampered data, ten-thousand
      peer churn, a queue flood, a large archive and a cancelled inference
  W08 THE SENTINEL LAW: the private body, key and node-id sentinels appear NOWHERE
      in the rendered output of ANY scenario
  W09 the metric VOCABULARY is closed: an unknown name is refused, so no free label
      can carry private data
  W10 redaction is BY REFUSAL: a string, a byte string or a list is refused outright,
      and the refusal is counted
  W11 the ring's bound is a CONSTRUCTION, not a hope: capacity is fixed, and the ring
      never exceedeth it whatever the load
  W12 the platform declarations agree: the shipping build carrieth no analytics, no
      tracking and no INTERNET, and the diagnostics are local-only
  W13 the three lanes share the ONE vocabulary and the ONE sentinel set

No external gate is closed; readiness stays false; nothing is transmitted anywhere.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

from diagnostics import (  # noqa: E402
    COUNTER_CEILING, METRIC_NAMES, RING_CAPACITY, SCENARIOS, SENTINEL_BODY,
    SENTINEL_KEY, SENTINEL_NODE_ID, Diagnostics, DiagnosticsMode,
    DiagnosticsRefusal, census_report, run_scenario,
)


def live(capacity: int = RING_CAPACITY) -> Diagnostics:
    made = Diagnostics(capacity=capacity)
    made.enable()
    return made


class T71OptInTest(unittest.TestCase):
    """W01-W02 -- opt-in, and the refusal of private data."""

    def test_w01_the_recorder_is_opt_in(self):
        quiet = Diagnostics()
        self.assertFalse(quiet.is_on)
        self.assertEqual(0, quiet.count("frames_persisted"))
        self.assertEqual(0, quiet.ring_size)
        self.assertIn("mode=off", quiet.render())
        self.assertEqual({}, quiet.counters)
        # an unknown metric is STILL refused while OFF: the vocabulary is a law of
        # the recorder, not of the mode
        with self.assertRaises(DiagnosticsRefusal):
            quiet.count("not_a_metric")
        quiet.enable()
        self.assertTrue(quiet.is_on)
        self.assertEqual(1, quiet.count("frames_persisted"))
        quiet.disable()
        self.assertEqual(0, quiet.count("frames_persisted"))
        self.assertIn("mode=off", quiet.render())

    def test_w02_a_body_or_a_key_is_refused_by_name(self):
        diag = live()
        # a MESSAGE BODY offered as a metric name
        with self.assertRaises(DiagnosticsRefusal) as caught:
            diag.count(SENTINEL_BODY)
        self.assertIn("vocabulary", str(caught.exception))
        # a KEY offered as a value: a string is exactly how a body or a key fragment
        # would enter the log
        with self.assertRaises(DiagnosticsRefusal) as caught2:
            diag.count("peers_seen", SENTINEL_KEY)
        self.assertIn("must be a number", str(caught2.exception))
        # a NODE ID offered as a value
        with self.assertRaises(DiagnosticsRefusal):
            diag.count("peers_seen", SENTINEL_NODE_ID)
        # and NONE of them reached the output
        rendered = diag.render()
        for sentinel in (SENTINEL_BODY, SENTINEL_KEY, SENTINEL_NODE_ID):
            self.assertNotIn(sentinel, rendered)
        self.assertEqual(0, diag.ring_size, "a refused call appends nothing")


class T71BoundsTest(unittest.TestCase):
    """W03-W06 -- the ring, the counters, the clock and the ids."""

    def test_w03_the_ring_is_bounded_and_drop_oldest_is_counted(self):
        diag = live(capacity=16)
        for i in range(100):
            diag.count("queue_superseded", 1)
        self.assertEqual(16, diag.ring_size)
        self.assertTrue(diag.is_bounded)
        self.assertEqual(84, diag.superseded, "every supersession must be COUNTED")
        # the ring carrieth the FRESHEST lines: the eldest are gone
        self.assertIn("superseded=84", diag.render())
        # a capacity of one is legal and still bounded
        tiny = live(capacity=1)
        for _ in range(5):
            tiny.count("frames_persisted", 1)
        self.assertEqual(1, tiny.ring_size)
        self.assertEqual(4, tiny.superseded)

    def test_w04_counters_saturate_and_gauges_never_go_negative(self):
        diag = live()
        diag.count("frames_persisted", COUNTER_CEILING * 4)
        self.assertEqual(COUNTER_CEILING, diag.counters["frames_persisted"],
                         "a counter SATURATETH: a flood cannot overflow into nonsense")
        diag.count("frames_persisted", 10)
        self.assertEqual(COUNTER_CEILING, diag.counters["frames_persisted"])
        diag.gauge("queue_depth", -5)
        self.assertEqual(0, diag.counters["queue_depth"], "a gauge never goeth negative")
        diag.gauge("queue_depth", COUNTER_CEILING * 2)
        self.assertEqual(COUNTER_CEILING, diag.counters["queue_depth"])

    def test_w05_durations_are_monotonic_microseconds(self):
        diag = live()
        diag.count("frames_persisted", 1, duration_micros=1500)
        line = diag.lines[-1]
        self.assertEqual(1500, line.duration_micros)
        rendered = diag.render()
        # a duration is a NUMBER OF MICROSECONDS, never a wall-clock timestamp
        self.assertIn("dur_us=1500", rendered)
        self.assertNotRegex(rendered, r"\b(19|20)\d\d-\d\d-\d\d\b",
                            "no calendar date may be recorded")
        self.assertNotRegex(rendered, r"\d{10,}", "no epoch-like timestamp may be recorded")
        # and a negative duration is clamped like any other value
        diag.count("frames_persisted", 1, duration_micros=-9)
        self.assertEqual(0, diag.lines[-1].duration_micros)

    def test_w06_relation_ids_are_ephemeral_and_opaque(self):
        diag = live()
        first = diag.relation(("peer", SENTINEL_NODE_ID))
        self.assertEqual("r1", first)
        self.assertEqual(first, diag.relation(("peer", SENTINEL_NODE_ID)),
                         "one relation carrieth one ordinal while the process liveth")
        second = diag.relation(("peer", "another"))
        self.assertEqual("r2", second)
        diag.count("peers_seen", 1, relation_key=("peer", SENTINEL_NODE_ID))
        rendered = diag.render()
        self.assertIn("rel=r1", rendered)
        self.assertNotIn(SENTINEL_NODE_ID, rendered, "a peer key NEVER reacheth the output")
        # EPHEMERAL: a reset forgetteth every relation and restarteth the ordinals,
        # so a line from before cannot be correlated with one from after
        diag.reset()
        self.assertEqual("r1", diag.relation(("peer", SENTINEL_NODE_ID)))
        self.assertEqual(0, diag.ring_size)
        self.assertEqual({}, diag.counters)


class T71ScenariosTest(unittest.TestCase):
    """W07-W09 -- the five scenarios, the sentinel law, the closed vocabulary."""

    def test_w07_the_five_scenarios_run_against_a_live_recorder(self):
        self.assertEqual(("tampered_data", "peer_churn_10k", "queue_flood",
                          "large_archive", "cancelled_inference"), SCENARIOS)
        for name in SCENARIOS:
            diag = live()
            census = run_scenario(name, diag, scale=200)
            self.assertEqual(name, census["scenario"])
            self.assertTrue(census["bounded"], name)
            self.assertGreater(census["ring"], 0, name)
            # every counter the scenario touched is IN the vocabulary
            for metric in census["counters"]:
                self.assertIn(metric, METRIC_NAMES, name)

    def test_w08_the_sentinels_appear_nowhere_in_any_scenario(self):
        for name in SCENARIOS:
            diag = live()
            run_scenario(name, diag, scale=500)
            rendered = diag.render()
            for sentinel in (SENTINEL_BODY, SENTINEL_KEY, SENTINEL_NODE_ID):
                self.assertNotIn(sentinel, rendered,
                                 "%s leaked %r" % (name, sentinel))
            # and the census (the other road out) is clean too
            census = census_report(diag)
            for sentinel in (SENTINEL_BODY, SENTINEL_KEY, SENTINEL_NODE_ID):
                self.assertNotIn(sentinel, census, name)
            # nor doth any line carry a string VALUE: every value is a number
            for line in diag.lines:
                self.assertIsInstance(line.value, int)
                self.assertIsInstance(line.duration_micros, int)
                self.assertTrue(re.fullmatch(r"r\d+", line.relation), line.relation)

    def test_w09_the_vocabulary_is_closed(self):
        diag = live()
        for metric in METRIC_NAMES:
            diag.count(metric, 1)
        self.assertEqual(len(METRIC_NAMES), len(diag.counters))
        for stranger in ("message_body", "peer_id", "key", "SENTINEL", "metric",
                         "peers_seen ", "PEERS_SEEN", ""):
            with self.assertRaises(DiagnosticsRefusal, msg=stranger):
                diag.count(stranger)
        # the vocabulary carrieth no name that could hold private data
        for metric in METRIC_NAMES:
            self.assertTrue(re.fullmatch(r"[a-z][a-z0-9_]*", metric), metric)
            self.assertNotIn("body", metric)
            self.assertNotIn("key", metric)
            self.assertNotIn("peer_id", metric)
            self.assertNotIn("node", metric)


class T71RedactionAndDeclarationsTest(unittest.TestCase):
    """W10-W13 -- redaction by refusal, the construction bound, the declarations."""

    def test_w10_redaction_is_by_refusal(self):
        diag = live()
        for value in ("a string", b"bytes", ["a", "list"], {"a": "dict"}, None, 1.5):
            with self.assertRaises(DiagnosticsRefusal, msg=repr(value)):
                diag.count("peers_seen", value)
        self.assertEqual(0, diag.ring_size)
        # boolean is a number in this vocabulary, and it is NORMALIZED
        self.assertEqual(1, diag.count("peers_seen", True))
        self.assertEqual(1, diag.counters["peers_seen"])

    def test_w11_the_ring_bound_is_a_construction(self):
        self.assertEqual(256, RING_CAPACITY)
        self.assertEqual(1 << 40, COUNTER_CEILING)
        diag = live()
        # a flood far past the capacity, through the real scenario
        run_scenario("queue_flood", diag, scale=5_000)
        self.assertLessEqual(diag.ring_size, diag.capacity)
        self.assertGreater(diag.superseded, 0, "the flood must have superseded lines")
        # and 10k peer churn carrieth the same bound
        churn = live()
        run_scenario("peer_churn_10k", churn, scale=10_000)
        self.assertLessEqual(churn.ring_size, churn.capacity)
        self.assertEqual(10_000, churn.counters["peers_seen"])

    def test_w12_the_declarations_agree_that_nothing_is_transmitted(self):
        manifest = (ROOT / "android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
        # the shipping app REMOVETH the internet permission and carrieth no
        # analytics: diagnostics cannot leave the device
        self.assertIn('android.permission.INTERNET" tools:node="remove"', manifest)
        source = (ROOT / "tools/readiness/diagnostics.py").read_text(encoding="utf-8")
        for forbidden in ("requests", "urllib", "socket", "http", "upload", "report_to"):
            self.assertNotIn(forbidden, source,
                             "the diagnostics must never transmit anything (%s)" % forbidden)
        # and the module declareth its mode's own words
        self.assertIn(DiagnosticsMode.OFF, source)
        self.assertIn("local", source.lower())

    def test_w13_the_three_lanes_share_one_vocabulary_and_sentinel_set(self):
        kotlin = (ROOT / "android/mesh/src/main/java/io/godstone/mesh/diag/Diagnostics.kt")
        swift = (ROOT / "ios/Godstone/Sources/GodstoneMesh/Diagnostics.swift")
        self.assertTrue(kotlin.is_file(), "the Android twin must exist")
        self.assertTrue(swift.is_file(), "the iOS twin must exist")
        ktext = kotlin.read_text(encoding="utf-8")
        stext = swift.read_text(encoding="utf-8")
        for metric in ("peers_seen", "queue_superseded", "frames_persisted"):
            self.assertIn(metric, ktext, metric)
            self.assertIn(metric, stext, metric)
        # the SENTINELS are injection FIXTURES, so they live in the COURTS: the
        # main files carry the VOCABULARY, the courts carry the private data
        kcourt = (ROOT / "android/mesh/src/test/java/io/godstone/mesh/readiness/"
                         "ReadinessT71Test.kt").read_text(encoding="utf-8")
        scourt = (ROOT / "ios/Godstone/Tests/GodstoneMeshTests/"
                         "ReadinessT71Tests.swift").read_text(encoding="utf-8")
        for sentinel in (SENTINEL_BODY, SENTINEL_KEY, SENTINEL_NODE_ID):
            self.assertIn(sentinel, kcourt, "the Android court must inject the same sentinel")
            self.assertIn(sentinel, scourt, "and so must the iOS court")
        # ... and every metric name this lane carrieth is in the other two
        for metric in METRIC_NAMES:
            self.assertIn('"%s"' % metric, ktext, metric)
            self.assertIn('"%s"' % metric, stext, metric)


if __name__ == "__main__":
    unittest.main(verbosity=2)
