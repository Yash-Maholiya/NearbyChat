"""NearbyChat wire protocol, ported 1:1 from the Flutter app.

Mesh layer (models/mesh_packet.dart): every packet is
  {"mesh":1,"pid":"<random id>","ttl":7,"kind":"env"|"ann"|"pub", ...body}
  env {"env": envelope}  ann {"u","pk","spk","ts","sig"}  pub {"id","u","pk","spk","ts","text","sig"}
ann and pub are signed with Ed25519 (see announce_signing_string / public_signing_string).

Everything here must stay byte compatible with nearby_chat/lib:
  models/chat_envelope.dart   envelope JSON keys and the AAD string
  services/frame_codec.dart   10 byte frame header, big endian
  services/crypto_service.dart  X25519 + HKDF-SHA256 + AES-GCM-256, HMAC ACKs, safety number
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import random
import struct
import time
import uuid
from dataclasses import dataclass, replace
from typing import Dict, Optional, Tuple

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

# GATT layout (ble_service.dart)
SERVICE_UUID = "c0de0001-beef-11e4-8998-0002a5d5c51b"
IDENTITY_CHAR_UUID = "c0de0002-beef-11e4-8998-0002a5d5c51b"
INBOX_CHAR_UUID = "c0de0003-beef-11e4-8998-0002a5d5c51b"
OUTBOX_CHAR_UUID = "c0de0004-beef-11e4-8998-0002a5d5c51b"   # notify, used for reverse links
PEER_NAME_PREFIX = "NC-"

PFS_SALT = b"nearbychat-pfs-v1"
SAFETY_SALT = b"nearbychat-safety-v1"
MAX_CLOCK_SKEW_MS = 30 * 60 * 1000


def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def b64d(s: str) -> bytes:
    return base64.b64decode(s)


def now_ms() -> int:
    return int(time.time() * 1000)


# ----------------------------------------------------------------- frames

HEADER_SIZE = 10
MIN_ATT_MTU = 23
MAX_FRAME_SIZE = 512


def frame_size_for_mtu(mtu: int) -> int:
    return max(MIN_ATT_MTU - 3, min(mtu - 3, MAX_FRAME_SIZE))


def fragment(data: bytes, max_frame_size: int = 180, msg_hash: Optional[int] = None) -> list[bytes]:
    h = msg_hash if msg_hash is not None else random.getrandbits(32)
    if not data:
        return [struct.pack(">IHHH", h, 0, 1, 0)]
    chunk = max_frame_size - HEADER_SIZE
    if chunk <= 0:
        raise ValueError("max_frame_size must be greater than the header size")
    total = (len(data) + chunk - 1) // chunk
    out = []
    for i in range(total):
        part = data[i * chunk:(i + 1) * chunk]
        out.append(struct.pack(">IHHH", h, i, total, len(part)) + part)
    return out


class Reassembler:
    """Same rules as FrameReassembler in frame_codec.dart."""

    MAX_BUFFERS = 100
    MAX_FRAMES = 500

    def __init__(self, timeout_s: float = 30.0):
        self.timeout_s = timeout_s
        self._buffers: Dict[str, Tuple[float, int, Dict[int, bytes]]] = {}
        self._last_prune = time.monotonic()

    def process(self, raw: bytes, sender: str = "default") -> Optional[bytes]:
        now = time.monotonic()
        if now - self._last_prune >= 5:
            self._last_prune = now
            for k in [k for k, v in self._buffers.items() if now - v[0] > self.timeout_s]:
                del self._buffers[k]
        if len(raw) < HEADER_SIZE:
            return None
        h, idx, total, plen = struct.unpack(">IHHH", raw[:HEADER_SIZE])
        if total == 0 or total > self.MAX_FRAMES or idx >= total:
            return None
        if len(raw) < HEADER_SIZE + plen:
            return None
        payload = raw[HEADER_SIZE:HEADER_SIZE + plen]
        key = f"{sender}:{h}"
        if key not in self._buffers:
            if len(self._buffers) >= self.MAX_BUFFERS:
                del self._buffers[next(iter(self._buffers))]
            self._buffers[key] = (now, total, {})
        created, btotal, chunks = self._buffers[key]
        if btotal != total:
            del self._buffers[key]
            return None
        chunks[idx] = payload
        if len(chunks) == total:
            del self._buffers[key]
            return b"".join(chunks[i] for i in range(total))
        return None


# --------------------------------------------------------------- envelope

@dataclass
class Envelope:
    message_id: str
    sender_username: str
    sender_public_key: str
    recipient_public_key: str
    timestamp: int
    nonce: bytes = b""
    ciphertext: bytes = b""
    mac: bytes = b""
    ephemeral_public_key: str = ""
    is_ack: bool = False
    original_message_id: Optional[str] = None
    version: int = 2

    @property
    def aad(self) -> bytes:
        s = (f"{self.version}:{self.message_id}:{self.sender_username}:{self.sender_public_key}:"
             f"{self.recipient_public_key}:{self.ephemeral_public_key}:{self.timestamp}:"
             f"{1 if self.is_ack else 0}:{self.original_message_id or ''}")
        return s.encode("utf-8")

    def to_json(self) -> dict:
        d = {
            "v": self.version, "id": self.message_id, "u": self.sender_username,
            "spk": self.sender_public_key, "rpk": self.recipient_public_key,
            "epk": self.ephemeral_public_key, "t": self.timestamp,
            "n": b64e(self.nonce), "c": b64e(self.ciphertext), "m": b64e(self.mac),
            "ack": self.is_ack,
        }
        if self.original_message_id is not None:
            d["origId"] = self.original_message_id
        return d

    def to_bytes(self) -> bytes:
        return json.dumps(self.to_json(), separators=(",", ":"), ensure_ascii=False).encode("utf-8")

    @classmethod
    def from_json(cls, j: dict) -> "Envelope":
        return cls(
            version=int(j.get("v", 2)), message_id=j["id"], sender_username=j["u"],
            sender_public_key=j["spk"], recipient_public_key=j["rpk"],
            ephemeral_public_key=j.get("epk") or "", timestamp=int(j["t"]),
            nonce=b64d(j["n"]) if j.get("n") is not None else b"",
            ciphertext=b64d(j["c"]) if j.get("c") is not None else b"",
            mac=b64d(j["m"]) if j.get("m") is not None else b"",
            is_ack=bool(j.get("ack", False)), original_message_id=j.get("origId"),
        )

    @classmethod
    def from_bytes(cls, b: bytes) -> "Envelope":
        return cls.from_json(json.loads(b.decode("utf-8")))

    def copy(self, **kw) -> "Envelope":
        return replace(self, **kw)


# ----------------------------------------------------------------- crypto

def _hkdf(secret: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(secret)


_RAW = serialization.Encoding.Raw


def _raw_pub(key) -> bytes:
    return key.public_bytes(_RAW, serialization.PublicFormat.Raw)


def _raw_priv(key) -> bytes:
    return key.private_bytes(_RAW, serialization.PrivateFormat.Raw, serialization.NoEncryption())


class Identity:
    """X25519 key pair (the identity, as in the app) plus an Ed25519 key for signing mesh packets."""

    def __init__(self, private_key: Optional[X25519PrivateKey] = None,
                 signing_key: Optional[Ed25519PrivateKey] = None):
        self.private_key = private_key or X25519PrivateKey.generate()
        self.public_key_b64 = b64e(_raw_pub(self.private_key.public_key()))
        self.signing_key = signing_key or Ed25519PrivateKey.generate()
        self.signing_public_b64 = b64e(_raw_pub(self.signing_key.public_key()))
        self._pending: Dict[str, Tuple[float, bytes]] = {}

    def sign(self, message: str) -> str:
        return b64e(self.signing_key.sign(message.encode("utf-8")))

    def signing_seed(self) -> bytes:
        return _raw_priv(self.signing_key)

    def private_bytes(self) -> bytes:
        return _raw_priv(self.private_key)

    @classmethod
    def from_private_bytes(cls, b: bytes, signing_seed: Optional[bytes] = None) -> "Identity":
        sk = Ed25519PrivateKey.from_private_bytes(signing_seed) if signing_seed else None
        return cls(X25519PrivateKey.from_private_bytes(b), sk)

    @classmethod
    def load_or_create(cls, path: str) -> "Identity":
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                j = json.load(f)
            ident = cls.from_private_bytes(b64d(j["privateKey"]),
                                           b64d(j["signingSeed"]) if j.get("signingSeed") else None)
            if j.get("signingSeed"):
                return ident
        else:
            ident = cls()
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"privateKey": b64e(ident.private_bytes()), "publicKey": ident.public_key_b64,
                       "signingSeed": b64e(ident.signing_seed())}, f)
        return ident

    @property
    def fingerprint(self) -> str:
        return fingerprint(self.public_key_b64)

    # same as deriveSafetyNumber in the app
    def safety_number(self, remote_pub_b64: str) -> Optional[str]:
        try:
            remote_raw = b64d(remote_pub_b64)
            shared = self.private_key.exchange(X25519PublicKey.from_public_bytes(remote_raw))
            local_raw = b64d(self.public_key_b64)
            keys = local_raw + remote_raw if local_raw <= remote_raw else remote_raw + local_raw
            out = _hkdf(shared, SAFETY_SALT, keys)[:6]
            return "-".join(f"{b:02x}" for b in out)
        except Exception:
            return None

    def encrypt(self, plaintext: str, sender_username: str, recipient_pub_b64: str,
                message_id: Optional[str] = None, timestamp: Optional[int] = None,
                _ephemeral: Optional[X25519PrivateKey] = None, _nonce: Optional[bytes] = None) -> Envelope:
        msg_id = message_id or str(uuid.uuid4())
        ts = timestamp if timestamp is not None else now_ms()
        eph = _ephemeral or X25519PrivateKey.generate()
        eph_pub = b64e(_raw_pub(eph.public_key()))
        shared = eph.exchange(X25519PublicKey.from_public_bytes(b64d(recipient_pub_b64)))
        key = _hkdf(shared, PFS_SALT, msg_id.encode("utf-8"))
        self._store_pending(msg_id, key)
        env = Envelope(message_id=msg_id, sender_username=sender_username,
                       sender_public_key=self.public_key_b64, recipient_public_key=recipient_pub_b64,
                       ephemeral_public_key=eph_pub, timestamp=ts)
        nonce = _nonce or os.urandom(12)
        ct_tag = AESGCM(key).encrypt(nonce, plaintext.encode("utf-8"), env.aad)
        return env.copy(nonce=nonce, ciphertext=ct_tag[:-16], mac=ct_tag[-16:])

    def decrypt(self, env: Envelope) -> Tuple[str, bytes]:
        if not env.ephemeral_public_key:
            raise ValueError("envelope has no ephemeral key")
        shared = self.private_key.exchange(X25519PublicKey.from_public_bytes(b64d(env.ephemeral_public_key)))
        key = _hkdf(shared, PFS_SALT, env.message_id.encode("utf-8"))
        pt = AESGCM(key).decrypt(env.nonce, env.ciphertext + env.mac, env.aad)
        return pt.decode("utf-8"), key

    def make_ack(self, original: Envelope, message_key: bytes, sender_username: str) -> Envelope:
        mac = _ack_mac(message_key, original.message_id)
        return Envelope(message_id=str(uuid.uuid4()), sender_username=sender_username,
                        sender_public_key=self.public_key_b64,
                        recipient_public_key=original.sender_public_key,
                        timestamp=now_ms(), mac=mac, is_ack=True,
                        original_message_id=original.message_id)

    def verify_ack(self, ack: Envelope) -> bool:
        if not ack.is_ack or not ack.original_message_id:
            return False
        entry = self._pending.get(ack.original_message_id)
        if entry is None:
            return False
        return hmac.compare_digest(_ack_mac(entry[1], ack.original_message_id), ack.mac)

    def forget_pending(self, msg_id: str) -> None:
        self._pending.pop(msg_id, None)

    def _store_pending(self, msg_id: str, key: bytes) -> None:
        now = time.monotonic()
        for k in [k for k, v in self._pending.items() if now - v[0] > 300]:
            del self._pending[k]
        if len(self._pending) >= 200:
            del self._pending[next(iter(self._pending))]
        self._pending[msg_id] = (now, key)


def _ack_mac(key: bytes, message_id: str) -> bytes:
    return hmac.new(key, f"ack:{message_id}".encode("utf-8"), hashlib.sha256).digest()


def fingerprint(pub_b64: str) -> str:
    return pub_b64[:12]


def hello_payload(username: str, pub_b64: str) -> bytes:
    """Written to a phone's inbox by a laptop that cannot run a GATT server (reverse link)."""
    return json.dumps({"hello": 1, "username": username, "publicKey": pub_b64},
                      separators=(",", ":")).encode("utf-8")


def identity_payload(username: str, pub_b64: str, kind: str = "laptop") -> bytes:
    """Value of the identity characteristic. The app reads only username and publicKey."""
    return json.dumps({"username": username, "publicKey": pub_b64, "node": kind},
                      separators=(",", ":")).encode("utf-8")


# ------------------------------------------------------------------- mesh

DEFAULT_TTL = 7
KIND_ENV, KIND_ANN, KIND_PUB = "env", "ann", "pub"


def new_pid() -> str:
    return os.urandom(8).hex()


def make_packet(kind: str, body: dict, ttl: int = DEFAULT_TTL, pid: Optional[str] = None) -> dict:
    return {"mesh": 1, "pid": pid or new_pid(), "ttl": ttl, "kind": kind, **body}


def packet_bytes(pkt: dict) -> bytes:
    return json.dumps(pkt, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def env_packet(env: "Envelope", ttl: int = DEFAULT_TTL) -> dict:
    return make_packet(KIND_ENV, {"env": env.to_json()}, ttl)


def announce_signing_string(u: str, pk: str, spk: str, ts: int) -> str:
    return f"nearbychat-ann-v1|{u}|{pk}|{spk}|{ts}"


def public_signing_string(mid: str, u: str, pk: str, spk: str, ts: int, text: str) -> str:
    return f"nearbychat-pub-v1|{mid}|{u}|{pk}|{spk}|{ts}|{text}"


def verify_signature(message: str, sig_b64: str, spk_b64: str) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(b64d(spk_b64)).verify(b64d(sig_b64), message.encode("utf-8"))
        return True
    except Exception:
        return False


def make_announce(ident: Identity, username: str) -> dict:
    ts = now_ms()
    sig = ident.sign(announce_signing_string(username, ident.public_key_b64, ident.signing_public_b64, ts))
    return make_packet(KIND_ANN, {"u": username, "pk": ident.public_key_b64, "spk": ident.signing_public_b64,
                                  "ts": ts, "sig": sig})


def make_public(ident: Identity, username: str, text: str, mid: Optional[str] = None) -> dict:
    ts = now_ms()
    mid = mid or str(uuid.uuid4())
    sig = ident.sign(public_signing_string(mid, username, ident.public_key_b64, ident.signing_public_b64, ts, text))
    return make_packet(KIND_PUB, {"id": mid, "u": username, "pk": ident.public_key_b64,
                                  "spk": ident.signing_public_b64, "ts": ts, "text": text, "sig": sig})
