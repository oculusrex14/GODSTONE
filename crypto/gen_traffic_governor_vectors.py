#!/usr/bin/env python3
"""Generate the SHARED traffic-governor budget vectors for T27 (equivalent iOS
traffic governance) -- the cross-platform parity oracle between the sealed
android abuse/PeerGovernor.kt (T26) and its new iOS PeerGovernor.swift twin.

Format (line oriented, dependency-free so BOTH the JVM test target -- which has
no JSON library -- and the Swift Foundation target parse the same bytes):

    #godstone-tgv-1
    S <name> max=<int>                                # begin scenario; fresh governor
    E <idHex> <hintHex|-> <prio> <expect0|1>          # ONE allowInbound call; expect admit bit

Every scenario runs at a single frozen instant (no refill), so each (authenticated
id, priority) bucket starts at capacity and is debited by exactly one per admitted
call: a pure integer threshold, bit-identical across the two platforms. To keep the
reference model equal to the REAL governors (which charge trust 0.05 on a token
denial and refuse a peer once trust crosses 0.25), this generator ENFORCES that no
identity accrues more than DENIALS_PER_ID token denials per scenario, so the trust
floor is never reached and admits() stays true throughout; the admit/drop decision
is then the pure bucket/bound predicate below. An over-bound FRESH identity is
denied by the global admission gate BEFORE any bucket allocation and without
charging trust (admitIdentity returns false), so those denials never touch trust.

The android parity court replays these vectors through the SEALED android governor
(authority); the iOS court replays them through the new iOS governor. Both matching
this one shared file is the cross-platform parity evidence; a divergence is a real
defect, not a fixture drift.
"""

from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "wire" / "traffic_governor_vectors.txt"

# capacity table, mirrored EXACTLY from the sealed android PeerGovernor.DEFAULT_CAPACITY.
CAPACITY = {0: 30, 1: 60, 2: 30, 3: 20, 4: 10}   # SOS DIRECT GROUP BROADCAST BULK
DENIALS_PER_ID = 8                                   # keep token denials/id < 15 (trust-floor guard)

LINES = ["#godstone-tgv-1"]


class Scenario:
    def __init__(self, name, max_peers):
        self.name = name
        self.max = max_peers
        self.events = []
        self.tracked = []
        self.tokens = {}
        self.denials = {}

    def _admit_identity(self, id_hex):
        if id_hex in self.tracked:
            return True
        if len(self.tracked) >= self.max:
            return False
        self.tracked.append(id_hex)
        return True

    def call(self, id_hex, hint_hex, prio):
        if not self._admit_identity(id_hex):
            return 0                                    # refused by the bound; no trust charge
        key = (id_hex, prio)
        if key not in self.tokens:
            self.tokens[key] = CAPACITY[prio]           # fresh bucket at capacity (frozen clock)
        if self.tokens[key] >= 1:
            self.tokens[key] -= 1
            return 1
        self.denials[id_hex] = self.denials.get(id_hex, 0) + 1
        if self.denials[id_hex] > DENIALS_PER_ID:
            raise AssertionError(
                "scenario %s id %s exceeds %d token denials; the reference model "
                "would diverge from the trust-charging governor"
                % (self.name, id_hex, DENIALS_PER_ID))
        return 0

    def run(self, id_hex, hint_hex, prio, count):
        for _ in range(count):
            exp = self.call(id_hex, hint_hex, prio)
            self.events.append((id_hex, hint_hex, prio, exp))


def emit(sc):
    LINES.append("S %s max=%d" % (sc.name, sc.max))
    for id_hex, hint_hex, prio, exp in sc.events:
        LINES.append("E %s %s %d %d" % (id_hex, hint_hex, prio, exp))


def ident(n):
    return "%032x" % n                                # distinct authenticated node id, 32 hex chars


def build():
    s = Scenario("direct_burst_at_capacity_then_drops", 64)
    s.run(ident(0xA1), "-", 1, 62)
    emit(s)

    s = Scenario("sos_spam_is_charged_not_exempt", 64)
    s.run(ident(0xB1), "-", 0, 32)
    emit(s)

    s = Scenario("per_class_isolation_no_starvation", 64)
    s.run(ident(0xC1), "-", 3, 22)
    s.run(ident(0xC1), "-", 1, 5)
    s.run(ident(0xC1), "-", 0, 3)
    emit(s)

    s = Scenario("bounded_identity_governor_under_sybil_churn", 8)
    for k in range(12):
        s.run(ident(0xD0 + k), "-", 1, 1)
    emit(s)

    s = Scenario("denial_leaves_existing_trusted_peers_intact", 64)
    s.run(ident(0xE1), "-", 1, 10)
    s.run(ident(0xE2), "-", 2, 5)
    s.run(ident(0xE3), "-", 4, 18)
    s.run(ident(0xE1), "-", 1, 2)
    s.run(ident(0xE2), "-", 2, 1)
    emit(s)

    s = Scenario("advertised_hint_is_never_the_authenticated_identity", 64)
    shared_hint = "0BADF00D"
    s.run(ident(0xF1), shared_hint, 1, 60)
    s.run(ident(0xF2), shared_hint, 1, 60)
    emit(s)

    s = Scenario("malformed_hint_does_not_collapse_distinct_identities", 64)
    s.run(ident(0x1234), "FF", 4, 10)
    s.run(ident(0x5678), "-", 4, 10)
    emit(s)


def main():
    build()
    OUT.write_text("\n".join(LINES) + "\n", encoding="utf-8")
    ev = sum(1 for l in LINES if l.startswith("E "))
    sc = sum(1 for l in LINES if l.startswith("S "))
    print("wrote %s scenarios=%d events=%d" % (OUT, sc, ev))


if __name__ == "__main__":
    main()
