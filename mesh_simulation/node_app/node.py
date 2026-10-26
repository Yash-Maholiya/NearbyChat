"""
Core MeshNode implementation: UDP transport, signed HELLO discovery, reverse-path routing with
alternate routes, end-to-end encrypted DATA, signed ACKs, retransmission, replay defence and
relay trust scoring.

Routing modes
  flood     : every DATA/ACK is flooded to all neighbours (duplicate cache stops loops)
  shortest  : unicast to the learned next hop with the fewest hops, flood when no route is known
  trust     : like shortest, but prefers the neighbour with the best relay trust score

Security modes
  secure=True  : SealedBox payload + Ed25519 signature + identity checks (normal operation)
  secure=False : plaintext payload, no signatures (baseline used only to measure overhead)
"""

import base64
import json
import logging
import random
import socket
import threading
import time
import uuid
from typing import Dict, List, Optional, Set, Tuple

from .crypto import NodeCrypto, node_id_from_verify_key
from .protocol import MAX_PAYLOAD_BYTES, Packet, PacketType
from .routing import NeighborTable, RelayTrustScore, ReplayCache, RouteTable
from .trust import TrustedRegistry

logging.basicConfig(level=logging.INFO, format='[%(asctime)s] [%(name)s] %(levelname)s: %(message)s')

Address = Tuple[str, int]


class PendingMessage:
    def __init__(self, mid: str, dest_id: str, payload: str):
        now = time.time()
        self.mid = mid
        self.dest_id = dest_id
        self.payload = payload
        self.first_sent = now
        self.last_sent = now
        self.attempt = 0
        self.next_hop: Optional[str] = None
        self.failed_hops: Set[str] = set()
        self.status = "pending"  # pending | delivered | failed
        self.acked_at: Optional[float] = None
        self.ack_hops: Optional[int] = None
        self.packet_size = 0
        self.event = threading.Event()


class MeshNode:
    def __init__(
        self,
        name: str,
        host: str = "127.0.0.1",
        port: int = 9001,
        trusted_keys=None,
        drop_ratio: float = 0.0,
        crypto: Optional[NodeCrypto] = None,
        routing_mode: str = "shortest",
        secure: bool = True,
        enforce_trust: bool = False,
        hello_interval: float = 5.0,
        neighbor_timeout: float = 15.0,
        ack_timeout: float = 2.0,
        max_retries: int = 3,
        default_ttl: int = 6,
        trust_threshold: float = 0.5,
        rate_limit_per_sec: int = 500,
        seed: Optional[int] = None,
        event_log_path: Optional[str] = None,
        broadcast_addr: Optional[str] = None,
        bootstrap_peers: Optional[List[Address]] = None,
        verbose: bool = True,
    ):
        if routing_mode not in ("flood", "shortest", "trust"):
            raise ValueError("routing_mode must be flood, shortest or trust")
        self.name = name
        self.host = host
        self.port = port
        self.crypto = crypto or NodeCrypto()
        self.node_id = self.crypto.node_id
        if isinstance(trusted_keys, TrustedRegistry):
            self.registry = trusted_keys
        else:
            self.registry = TrustedRegistry(trusted_keys or {})
        self.drop_ratio = drop_ratio  # Simulates malicious or congested dropper relay
        self.routing_mode = routing_mode
        self.secure = secure
        self.enforce_trust = enforce_trust
        self.hello_interval = hello_interval
        self.ack_timeout = ack_timeout
        self.max_retries = max_retries
        self.default_ttl = default_ttl
        self.trust_threshold = trust_threshold
        self.rate_limit_per_sec = rate_limit_per_sec
        self.broadcast_addr = broadcast_addr
        self.bootstrap_peers: List[Address] = list(bootstrap_peers or [])
        self.event_log_path = event_log_path

        self.neighbors = NeighborTable(timeout_seconds=neighbor_timeout)
        self.replay_cache = ReplayCache()
        self.trust_scores = RelayTrustScore()
        self.routes = RouteTable()

        # Simulated radio range: address -> loss probability. None = no restriction (real network).
        self.radio_links: Optional[Dict[Address, float]] = None
        self._radio_lock = threading.Lock()
        self.rng = random.Random(seed)

        self.inbox: List[dict] = []
        self.acknowledged_messages: set = set()
        self.security_events: List[dict] = []
        self.metrics: List[dict] = []
        self.pending: Dict[str, PendingMessage] = {}
        self._delivered_ids: Set[str] = set()
        self._last_hello_ts: Dict[str, float] = {}
        self._rate_window: Dict[Address, List[float]] = {}
        self.capture_enabled = False
        self.captured: List[bytes] = []
        self.stats = {
            "sent_packets": 0, "sent_bytes": 0, "recv_packets": 0, "forwarded": 0,
            "dropped_loss": 0, "dropped_dropper": 0, "dropped_out_of_range": 0,
            "duplicates": 0, "retransmissions": 0,
        }

        self._socket: Optional[socket.socket] = None
        self._running = False
        self._threads: List[threading.Thread] = []
        self._seq = 0
        self._seq_lock = threading.Lock()
        self._state_lock = threading.RLock()
        self._last_hello_sent = 0.0
        self.logger = logging.getLogger(f"Node-{self.name}")
        if not verbose:
            self.logger.setLevel(logging.WARNING)

    # ------------------------------------------------------------------ lifecycle

    def start(self) -> None:
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if self.broadcast_addr:
            self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.bind((self.host if not self.broadcast_addr else "", self.port))
        self.port = self._socket.getsockname()[1]
        self._socket.settimeout(0.2)
        self._running = True
        for target in (self._listen_loop, self._maintenance_loop):
            t = threading.Thread(target=target, daemon=True)
            t.start()
            self._threads.append(t)
        self.logger.info(f"Node started at {self.host}:{self.port} with ID {self.node_id}")

    def stop(self) -> None:
        self._running = False
        for t in self._threads:
            if t.is_alive():
                t.join(timeout=2.0)
        self._threads = []
        if self._socket:
            self._socket.close()
            self._socket = None

    @property
    def address(self) -> Address:
        return (self.host, self.port)

    # ------------------------------------------------------------------ radio model

    def set_radio_links(self, links: Dict[Address, float]) -> None:
        with self._radio_lock:
            self.radio_links = dict(links)

    def add_radio_link(self, addr: Address, loss: float = 0.0) -> None:
        with self._radio_lock:
            if self.radio_links is None:
                self.radio_links = {}
            self.radio_links[tuple(addr)] = loss

    def remove_radio_link(self, addr: Address) -> None:
        with self._radio_lock:
            if self.radio_links is not None:
                self.radio_links.pop(tuple(addr), None)

    def _radio_targets(self) -> List[Address]:
        with self._radio_lock:
            return list(self.radio_links.keys()) if self.radio_links is not None else []

    # ------------------------------------------------------------------ helpers

    def _next_seq(self) -> int:
        with self._seq_lock:
            self._seq += 1
            return self._seq

    def _sign(self, packet: Packet) -> None:
        packet.secure = self.secure
        if self.secure:
            sig = self.crypto.sign(packet.canonical_bytes())
            packet.signature = base64.b64encode(sig).decode('utf-8')

    def _log_security_event(self, event_type: str, packet: Packet, detail: str = "") -> None:
        event = {
            "type": event_type,
            "packet": packet.hash_prefix(),
            "mid": packet.message_id,
            "sender": packet.sender_id,
            "detail": detail,
            "time": time.time(),
        }
        with self._state_lock:
            self.security_events.append(event)
        self._write_log(event)
        if event_type != "DUPLICATE_SUPPRESSED":
            self.logger.warning(f"Security event: {event_type} for packet {packet.message_id} ({detail})")

    def _write_log(self, record: dict) -> None:
        if not self.event_log_path:
            return
        try:
            with open(self.event_log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(dict(record, node=self.name)) + "\n")
        except OSError:
            pass

    def _record_relay_tamper(self, sender_addr: Address) -> None:
        n = self.neighbors.by_address(sender_addr)
        if n is not None:
            self.trust_scores.record_tamper(n.node_id)
            self.logger.warning(f"Recorded tamper penalty for neighbor {n.node_id} at {sender_addr}")

    def lookup_public_key(self, node_id: str) -> Optional[str]:
        pk = self.registry.public_key(node_id)
        if pk:
            return pk
        n = self.neighbors.get(node_id)
        return n.public_key_b64 if n else None

    # ------------------------------------------------------------------ sending

    def _send_raw(self, packet: Packet, host: str, port: int) -> None:
        if not self._socket:
            return
        addr = (host, port)
        with self._radio_lock:
            if self.radio_links is not None and addr not in self.radio_links:
                self.stats["dropped_out_of_range"] += 1
                return
            loss = self.radio_links.get(addr, 0.0) if self.radio_links is not None else 0.0
        if loss > 0 and self.rng.random() < loss:
            self.stats["dropped_loss"] += 1
            return
        data = packet.to_json().encode('utf-8')
        try:
            self._socket.sendto(data, addr)
            self.stats["sent_packets"] += 1
            self.stats["sent_bytes"] += len(data)
        except OSError as e:
            self.logger.error(f"Failed to send to {host}:{port}: {e}")

    def send_hello(self, target_host: Optional[str] = None, target_port: Optional[int] = None) -> None:
        """Sends a signed HELLO discovery packet. Without a target it goes to everything in radio range."""
        packet = Packet(
            packet_type=PacketType.HELLO,
            sender_id=self.node_id,
            sender_vk=self.crypto.verify_key_b64,
            destination_id="*",
            message_id=f"hello_{self.node_id}_{self._next_seq()}",
            seq=self._seq,
            ttl=1,
            payload=json.dumps({"name": self.name, "pk": self.crypto.public_key_b64}),
            expiry=time.time() + 30.0,
        )
        self._sign(packet)
        if target_host is not None:
            self._send_raw(packet, target_host, target_port)
            return
        targets = set(self._radio_targets())
        if self.radio_links is None:
            targets.update((n.address, n.port) for n in self.neighbors.get_active().values())
            targets.update(tuple(p) for p in self.bootstrap_peers)
        for host, port in targets:
            self._send_raw(packet, host, port)
        if self.broadcast_addr:
            self._send_raw(packet, self.broadcast_addr, self.port)

    def send_message(self, destination_id: str, dest_pk_b64: Optional[str] = None, plaintext: str = "") -> str:
        """Encrypts the payload for the recipient and sends a signed DATA packet. Returns the message id."""
        if self.secure:
            pk = dest_pk_b64 or self.lookup_public_key(destination_id)
            if not pk:
                raise ValueError(f"No public key known for destination {destination_id}")
            payload = self.crypto.encrypt_for_peer(pk, plaintext)
        else:
            payload = base64.b64encode(plaintext.encode('utf-8')).decode('utf-8')
        if len(payload) > MAX_PAYLOAD_BYTES:
            raise ValueError("Message too large")
        mid = f"msg_{self.node_id}_{uuid.uuid4().hex[:12]}"
        p = PendingMessage(mid, destination_id, payload)
        with self._state_lock:
            self.pending[mid] = p
        self._transmit_data(p)
        return mid

    def _transmit_data(self, p: PendingMessage) -> None:
        packet = Packet(
            packet_type=PacketType.DATA,
            sender_id=self.node_id,
            sender_vk=self.crypto.verify_key_b64,
            destination_id=p.dest_id,
            message_id=p.mid,
            attempt=p.attempt,
            seq=self._next_seq(),
            ttl=self.default_ttl,
            hop_count=0,
            payload=p.payload,
        )
        self._sign(packet)
        p.packet_size = packet.size_bytes()
        self.replay_cache.record(self.node_id, packet.replay_key)
        p.last_sent = time.time()
        p.next_hop = self._route_packet(packet, exclude=set(p.failed_hops), exclude_flood=set())
        if p.next_hop:
            self.trust_scores.record_forward(p.next_hop)

    def wait_for_ack(self, mid: str, timeout: float = 10.0) -> bool:
        p = self.pending.get(mid)
        if p is None:
            return mid in self.acknowledged_messages
        p.event.wait(timeout)
        return p.status == "delivered"

    def message_status(self, mid: str) -> str:
        p = self.pending.get(mid)
        return p.status if p else "unknown"

    # ------------------------------------------------------------------ routing

    def choose_next_hop(self, destination_id: str, exclude: Optional[Set[str]] = None) -> Optional[str]:
        if self.routing_mode == "flood":
            return None
        exclude = exclude or set()
        active = self.neighbors.get_active()
        if destination_id in active and destination_id not in exclude:
            return destination_id
        cands = self.routes.candidates(destination_id, set(active.keys()), exclude)
        if not cands:
            return None
        if self.routing_mode == "shortest":
            return cands[0][0]
        scored = [(self.trust_scores.get_score(v), -h, v) for v, h in cands]
        good = [c for c in scored if c[0] >= self.trust_threshold] or scored
        return max(good)[2]

    def _route_packet(self, packet: Packet, exclude: Set[str], exclude_flood: Optional[Set[str]] = None,
                      from_addr: Optional[Address] = None) -> Optional[str]:
        """Unicast to the chosen next hop, or flood when no route is known. Returns the next hop or None."""
        nh = self.choose_next_hop(packet.destination_id, exclude)
        active = self.neighbors.get_active()
        if nh and nh in active:
            n = active[nh]
            self._send_raw(packet, n.address, n.port)
            return nh
        skip = exclude if exclude_flood is None else exclude_flood
        for n in active.values():
            if n.node_id in skip or n.node_id == packet.sender_id:
                continue
            if from_addr is not None and (n.address, n.port) == tuple(from_addr):
                continue
            self._send_raw(packet, n.address, n.port)
        return None

    # ------------------------------------------------------------------ receiving

    def _listen_loop(self) -> None:
        while self._running:
            try:
                data, addr = self._socket.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            if not self._running:
                break
            if self.capture_enabled:
                self.captured.append(data)
            try:
                packet = Packet.from_dict(json.loads(data.decode('utf-8')))
            except (ValueError, KeyError, TypeError):
                continue
            try:
                self._handle_packet(packet, addr)
            except Exception as e:  # keep the node alive on any malformed input
                self.logger.error(f"Error handling packet: {e}")

    def _rate_limited(self, addr: Address) -> bool:
        now = time.time()
        window = [t for t in self._rate_window.get(addr, []) if now - t < 1.0]
        window.append(now)
        self._rate_window[addr] = window
        return len(window) > self.rate_limit_per_sec

    def _handle_packet(self, packet: Packet, sender_addr: Address) -> None:
        if packet.sender_id == self.node_id:
            return  # our own broadcast or a flood reflection
        self.stats["recv_packets"] += 1

        # 0. Flooding protections
        if self._rate_limited(tuple(sender_addr)):
            self._log_security_event("RATE_LIMITED", packet, f"from {sender_addr}")
            return
        if len(packet.payload or "") > MAX_PAYLOAD_BYTES:
            self._log_security_event("OVERSIZE_PAYLOAD", packet)
            return

        # 1. Expiry check
        if packet.is_expired():
            self._log_security_event("PACKET_EXPIRED", packet)
            return

        if self.secure:
            if not packet.secure:
                self._log_security_event("INSECURE_PACKET", packet, "Unsigned packet in secure mode")
                return
            # 2. Cryptographic signature check
            if not packet.signature:
                self._log_security_event("MISSING_SIGNATURE", packet)
                return
            try:
                sig_bytes = base64.b64decode(packet.signature)
                valid = NodeCrypto.verify(packet.sender_vk, packet.canonical_bytes(), sig_bytes)
            except (ValueError, TypeError):
                valid = False
            if not valid:
                self._log_security_event("INVALID_SIGNATURE", packet, "Tampered header or payload")
                self._record_relay_tamper(sender_addr)
                return
            # 3. Identity binding: node id must be derived from the signing key
            try:
                derived = node_id_from_verify_key(packet.sender_vk)
            except (ValueError, TypeError):
                derived = None
            if derived != packet.sender_id:
                self._log_security_event("ID_MISMATCH", packet, "Sender id does not match signing key")
                return
            # 4. Trusted enrolment
            enrolled_vk = self.registry.verify_key(packet.sender_id)
            if enrolled_vk is not None and enrolled_vk != packet.sender_vk:
                self._log_security_event("UNTRUSTED_KEY", packet, "Key substitution detected")
                return
            if self.enforce_trust and enrolled_vk is None:
                self._log_security_event("UNTRUSTED_IDENTITY", packet, "Sender not in trusted registry")
                return

        from_nb = self.neighbors.by_address(tuple(sender_addr))

        if packet.packet_type == PacketType.HELLO:
            self._handle_hello(packet, sender_addr)
            return

        # 5. Simulated dropper relay (after crypto validation, only for transit traffic)
        if self.drop_ratio > 0 and packet.destination_id != self.node_id:
            if self.rng.random() < self.drop_ratio:
                self.stats["dropped_dropper"] += 1
                self.logger.info(f"Simulated dropper dropped packet {packet.message_id}")
                return

        # Learn the reverse route from every verified copy, including flood duplicates, so an
        # alternate path is already known when the preferred one fails.
        if from_nb is not None and packet.packet_type in (PacketType.DATA, PacketType.ACK):
            self.routes.learn(packet.sender_id, from_nb.node_id, packet.hop_count + 1)

        # 6. Duplicate suppression / replay detection (per transmission attempt)
        if self.replay_cache.check_and_record(packet.sender_id, packet.replay_key):
            self.stats["duplicates"] += 1
            self._log_security_event("DUPLICATE_SUPPRESSED", packet, "Duplicate or replayed packet dropped")
            return

        if packet.packet_type == PacketType.DATA:
            self._handle_data(packet, sender_addr, from_nb)
        elif packet.packet_type == PacketType.ACK:
            self._handle_ack(packet, sender_addr, from_nb)

    def destination_id_is_not_local(self, packet: Packet) -> bool:
        return packet.destination_id != self.node_id

    def _handle_hello(self, packet: Packet, sender_addr: Address) -> None:
        last = self._last_hello_ts.get(packet.sender_id, 0.0)
        if packet.timestamp <= last:
            return  # stale or replayed HELLO
        self._last_hello_ts[packet.sender_id] = packet.timestamp
        try:
            info = json.loads(packet.payload)
            is_new = self.neighbors.update(
                node_id=packet.sender_id,
                address=sender_addr[0],
                port=sender_addr[1],
                verify_key_b64=packet.sender_vk,
                public_key_b64=info["pk"],
                name=info.get("name", ""),
            )
            self.routes.learn(packet.sender_id, packet.sender_id, 1)
            if is_new:
                self.logger.info(f"Updated neighbor: {info.get('name')} ({packet.sender_id})")
                self.send_hello(sender_addr[0], sender_addr[1])  # answer so discovery is quick
        except (ValueError, KeyError, TypeError) as e:
            self.logger.warning(f"Malformed HELLO payload: {e}")

    def _handle_data(self, packet: Packet, sender_addr: Address, from_nb) -> None:

        if packet.destination_id == self.node_id:
            with self._state_lock:
                first_time = packet.message_id not in self._delivered_ids
            if first_time:
                try:
                    if packet.secure:
                        body = self.crypto.decrypt_sealed_message(packet.payload)
                    else:
                        body = base64.b64decode(packet.payload).decode('utf-8')
                except Exception as e:
                    self._log_security_event("DECRYPTION_FAILED", packet, str(e))
                    return
                with self._state_lock:
                    self._delivered_ids.add(packet.message_id)
                    self.inbox.append({
                        "mid": packet.message_id,
                        "sender": packet.sender_id,
                        "body": body,
                        "hops": packet.hop_count,
                        "time": time.time(),
                    })
                self.logger.info(f"Message delivered from {packet.sender_id} (hops={packet.hop_count})")
            self._send_ack(packet, from_nb, sender_addr)
            return

        # Multi-hop relay forwarding
        if packet.ttl <= 1:
            self.logger.info(f"TTL expired for packet {packet.message_id}; dropping")
            return
        packet.ttl -= 1
        packet.hop_count += 1
        self.stats["forwarded"] += 1
        exclude = {from_nb.node_id} if from_nb is not None else set()
        self._route_packet(packet, exclude=exclude, from_addr=sender_addr)

    def _send_ack(self, data_packet: Packet, from_nb, sender_addr: Address) -> None:
        ack_packet = Packet(
            packet_type=PacketType.ACK,
            sender_id=self.node_id,
            sender_vk=self.crypto.verify_key_b64,
            destination_id=data_packet.sender_id,
            message_id=f"ack_{data_packet.message_id}",
            attempt=data_packet.attempt,
            seq=self._next_seq(),
            ttl=self.default_ttl,
            hop_count=0,
            payload=data_packet.message_id,
        )
        self._sign(ack_packet)
        self.replay_cache.record(self.node_id, ack_packet.replay_key)
        # Prefer the reverse path the DATA arrived on
        if from_nb is not None and from_nb.node_id in self.neighbors.get_active():
            self._send_raw(ack_packet, from_nb.address, from_nb.port)
        else:
            self._route_packet(ack_packet, exclude=set())

    def _handle_ack(self, packet: Packet, sender_addr: Address, from_nb) -> None:

        if packet.destination_id == self.node_id:
            delivered_mid = packet.payload
            with self._state_lock:
                p = self.pending.get(delivered_mid)
                if p is None or p.dest_id != packet.sender_id or p.status == "delivered":
                    return
                p.status = "delivered"
                p.acked_at = time.time()
                p.ack_hops = packet.hop_count + 1
                self.acknowledged_messages.add(delivered_mid)
            credited = p.next_hop or (from_nb.node_id if from_nb is not None else None)
            if credited:
                self.trust_scores.record_ack(credited)
            record = {
                "event": "delivered", "mid": delivered_mid, "dest": p.dest_id,
                "latency": p.acked_at - p.first_sent, "attempts": p.attempt + 1,
                "first_hop": credited, "size": p.packet_size, "time": p.acked_at,
            }
            self.metrics.append(record)
            self._write_log(record)
            p.event.set()
            self.logger.info(f"Delivery acknowledged for message {delivered_mid} via relay {credited}")
            return

        if packet.ttl <= 1:
            return
        packet.ttl -= 1
        packet.hop_count += 1
        self.stats["forwarded"] += 1
        exclude = {from_nb.node_id} if from_nb is not None else set()
        self._route_packet(packet, exclude=exclude, from_addr=sender_addr)

    # ------------------------------------------------------------------ timers

    def _maintenance_loop(self) -> None:
        while self._running:
            now = time.time()
            if now - self._last_hello_sent >= self.hello_interval:
                self._last_hello_sent = now
                self.send_hello()
            self._check_timeouts(now)
            time.sleep(0.05)

    def _check_timeouts(self, now: float) -> None:
        with self._state_lock:
            waiting = [p for p in self.pending.values() if p.status == "pending" and now - p.last_sent > self.ack_timeout]
        for p in waiting:
            if p.next_hop:
                self.trust_scores.record_drop(p.next_hop)
                p.failed_hops.add(p.next_hop)
                self.routes.invalidate(p.dest_id, p.next_hop)
            if p.attempt >= self.max_retries:
                p.status = "failed"
                record = {"event": "failed", "mid": p.mid, "dest": p.dest_id, "attempts": p.attempt + 1,
                          "time": now, "size": p.packet_size}
                self.metrics.append(record)
                self._write_log(record)
                p.event.set()
                self.logger.warning(f"Message {p.mid} failed after {p.attempt + 1} attempts")
                continue
            p.attempt += 1
            self.stats["retransmissions"] += 1
            self._transmit_data(p)

    # ------------------------------------------------------------------ introspection

    def snapshot(self) -> dict:
        active = self.neighbors.get_active()
        with self._state_lock:
            pending = [
                {"mid": p.mid, "dest": p.dest_id, "status": p.status, "attempts": p.attempt + 1,
                 "latency_ms": round((p.acked_at - p.first_sent) * 1000, 1) if p.acked_at else None}
                for p in list(self.pending.values())[-20:]
            ]
            inbox = [dict(m) for m in self.inbox[-20:]]
            events = list(self.security_events[-30:])
        return {
            "name": self.name, "node_id": self.node_id, "port": self.port,
            "routing_mode": self.routing_mode, "secure": self.secure, "drop_ratio": self.drop_ratio,
            "neighbors": [{"id": n.node_id, "name": n.name} for n in active.values()],
            "routes": self.routes.snapshot(),
            "trust": self.trust_scores.snapshot(),
            "stats": dict(self.stats),
            "outbox": pending, "inbox": inbox, "events": events,
        }
