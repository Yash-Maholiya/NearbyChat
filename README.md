# NearbyChat: Secure Peer to Peer Mesh Communication System

**Academic project:** Design and Security Analysis of a Secure Peer to Peer Mesh Communication System
**Authors:** Yash (24BCT0155) and Rohan (24BKT0060)

NearbyChat is off grid, serverless, end to end encrypted messaging for situations with no internet
or cellular service. The repository has two tracks:

1. **Mobile app (`nearby_chat/`).** Flutter app for Android and iOS. A bitchat style Bluetooth LE
   mesh: every device relays (TTL 7, duplicate suppression), signed announces show people several
   hops away, private chats are end to end encrypted and there is a signed public `#nearby` room.
   Windows laptops join the same mesh with the laptop node in `FOR_LAPTOP/`.
2. **Mesh simulation (`mesh_simulation/`).** Python prototype of the multi-hop part: discovery,
   relaying over untrusted nodes, route recovery, relay trust scoring, security tests and measured
   experiments. Runs on local UDP sockets, optionally inside Mininet-WiFi.

## Status (October 2026)

| Part | State |
|---|---|
| App code (BLE mesh, crypto, storage, UI) | Complete: multi-hop relay, signed announces, public room, offline queue |
| App static analysis | `flutter analyze`: no issues |
| App tests | 56 / 56 pass (incl. mesh routing and interop with the laptop node) |
| Laptop node (`FOR_LAPTOP/`) | Same mesh protocol over Windows BLE, 19 / 19 tests, offline install |
| Android APK | `FOR_ANDROID/NearbyChat.apk` (release build, install directly) |
| App on real devices | Next step: field test with 1 phone + 2 laptops (`DEMO_GUIDE.md`) |
| iOS build | Code and Bluetooth usage strings ready; needs a Mac with Xcode to build |
| Mesh simulation | Complete: discovery, routing modes, retries, trust, enrolment, baseline mode |
| Simulation tests | 21 / 21 pass |
| Experiments E1 to E5 | Done, results in `mesh_simulation/results/` |
| Dashboard | Done (`mesh_simulation/dashboard`) |
| Mininet-WiFi script | Written, not yet run (needs Ubuntu with root) |

How to run: `HOW_TO_RUN.md`. Demo script: `DEMO_GUIDE.md`.

## Repository layout

```
NearbyChat/
  README.md, PROJECT_CONTEXT.md, TEAM_GUIDE.md
  FOR_ANDROID/                  NearbyChat.apk + install README
  FOR_LAPTOP/                   laptop node (Windows, BLE only) + README
  HOW_TO_RUN.md, DEMO_GUIDE.md  running the 3 device demo
  nearbychat_demo.html          browser demo: two phones, discovery and encrypted chat
  nearbychat_relay_demo.html    browser demo: three device relay with packet inspection
  tools/                        Windows helpers: install Flutter, Android SDK, build the APK
  nearby_chat/                  TRACK 1: Flutter app
    lib/                        models, services (crypto, BLE, frames, storage), controller, screens
    test/                       34 tests
  mesh_simulation/              TRACK 2: Python mesh
    node_app/ topology/ experiments/ dashboard/ scripts/ tests/ results/
```

## App security design (as implemented)

* **Identity.** One X25519 key pair per install, stored with `flutter_secure_storage`
  (Android Keystore / iOS Keychain). The public key is the identity; the fingerprint is its first 12
  base64 characters.
* **Discovery.** Each phone is a GATT server and client at the same time. It advertises
  `NC-<username>` with service `c0de0001-...`. A Read characteristic returns `{username, publicKey}`,
  and a Write characteristic is the inbox.
* **Per message forward secrecy.** For every message the sender makes a fresh ephemeral X25519
  key, computes `X25519(ephemeral, recipient static)` and derives the message key with
  HKDF-SHA256 (salt `nearbychat-pfs-v1`, info = message id). The ephemeral private key is discarded.
* **Encryption.** AES-GCM-256 with a random 12 byte nonce. The AAD binds version, message id,
  sender name, both public keys, the ephemeral key, the timestamp, the ACK flag and the original
  message id. Changing any header field makes decryption fail.
* **Delivery receipts.** ACK = HMAC-SHA256(message key, "ack:" + message id). Only the real
  recipient can derive the message key, so ACKs cannot be forged.
* **Replay and freshness.** A message id that was already accepted is never stored twice (it is
  ACKed again). Messages whose authenticated timestamp is more than 30 minutes off are rejected.
* **Safety number.** HKDF-SHA256 over the static X25519 secret with the sorted public keys,
  first 6 bytes shown as `xx-xx-xx-xx-xx-xx`. Users compare it in person to detect a MITM.
* **Impersonation.** Display names come from the locally known public key, never from the
  envelope. Unknown keys show as `Unverified (<fingerprint>)`. The same name with a different key
  shows a name collision warning.
* **Framing.** 10 byte header (4 byte message hash, frame index, total frames, payload length).
  The app asks for a 247 byte ATT MTU after connecting and sizes frames to fit. If that fails it
  falls back to 20 byte writes, which every BLE device supports.
* **History at rest.** Encrypted with AES-GCM-256 under a random database key kept in secure
  storage. Rolling 500 messages per peer. Old plaintext history is migrated automatically.

Limits: an ACK that arrives after the app restarts cannot be verified (message keys stay in RAM
only, by design). `originalMessageId` in ACK headers is visible to an eavesdropper, so receipts
can be linked to messages. The username is stored in shared preferences, not secure storage.

## How to run

### App
```bash
cd nearby_chat
flutter pub get
flutter analyze
flutter test
flutter run            # with a phone connected by USB
```
On Windows, `tools/START_FLUTTER_TOOLS.bat` installs Flutter and runs the checks, and
`tools/SETUP_ANDROID_SDK.bat` installs Java 17 and the Android SDK, and
`tools/FIX_ANDROID_BUILD.bat` checks the network, installs the Android platform and builds a debug APK.

### Mesh simulation
```bash
pip install -r mesh_simulation/requirements.txt
python -m pytest mesh_simulation/tests -v
python -m mesh_simulation.experiments.run_experiments
python -m mesh_simulation.dashboard.app          # http://127.0.0.1:5000
```
See `mesh_simulation/README.md` for the CLI node, enrolment and Mininet-WiFi.

### Browser demos
Open `nearbychat_demo.html` or `nearbychat_relay_demo.html` in a browser. They are teaching
animations of the protocol and do not run the real app code.

