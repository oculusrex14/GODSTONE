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

        self.nodes = [
            Node(node_id=i,
                 x=self.rng.uniform(0, scenario.area_m),
                 y=self.rng.uniform(0, scenario.area_m),
                 battery=self.rng.uniform(*scenario.initial_battery),
                 charging=self.rng.random() < scenario.charging_fraction)
            for i in range(node_count)
        ]

    # -- radio ------------------------------------------------------------

    def neighbours(self, node: Node) -> list[Node]:
        r2 = self.scenario.range_m ** 2
        out = []
        for other in self.nodes:
            if other.node_id == node.node_id or not other.alive:
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
                if message.delivered_tick is None and message.destination != -1:
                    message.delivered_tick = self.tick

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

        # Store and forward: retry anything queued for a peer now in range.
        if node.pending and node.will_relay():
            in_range = {p.node_id for p in self.neighbours(node)}
            still: list[Message] = []
            for message in node.pending:
                if message.destination in in_range or message.destination == -1:
                    self.transmit(node, message)
                else:
                    still.append(message)
            node.pending = still[-self.scenario.pending_capacity:]

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
            if destination != -1 and destination not in \
                    {p.node_id for p in self.neighbours(source)}:
                source.pending.append(message)
                source.pending = source.pending[-self.scenario.pending_capacity:]
            self.transmit(source, message)

    # -- main loop --------------------------------------------------------

    def run(self, ticks: int) -> dict:
        for self.tick in range(ticks):
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

    if args.assert_delivery is not None:
        if result["delivery_ratio"] < args.assert_delivery:
            raise SystemExit(
                f"FAIL delivery ratio {result['delivery_ratio']:.3f} "
                f"below required {args.assert_delivery:.3f}"
            )
        print(f"PASS delivery ratio meets {args.assert_delivery:.3f}")


if __name__ == "__main__":
    main()
