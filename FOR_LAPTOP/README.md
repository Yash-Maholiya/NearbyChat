# NearbyChat on a laptop (Windows)

The laptop joins the same Bluetooth mesh as the phones. No internet, no WiFi, no pairing: it
finds NearbyChat devices by Bluetooth LE advertising, opens short GATT connections (no Windows
pairing prompt, nothing is bonded) and relays packets for everyone, exactly like the app.

Copy this whole `FOR_LAPTOP` folder to each laptop (pen drive). Every laptop uses the same folder
and just gets a different name.

## Needs

* Windows 10 or 11 with Bluetooth LE, Bluetooth switched **on**.
* Python 3.11 to 3.14, 64 bit, installed once (python.org installer, tick "Add python.exe to
  PATH"). Most laptops already have it.
* Nothing else. All Python packages are in the `wheels` folder and install offline.

## Run it

1. Double click **`START_LAPTOP_NODE.bat`**.
2. First run only: it creates a private Python environment and installs the packages from
   `wheels` (about 30 s, offline).
3. Type a name: `LaptopA` on one laptop, `LaptopB` on the other. It is remembered.
4. The page **http://127.0.0.1:8765** opens in the browser. It is a local page served by the
   laptop itself, not a website. Keep the black window open.

## The page

| Left | Middle | Right |
|---|---|---|
| **#nearby** public room, then every device in the mesh: `direct BLE` (in radio range, with dBm) or `mesh · N hops away` (learned from a relayed, signed announce) | The selected chat. Private chats are end to end encrypted; the header shows the safety number and the route | **Packets**: every packet in, out and relayed (click one for the raw JSON: only ciphertext). **Events**: log |

Security demo controls (right column):
* **Relay for others**: forward packets meant for other devices (on by default, like every node).
* **Tamper next message**: flip one ciphertext bit in the next private message this laptop
  relays or sends. The receiver's AES-GCM check fails and drops it (the phone shows a red
  banner). Works with just one laptop and the phone.
* **Replay last**: resend the last relayed message under a new packet id. The receiver shows it
  once and only re-sends the ACK.

Per device (left): **out of range (force multi-hop)** ignores the direct link to that device, so
traffic has to be relayed through the others. Use it to show multi-hop when everything is on one
desk.

## How the mesh works (same in the app)

* Every packet: `{"mesh":1,"pid","ttl":7,"kind":...}`. A device that is not the final recipient
  forwards it with `ttl - 1` to all its neighbours except the one it came from, and drops packet
  ids it has seen before. TTL 7 limits a packet to 7 hops.
* `ann`: every 15 s each device floods a signed announce (name, X25519 key, Ed25519 key), so you
  can see and message devices you cannot hear directly.
* `env`: private message or ACK, X25519 + HKDF + AES-GCM-256 for the recipient only. Sent direct
  when the recipient is a neighbour, otherwise flooded.
* `pub`: public #nearby message, Ed25519 signed, flooded to everyone.

## Bluetooth modes

Double click **`BLUETOOTH_SELFTEST.bat`** to check (40 s, writes `bluetooth_selftest.log`):

* `GATT server advertising NearbyChat service`: **normal mode**. Other devices find this laptop by
  scanning and write to it.
* `Using REVERSE LINK mode`: Windows on this laptop refuses to host a Bluetooth GATT server (seen
  on some Windows 11 machines although the adapter supports it). Still works: the laptop
  connects to the phones (and to laptops in normal mode) itself, subscribes to their outbox and
  says hello; they send to it as notifications on that same connection. Two laptops that are
  both in reverse link mode cannot connect to each other directly, but they still reach each
  other through a phone, because the phone relays.

## Files

* `START_LAPTOP_NODE.bat`, `BLUETOOTH_SELFTEST.bat`
* `wheels/`: offline Python packages (bleak, cryptography and their dependencies) for Python 3.11 to 3.14
* `laptop_node/protocol.py`: envelope, X25519 / HKDF / AES-GCM / HMAC, Ed25519 signing, frames,
  mesh packets. Byte compatible with the app (checked by the app's interop tests)
* `laptop_node/node.py`: mesh node (neighbours, flooding, announces, public room, ACKs, attacks)
* `laptop_node/ble_windows.py`: Bluetooth LE for Windows (GATT server + client, reverse links)
* `laptop_node/web.py`, `laptop_node/static/index.html`: the local page
* `laptop_node/tests/`: 20 tests (`python -m pytest laptop_node/tests`)
