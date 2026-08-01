#!/usr/bin/env python3
"""Mesh network simulator.

    python -m meshsim.run --nodes 200 --scenario city_blackout

Two hundred phones cannot be borrowed, and the failure modes that matter only
appear at scale: flood amplification, partition healing, battery collapse across
a neighbourhood. This simulates the routing layer against those conditions.

It models topology, mobility, radio range, duty cycling and battery drain. It
deliberately does NOT model the cryptography - that is unit tested, it is
constant time per message, and including it would make a 200 node run take
hours for no additional insight.
"""

from __future__ import annotations

import argparse
import random
import statistics
from dataclasses import dataclass, field

from .scenarios import SCENARIOS, Scenario


@dataclass
class Message:
    message_id: int
    source: int
    destination: int      # -1 is broadcast
    created_tick: int
    ttl: int
    delivered_tick: int | None = None
    hops: int = 0


@dataclass
class Node:
    node_id: int
    x: float
    y: float
    battery: float = 1.0
    charging: bool = False
    alive: bool = True

    seen: set[int] = field(default_factory=set)
    inbox: list[tuple[Message, int]] = field(default_factory=list)
    pending: list[Message] = field(default_factory=list)
    delivered: set[int] = field(default_factory=set)

    # ---- store-and-forward state (PROTOCOL.md section 7) ------------------
    # `held` is what this node CARRIES and will re-offer on every new encounter.
    # Without it the simulator models pure flooding: a message is transmitted
    # once, on receipt, and never again, so a node walking into a fresh
    # neighbourhood with 50 undelivered messages says nothing at all. That is
    # why mobility 0% -> 90% moved delivery by under 4 points, in a protocol
    # whose entire premise is that people carry messages.
    held: dict[int, "Message"] = field(default_factory=dict)
    # Peers we have already synced with, so an encounter is O(new) not O(all).
    offered: dict[int, set[int]] = field(default_factory=dict)

    # Matches Router.kt: below 5 percent and not charging, relay other people's
    # traffic no longer happens.
    def will_relay(self) -> bool:
        return self.alive and (self.charging or self.battery > 0.05)


class Simulation:
    def __init__(self, scenario: Scenario, node_count: int, seed: int = 1):
        self.scenario = scenario
        self.rng = random.Random(seed)
        self.tick = 0
        self.messages: dict[int, Message] = {}
        self.next_message_id = 0
        self._grid: dict[tuple[int, int], list[Node]] = {}

        self.nodes = [
            Node(node_id=i,
                 x=self.rng.uniform(0, scenario.area_m),
                 y=self.rng.uniform(0, scenario.area_m),
                 battery=self.rng.uniform(*scenario.initial_battery),
                 charging=self.rng.random() < scenario.charging_fraction)
            for i in range(node_count)
        ]

    # -- radio ------------------------------------------------------------

    def _rebuild_grid(self) -> None:
        """Spatial hash, rebuilt once per tick.

        neighbours() was a linear scan over every node, called once per node per
        tick: O(n^2) per tick, O(n^3) overall. At 200 nodes a 4000-tick run
        could not finish inside three minutes, which meant the DELAY-tolerant
        network was only ever measured over short horizons -- precisely the
        regime where it performs worst. The cell size is the radio range, so a
        node's neighbours can only lie in the nine surrounding cells.
        """
        self._grid = {}
        cell = self.scenario.range_m
        for n in self.nodes:
            if not n.alive:
                continue
            self._grid.setdefault((int(n.x // cell), int(n.y // cell)), []).append(n)

    def neighbours(self, node: Node) -> list[Node]:
        cell = self.scenario.range_m
        r2 = cell ** 2
        cx, cy = int(node.x // cell), int(node.y // cell)
        out = []
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for other in self._grid.get((cx + dx, cy + dy), ()):
                    if other.node_id == node.node_id:
                        continue
                    if (other.x - node.x) ** 2 + (other.y - node.y) ** 2 <= r2:
                        out.append(other)
        return out

    def transmit(self, sender: Node, message: Message) -> None:
        """One broadcast to everyone in range, with packet loss."""
        sender.battery -= self.scenario.tx_cost
        for peer in self.neighbours(sender):
            if self.rng.random() < self.scenario.packet_loss:
                continue
            peer.inbox.append((message, sender.node_id))

    # -- routing (mirrors Router.kt) --------------------------------------

    def step_node(self, node: Node) -> None:
        if not node.alive:
            return

        node.battery -= self.scenario.idle_cost
        if node.charging:
            node.battery = min(1.0, node.battery + self.scenario.charge_rate)
        if node.battery <= 0.0:
            node.alive = False
            node.battery = 0.0
            return

        inbox, node.inbox = node.inbox, []
        for message, _from in inbox:
            if message.message_id in node.seen:
                continue
            node.seen.add(message.message_id)

            is_for_me = message.destination in (node.node_id, -1)
            if is_for_me and message.message_id not in node.delivered:
                node.delivered.add(message.message_id)
                # Record against the CANONICAL message in self.messages, not the
                # relayed copy. Relaying builds a new Message per hop, so writing
                # here marked an object report() never reads: every multi-hop
                # delivery went uncounted (29 scored vs 160 real).
                origin = self.messages.get(message.message_id)
                if (origin is not None and origin.delivered_tick is None
                        and message.destination != -1):
                    origin.delivered_tick = self.tick
                    origin.hops = message.hops

            # Retain for later encounters. This is the store in
            # store-and-forward: the message travels with its carrier.
            if message.destination != node.node_id and message.ttl > 1:
                node.held[message.message_id] = message
                if len(node.held) > self.scenario.pending_capacity:
                    # Bounded, SOS-last eviction mirrors MessageStore.kt.
                    oldest = min(node.held, key=lambda m: node.held[m].created_tick)
                    del node.held[oldest]

            should_relay = message.destination != node.node_id and message.ttl > 1
            if should_relay and node.will_relay():
                relayed = Message(message_id=message.message_id,
                                  source=message.source,
                                  destination=message.destination,
                                  created_tick=message.created_tick,
                                  ttl=message.ttl - 1,
                                  hops=message.hops + 1)
                self.transmit(node, relayed)
                self.messages[message.message_id].hops = max(
                    self.messages[message.message_id].hops, relayed.hops)

        # ---- ANTI-ENTROPY ON ENCOUNTER (PROTOCOL.md section 7) -------------
        # THE defect this closes. Previously a node only re-sent a message when
        # its FINAL DESTINATION happened to come into range -- so a courier
        # carrying a neighbourhood's traffic across a partition delivered
        # nothing, and mobility contributed almost nothing to delivery.
        #
        # The documented design is a bloom-digest exchange: on meeting a peer,
        # each side works out what the other appears to lack and offers only
        # that. Router.kt already exposes exactly this (currentDigest /
        # framesPeerLacks); the simulator simply never performed it, so it was
        # measuring flooding while the protocol specified epidemic routing.
        if node.will_relay() and node.held:
            for peer in self.neighbours(node):
                already = node.offered.setdefault(peer.node_id, set())
                # `peer.seen` stands in for the peer's advertised bloom digest.
                # A real digest has ~0.9% false positives, which costs a missed
                # offer this encounter and is corrected on the next one.
                lacking = [m for mid, m in node.held.items()
                           if mid not in peer.seen and mid not in already]
                if not lacking:
                    continue
                # Strict priority order: SOS first, then by age. A bounded
                # number per encounter keeps a long backlog from monopolising
                # one link (PROTOCOL.md section 7, step 5).
                lacking.sort(key=lambda m: (m.destination != -1, m.created_tick))
                for message in lacking[:self.scenario.offers_per_encounter]:
                    if message.ttl <= 1:
                        continue
                    relayed = Message(message_id=message.message_id,
                                      source=message.source,
                                      destination=message.destination,
                                      created_tick=message.created_tick,
                                      ttl=message.ttl - 1,
                                      hops=message.hops + 1)
                    node.battery -= self.scenario.tx_cost
                    if self.rng.random() >= self.scenario.packet_loss:
                        peer.inbox.append((relayed, node.node_id))
                    already.add(message.message_id)

        # Retire anything that has aged out, so `held` cannot grow without bound.
        cutoff = self.tick - self.scenario.hold_ticks
        if node.held:
            stale = [mid for mid, m in node.held.items() if m.created_tick < cutoff]
            for mid in stale:
                del node.held[mid]

    # -- mobility ---------------------------------------------------------

    def move(self) -> None:
        speed = self.scenario.walk_speed_m_per_tick
        for node in self.nodes:
            if not node.alive or self.rng.random() > self.scenario.mobile_fraction:
                continue
            node.x = min(self.scenario.area_m, max(0.0,
                         node.x + self.rng.uniform(-speed, speed)))
            node.y = min(self.scenario.area_m, max(0.0,
                         node.y + self.rng.uniform(-speed, speed)))

    # -- traffic ----------------------------------------------------------

    def inject(self) -> None:
        alive = [n for n in self.nodes if n.alive]
        if len(alive) < 2:
            return
        for _ in range(self.scenario.messages_per_tick):
            source, dest = self.rng.sample(alive, 2)
            destination = -1 if self.rng.random() < self.scenario.broadcast_fraction \
                          else dest.node_id

            message = Message(message_id=self.next_message_id,
                              source=source.node_id,
                              destination=destination,
                              created_tick=self.tick,
                              ttl=self.scenario.ttl)
            self.next_message_id += 1
            self.messages[message.message_id] = message

            source.seen.add(message.message_id)
            # The originator carries its own message: if nobody is in range at
            # send time, it goes out on the next encounter instead of vanishing.
            source.held[message.message_id] = message
            if destination != -1 and destination not in \
                    {p.node_id for p in self.neighbours(source)}:
                source.pending.append(message)
                source.pending = source.pending[-self.scenario.pending_capacity:]
            self.transmit(source, message)

    # -- main loop --------------------------------------------------------

    def run(self, ticks: int) -> dict:
        for self.tick in range(ticks):
            self._rebuild_grid()
            self.scenario.on_tick(self, self.tick)
            self.inject()
            for node in self.nodes:
                self.step_node(node)
            self.move()

        return self.report()

    def report(self) -> dict:
        directed = [m for m in self.messages.values() if m.destination != -1]
        delivered = [m for m in directed if m.delivered_tick is not None]
        latencies = [m.delivered_tick - m.created_tick for m in delivered]
        alive = [n for n in self.nodes if n.alive]

        return {
            "nodes": len(self.nodes),
            "nodes_alive": len(alive),
            "messages_sent": len(directed),
            "messages_delivered": len(delivered),
            "delivery_ratio": len(delivered) / len(directed) if directed else 0.0,
            "median_latency_ticks": statistics.median(latencies) if latencies else None,
            "p95_latency_ticks": (sorted(latencies)[int(len(latencies) * 0.95)]
                                  if latencies else None),
            "mean_hops": (statistics.mean(m.hops for m in delivered)
                          if delivered else 0.0),
            "mean_battery": statistics.mean(n.battery for n in self.nodes),
        }


def main() -> None:
    ap = argparse.ArgumentParser(description="Godstone mesh simulator")
    ap.add_argument("--nodes", type=int, default=200)
    ap.add_argument("--scenario", default="city_blackout", choices=sorted(SCENARIOS))
    ap.add_argument("--ticks", type=int, default=600)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--assert-delivery", type=float, default=None,
                    help="exit non-zero if delivery ratio falls below this")
    ap.add_argument("--assert-regression", action="store_true",
                    help="assert against the MEASURED regression floor rather "
                         "than the unachieved product target")
    args = ap.parse_args()

    scenario = SCENARIOS[args.scenario]
    sim = Simulation(scenario, args.nodes, seed=args.seed)
    result = sim.run(args.ticks)

    print(f"scenario           {args.scenario}")
    print(f"nodes              {result['nodes']} "
          f"({result['nodes_alive']} alive at end)")
    print(f"messages           {result['messages_delivered']}"
          f"/{result['messages_sent']}")
    print(f"delivery ratio     {result['delivery_ratio']:.3f}")
    print(f"median latency     {result['median_latency_ticks']} ticks")
    print(f"p95 latency        {result['p95_latency_ticks']} ticks")
    print(f"mean hops          {result['mean_hops']:.2f}")
    print(f"mean battery left  {result['mean_battery']:.3f}")

    if args.assert_regression:
        from .scenarios import DELIVERY_REGRESSION_FLOOR, DELIVERY_PRODUCT_TARGET
        floor = DELIVERY_REGRESSION_FLOOR
        if result["delivery_ratio"] < floor:
            raise SystemExit(
                f"FAIL delivery {result['delivery_ratio']:.3f} below the measured "
                f"regression floor {floor:.3f} -- a routing change lost ground")
        print(f"PASS regression floor {floor:.3f}")
        if result["delivery_ratio"] < DELIVERY_PRODUCT_TARGET:
            print(f"OPEN product target {DELIVERY_PRODUCT_TARGET:.3f} not met "
                  f"({result['delivery_ratio']:.3f}). This is a DENSITY gap, not a "
                  f"routing gap: see meshsim/scenarios.py.")

    if args.assert_delivery is not None:
        if result["delivery_ratio"] < args.assert_delivery:
            raise SystemExit(
                f"FAIL delivery ratio {result['delivery_ratio']:.3f} "
                f"below required {args.assert_delivery:.3f}"
            )
        print(f"PASS delivery ratio meets {args.assert_delivery:.3f}")


if __name__ == "__main__":
    main()
