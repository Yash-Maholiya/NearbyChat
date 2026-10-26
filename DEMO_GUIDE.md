# NearbyChat demo: 2 laptops + 1 Android phone, Bluetooth only

Three real devices form one bitchat style mesh. No internet, no WiFi, no pairing, no server.

```
  LaptopA  ~~~ BLE ~~~  Android phone  ~~~ BLE ~~~  LaptopB
     \______________________ BLE _______________________/
   every device relays for the others (TTL 7, duplicate suppression)
```

* Phone: `FOR_ANDROID/NearbyChat.apk` (see `FOR_ANDROID/README.md`).
* Laptops: `FOR_LAPTOP/START_LAPTOP_NODE.bat` (see `FOR_LAPTOP/README.md`).
* Before the demo: switch **off** WiFi and mobile data on all three devices, so it is obvious that
  only Bluetooth is used.

## Demo script (about 6 minutes)

**1. Discovery without a server.** Open the app on the phone and start the node on both laptops.
Within about 15 s the phone lists LaptopA and LaptopB, and each laptop page lists the phone and
the other laptop (`direct BLE` with dBm, or `mesh · 2 hops` if it only hears it through a relay).

**2. Identity check (MITM).** Open the chat with LaptopA on the phone and open its safety number.
Select the phone on LaptopA: the header shows the same 6 byte number. Mark it verified.

**3. Private encrypted chat.** Phone sends "hello A". It appears on LaptopA and the phone shows
sent, then delivered (authenticated ACK). On LaptopA click the packet in the Packets column: the
JSON has only ciphertext, the ephemeral key, nonce and tag.

**4. Public room.** On LaptopB open `#nearby` and post "hi everyone". It shows up on the phone and
on LaptopA, each with its hop count. Signed with Ed25519, so it cannot be forged.

**5. Multi-hop.** On LaptopA tick **out of range (force multi-hop)** next to LaptopB. LaptopB now
shows as `mesh · 2 hops`. Send LaptopA to LaptopB:
* the phone relays it (the `#nearby` tile's relayed counter goes up) and cannot read it,
* LaptopB receives it, its ACK comes back the same way, LaptopA shows delivered via mesh flood.
(If one laptop is in reverse link mode the two laptops cannot connect directly anyway, so this
path through the phone is the only one, no tick needed.)

**6. Tampering attack.** On LaptopA press **Tamper next message**, then send the phone a message
from LaptopA. LaptopA flips one ciphertext bit before it goes out. The phone's AES-GCM check
fails, a red banner says the message was modified in transit and dropped, nothing appears in
the chat, and LaptopA's message stays at sent (no ACK). Send again normally: it is delivered.
With both laptops you can also show it as a relay attack: on LaptopB tick out of range for the
phone, press the button on LaptopA, then send LaptopB to phone. LaptopA flips the bit while
relaying, with the same result on the phone.

**7. Replay attack.** On LaptopA press **Replay last**: it resends the captured packet with a new
packet id. The receiver shows it only once (message id check) and just re-sends the ACK.

**8. Relay off.** Untick **Relay for others** on the relay laptop and send again across it: nothing
arrives. Delivery really depended on the relay.

**9. Offline queue.** Close the app on the phone (or walk it away), send it a message from the
phone's side before closing, or from a laptop: it fails. Reopen: once the device is reachable
again the app resends queued messages automatically.

Untick everything to go back to normal.

## Mesh simulation (5 nodes, on one laptop)

Double click `START_MESH_SIM.bat` (needs internet the first time to install pynacl, flask and
matplotlib). The dashboard opens at http://127.0.0.1:5000 with nodes A to E:
A-B-D on top, A-C-E-D as the alternate path.

1. Send NodeA to NodeD: it goes A-B-D and the outbox shows it delivered with an ACK.
2. Click the B-D line to cut it, send again: the retry moves to A-C-E-D (route recovery).
3. Set Dropper relay NodeB at 100% and send a few: B's trust score falls and NodeA prefers C.
4. Press Tampered packet, Replay captured packet and Unknown node HELLO: each shows up in
   Security events as rejected.
5. Show `mesh_simulation/results/SUMMARY.md` and the charts in `results/charts` for E1 to E5.

`START_MESH_SIM.bat tests` runs the 21 tests, `START_MESH_SIM.bat experiments` reruns E1 to E5.

## What to say

* **Discovery**: BLE advertising of service `c0de0001` + name, identity read over GATT, signed
  announces flooded through the mesh for devices further away.
* **Key exchange without a server**: public keys travel over the radio; the safety number
  (HKDF over the static X25519 secret and both keys) detects key substitution.
* **Per message forward secrecy**: fresh ephemeral X25519 key per message, HKDF-SHA256, AES-GCM-256
  with every header field in the AAD.
* **Delivery receipts**: HMAC-SHA256 ACK keyed with the message key; only the real recipient can
  produce it.
* **Mesh**: flooding with TTL 7 and packet id duplicate suppression, direct send when the
  recipient is a neighbour, reverse path learning, store and forward retry.
* **Untrusted relays**: forward ciphertext they cannot read; tampering detected by AES-GCM, replay
  by message id, forged announces / public posts by Ed25519 signatures bound to the first key seen.
* **Fragmentation**: 10 byte frame header, frames sized to the negotiated MTU, 20 byte fallback.
* **At scale**: the Python mesh simulation in `mesh_simulation/` measures the routing ideas (route
  recovery, loss tolerance, trust aware routing) on 5 nodes.

## Troubleshooting

| Problem | Fix |
|---|---|
| Phone does not list a laptop | Bluetooth on, node window open. In reverse link mode the laptop must find the phone first: keep the app on screen and wait 15 s. Tap the radar button twice on the phone. |
| Laptop does not list the phone | Keep the app in the foreground, allow Nearby devices and Location. |
| Message stays "sent" | The ACK did not come back yet; tap retry, or wait for the automatic resend. |
| `#nearby` message only on some devices | Wait one announce round (15 s) so every device knows its neighbours. |
| Sender shows as "Unverified (...)" | A message from a key whose announce has not arrived yet. It fixes itself within 15 s. |

## Tests

* App: `flutter test` in `nearby_chat/` (crypto, frames, storage, controller, ACK routing, mesh
  routing, signed announces / public room, and interop with the laptop code).
* Laptop: `python -m pytest laptop_node/tests` inside `FOR_LAPTOP` (20 tests: two hop delivery,
  hop counts, TTL limit, duplicates, public room, forgery, impersonation, tamper, replay, relay off).
* Simulation: `python -m pytest mesh_simulation/tests` (21 tests).
