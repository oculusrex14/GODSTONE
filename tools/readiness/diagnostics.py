#!/usr/bin/env python3
"""Bounded local diagnostics, with no private telemetry (T71).

"Correctness under load needs measurable limits, but this offline app must not
introduce tracking."

So this module is deliberately SMALL and deliberately BLUNT:

  * OPT-IN. The default mode is OFF, and an OFF recorder counteth nothing and
    ringeth nothing -- a build that was never asked for diagnostics carrieth none.
  * A FIXED METRIC VOCABULARY. A counter may only be named from
    [METRIC_NAMES]; an unknown name is REFUSED rather than admitted, because free
    names are how a peer id, a message id or a body fragment endeth up in a metric
    label.
  * BOUNDED COUNTERS. Each counter is a saturating integer with a declared bound;
    a counter never groweth without limit and never carryeth a string value.
  * MONOTONIC DURATIONS ONLY. Durations are differences of a monotonic clock; no
    wall-clock timestamp is ever recorded, so two logs cannot be correlated by time.
  * EPHEMERAL RELATION IDS. A relation is named by a per-process counter (r1, r2,
    ...), never a node id, never a hint, and nothing is persisted: a restart
    renameth every relation, so a log line cannot identify a peer across runs.
  * A BOUNDED RING. The ring droppeth the OLDEST line when full and COUNTETH the
    supersessions, so memory is bounded under a flood and the loss is visible.
  * REDACTION BY REFUSAL. A value that is a string, a byte string, a node-id-sized
    blob or a fingerprint is REFUSED outright; the recorder accepteth numbers,
    booleans and metric names only.

THE SENTINEL LAW: the court injecteth a private sentinel (a message body, a key
byte, a node id) into the data being measured, and asserteth that the RENDERED
output carrieth it NOWHERE -- under tampered data, ten-thousand-peer churn, a queue
flood, a large archive and a cancelled inference.
"""
from __future__ import annotations

from dataclasses import dataclass, field

__all__ = [
    "MetricName", "METRIC_NAMES", "DiagnosticsMode", "DiagnosticsRefusal",
    "Diagnostics", "DiagnosticsLine", "SCENARIOS", "run_scenario",
    "SENTINEL_BODY", "SENTINEL_KEY", "SENTINEL_NODE_ID",
]


class DiagnosticsMode:
    OFF = "off"
    ON = "on"


class DiagnosticsRefusal(Exception):
    """A refused diagnostic. Raised rather than silently dropped."""


#: THE VOCABULARY. A metric may only be named from this set: free names are how
#: private data reacheth a label.
METRIC_NAMES = (
    "peers_seen",
    "peers_trusted",
    "frames_persisted",
    "frames_duplicate",
    "frames_forwarded",
    "frames_dropped_capacity",
    "queue_depth",
    "queue_superseded",
    "acks_admitted",
    "acks_refused",
    "archive_documents",
    "archive_bytes",
    "inference_started",
    "inference_cancelled",
    "inference_completed",
    "wipe_stages",
    "relations_opened",
    "relations_closed",
)
MetricName = str  # documented as one of METRIC_NAMES

#: The ring's bound: memory is bounded by CONSTRUCTION, not by hope.
RING_CAPACITY = 256

#: A counter's ceiling: saturating, so a flood cannot overflow into nonsense.
COUNTER_CEILING = 1 << 40

#: The private sentinels the court injecteth. They are deliberately un-guessable
#: strings so a leak is unambiguous.
SENTINEL_BODY = "SENTINEL-BODY-do-not-log-me-4417"
SENTINEL_KEY = "SENTINEL-KEY-do-not-log-me-8823"
SENTINEL_NODE_ID = "SENTINEL-NODE-do-not-log-me-1193"


@dataclass(frozen=True)
class DiagnosticsLine:
    """One rendered line: a metric name, a number, a monotonic duration."""
    metric: str
    value: int
    duration_micros: int
    relation: str

    def render(self) -> str:
        return "metric=%s value=%d dur_us=%d rel=%s" % (
            self.metric, self.value, self.duration_micros, self.relation)


@dataclass
class Diagnostics:
    """An opt-in, local, bounded recorder."""
    mode: str = DiagnosticsMode.OFF
    capacity: int = RING_CAPACITY
    counters: dict = field(default_factory=dict)
    lines: list = field(default_factory=list)
    superseded: int = 0
    refusals: int = 0
    _relation_seq: int = 0
    _relation_by_key: dict = field(default_factory=dict)

    # ---- mode -----------------------------------------------------------

    def enable(self) -> None:
        self.mode = DiagnosticsMode.ON

    def disable(self) -> None:
        self.mode = DiagnosticsMode.OFF

    @property
    def is_on(self) -> bool:
        return self.mode == DiagnosticsMode.ON

    # ---- counters -------------------------------------------------------

    def _check_metric(self, metric) -> str:
        if not isinstance(metric, str) or metric not in METRIC_NAMES:
            raise DiagnosticsRefusal(
                "the metric name %r is not in the vocabulary: free names are how private data "
                "reacheth a label" % (metric,))
        return metric

    def _check_value(self, value) -> int:
        # REDACTION BY REFUSAL: numbers and booleans only.
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, int):
            return max(0, min(value, COUNTER_CEILING))
        raise DiagnosticsRefusal(
            "a diagnostic value must be a number; %r is a %s, and a string is exactly how a "
            "message body or a key fragment would enter the log" % (value, type(value).__name__))

    def count(self, metric, value=1, duration_micros=0, relation_key=None) -> int:
        """Increment a counter. A metric OUTSIDE the vocabulary is REFUSED."""
        name = self._check_metric(metric)
        amount = self._check_value(value)
        if not self.is_on:
            return 0                                  # OFF recordeth nothing at all
        duration = self._check_value(duration_micros)
        current = self.counters.get(name, 0)
        updated = min(current + amount, COUNTER_CEILING)
        self.counters[name] = updated
        self._append(name, amount, duration, relation_key)
        return updated

    def gauge(self, metric, value, relation_key=None) -> int:
        """Set a gauge (never below zero, never above the ceiling)."""
        name = self._check_metric(metric)
        amount = self._check_value(value)
        if not self.is_on:
            return 0
        self.counters[name] = amount
        self._append(name, amount, 0, relation_key)
        return amount

    # ---- the ring -------------------------------------------------------

    def _append(self, metric: str, value: int, duration_micros: int, relation_key) -> None:
        line = DiagnosticsLine(metric=metric, value=value,
                               duration_micros=duration_micros,
                               relation=self.relation(relation_key))
        if len(self.lines) >= self.capacity:
            self.lines.pop(0)                          # drop-oldest, and COUNT it
            self.superseded += 1
        self.lines.append(line)

    def relation(self, key=None) -> str:
        """An EPHEMERAL relation id: per-process, opaque, never a node id.

        GS-DIAG-001: the MAP is bounded exactly as the ring is. The audit reproduced a
        ten-thousand-peer churn retaining every historic key in a SECOND unbounded map
        (`{"ring": 16, "retained_relation_keys": 10000}`): the ring dropped its lines while
        the key map grew without limit, so the recorder's memory was bounded by the number
        of peers ever seen, not by its capacity. An evicted key simply receiveth a FRESH
        ordinal if it returneth -- ephemerality is the point.
        """
        if key is None:
            self._relation_seq += 1
            return "r%d" % self._relation_seq
        # a caller may group lines of one relation, but the KEY never reacheth the
        # output: only a per-process ordinal doth
        if key not in self._relation_by_key:
            self._relation_seq += 1
            self._relation_by_key[key] = "r%d" % self._relation_seq
            while len(self._relation_by_key) > self.capacity:
                eldest = next(iter(self._relation_by_key))
                del self._relation_by_key[eldest]
                self.superseded += 1
        return self._relation_by_key[key]

    @property
    def ring_size(self) -> int:
        return len(self.lines)

    @property
    def is_bounded(self) -> bool:
        return self.ring_size <= self.capacity

    def render(self) -> str:
        """The whole output, as it would be written. THE ONLY ROAD OUT."""
        header = "diagnostics mode=%s lines=%d superseded=%d refusals=%d\n" % (
            self.mode, self.ring_size, self.superseded, self.refusals)
        return header + "\n".join(line.render() for line in self.lines)

    def reset(self) -> None:
        """Everything this recorder knoweth vanisheth -- and the relation ordinals
        restart, so a line from before cannot be correlated with one from after."""
        self.counters.clear()
        self.lines.clear()
        self.superseded = 0
        self.refusals = 0
        self._relation_seq = 0
        self._relation_by_key.clear()


# ---------------------------------------------------------------------------
# The five scenarios the card nameth
# ---------------------------------------------------------------------------

SCENARIOS = ("tampered_data", "peer_churn_10k", "queue_flood",
             "large_archive", "cancelled_inference")


def run_scenario(scenario: str, diag: Diagnostics, scale: int = 10_000) -> dict:
    """Exercise one scenario against a LIVE recorder. Returneth the census."""
    if scenario not in SCENARIOS:
        raise ValueError("unknown scenario %r" % scenario)

    if scenario == "tampered_data":
        # a tampered frame: the BODY is the sentinel, and it must never be logged
        diag.count("frames_persisted", 1, duration_micros=120)
        diag.count("frames_dropped_capacity", 1, duration_micros=0)
        for metric in ("frames_persisted", "frames_dropped_capacity"):
            diag.count(metric, 1, duration_micros=1)
        try:
            diag.count(SENTINEL_BODY)              # a body is not a metric name
        except DiagnosticsRefusal:
            diag.refusals += 1
        try:
            diag.count("peers_seen", SENTINEL_KEY)  # a key is not a number
        except DiagnosticsRefusal:
            diag.refusals += 1

    elif scenario == "peer_churn_10k":
        for peer in range(scale):
            # the PEER is a key, never an output value: the line carrieth only a
            # per-process ordinal
            diag.count("peers_seen", 1, relation_key=("peer", peer % 64))
            if peer % 3 == 0:
                diag.count("relations_opened", 1, relation_key=("peer", peer % 64))
            if peer % 5 == 0:
                diag.count("relations_closed", 1, relation_key=("peer", peer % 64))

    elif scenario == "queue_flood":
        for i in range(scale):
            diag.gauge("queue_depth", i % 512)
            diag.count("queue_superseded", 1)

    elif scenario == "large_archive":
        diag.gauge("archive_documents", scale)
        diag.gauge("archive_bytes", scale * 1024)
        diag.count("frames_persisted", 1)

    elif scenario == "cancelled_inference":
        diag.count("inference_started", 1)
        diag.count("inference_cancelled", 1)
        try:
            diag.count("inference_completed", SENTINEL_BODY)   # a body is not a count
        except DiagnosticsRefusal:
            diag.refusals += 1

    return {"scenario": scenario, "counters": dict(diag.counters),
            "ring": diag.ring_size, "superseded": diag.superseded,
            "refusals": diag.refusals, "bounded": diag.is_bounded}


def census_report(diag: Diagnostics) -> str:
    return ("mode=%s counters=%d ring=%d/%d superseded=%d refusals=%d"
            % (diag.mode, len(diag.counters), diag.ring_size, diag.capacity,
               diag.superseded, diag.refusals))


if __name__ == "__main__":
    probe = Diagnostics()
    probe.enable()
    for name in SCENARIOS:
        run_scenario(name, probe)
    print(census_report(probe))
    print(probe.render()[:400])
