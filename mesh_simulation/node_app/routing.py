"""
Routing, duplicate suppression cache, neighbor tracking, route table and relay trust scoring.
"""

import threading
import time
from typing import Dict, List, Optional, Set, Tuple


class ReplayCache:
    """Bounded duplicate suppression cache keyed by (sender_id, message_id)."""
    def __init__(self, capacity: int = 1000, ttl_seconds: float = 120.0):
        self.capacity = capacity
        self.ttl_seconds = ttl_seconds
        self._cache: Dict[Tuple[str, str], float] = {}
        self._lock = threading.Lock()

    def has_seen(self, sender_id: str, message_id: str) -> bool:
        with self._lock:
            self._prune_locked()
            return (sender_id, message_id) in self._cache

    def check_and_record(self, sender_id: str, message_id: str) -> bool:
        """Atomically returns True if already seen, otherwise records it and returns False."""
        with self._lock:
            self._prune_locked()
            key = (sender_id, message_id)
            if key in self._cache:
                return True
            self._record_locked(key)
            return False

    def record(self, sender_id: str, message_id: str) -> None:
        with self._lock:
            self._record_locked((sender_id, message_id))

    def _record_locked(self, key: Tuple[str, str]) -> None:
        if len(self._cache) >= self.capacity and key not in self._cache:
            oldest_key = min(self._cache, key=self._cache.get)
            del self._cache[oldest_key]
        self._cache[key] = time.time()

    def prune(self) -> None:
        with self._lock:
            self._prune_locked()

    def _prune_locked(self) -> None:
        now = time.time()
        stale_keys = [k for k, t in self._cache.items() if now - t > self.ttl_seconds]
        for k in stale_keys:
            del self._cache[k]


class Neighbor:
    def __init__(self, node_id: str, address: str, port: int, verify_key_b64: str, public_key_b64: str, name: str = ""):
        self.node_id = node_id
        self.address = address
        self.port = port
        self.verify_key_b64 = verify_key_b64
        self.public_key_b64 = public_key_b64
        self.name = name
        self.last_seen = time.time()

    def is_alive(self, timeout_seconds: float = 15.0) -> bool:
        return (time.time() - self.last_seen) <= timeout_seconds


class NeighborTable:
    def __init__(self, timeout_seconds: float = 15.0):
        self.timeout_seconds = timeout_seconds
        self._neighbors: Dict[str, Neighbor] = {}
        self._lock = threading.Lock()

    def update(self, node_id: str, address: str, port: int, verify_key_b64: str, public_key_b64: str, name: str = "") -> bool:
        """Returns True if this is a new (or revived) neighbor."""
        with self._lock:
            n = self._neighbors.get(node_id)
            if n is not None:
                revived = not n.is_alive(self.timeout_seconds)
                n.address = address
                n.port = port
                n.verify_key_b64 = verify_key_b64
                n.public_key_b64 = public_key_b64
                n.name = name or n.name
                n.last_seen = time.time()
                return revived
            self._neighbors[node_id] = Neighbor(node_id, address, port, verify_key_b64, public_key_b64, name)
            return True

    def get_active(self) -> Dict[str, Neighbor]:
        with self._lock:
            return {
                nid: n for nid, n in self._neighbors.items()
                if n.is_alive(self.timeout_seconds)
            }

    def by_address(self, addr: Tuple[str, int]) -> Optional[Neighbor]:
        with self._lock:
            for n in self._neighbors.values():
                if (n.address, n.port) == tuple(addr):
                    return n
        return None

    def get(self, node_id: str) -> Optional[Neighbor]:
        with self._lock:
            return self._neighbors.get(node_id)

    def remove(self, node_id: str) -> None:
        with self._lock:
            self._neighbors.pop(node_id, None)


class RouteTable:
    """
    Reverse-path learned routes. When a packet from ORIGIN arrives via neighbor N after h hops,
    N is a candidate next hop toward ORIGIN with cost h. Several candidates per destination are
    kept so an alternative path is available when one fails.
    """
    def __init__(self, ttl_seconds: float = 60.0):
        self.ttl_seconds = ttl_seconds
        self._routes: Dict[str, Dict[str, Tuple[int, float]]] = {}
        self._lock = threading.Lock()

    def learn(self, destination_id: str, via: str, hops: int) -> None:
        with self._lock:
            entry = self._routes.setdefault(destination_id, {})
            old = entry.get(via)
            if old is None or hops <= old[0] or time.time() - old[1] > self.ttl_seconds:
                entry[via] = (hops, time.time())
            else:
                entry[via] = (old[0], time.time())

    def invalidate(self, destination_id: str, via: str) -> None:
        with self._lock:
            self._routes.get(destination_id, {}).pop(via, None)

    def remove_via(self, via: str) -> None:
        with self._lock:
            for entry in self._routes.values():
                entry.pop(via, None)

    def candidates(self, destination_id: str, active: Set[str], exclude: Optional[Set[str]] = None) -> List[Tuple[str, int]]:
        exclude = exclude or set()
        now = time.time()
        with self._lock:
            entry = self._routes.get(destination_id, {})
            return sorted(
                [(via, hops) for via, (hops, t) in entry.items()
                 if via in active and via not in exclude and now - t <= self.ttl_seconds],
                key=lambda x: x[1],
            )

    def snapshot(self) -> Dict[str, Dict[str, int]]:
        with self._lock:
            return {d: {v: h for v, (h, _) in e.items()} for d, e in self._routes.items()}


class RelayTrustScore:
    """
    Observable forwarding reliability per neighbor, computed without inspecting payloads.
    score = acknowledged / (acknowledged + dropped) - 0.3 * tampered, clamped to [0, 1].
    This is an experimental heuristic, not proof of malicious intent.
    """
    def __init__(self, default_score: float = 1.0):
        self.default_score = default_score
        self._stats: Dict[str, dict] = {}
        self._lock = threading.Lock()

    def _ensure_relay(self, relay_id: str) -> dict:
        if relay_id not in self._stats:
            self._stats[relay_id] = {
                "forwarded": 0,
                "acknowledged": 0,
                "dropped": 0,
                "tampered": 0,
            }
        return self._stats[relay_id]

    def record_forward(self, relay_id: str) -> None:
        with self._lock:
            self._ensure_relay(relay_id)["forwarded"] += 1

    def record_ack(self, relay_id: str) -> None:
        with self._lock:
            self._ensure_relay(relay_id)["acknowledged"] += 1

    def record_drop(self, relay_id: str) -> None:
        with self._lock:
            self._ensure_relay(relay_id)["dropped"] += 1

    def record_tamper(self, relay_id: str) -> None:
        with self._lock:
            self._ensure_relay(relay_id)["tampered"] += 1

    def get_score(self, relay_id: str) -> float:
        with self._lock:
            stats = self._ensure_relay(relay_id)
            total = stats["acknowledged"] + stats["dropped"]
            ratio = self.default_score if total == 0 else stats["acknowledged"] / total
            penalty = stats["tampered"] * 0.3
            return round(max(0.0, min(1.0, ratio - penalty)), 2)

    def snapshot(self) -> Dict[str, dict]:
        with self._lock:
            ids = list(self._stats.keys())
        return {rid: dict(self._stats[rid], score=self.get_score(rid)) for rid in ids}
