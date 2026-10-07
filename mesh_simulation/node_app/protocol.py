"""
Packet protocol definition, serialization, and canonical signing encoding.
"""

import base64
import json
import time
from typing import Optional


class PacketType:
    HELLO = "HELLO"
    DATA = "DATA"
    ACK = "ACK"
    ALERT = "ALERT"


class Packet:
    def __init__(
        self,
        packet_type: str,
        sender_id: str,
        sender_vk: str,
        destination_id: str,
        message_id: str,
        seq: int,
        ttl: int = 4,
        hop_count: int = 0,
        payload: str = "",
        timestamp: Optional[float] = None,
        expiry: Optional[float] = None,
        signature: Optional[str] = None,
        version: int = 1,
    ):
        self.version = version
        self.packet_type = packet_type
        self.sender_id = sender_id
        self.sender_vk = sender_vk
        self.destination_id = destination_id
        self.message_id = message_id
        self.seq = seq
        self.timestamp = timestamp if timestamp is not None else time.time()
        self.expiry = expiry if expiry is not None else (self.timestamp + 300.0)
        self.ttl = ttl
        self.hop_count = hop_count
        self.payload = payload
        self.signature = signature

    def canonical_bytes(self) -> bytes:
        """Returns deterministic byte sequence covering all immutable fields and payload for signing."""
        canonical_dict = {
            "v": self.version,
            "type": self.packet_type,
            "sender": self.sender_id,
            "dest": self.destination_id,
            "mid": self.message_id,
            "seq": self.seq,
            "t": round(self.timestamp, 3),
            "exp": round(self.expiry, 3),
            "payload": self.payload,
        }
        return json.dumps(canonical_dict, sort_keys=True, separators=(',', ':')).encode('utf-8')

    def is_expired(self, current_time: Optional[float] = None, grace_period: float = 60.0) -> bool:
        now = current_time if current_time is not None else time.time()
        # Add a grace period to account for clock skew in decentralized mesh networks
        return now > (self.expiry + grace_period)

    def to_dict(self) -> dict:
        return {
            "v": self.version,
            "type": self.packet_type,
            "sender_id": self.sender_id,
            "sender_vk": self.sender_vk,
            "destination_id": self.destination_id,
            "message_id": self.message_id,
            "seq": self.seq,
            "timestamp": self.timestamp,
            "expiry": self.expiry,
            "ttl": self.ttl,
            "hop_count": self.hop_count,
            "payload": self.payload,
            "signature": self.signature,
        }

    @classmethod
    def from_dict(cls, d: dict) -> 'Packet':
        return cls(
            version=d.get("v", 1),
            packet_type=d["type"],
            sender_id=d["sender_id"],
            sender_vk=d["sender_vk"],
            destination_id=d["destination_id"],
            message_id=d["message_id"],
            seq=d["seq"],
            timestamp=d.get("timestamp"),
            expiry=d.get("expiry"),
            ttl=d.get("ttl", 4),
            hop_count=d.get("hop_count", 0),
            payload=d.get("payload", ""),
            signature=d.get("signature"),
        )

    def to_json(self) -> str:
        return json.dumps(self.to_dict())

    @classmethod
    def from_json(cls, json_str: str) -> 'Packet':
        return cls.from_dict(json.loads(json_str))
