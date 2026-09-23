"""
Routing, duplicate suppression cache, neighbor tracking, and relay trust scoring.
"""

import threading
import time
from typing import Dict, Optional, Tuple


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

    def record(self, sender_id: str, message_id: str) -> None:
        with self._lock:
            if len(self._cache) >= self.capacity:
                # Evict oldest entry
                oldest_key = min(self._cache, key=self._cache.get)
                del self._cache[oldest_key]
            self._cache[(sender_id, message_id)] = time.time()

    def prune(self) -> None:
        with self._lock:
            self._prune_locked()

    def _prune_locked(self) -> None:
        now = time.time()
        stale_keys = [k for k, t in self._cache.items() if now - t > self.ttl_seconds]
        for k in stale_keys:
            del self._cache[k]


class Neighbor:
    def __init__(self, node_id: str, address: str, port: int, verify_key_b64: str, public_key_b64: str):
        self.node_id = node_id
        self.address = address
        self.port = port
        self.verify_key_b64 = verify_key_b64
        self.public_key_b64 = public_key_b64
        self.last_seen = time.time()

    def is_alive(self, timeout_seconds: float = 15.0) -> bool:
        return (time.time() - self.last_seen) <= timeout_seconds


class NeighborTable:
    def __init__(self, timeout_seconds: float = 15.0):
        self.timeout_seconds = timeout_seconds
        self._neighbors: Dict[str, Neighbor] = {}
        self._lock = threading.Lock()

    def update(self, node_id: str, address: str, port: int, verify_key_b64: str, public_key_b64: str) -> None:
        with self._lock:
            if node_id in self._neighbors:
                n = self._neighbors[node_id]
                n.address = address
                n.port = port
                n.verify_key_b64 = verify_key_b64
                n.public_key_b64 = public_key_b64
                n.last_seen = time.time()
            else:
                self._neighbors[node_id] = Neighbor(
                    node_id=node_id,
                    address=address,
                    port=port,
                    verify_key_b64=verify_key_b64,
                    public_key_b64=public_key_b64,
                )

    def get_active(self) -> Dict[str, Neighbor]:
        with self._lock:
            return {
                nid: n for nid, n in self._neighbors.items()
                if n.is_alive(self.timeout_seconds)
            }

    def remove(self, node_id: str) -> None:
        with self._lock:
            self._neighbors.pop(node_id, None)


class RelayTrustScore:
    """Calculates observable forwarding reliability scores without inspecting payload content."""
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
            stats = self._ensure_relay(relay_id)
            stats["forwarded"] += 1

    def record_ack(self, relay_id: str) -> None:
        with self._lock:
            stats = self._ensure_relay(relay_id)
            stats["acknowledged"] += 1

    def record_drop(self, relay_id: str) -> None:
        with self._lock:
            stats = self._ensure_relay(relay_id)
            stats["dropped"] += 1

    def record_tamper(self, relay_id: str) -> None:
        with self._lock:
            stats = self._ensure_relay(relay_id)
            stats["tampered"] += 1

    def get_score(self, relay_id: str) -> float:
        with self._lock:
            stats = self._ensure_relay(relay_id)
            total = stats["forwarded"]
            if total == 0:
                return self.default_score

            # Success ratio with heavy penalty for observed tampering
            ratio = stats["acknowledged"] / total
            penalty = stats["tampered"] * 0.3
            score = max(0.0, min(1.0, ratio - penalty))
            return round(score, 2)
