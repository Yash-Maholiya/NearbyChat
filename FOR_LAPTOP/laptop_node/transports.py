"""In-memory 'radio' used by the tests. The real transport is Bluetooth LE (ble_windows.py);
there is deliberately no WiFi or internet transport."""
from __future__ import annotations

import asyncio
from typing import Dict


class LoopbackHub:
    """Links are explicit (who is in radio range of whom); packets are delivered asynchronously."""

    def __init__(self):
        self.nodes: Dict[str, object] = {}
        self.links: set = set()
        self.intercept = None   # optional fn(src, dst, data) -> data or None (drop)

    def connect(self, a: str, b: str) -> None:
        self.links.add(frozenset((a, b)))

    def disconnect(self, a: str, b: str) -> None:
        self.links.discard(frozenset((a, b)))
        for x, y in ((a, b), (b, a)):
            if x in self.nodes:
                self.nodes[x].drop_link("loop", y)

    def discover(self) -> None:
        """Every node learns its direct neighbours (like a BLE scan + identity read)."""
        for a, na in self.nodes.items():
            for b, nb in self.nodes.items():
                if a != b and frozenset((a, b)) in self.links:
                    na.on_neighbour(nb.public_key, nb.username, "loop", b, kind=nb.kind)


class LoopbackTransport:
    name = "loop"

    def __init__(self, hub: LoopbackHub, addr: str):
        self.hub = hub
        self.addr = addr
        self.node = None

    async def start(self, node) -> None:
        self.node = node
        self.hub.nodes[self.addr] = node

    async def send(self, addr: str, data: bytes) -> bool:
        if frozenset((self.addr, addr)) not in self.hub.links or addr not in self.hub.nodes:
            return False
        if self.hub.intercept:
            data = self.hub.intercept(self.addr, addr, data)
            if data is None:
                return True
        asyncio.get_running_loop().call_soon(
            lambda: asyncio.ensure_future(self.hub.nodes[addr].on_packet(data, "loop", self.addr)))
        return True

    async def stop(self) -> None:
        pass
