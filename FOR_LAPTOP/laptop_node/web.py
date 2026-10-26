"""Local web UI for the laptop node (http://127.0.0.1:8765). Live updates over a WebSocket.

Uses only the Python standard library: a tiny HTTP server that serves index.html and
upgrades /ws to a WebSocket (RFC 6455, text frames only, which is all the page uses).
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import struct

log = logging.getLogger("nearbychat.web")
STATIC = os.path.join(os.path.dirname(__file__), "static")
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class _WebSocket:
    """Server side of one WebSocket connection."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader, self.writer = reader, writer
        self.lock = asyncio.Lock()

    async def _send_frame(self, opcode: int, payload: bytes) -> None:
        n = len(payload)
        if n < 126:
            head = struct.pack("!BB", 0x80 | opcode, n)
        elif n < 65536:
            head = struct.pack("!BBH", 0x80 | opcode, 126, n)
        else:
            head = struct.pack("!BBQ", 0x80 | opcode, 127, n)
        async with self.lock:
            self.writer.write(head + payload)
            await self.writer.drain()

    async def send_str(self, text: str) -> None:
        await self._send_frame(0x1, text.encode("utf-8"))

    async def receive(self):
        """Return the next text message, or None when the connection closes."""
        parts = []
        while True:
            b1, b2 = await self.reader.readexactly(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", await self.reader.readexactly(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", await self.reader.readexactly(8))[0]
            mask = await self.reader.readexactly(4) if b2 & 0x80 else b"\0\0\0\0"
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(await self.reader.readexactly(n)))
            if opcode == 0x8:                       # close
                return None
            if opcode == 0x9:                       # ping
                await self._send_frame(0xA, data)
                continue
            if opcode in (0x0, 0x1):                # text or continuation
                parts.append(data)
                if fin:
                    return b"".join(parts).decode("utf-8")
            # binary and pong frames are ignored


class WebUI:
    def __init__(self, node, host: str = "127.0.0.1", port: int = 8765):
        self.node = node
        self.host, self.port = host, port
        self.clients: set = set()
        self.history: list = []          # recent log and packet events for late joiners
        node.subscribe(self._on_event)

    def _on_event(self, ev: dict) -> None:
        if ev["type"] in ("log", "packet"):
            self.history.append(ev)
            del self.history[:-300]
        data = json.dumps(ev)
        for ws in list(self.clients):
            asyncio.ensure_future(self._safe_send(ws, data))

    async def _safe_send(self, ws, data: str) -> None:
        try:
            await ws.send_str(data)
        except Exception:
            self.clients.discard(ws)

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            head = await reader.readuntil(b"\r\n\r\n")
            lines = head.decode("latin-1").split("\r\n")
            parts = lines[0].split(" ")
            path = parts[1] if len(parts) > 1 else "/"
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()

            if path == "/ws" and headers.get("upgrade", "").lower() == "websocket":
                accept = base64.b64encode(
                    hashlib.sha1((headers["sec-websocket-key"] + WS_GUID).encode()).digest()).decode()
                writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                              f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())
                await writer.drain()
                await self._ws_session(_WebSocket(reader, writer))
                return

            if path.split("?")[0] in ("/", "/index.html"):
                with open(os.path.join(STATIC, "index.html"), "rb") as f:
                    body = f.read()
                status, ctype = "200 OK", "text/html; charset=utf-8"
            else:
                body, status, ctype = b"Not found", "404 Not Found", "text/plain"
            writer.write((f"HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\n"
                          f"Content-Length: {len(body)}\r\nCache-Control: no-store\r\n"
                          "Connection: close\r\n\r\n").encode() + body)
            await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError, asyncio.LimitOverrunError):
            pass
        except Exception:
            log.exception("web request failed")
        finally:
            writer.close()

    async def _ws_session(self, ws: _WebSocket) -> None:
        self.clients.add(ws)
        try:
            await ws.send_str(json.dumps(self.node.state()))
            for ev in self.history:
                await ws.send_str(json.dumps(ev))
            while True:
                text = await ws.receive()
                if text is None:
                    break
                try:
                    await self._command(json.loads(text))
                except Exception as e:
                    log.exception("command failed")
                    await ws.send_str(json.dumps({"type": "log", "level": "error", "text": f"Command failed: {e}"}))
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            self.clients.discard(ws)

    async def _command(self, c: dict) -> None:
        n = self.node
        a = c.get("action")
        if a == "send":
            asyncio.ensure_future(n.send_text(c["to"], c["text"]))
        elif a == "resend":
            m = next((m for m in n.messages if m.id == c["id"] and m.mine), None)
            if m:
                asyncio.ensure_future(n.send_text(m.peer, m.body, message_id=m.id))
        elif a == "public":
            asyncio.ensure_future(n.send_public(c["text"]))
        elif a == "block":
            p = n.peers.get(c["peer"])
            if p:
                p.blocked = bool(c.get("blocked"))
                n.emit({"type": "log", "level": "info",
                        "text": f"{p.username}: {'treated as OUT OF RANGE (mesh only)' if p.blocked else 'direct link allowed again'}"})
                n.emit_peers()
        elif a == "relay":
            n.relay_enabled = bool(c.get("enabled"))
            n.emit({"type": "log", "level": "info", "text": f"Relaying {'ON' if n.relay_enabled else 'OFF'}"})
            n.emit(n.state())
        elif a == "tamper":
            n.tamper_next = True
            n.emit({"type": "log", "level": "warn",
                    "text": "ATTACK DEMO armed: the next private message this laptop relays or sends "
                            "gets one ciphertext bit flipped"})
            n.emit({"type": "tamper", "armed": True})
        elif a == "replay":
            if not await n.replay_last():
                n.emit({"type": "log", "level": "warn", "text": "Nothing relayed yet to replay"})

    async def start(self) -> None:
        await asyncio.start_server(self._handle, self.host, self.port)
        asyncio.ensure_future(self._tick())

    async def _tick(self) -> None:
        while True:                       # links age out, so refresh the peer list regularly
            await asyncio.sleep(3)
            self.node.emit({"type": "peers", "peers": self.node.peer_view()})
            self.node.emit({"type": "stats", "stats": self.node.stats})
