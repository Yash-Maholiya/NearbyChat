"""Bluetooth LE link for Windows laptops, speaking exactly the same GATT protocol as the phone app.

Peripheral side (other devices write to us): a WinRT GattServiceProvider with
  service  c0de0001  advertised so the phone's scan filter finds this laptop
  c0de0002 identity   READ   -> {"username", "publicKey", "node": "laptop"}  (honours read offset)
  c0de0003 inbox      WRITE / WRITE WITHOUT RESPONSE  -> frames, reassembled per connection
Central side (we write to others): bleak scans for the service, connects, reads the identity and
writes fragmented envelopes into the remote inbox.

Needs Windows 10 1803+ and an adapter that supports the peripheral role (most Intel and
Realtek laptop adapters do). If the peripheral role is missing the laptop can still send, but the
phone cannot write to it, so ACKs and replies will fail; the start screen tells you.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid as _uuid
from typing import Dict, Optional

from bleak import BleakClient, BleakScanner

from winrt.windows.devices.bluetooth import BluetoothAdapter, BluetoothError
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattCharacteristicProperties,
    GattLocalCharacteristicParameters,
    GattProtectionLevel,
    GattServiceProvider,
    GattServiceProviderAdvertisementStatus,
    GattServiceProviderAdvertisingParameters,
    GattWriteOption,
)
from winrt.windows.storage.streams import Buffer

from .protocol import (IDENTITY_CHAR_UUID, INBOX_CHAR_UUID, OUTBOX_CHAR_UUID, PEER_NAME_PREFIX,
                       SERVICE_UUID, Reassembler, fragment, frame_size_for_mtu, hello_payload,
                       identity_payload)

log = logging.getLogger("nearbychat.ble")

IDLE_DISCONNECT_S = 40
HELLO_EVERY_S = 8
RESOLVE_RETRY_S = 12


def _to_buffer(value: bytes) -> Buffer:
    buf = Buffer(max(len(value), 1))
    buf.length = len(value)
    if value:
        with memoryview(buf) as mv:
            mv[: len(value)] = value
    return buf


def _mac(addr_int: int) -> str:
    h = f"{addr_int:012X}"
    return ":".join(h[i:i + 2] for i in range(0, 12, 2))


class WindowsBleTransport:
    name = "ble"

    def __init__(self):
        self.node = None
        self.loop: Optional[asyncio.AbstractEventLoop] = None
        self.provider = None
        self._chars = []            # keep WinRT objects alive
        self._tokens = []
        self.identity_value = b""
        self.reassembler = Reassembler()
        self.scanner: Optional[BleakScanner] = None
        self.devices: Dict[str, object] = {}
        self.resolved: Dict[str, str] = {}          # address -> public key
        self.resolving: set = set()
        self.failed_at: Dict[str, float] = {}
        self.clients: Dict[str, BleakClient] = {}
        self.last_used: Dict[str, float] = {}
        self.locks: Dict[str, asyncio.Lock] = {}
        self.own_address = ""
        self.peripheral_ok = False
        self._reaper: Optional[asyncio.Task] = None
        # reverse links: when Windows refuses to host our GATT server, we stay connected to the
        # phone, subscribe to its outbox and it sends us everything as notifications
        self.reverse: Dict[str, float] = {}
        self.outbox = None
        self.notify_reassembler = Reassembler()

    # ----------------------------------------------------------------- start
    async def start(self, node) -> None:
        self.node = node
        self.loop = asyncio.get_running_loop()
        self.identity_value = identity_payload(node.username, node.public_key, node.kind)

        adapter = await BluetoothAdapter.get_default_async()
        if adapter is None or not adapter.is_low_energy_supported:
            raise RuntimeError("No Bluetooth LE adapter found, or Bluetooth is switched off")
        self.own_address = _mac(adapter.bluetooth_address)
        try:
            radio = await adapter.get_radio_async()
            radio_state = getattr(radio.state, "name", str(radio.state))
        except Exception as e:
            radio_state = f"unknown ({e})"
        node.emit({"type": "log", "level": "info", "text": f"Bluetooth radio state: {radio_state}"})
        if radio_state == "OFF":
            raise RuntimeError("Bluetooth is switched off. Turn it on in Windows Settings > Bluetooth & devices")
        node.emit({"type": "log", "level": "info",
                   "text": f"Bluetooth adapter {self.own_address}: central={adapter.is_central_role_supported} "
                           f"peripheral={adapter.is_peripheral_role_supported}"})

        if adapter.is_peripheral_role_supported:
            await self._start_gatt_server()
        else:
            node.emit({"type": "log", "level": "error",
                       "text": "This adapter cannot act as a BLE peripheral. The phone will not be able to "
                               "send to this laptop over BLE. Use the other laptop for phone traffic."})

        self.scanner = BleakScanner(detection_callback=self._on_advertisement, scanning_mode="active")
        await self.scanner.start()
        self._reaper = asyncio.create_task(self._reap_idle())
        if not self.peripheral_ok:
            node.emit({"type": "log", "level": "warn",
                       "text": "Using REVERSE LINK mode: this laptop connects to phones and receives over "
                               "notifications (phone app needs the outbox characteristic, v2 APK)."})

    async def _start_gatt_server(self) -> None:
        res = await GattServiceProvider.create_async(_uuid.UUID(SERVICE_UUID))
        if res.error != BluetoothError.SUCCESS:
            raise RuntimeError(f"Could not create GATT service: {res.error!r}")
        self.provider = res.service_provider

        p = GattLocalCharacteristicParameters()
        p.characteristic_properties = GattCharacteristicProperties.READ
        p.read_protection_level = GattProtectionLevel.PLAIN
        r = await self.provider.service.create_characteristic_async(_uuid.UUID(IDENTITY_CHAR_UUID), p)
        if r.error != BluetoothError.SUCCESS:
            raise RuntimeError(f"Could not create identity characteristic: {r.error!r}")
        ident = r.characteristic
        self._tokens.append(ident.add_read_requested(self._on_read))

        p2 = GattLocalCharacteristicParameters()
        p2.characteristic_properties = (GattCharacteristicProperties.WRITE |
                                        GattCharacteristicProperties.WRITE_WITHOUT_RESPONSE)
        p2.write_protection_level = GattProtectionLevel.PLAIN
        r2 = await self.provider.service.create_characteristic_async(_uuid.UUID(INBOX_CHAR_UUID), p2)
        if r2.error != BluetoothError.SUCCESS:
            raise RuntimeError(f"Could not create inbox characteristic: {r2.error!r}")
        inbox = r2.characteristic
        self._tokens.append(inbox.add_write_requested(self._on_write))

        # outbox: a central that cannot host a server subscribes here and we notify it
        p3 = GattLocalCharacteristicParameters()
        p3.characteristic_properties = GattCharacteristicProperties.NOTIFY | GattCharacteristicProperties.READ
        p3.read_protection_level = GattProtectionLevel.PLAIN
        r3 = await self.provider.service.create_characteristic_async(_uuid.UUID(OUTBOX_CHAR_UUID), p3)
        self.outbox = r3.characteristic if r3.error == BluetoothError.SUCCESS else None
        if self.outbox is not None:
            self._tokens.append(self.outbox.add_read_requested(self._on_read_empty))
        self._chars = [ident, inbox, self.outbox]

        self._adv_errors = []

        def on_status(sender, args):
            try:
                self._adv_errors.append(f"{args.status!r} error={args.error!r}")
            except Exception:
                pass
        self._tokens.append(self.provider.add_advertisement_status_changed(on_status))

        # Some adapters abort discoverable advertising; fall back to plainer variants.
        for variant in ("connectable+discoverable", "connectable", "default"):
            if variant == "default":
                self.provider.start_advertising()
            else:
                adv = GattServiceProviderAdvertisingParameters()
                adv.is_connectable = True
                adv.is_discoverable = variant == "connectable+discoverable"
                self.provider.start_advertising_with_parameters(adv)
            for _ in range(30):
                await asyncio.sleep(0.1)
                st = self.provider.advertisement_status
                if st in (GattServiceProviderAdvertisementStatus.STARTED,
                          GattServiceProviderAdvertisementStatus.STARTED_WITHOUT_ALL_ADVERTISEMENT_DATA):
                    self.peripheral_ok = True
                    break
                if st == GattServiceProviderAdvertisementStatus.ABORTED:
                    break
            self.node.emit({"type": "log", "level": "info",
                            "text": f"advertising ({variant}): {self.provider.advertisement_status!r} {self._adv_errors[-3:]}"})
            if self.peripheral_ok:
                break
            try:
                self.provider.stop_advertising()
            except Exception:
                pass
            await asyncio.sleep(0.3)
        if self.peripheral_ok:
            self.node.emit({"type": "log", "level": "ok",
                            "text": "GATT server advertising NearbyChat service (phones can now see this laptop)"})
        else:
            self.node.emit({"type": "log", "level": "error",
                            "text": f"GATT advertising did not start (status {self.provider.advertisement_status!r})"})

    # ------------------------------------------------- peripheral callbacks
    # WinRT calls these on its own threads; take the deferral synchronously, finish on the loop.
    def _on_read(self, sender, args) -> None:
        deferral = args.get_deferral()
        asyncio.run_coroutine_threadsafe(self._answer_read(args, deferral), self.loop)

    async def _answer_read(self, args, deferral) -> None:
        try:
            req = await args.get_request_async()
            if req is None:
                return
            off = int(req.offset)
            req.respond_with_value(_to_buffer(self.identity_value[off:]))
        except Exception:
            log.exception("identity read failed")
        finally:
            deferral.complete()

    def _on_read_empty(self, sender, args) -> None:
        deferral = args.get_deferral()

        async def answer():
            try:
                req = await args.get_request_async()
                if req is not None:
                    req.respond_with_value(_to_buffer(b""))
            finally:
                deferral.complete()
        asyncio.run_coroutine_threadsafe(answer(), self.loop)

    def _subscribed_client(self, session: str):
        if getattr(self, "outbox", None) is None:
            return None
        for c in self.outbox.subscribed_clients or []:
            try:
                if c.session.device_id.id == session:
                    return c
            except Exception:
                pass
        return None

    async def _notify(self, session: str, data: bytes) -> bool:
        client = self._subscribed_client(session)
        if client is None:
            return False
        try:
            size = int(client.max_notification_size or 20)
        except Exception:
            size = 20
        for f in fragment(data, max_frame_size=max(20, min(size, 512))):
            await self.outbox.notify_value_for_subscribed_client_async(_to_buffer(f), client)
            await asyncio.sleep(0.02)
        return True

    def _on_write(self, sender, args) -> None:
        deferral = args.get_deferral()
        try:
            session = args.session.device_id.id
        except Exception:
            session = "unknown"
        asyncio.run_coroutine_threadsafe(self._handle_write(args, deferral, session), self.loop)

    async def _handle_write(self, args, deferral, session: str) -> None:
        data = b""
        try:
            req = await args.get_request_async()
            if req is None:
                return
            data = bytes(bytearray(req.value))
            if req.option == GattWriteOption.WRITE_WITH_RESPONSE:
                req.respond()
        except Exception:
            log.exception("inbox write failed")
        finally:
            deferral.complete()
        if data:
            full = self.reassembler.process(data, sender=session)
            if full is None:
                return
            try:
                j = json.loads(full.decode("utf-8"))
            except Exception:
                j = None
            if isinstance(j, dict) and j.get("hello"):
                # reverse link: this central cannot host a server, so we answer by notification
                self.node.on_neighbour(j.get("publicKey") or "", j.get("username") or "", "ble",
                                       f"session:{session}", kind="laptop")
                return
            await self.node.on_packet(full, "ble", f"session:{session}")

    # ----------------------------------------------------------- central
    def _on_advertisement(self, device, adv) -> None:
        self.adverts_seen = getattr(self, "adverts_seen", 0) + 1
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        name = adv.local_name or device.name or ""
        if SERVICE_UUID not in uuids and not name.startswith(PEER_NAME_PREFIX):
            return
        addr = device.address
        if addr.upper() == self.own_address:
            return
        self.devices[addr] = device
        if addr in self.resolved:
            self.node.touch("ble", addr, adv.rssi)
            return
        if addr in self.resolving or time.monotonic() - self.failed_at.get(addr, 0) < RESOLVE_RETRY_S:
            return
        self.resolving.add(addr)
        asyncio.ensure_future(self._resolve(addr, name, adv.rssi))

    def _lock(self, addr: str) -> asyncio.Lock:
        if addr not in self.locks:
            self.locks[addr] = asyncio.Lock()
        return self.locks[addr]

    async def _client(self, addr: str) -> BleakClient:
        c = self.clients.get(addr)
        if c is not None and c.is_connected:
            self.last_used[addr] = time.monotonic()
            return c
        target = self.devices.get(addr, addr)
        c = BleakClient(target, disconnected_callback=lambda _c, a=addr: self._on_disconnect(a),
                        timeout=15.0, winrt={"use_cached_services": False})
        await c.connect()
        await asyncio.sleep(0.3)        # let Windows finish the MTU exchange
        self.clients[addr] = c
        self.last_used[addr] = time.monotonic()
        return c

    def _on_disconnect(self, addr: str) -> None:
        self.clients.pop(addr, None)
        if self.node is not None and addr in self.reverse:
            self.node.drop_link("ble", addr)
        if self.reverse.pop(addr, None) is not None:
            self.resolved.pop(addr, None)          # reconnect on the next advertisement
            self.node.emit({"type": "log", "level": "warn", "text": f"Reverse link to {addr} dropped, will reconnect"})

    async def _open_reverse(self, addr: str, c: BleakClient, name: str) -> None:
        def on_notify(_char, data: bytearray) -> None:
            full = self.notify_reassembler.process(bytes(data), sender=addr)
            if full is not None:
                asyncio.ensure_future(self.node.on_packet(full, "ble", addr))
        try:
            await c.start_notify(OUTBOX_CHAR_UUID, on_notify)
        except Exception as e:
            self.node.emit({"type": "log", "level": "warn",
                            "text": f"{name} has no outbox (older app?): this laptop can send to it but not receive from it ({e})"})
            return
        self.reverse[addr] = time.monotonic()
        await self._write_frames(c, hello_payload(self.node.username, self.node.public_key))
        self.node.emit({"type": "log", "level": "ok", "text": f"Reverse link open with {name}: it can now send to this laptop"})

    async def _write_frames(self, c: BleakClient, data: bytes) -> int:
        fs = frame_size_for_mtu(c.mtu_size or 23)
        frames = fragment(data, max_frame_size=fs)
        for f in frames:
            await c.write_gatt_char(INBOX_CHAR_UUID, f, response=True)
        return len(frames)

    async def _drop(self, addr: str) -> None:
        if self.reverse.pop(addr, None) is not None:
            self.resolved.pop(addr, None)
        c = self.clients.pop(addr, None)
        if c is not None:
            try:
                await c.disconnect()
            except Exception:
                pass

    async def _resolve(self, addr: str, adv_name: str, rssi: Optional[int]) -> None:
        try:
            async with self._lock(addr):
                c = await self._client(addr)
                raw = await c.read_gatt_char(IDENTITY_CHAR_UUID)
                j = json.loads(bytes(raw).decode("utf-8"))
                pk = j.get("publicKey") or ""
                if not pk:
                    raise ValueError("empty identity")
                name = j.get("username") or (adv_name[len(PEER_NAME_PREFIX):] if adv_name.startswith(PEER_NAME_PREFIX) else adv_name)
                self.resolved[addr] = pk
                self.node.on_neighbour(pk, name, "ble", addr, kind=j.get("node", "phone"), rssi=rssi)
                if not self.peripheral_ok:
                    await self._open_reverse(addr, c, name)
        except Exception as e:
            self.failed_at[addr] = time.monotonic()
            log.info("identity read from %s failed: %s", addr, e)
            await self._drop(addr)
        finally:
            self.resolving.discard(addr)

    async def send(self, addr: str, data: bytes) -> bool:
        if addr.startswith("session:"):
            async with self._lock(addr):
                return await self._notify(addr[len("session:"):], data)
        async with self._lock(addr):
            for attempt in (1, 2):
                try:
                    c = await self._client(addr)
                    n = await self._write_frames(c, data)
                    self.last_used[addr] = time.monotonic()
                    log.info("sent %d bytes in %d frames (MTU %s) to %s", len(data), n, c.mtu_size, addr)
                    return True
                except Exception as e:
                    log.info("BLE send to %s failed (attempt %d): %s", addr, attempt, e)
                    await self._drop(addr)
            return False

    async def _reap_idle(self) -> None:
        while True:
            await asyncio.sleep(4)
            now = time.monotonic()
            for addr in list(self.clients):
                if addr in self.reverse:
                    if now - self.reverse[addr] > HELLO_EVERY_S and not self._lock(addr).locked():
                        self.reverse[addr] = now
                        try:
                            async with self._lock(addr):
                                await self._write_frames(self.clients[addr],
                                                         hello_payload(self.node.username, self.node.public_key))
                        except Exception as e:
                            log.info("keepalive to %s failed: %s", addr, e)
                    continue
                if now - self.last_used.get(addr, 0) > IDLE_DISCONNECT_S and not self._lock(addr).locked():
                    await self._drop(addr)

    async def stop(self) -> None:
        if self._reaper:
            self._reaper.cancel()
        if self.scanner:
            try:
                await self.scanner.stop()
            except Exception:
                pass
        for addr in list(self.clients):
            await self._drop(addr)
        if self.provider is not None:
            try:
                self.provider.stop_advertising()
            except Exception:
                pass
