"""
In-process simulated wireless mesh.

Every node is a real MeshNode with its own UDP socket on 127.0.0.1. Radio range is modelled per
node: a node can only transmit to the addresses in its radio_links, each with a loss probability.
Cutting a link removes it in both directions, so HELLOs stop and the neighbour expires, exactly as
when a station moves out of range in Mininet-WiFi.
"""

import time
from typing import Dict, Iterable, List, Optional, Tuple

from mesh_simulation.node_app.crypto import NodeCrypto
from mesh_simulation.node_app.node import MeshNode
from mesh_simulation.node_app.trust import TrustedRegistry

# Fast timers so experiments finish in seconds
FAST_TIMERS = dict(hello_interval=0.25, neighbor_timeout=0.9, ack_timeout=0.6)


class NodeMap(dict):
    """name -> MeshNode, also indexable by position (net.nodes[0])."""
    def __getitem__(self, key):
        if isinstance(key, int):
            return list(self.values())[key]
        return super().__getitem__(key)


class SimulatedNetwork:
    def __init__(
        self,
        names: Iterable[str],
        edges: Iterable[Tuple[str, str]],
        base_port: int = 0,
        loss: float = 0.0,
        secure: bool = True,
        routing_mode: str = "shortest",
        enforce_trust: bool = True,
        seed: int = 1,
        fast: bool = True,
        node_kwargs: Optional[Dict[str, dict]] = None,
        verbose: bool = False,
    ):
        self.names = list(names)
        self.edges = [tuple(e) for e in edges]
        self.loss = loss
        timers = FAST_TIMERS if fast else {}
        node_kwargs = node_kwargs or {}

        # Simulated QR enrolment: every legitimate node trusts every other's keys
        cryptos = {n: NodeCrypto() for n in self.names}
        self.registry = TrustedRegistry()
        for n, c in cryptos.items():
            self.registry.enroll(n, c.verify_key_b64, c.public_key_b64)

        self.nodes: Dict[str, MeshNode] = NodeMap()
        for i, n in enumerate(self.names):
            port = base_port + i if base_port else 0
            kwargs = dict(
                crypto=cryptos[n], trusted_keys=self.registry, secure=secure,
                routing_mode=routing_mode, enforce_trust=enforce_trust and secure,
                seed=seed * 1000 + i, verbose=verbose,
            )
            kwargs.update(timers)
            kwargs.update(node_kwargs.get(n, {}))
            self.nodes[n] = MeshNode(n, "127.0.0.1", port, **kwargs)

    def __getitem__(self, name: str) -> MeshNode:
        return self.nodes[name]

    def start(self, converge_timeout: float = 5.0) -> None:
        for node in self.nodes.values():
            node.start()
            node.set_radio_links({})
        for a, b in self.edges:
            self.connect(a, b)
        for node in self.nodes.values():
            node.send_hello()
        self.wait_converged(converge_timeout)

    def stop(self) -> None:
        for node in self.nodes.values():
            node.stop()

    def connect(self, a: str, b: str, loss: Optional[float] = None) -> None:
        loss = self.loss if loss is None else loss
        na, nb = self.nodes[a], self.nodes[b]
        na.add_radio_link(nb.address, loss)
        nb.add_radio_link(na.address, loss)
        if (a, b) not in self.edges and (b, a) not in self.edges:
            self.edges.append((a, b))

    def cut(self, a: str, b: str) -> None:
        na, nb = self.nodes[a], self.nodes[b]
        na.remove_radio_link(nb.address)
        nb.remove_radio_link(na.address)
        self.edges = [e for e in self.edges if set(e) != {a, b}]

    def set_loss(self, loss: float) -> None:
        self.loss = loss
        for a, b in self.edges:
            self.connect(a, b, loss)

    def wait_converged(self, timeout: float = 5.0) -> bool:
        """Waits until every node sees all of its radio neighbours."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            ok = True
            for a, b in self.edges:
                if self.nodes[b].node_id not in self.nodes[a].neighbors.get_active() or \
                   self.nodes[a].node_id not in self.nodes[b].neighbors.get_active():
                    ok = False
                    break
            if ok:
                return True
            time.sleep(0.05)
        return False

    def send(self, src: str, dst: str, text: str) -> str:
        d = self.nodes[dst]
        return self.nodes[src].send_message(d.node_id, d.crypto.public_key_b64, text)

    def send_and_wait(self, src: str, dst: str, text: str, timeout: float = 10.0) -> Tuple[str, bool]:
        mid = self.send(src, dst, text)
        ok = self.nodes[src].wait_for_ack(mid, timeout)
        return mid, ok

    def name_of(self, node_id: Optional[str]) -> Optional[str]:
        for n, node in self.nodes.items():
            if node.node_id == node_id:
                return n
        return None


# ---------------------------------------------------------------- standard topologies

def line(n: int = 4) -> Tuple[List[str], List[Tuple[str, str]]]:
    """NodeA <-> NodeB <-> NodeC <-> NodeD ..."""
    names = [f"Node{chr(ord('A') + i)}" for i in range(n)]
    return names, list(zip(names, names[1:]))


def alternate_path() -> Tuple[List[str], List[Tuple[str, str]]]:
    """
    Two disjoint routes from A to D:
        short route  A - B - D        (2 hops)
        long route   A - C - E - D    (3 hops)
    """
    names = ["NodeA", "NodeB", "NodeC", "NodeD", "NodeE"]
    edges = [("NodeA", "NodeB"), ("NodeB", "NodeD"), ("NodeA", "NodeC"), ("NodeC", "NodeE"), ("NodeE", "NodeD")]
    return names, edges
