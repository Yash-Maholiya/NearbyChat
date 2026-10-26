"""Transport independent NearbyChat mesh node (same behaviour as the phone app's BleService +
ChatController): neighbours, flooding with TTL, duplicate suppression, signed announces, the public
#nearby room, private end to end encrypted messages with authenticated ACKs, and the demo attacks.

Transports call node.on_neighbour(...) when they can talk to a device directly and
node.on_packet(data, transport, addr) for every complete packet; the node calls
transport.send(addr, data).
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Protocol

from .protocol import (DEFAULT_TTL, KIND_ANN, KIND_ENV, KIND_PUB, MAX_CLOCK_SKEW_MS, Envelope, Identity,
                       announce_signing_string, b64e, env_packet, fingerprint, make_announce, make_public,
                       new_pid, now_ms, packet_bytes, public_signing_string, verify_signature)

log = logging.getLogger("nearbychat.node")

NEIGHBOUR_TIMEOUT_S = 60
MESH_PEER_TIMEOUT_S = 45
ANNOUNCE_EVERY_S = 15


class Transport(Protocol):
    name: str

    async def start(self, node: "Node") -> None: ...
    async def send(self, addr: str, data: bytes) -> bool: ...
    async def stop(self) -> None: ...


@dataclass
class Peer:
    public_key: str
    username: str
    kind: str = "phone"                 # phone | laptop (from the identity characteristic)
    links: Dict[str, float] = field(default_factory=dict)   # "transport|addr" -> last seen
    rssi: Optional[int] = None
    hops: int = 0                       # from the last announce (1 = neighbour)
    last_announce: float = 0.0
    safety_number: Optional[str] = None
    blocked: bool = False               # demo: "out of range", never use the direct link

    @property
    def fingerprint(self) -> str:
        return fingerprint(self.public_key)

    def live_links(self) -> List[str]:
        now = time.monotonic()
        return [k for k, t in self.links.items() if now - t < NEIGHBOUR_TIMEOUT_S]

    def mesh_reachable(self) -> bool:
        return time.monotonic() - self.last_announce < MESH_PEER_TIMEOUT_S


@dataclass
class Message:
    id: str
    peer: str            # pubkey of the other side
    mine: bool
    body: str
    ts: int
    status: str          # sending | sent | delivered | failed | received
    route: str = ""


@dataclass
class PublicMessage:
    id: str
    sender: str
    public_key: str
    text: str
    ts: int
    mine: bool
    hops: int = 0


class Node:
    def __init__(self, identity: Identity, username: str, *, kind: str = "laptop"):
        self.identity = identity
        self.username = username
        self.kind = kind
        self.transports: Dict[str, Transport] = {}
        self.peers: Dict[str, Peer] = {}
        self.messages: List[Message] = []
        self.public: List[PublicMessage] = []
        self.relay_enabled = True
        self.tamper_next = False
        self.last_relayed: Optional[dict] = None
        self._seen_pids: "OrderedDict[str, None]" = OrderedDict()
        self._seen_msg_ids: "OrderedDict[str, None]" = OrderedDict()
        self._seen_public: "OrderedDict[str, None]" = OrderedDict()
        self._signing_keys: Dict[str, str] = {}
        self._last_flush: Dict[str, float] = {}
        self._listeners: List[Callable[[dict], Any]] = []
        self._tasks: List[asyncio.Task] = []
        self.stats = {"sent": 0, "received": 0, "relayed": 0, "dropped": 0, "acks": 0, "duplicates": 0}

    # ------------------------------------------------------------ plumbing
    def add_transport(self, t: Transport) -> None:
        self.transports[t.name] = t

    async def start(self, announce: bool = True) -> None:
        for t in list(self.transports.values()):
            try:
                await t.start(self)
                self.emit({"type": "log", "level": "ok", "text": f"{t.name.upper()} link started"})
            except Exception as e:
                log.exception("transport %s failed", t.name)
                self.emit({"type": "log", "level": "error", "text": f"{t.name.upper()} link failed: {e}"})
                self.transports.pop(t.name, None)
        if announce:
            self._tasks.append(asyncio.ensure_future(self._announce_loop()))

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        for t in self.transports.values():
            try:
                await t.stop()
            except Exception:
                pass

    def subscribe(self, fn: Callable[[dict], Any]) -> None:
        self._listeners.append(fn)

    def emit(self, ev: dict) -> None:
        ev.setdefault("time", time.strftime("%H:%M:%S"))
        for fn in list(self._listeners):
            try:
                fn(ev)
            except Exception:
                log.exception("listener failed")

    @property
    def public_key(self) -> str:
        return self.identity.public_key_b64

    def _remember(self, od: "OrderedDict[str, None]", k: str, cap: int = 3000) -> bool:
        """Adds k; returns False if it was already there."""
        if k in od:
            return False
        od[k] = None
        while len(od) > cap:
            od.popitem(last=False)
        return True

    # ---------------------------------------------------------- neighbours
    def on_neighbour(self, public_key: str, username: str, transport: str, addr: str,
                     kind: str = "phone", rssi: Optional[int] = None) -> None:
        """A transport can talk to this device directly (BLE identity read, reverse link hello)."""
        if not public_key or public_key == self.public_key:
            return
        p = self.peers.get(public_key)
        new = p is None
        if new:
            p = Peer(public_key=public_key, username=username or "Nearby User", kind=kind)
            p.safety_number = self.identity.safety_number(public_key)
            self.peers[public_key] = p
        p.username = username or p.username
        p.kind = kind or p.kind
        p.links[f"{transport}|{addr}"] = time.monotonic()
        if rssi is not None:
            p.rssi = rssi
        if new:
            self.emit({"type": "log", "level": "ok",
                       "text": f"Neighbour {p.username} ({p.kind}) over {transport.upper()} [{p.fingerprint}]"})
        self.emit_peers()
        self._flush_queue(public_key)

    def touch(self, transport: str, addr: str, rssi: Optional[int] = None) -> None:
        key = f"{transport}|{addr}"
        for p in self.peers.values():
            if key in p.links:
                p.links[key] = time.monotonic()
                if rssi is not None:
                    p.rssi = rssi

    def drop_link(self, transport: str, addr: str) -> None:
        key = f"{transport}|{addr}"
        for p in self.peers.values():
            p.links.pop(key, None)

    def _neighbour_links(self, exclude: Optional[str] = None) -> List[tuple]:
        """One (transport, addr, pubkey) per reachable neighbour, newest link first."""
        out = []
        for p in self.peers.values():
            if p.blocked:
                continue
            links = sorted(p.live_links(), key=lambda k: -p.links[k])
            links = [k for k in links if k.split("|", 1)[0] in self.transports and k != exclude]
            if links:
                t, a = links[0].split("|", 1)
                out.append((t, a, p.public_key))
        return out

    def _direct_link(self, pk: str) -> Optional[tuple]:
        for t, a, p in self._neighbour_links():
            if p == pk:
                return t, a
        return None

    def peer_view(self) -> list:
        out = []
        for p in self.peers.values():
            direct = bool(p.live_links()) and not p.blocked
            online = direct or p.mesh_reachable()
            out.append({
                "publicKey": p.public_key, "fingerprint": p.fingerprint, "username": p.username,
                "kind": p.kind, "direct": direct, "links": sorted({k.split('|')[0] for k in p.live_links()}),
                "rssi": p.rssi, "hops": p.hops, "safety": p.safety_number, "blocked": p.blocked,
                "online": online,
                "nextHop": "direct BLE" if direct else ("mesh flood" if online else "out of reach"),
            })
        out.sort(key=lambda x: (not x["online"], x["username"].lower()))
        return out

    def emit_peers(self) -> None:
        self.emit({"type": "peers", "peers": self.peer_view()})

    # ------------------------------------------------------------- sending
    async def _send_to(self, t: str, addr: str, data: bytes) -> bool:
        try:
            return await self.transports[t].send(addr, data)
        except Exception as e:
            log.info("send via %s to %s failed: %s", t, addr, e)
            return False

    async def _flood(self, pkt: dict, exclude: Optional[str] = None) -> int:
        """Sends to every neighbour (except the link it came from). Returns how many worked."""
        data = packet_bytes(pkt)
        targets = self._neighbour_links(exclude)
        if not targets:
            return 0
        results = await asyncio.gather(*[self._send_to(t, a, data) for t, a, _ in targets])
        return sum(1 for r in results if r)

    async def _route_env(self, env: Envelope, kind: str = "out") -> tuple:
        """Direct if the recipient is a neighbour, otherwise flood. Returns (ok, description)."""
        pkt = env_packet(env)
        self._remember(self._seen_pids, pkt["pid"])
        data = packet_bytes(pkt)
        dest = env.recipient_public_key
        link = self._direct_link(dest)
        if link:
            ok = await self._send_to(link[0], link[1], data)
            self.emit_packet(kind, env, data, link[0], note=f"to {self._name(dest)} direct", ok=ok)
            if ok:
                return True, "direct (BLE)"
        n = await self._flood(pkt)
        self.emit_packet(kind, env, data, "mesh", note=f"to {self._name(dest)} flooded to {n} neighbour(s)", ok=n > 0)
        return n > 0, f"mesh flood ({n} neighbour{'s' if n != 1 else ''})"

    async def send_text(self, dest: str, text: str, message_id: Optional[str] = None) -> Message:
        text = text.strip()
        if dest not in self.peers or not text:
            raise ValueError("unknown peer or empty message")
        msg_id = message_id or str(uuid.uuid4())
        msg = next((m for m in self.messages if m.id == msg_id), None)
        if msg is None:
            msg = Message(id=msg_id, peer=dest, mine=True, body=text, ts=now_ms(), status="sending")
            self.messages.append(msg)
        msg.status = "sending"
        self.emit_message(msg)
        env = self.identity.encrypt(text, self.username, dest, message_id=msg_id)
        if self.tamper_next:
            # Two-device version of the demo: act as if the radio link changed our own packet.
            env = self._flip_bit(env)
            self.emit({"type": "log", "level": "warn",
                       "text": f"ATTACK DEMO: flipped one ciphertext bit in outgoing message {msg_id[:8]} "
                               f"to {self._name(dest)}. It should be rejected and never ACKed."})
        ok, route = await self._route_env(env)
        self.stats["sent"] += 1
        if msg.status != "delivered":
            msg.status = "sent" if ok else "failed"
        msg.route = route
        if not ok:
            self.identity.forget_pending(msg_id)
        self.emit_message(msg)
        return msg

    async def send_public(self, text: str) -> PublicMessage:
        pkt = make_public(self.identity, self.username, text.strip())
        self._remember(self._seen_pids, pkt["pid"])
        self._remember(self._seen_public, pkt["id"])
        m = PublicMessage(id=pkt["id"], sender=self.username, public_key=self.public_key, text=pkt["text"],
                          ts=pkt["ts"], mine=True)
        self.public.append(m)
        del self.public[:-500]
        self.emit_public(m)
        n = await self._flood(pkt)
        self.emit({"type": "log", "level": "info", "text": f"#nearby message flooded to {n} neighbour(s)"})
        return m

    async def send_announce(self) -> int:
        pkt = make_announce(self.identity, self.username)
        self._remember(self._seen_pids, pkt["pid"])
        return await self._flood(pkt)

    async def _announce_loop(self) -> None:
        await asyncio.sleep(2)
        while True:
            try:
                await self.send_announce()
            except Exception:
                log.exception("announce failed")
            await asyncio.sleep(ANNOUNCE_EVERY_S)

    def _flush_queue(self, pk: str) -> None:
        """Store and forward: resend failed messages once the peer is reachable again."""
        failed = [m for m in self.messages if m.mine and m.peer == pk and m.status == "failed"]
        if not failed or time.monotonic() - self._last_flush.get(pk, -1e9) < 30:
            return
        self._last_flush[pk] = time.monotonic()
        self.emit({"type": "log", "level": "info",
                   "text": f"{self._name(pk)} reachable again: resending {len(failed)} queued message(s)"})

        async def go():
            for m in failed:
                await self.send_text(pk, m.body, message_id=m.id)
        try:
            asyncio.get_running_loop().create_task(go())
        except RuntimeError:
            pass

    # ----------------------------------------------------------- receiving
    async def on_packet(self, data: bytes, transport: str, addr: str) -> None:
        link = f"{transport}|{addr}"
        try:
            j = json.loads(data.decode("utf-8"))
        except Exception as e:
            self.stats["dropped"] += 1
            self.emit({"type": "log", "level": "warn", "text": f"Unparseable packet on {transport}: {e}"})
            return
        if j.get("mesh") != 1:
            # bare envelope from an older client: deliver if it is ours, never relay
            try:
                env = Envelope.from_json(j)
            except Exception:
                return
            if env.recipient_public_key == self.public_key:
                await self._deliver(env, data, transport)
            return
        pid = j.get("pid")
        if not isinstance(pid, str) or not self._remember(self._seen_pids, pid):
            self.stats["duplicates"] += 1
            return
        ttl = j.get("ttl") if isinstance(j.get("ttl"), int) else 0
        hops = max(1, DEFAULT_TTL - ttl + 1)
        kind = j.get("kind")
        if kind == KIND_ENV:
            try:
                env = Envelope.from_json(j["env"])
            except Exception:
                self.stats["dropped"] += 1
                return
            if env.recipient_public_key == self.public_key:
                await self._deliver(env, data, transport)
            else:
                await self._relay(j, env, link)
            return
        if kind == KIND_ANN:
            self._handle_announce(j, hops)
        elif kind == KIND_PUB:
            self._handle_public(j, hops)
        else:
            return
        if self.relay_enabled and ttl > 1:
            fwd = dict(j, ttl=ttl - 1)
            n = await self._flood(fwd, exclude=link)
            if n:
                self.stats["relayed"] += 1

    def _verify_signed(self, pk: str, spk: str, sig: str, signed: str) -> bool:
        if not verify_signature(signed, sig, spk):
            self.stats["dropped"] += 1
            self.emit({"type": "log", "level": "error", "text": f"Bad Ed25519 signature from {fingerprint(pk)}: dropped"})
            return False
        bound = self._signing_keys.get(pk)
        if bound is not None and bound != spk:
            self.stats["dropped"] += 1
            self.emit({"type": "log", "level": "error",
                       "text": f"Signing key changed for {fingerprint(pk)} (impersonation attempt): dropped"})
            return False
        self._signing_keys[pk] = spk
        return True

    def _fields(self, j: dict) -> Optional[tuple]:
        u, pk, spk, sig, ts = j.get("u") or "", j.get("pk") or "", j.get("spk") or "", j.get("sig") or "", j.get("ts")
        if not (pk and spk and sig and isinstance(ts, int)) or pk == self.public_key:
            return None
        if abs(now_ms() - ts) > MAX_CLOCK_SKEW_MS:
            return None
        return u, pk, spk, sig, ts

    def _handle_announce(self, j: dict, hops: int) -> None:
        f = self._fields(j)
        if not f:
            return
        u, pk, spk, sig, ts = f
        if not self._verify_signed(pk, spk, sig, announce_signing_string(u, pk, spk, ts)):
            return
        p = self.peers.get(pk)
        if p is None:
            p = Peer(public_key=pk, username=u or "Nearby User", kind="mesh")
            p.safety_number = self.identity.safety_number(pk)
            self.peers[pk] = p
            self.emit({"type": "log", "level": "info",
                       "text": f"Announce: {p.username} [{p.fingerprint}] is in the mesh, {hops} hop(s) away"})
        p.username = u or p.username
        p.hops = hops
        p.last_announce = time.monotonic()
        self.emit_peers()
        self._flush_queue(pk)

    def _handle_public(self, j: dict, hops: int) -> None:
        f = self._fields(j)
        if not f:
            return
        u, pk, spk, sig, ts = f
        mid, text = j.get("id") or "", j.get("text") or ""
        if not mid or not text or mid in self._seen_public:
            return
        if not self._verify_signed(pk, spk, sig, public_signing_string(mid, u, pk, spk, ts, text)):
            return
        self._remember(self._seen_public, mid)
        m = PublicMessage(id=mid, sender=u or "Nearby User", public_key=pk, text=text, ts=ts, mine=False, hops=hops)
        self.public.append(m)
        del self.public[:-500]
        self.emit_public(m)

    async def _deliver(self, env: Envelope, data: bytes, transport: str) -> None:
        self.emit_packet("in", env, data, transport, note=f"from {self._name(env.sender_public_key)}")
        if env.is_ack:
            if not self.identity.verify_ack(env):
                self.stats["dropped"] += 1
                self.emit({"type": "log", "level": "warn", "text": "Rejected ACK with a bad HMAC"})
                return
            self.stats["acks"] += 1
            for m in self.messages:
                if m.id == env.original_message_id and m.mine:
                    m.status = "delivered"
                    self.identity.forget_pending(m.id)
                    self.emit_message(m)
            return
        try:
            text, key = self.identity.decrypt(env)
        except Exception:
            self.stats["dropped"] += 1
            self.emit({"type": "log", "level": "error",
                       "text": f"AES-GCM authentication FAILED for {env.message_id[:8]} from "
                               f"{self._name(env.sender_public_key)}: modified in transit, dropped"})
            return
        if abs(now_ms() - env.timestamp) > MAX_CLOCK_SKEW_MS:
            self.stats["dropped"] += 1
            self.emit({"type": "log", "level": "warn", "text": f"Stale message {env.message_id[:8]} rejected"})
            return
        if self._remember(self._seen_msg_ids, env.message_id):
            if env.sender_public_key not in self.peers:
                p = Peer(public_key=env.sender_public_key,
                         username=f"Unverified ({fingerprint(env.sender_public_key)})", kind="node")
                p.safety_number = self.identity.safety_number(env.sender_public_key)
                self.peers[env.sender_public_key] = p
                self.emit_peers()
            msg = Message(id=env.message_id, peer=env.sender_public_key, mine=False, body=text,
                          ts=env.timestamp, status="received")
            self.messages.append(msg)
            self.stats["received"] += 1
            self.emit_message(msg)
        else:
            self.emit({"type": "log", "level": "warn",
                       "text": f"Replay of message {env.message_id[:8]} suppressed (shown once, ACK sent again)"})
        ack = self.identity.make_ack(env, key, self.username)
        await self._route_env(ack)

    async def _relay(self, j: dict, env: Envelope, link: str) -> None:
        dest = env.recipient_public_key
        ttl = j.get("ttl") if isinstance(j.get("ttl"), int) else 0
        if not self.relay_enabled:
            self.stats["dropped"] += 1
            self.emit_packet("drop", env, packet_bytes(j), link.split("|")[0], note="relay disabled", ok=False)
            return
        if ttl <= 1:
            self.emit_packet("drop", env, packet_bytes(j), link.split("|")[0], note="ttl expired", ok=False)
            return
        fwd = dict(j, ttl=ttl - 1)
        note = ""
        if self.tamper_next and not env.is_ack and env.ciphertext:
            fwd["env"] = self._flip_bit(env).to_json()
            note = " TAMPERED one ciphertext bit."
        if not env.is_ack:
            self.last_relayed = fwd          # the replay demo replays messages, not ACKs
        self.stats["relayed"] += 1
        self.emit({"type": "log", "level": "info",
                   "text": f"Relaying {'ACK' if env.is_ack else 'message'} {env.message_id[:8]} "
                           f"{self._name(env.sender_public_key)} -> {self._name(dest)} (ttl {ttl - 1}). "
                           f"Cannot read it: encrypted for {fingerprint(dest)} only.{note}"})
        data = packet_bytes(fwd)
        direct = self._direct_link(dest)
        if direct and f"{direct[0]}|{direct[1]}" != link:
            ok = await self._send_to(direct[0], direct[1], data)
            self.emit_packet("relay", env, data, direct[0], note=f"to {self._name(dest)} direct", ok=ok)
            if ok:
                return
        n = await self._flood(fwd, exclude=link)
        self.emit_packet("relay", env, data, "mesh", note=f"flooded to {n} neighbour(s)", ok=n > 0)

    def _flip_bit(self, env: Envelope) -> Envelope:
        self.tamper_next = False
        self.emit({"type": "tamper", "armed": False})
        ct = bytearray(env.ciphertext)
        ct[0] ^= 0x01
        return env.copy(ciphertext=bytes(ct))

    async def replay_last(self) -> bool:
        """Attack demo: resend the last relayed packet under a fresh packet id, so it passes the
        mesh duplicate filter and has to be stopped by the receiver's message id check."""
        if not self.last_relayed:
            return False
        pkt = dict(self.last_relayed, pid=new_pid())
        env = Envelope.from_json(pkt["env"])
        self.emit({"type": "log", "level": "warn",
                   "text": f"ATTACK DEMO: replaying captured packet {env.message_id[:8]} with a new packet id"})
        n = await self._flood(pkt)
        self.emit_packet("replay", env, packet_bytes(pkt), "mesh", note=f"replayed to {n} neighbour(s)", ok=n > 0)
        return n > 0

    # ---------------------------------------------------------------- misc
    def _name(self, pk: str) -> str:
        if pk == self.public_key:
            return self.username
        p = self.peers.get(pk)
        return p.username if p else fingerprint(pk)

    def emit_message(self, m: Message) -> None:
        self.emit({"type": "message", "message": self._msg_json(m)})

    def emit_public(self, m: PublicMessage) -> None:
        self.emit({"type": "public", "message": self._pub_json(m)})

    @staticmethod
    def _msg_json(m: Message) -> dict:
        return {"id": m.id, "peer": m.peer, "mine": m.mine, "body": m.body, "ts": m.ts,
                "status": m.status, "route": m.route}

    @staticmethod
    def _pub_json(m: PublicMessage) -> dict:
        return {"id": m.id, "sender": m.sender, "fingerprint": fingerprint(m.public_key), "text": m.text,
                "ts": m.ts, "mine": m.mine, "hops": m.hops}

    def emit_packet(self, direction: str, env: Envelope, data: bytes, link: str, note: str = "",
                    ok: bool = True) -> None:
        self.emit({"type": "packet", "dir": direction, "kind": "ACK" if env.is_ack else "MSG",
                   "id": env.message_id[:8], "bytes": len(data), "link": link, "note": note, "ok": ok,
                   "from": self._name(env.sender_public_key), "to": self._name(env.recipient_public_key),
                   "ciphertext": b64e(env.ciphertext[:24]) if env.ciphertext else "",
                   "raw": data.decode("utf-8", "replace")[:700]})

    def state(self) -> dict:
        return {
            "type": "state", "username": self.username, "publicKey": self.public_key,
            "fingerprint": self.identity.fingerprint, "transports": sorted(self.transports),
            "relay": self.relay_enabled, "tamper": self.tamper_next, "stats": self.stats,
            "peers": self.peer_view(),
            "messages": [self._msg_json(m) for m in self.messages],
            "public": [self._pub_json(m) for m in self.public],
        }
