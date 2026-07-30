"""Simulation scenarios.

Each scenario is a set of conditions the mesh is expected to survive. They are
drawn from the situations the product exists for, not from convenient network
topologies.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable


@dataclass
class Scenario:
    name: str
    description: str

    area_m: float = 1000.0
    range_m: float = 80.0            # BLE in an urban environment, pessimistic
    packet_loss: float = 0.10

    ttl: int = 8
    pending_capacity: int = 64
    messages_per_tick: int = 2
    broadcast_fraction: float = 0.15

    initial_battery: tuple[float, float] = (0.4, 1.0)
    charging_fraction: float = 0.10
    idle_cost: float = 0.00008       # ~3 percent/hour listening (C4)
    tx_cost: float = 0.00002
    charge_rate: float = 0.0005

    mobile_fraction: float = 0.3
    walk_speed_m_per_tick: float = 8.0

    hook: Callable[[object, int], None] | None = field(default=None, repr=False)

    def on_tick(self, sim, tick: int) -> None:
        if self.hook is not None:
            self.hook(sim, tick)


def _blackout_hook(sim, tick: int) -> None:
    """Nobody can charge anything after the grid goes down.

    At tick 200 the last generators and power banks are gone. This is the case
    that decides whether the mesh is useful on day three or whether it has
    quietly flattened every phone in the neighbourhood.
    """
    if tick == 200:
        for node in sim.nodes:
            node.charging = False


def _crowd_hook(sim, tick: int) -> None:
    """Everyone converges on one point, then disperses.

    Dense clustering is the worst case for a flooding protocol: every node hears
    every other node and the duplicate suppression is all that stands between
    the mesh and a broadcast storm.
    """
    if tick == 150:
        centre = sim.scenario.area_m / 2
        for node in sim.nodes:
            node.x = centre + (node.x - centre) * 0.15
            node.y = centre + (node.y - centre) * 0.15


def _partition_hook(sim, tick: int) -> None:
    """A river, a motorway or a collapsed block splits the map in two.

    Messages must queue rather than vanish, and must flow when a courier - one
    mobile node - crosses between the halves. Store and forward is the only
    reason this scenario delivers anything at all.
    """
    if tick == 100:
        for node in sim.nodes:
            if node.node_id % 2 == 0:
                node.x = min(node.x, sim.scenario.area_m * 0.3)
            else:
                node.x = max(node.x, sim.scenario.area_m * 0.7)


SCENARIOS: dict[str, Scenario] = {

    "city_blackout": Scenario(
        name="city_blackout",
        description=(
            "Dense urban area, grid down, no charging after tick 200. "
            "The reference scenario from the README."
        ),
        area_m=1000.0,
        range_m=80.0,
        packet_loss=0.12,
        charging_fraction=0.08,
        mobile_fraction=0.35,
        hook=_blackout_hook,
    ),

    "rural_sparse": Scenario(
        name="rural_sparse",
        description=(
            "Few nodes over a wide area. Most of the time nobody is in range "
            "and delivery depends entirely on store and forward."
        ),
        area_m=5000.0,
        range_m=120.0,
        packet_loss=0.06,
        mobile_fraction=0.6,
        walk_speed_m_per_tick=25.0,
        ttl=12,
    ),

    "crowd_surge": Scenario(
        name="crowd_surge",
        description=(
            "Evacuation point. Extreme density, heavy contention, high loss."
        ),
        area_m=600.0,
        range_m=60.0,
        packet_loss=0.30,
        messages_per_tick=6,
        broadcast_fraction=0.35,
        hook=_crowd_hook,
    ),

    "partition_heal": Scenario(
        name="partition_heal",
        description=(
            "The map splits in two at tick 100. Tests queueing and the courier "
            "pattern - one walker carrying a neighbourhood's messages across."
        ),
        area_m=1500.0,
        range_m=90.0,
        mobile_fraction=0.25,
        ttl=10,
        hook=_partition_hook,
    ),

    "flat_batteries": Scenario(
        name="flat_batteries",
        description=(
            "Everyone starts nearly flat. Verifies the relay suppression floor "
            "keeps nodes alive as leaves instead of letting them die relaying."
        ),
        initial_battery=(0.05, 0.25),
        charging_fraction=0.02,
        idle_cost=0.00015,
    ),
}
