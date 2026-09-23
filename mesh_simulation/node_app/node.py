"""
Core MeshNode implementation handling UDP networking, multi-hop routing, and security policies.
"""

import base64
import json
import logging
import socket
import threading
import time
from typing import Callable, Dict, List, Optional

from .crypto import NodeCrypto
from .protocol import Packet, PacketType
from .routing import NeighborTable, ReplayCache, RelayTrustScore

logging.basicConfig(level=logging.INFO, format='[%(asctime)s] [%(name)s] %(levelname)s: %(message)s')


class MeshNode:
    def __init__(
        self,
        name: str,
        host: str = "127.0.0.1",
        port: int = 9001,
        trusted_keys: Optional[Dict[str, str]] = None,
        drop_ratio: float = 0.0,
    ):
        self.name = name
        self.host = host
        self.port = port
        self.crypto = NodeCrypto()
        self.node_id = self.crypto.node_id
        self.trusted_keys = trusted_keys or {}  # node_id -> verify_key_b64
        self.drop_ratio = drop_ratio  # Simulates malicious or congested dropper relay

        self.neighbors = NeighborTable()
        self.replay_cache = ReplayCache()
        self.trust_scores = RelayTrustScore()

        self.inbox: List[dict] = []
        self.acknowledged_messages: set = set()
        self.security_events: List[dict] = []

        self._socket: Optional[socket.socket] = None
        self._running = False
        self._listener_thread: Optional[threading.Thread] = None
        self._seq = 0
        self._seq_lock = threading.Lock()
        self._security_events_lock = threading.Lock()
        self._inbox_lock = threading.Lock()
        self.logger = logging.getLogger(f"Node-{self.name}")

    def start(self) -> None:
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.bind((self.host, self.port))
        self._running = True

        self._listener_thread = threading.Thread(target=self._listen_loop, daemon=True)
        self._listener_thread.start()
        
        self._heartbeat_thread = threading.Thread(target=self._heartbeat_loop, daemon=True)
        self._heartbeat_thread.start()
        
        self.logger.info(f"Node started at {self.host}:{self.port} with ID {self.node_id}")

    def stop(self) -> None:
        self._running = False
        if self._socket:
            # Send a dummy packet to unblock recvfrom
            try:
                self._socket.sendto(b"{}", (self.host, self.port))
            except Exception:
                pass
            self._socket.close()
            self._socket = None
        if self._listener_thread and self._listener_thread.is_alive():
            self._listener_thread.join(timeout=2.0)
        if hasattr(self, '_heartbeat_thread') and self._heartbeat_thread.is_alive():
            self._heartbeat_thread.join(timeout=2.0)

    def _heartbeat_loop(self) -> None:
        """Periodically broadcast HELLO to known neighbors to keep them alive."""
        while self._running:
            time.sleep(5.0)
            if not self._running:
                break
            # Use thread-safe get_active() instead of directly accessing _neighbors
            for n in list(self.neighbors.get_active().values()):
                self.send_hello(n.address, n.port)

    def _next_seq(self) -> int:
        with self._seq_lock:
            self._seq += 1
            return self._seq

    def _log_security_event(self, event_type: str, packet: Packet, detail: str = "") -> None:
        event = {
            "type": event_type,
            "mid": packet.message_id,
            "sender": packet.sender_id,
            "detail": detail,
            "time": time.time(),
        }
        with self._security_events_lock:
            self.security_events.append(event)
        self.logger.warning(f"Security event: {event_type} for packet {packet.message_id} ({detail})")

    def send_hello(self, target_host: str, target_port: int) -> None:
        """Sends signed HELLO discovery packet to a peer."""
        payload_data = json.dumps({
            "name": self.name,
            "pk": self.crypto.public_key_b64,
        })

        packet = Packet(
            packet_type=PacketType.HELLO,
            sender_id=self.node_id,
            sender_vk=self.crypto.verify_key_b64,
            destination_id="*",
            message_id=f"hello_{self.node_id}_{int(time.time())}",
            seq=self._next_seq(),
            ttl=1,
            payload=payload_data,
        )

        sig = self.crypto.sign(packet.canonical_bytes())
        packet.signature = base64.b64encode(sig).decode('utf-8')

        self._send_raw(packet, target_host, target_port)

    def send_message(self, destination_id: str, dest_pk_b64: str, plaintext: str) -> str:
        """Encrypts payload for recipient and broadcasts signed DATA packet to neighbors."""
        ciphertext = self.crypto.encrypt_for_peer(dest_pk_b64, plaintext)
        seq_num = self._next_seq()
        mid = f"msg_{self.node_id}_{seq_num}_{int(time.time())}"

        packet = Packet(
            packet_type=PacketType.DATA,
            sender_id=self.node_id,
            sender_vk=self.crypto.verify_key_b64,
            destination_id=destination_id,
            message_id=mid,
            seq=seq_num,
            ttl=4,
            hop_count=0,
            payload=ciphertext,
        )

        sig = self.crypto.sign(packet.canonical_bytes())
        packet.signature = base64.b64encode(sig).decode('utf-8')

        # Record locally to suppress loop reflections
        self.replay_cache.record(self.node_id, mid)

        # Forward to all active neighbors
        for neighbor in self.neighbors.get_active().values():
            self._send_raw(packet, neighbor.address, neighbor.port)
            self.trust_scores.record_forward(neighbor.node_id)

        return mid

    def _send_raw(self, packet: Packet, host: str, port: int) -> None:
        if not self._socket:
            return
        data = packet.to_json().encode('utf-8')
        try:
            self._socket.sendto(data, (host, port))
        except Exception as e:
            self.logger.error(f"Failed to send to {host}:{port}: {e}")

    def _listen_loop(self) -> None:
        while self._running:
            try:
                data, addr = self._socket.recvfrom(65535)
                if not self._running or not data or data == b"{}":
                    break
                packet_dict = json.loads(data.decode('utf-8'))
                packet = Packet.from_dict(packet_dict)
                self._handle_packet(packet, addr)
            except socket.error:
                break
            except json.JSONDecodeError:
                continue
            except Exception as e:
                self.logger.error(f"Error handling packet: {e}")
                continue

    def _handle_packet(self, packet: Packet, sender_addr: tuple) -> None:
        # 1. Expiry check
        if packet.is_expired():
            self._log_security_event("PACKET_EXPIRED", packet)
            return

        # 2. Cryptographic signature check
        if not packet.signature:
            self._log_security_event("MISSING_SIGNATURE", packet)
            return

        try:
            sig_bytes = base64.b64decode(packet.signature)
            if not NodeCrypto.verify(packet.sender_vk, packet.canonical_bytes(), sig_bytes):
                self._log_security_event("INVALID_SIGNATURE", packet, "Tampered header or payload")
                return
        except Exception as e:
            self._log_security_event("INVALID_SIGNATURE", packet, f"Malformed signature: {e}")
            return

        # 3. Trusted enrollment check (if enforced)
        if self.trusted_keys and packet.sender_id in self.trusted_keys:
            if self.trusted_keys[packet.sender_id] != packet.sender_vk:
                self._log_security_event("UNTRUSTED_KEY", packet, "Key substitution detected")
                return

        # 4. Simulated drop (dropper relay experiment) - run AFTER crypto validation
        if self.drop_ratio > 0 and self.destination_id_is_not_local(packet):
            import random
            if random.random() < self.drop_ratio:
                self.logger.info(f"Simulated dropper dropped packet {packet.message_id}")
                return

        # 5. Duplicate suppression / Replay detection
        if self.replay_cache.has_seen(packet.sender_id, packet.message_id):
            self._log_security_event("REPLAY_SUPPRESSED", packet, "Duplicate packet dropped")
            return

        self.replay_cache.record(packet.sender_id, packet.message_id)

        # 6. Process according to packet type
        if packet.packet_type == PacketType.HELLO:
            self._handle_hello(packet, sender_addr)
        elif packet.packet_type == PacketType.DATA:
            self._handle_data(packet, sender_addr)
        elif packet.packet_type == PacketType.ACK:
            self._handle_ack(packet, sender_addr)

    def destination_id_is_not_local(self, packet: Packet) -> bool:
        return packet.destination_id != self.node_id

    def _handle_hello(self, packet: Packet, sender_addr: tuple) -> None:
        try:
            info = json.loads(packet.payload)
            self.neighbors.update(
                node_id=packet.sender_id,
                address=sender_addr[0],
                port=sender_addr[1],
                verify_key_b64=packet.sender_vk,
                public_key_b64=info["pk"],
            )
            self.logger.info(f"Updated neighbor: {info['name']} ({packet.sender_id})")
        except Exception as e:
            self.logger.warning(f"Malformed HELLO payload: {e}")

    def _handle_data(self, packet: Packet, sender_addr: tuple) -> None:
        # Recipient delivery
        if packet.destination_id == self.node_id:
            try:
                decrypted = self.crypto.decrypt_sealed_message(packet.payload)
                with self._inbox_lock:
                    self.inbox.append({
                        "mid": packet.message_id,
                        "sender": packet.sender_id,
                        "body": decrypted,
                        "hops": packet.hop_count,
                        "time": time.time(),
                    })
                self.logger.info(f"Message delivered: '{decrypted}' from {packet.sender_id} (hops={packet.hop_count})")
                self._send_ack(packet)
            except Exception as e:
                self._log_security_event("DECRYPTION_FAILED", packet, str(e))
        else:
            # Multi-hop relay forwarding
            if packet.ttl <= 1:
                self.logger.info(f"TTL expired for packet {packet.message_id}; dropping")
                return

            packet.ttl -= 1
            packet.hop_count += 1

            for neighbor in self.neighbors.get_active().values():
                # Skip original sender AND the immediate relay that just forwarded to us
                if neighbor.node_id == packet.sender_id:
                    continue
                if (neighbor.address, neighbor.port) == sender_addr:
                    continue
                self._send_raw(packet, neighbor.address, neighbor.port)
                self.logger.info(f"Relayed packet {packet.message_id} to {neighbor.node_id} (ttl={packet.ttl})")

    def _send_ack(self, data_packet: Packet) -> None:
        ack_packet = Packet(
            packet_type=PacketType.ACK,
            sender_id=self.node_id,
            sender_vk=self.crypto.verify_key_b64,
            destination_id=data_packet.sender_id,
            message_id=f"ack_{data_packet.message_id}",
            seq=self._next_seq(),
            ttl=4,
            hop_count=0,
            payload=data_packet.message_id,
        )

        sig = self.crypto.sign(ack_packet.canonical_bytes())
        ack_packet.signature = base64.b64encode(sig).decode('utf-8')

        # Record locally to suppress loop reflections
        self.replay_cache.record(self.node_id, ack_packet.message_id)

        for neighbor in self.neighbors.get_active().values():
            self._send_raw(ack_packet, neighbor.address, neighbor.port)

    def _handle_ack(self, packet: Packet, sender_addr: tuple) -> None:
        if packet.destination_id == self.node_id:
            delivered_mid = packet.payload
            with self._inbox_lock:
                self.acknowledged_messages.add(delivered_mid)
            relay_neighbor_id = None
            for n in self.neighbors.get_active().values():
                if (n.address, n.port) == sender_addr:
                    relay_neighbor_id = n.node_id
                    break
            credited_id = relay_neighbor_id or packet.sender_id
            self.trust_scores.record_ack(credited_id)
            self.logger.info(f"Delivery acknowledged for message {delivered_mid} via relay {credited_id}")
        else:
            if packet.ttl <= 1:
                return
            packet.ttl -= 1
            packet.hop_count += 1
            for neighbor in self.neighbors.get_active().values():
                if neighbor.node_id == packet.sender_id:
                    continue
                if (neighbor.address, neighbor.port) == sender_addr:
                    continue
                self._send_raw(packet, neighbor.address, neighbor.port)
