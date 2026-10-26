# Project Context: NearbyChat (Secure Peer-to-Peer Mesh Communication System)

> **Document Type:** System Architecture, Technical Context & Development Guide  
> **Project Name:** NearbyChat  
> **Academic Title:** Design and Security Analysis of a Secure Peer-to-Peer Mesh Communication System  
> **Authors:** Yash (Reg. No. 24BCT0155) & Rohan (Reg. No. 24BKT0060)  
> **Target Platforms:** Android & iOS (Flutter 3.44+, verified with Flutter 3.47.7, Dart 3.x)  
> **Network Transport:** Bluetooth Low Energy (BLE) Dual-Role (Central + Peripheral)  
> **Last Updated:** October 2026  

---

## 1. Executive Summary & Vision

**NearbyChat** is an infrastructure-independent, cross-platform, serverless direct and mesh communication system. It is designed to operate completely without internet connectivity, cellular base stations, external radio hardware, or centralized accounts.

### Problem Addressed
1. **Total Infrastructure Dependency:** Modern messaging platforms (Signal, WhatsApp, Telegram, iMessage) require active servers and internet connectivity. In natural disasters, military conflicts, remote environments, or state-mandated internet shutdowns, centralized communication collapses.
2. **Local Communication Paradox:** Two people situated 10 meters apart are routinely forced to route communications through data centers located thousands of miles away, exposing metadata and creating unnecessary failure points.
3. **Surveillance & Identity Linkage:** Traditional platforms require phone numbers, national identity numbers, or email addresses, leaving permanent surveillance footprints.

### Core Value Proposition
NearbyChat provides **zero-knowledge, end-to-end encrypted direct messaging** using the native Bluetooth Low Energy (BLE) radios already present in everyday smartphones. By simultaneously functioning as a BLE GATT Server (Peripheral) and GATT Client (Central), devices can discover one another, establish cryptographic shared secrets via **X25519** Elliptic Curve Diffie-Hellman (ECDH), encrypt communications with **AES-GCM-256**, verify peer identity using **Safety Numbers**, and forward traffic across multi-hop relay chains without intermediate nodes ever seeing plaintext data.

---

## 2. Project Architecture: The Dual Dimensions

The NearbyChat repository bridges two complementary tracks:

```
                                  NearbyChat Repository
                                            │
           ┌────────────────────────────────┴────────────────────────────────┐
           ▼                                                                 ▼
    Dimension 1: Mobile App                                         Dimension 2: Research & Mesh
    (Flutter / Dart / BLE)                                          (Mininet-WiFi / Python / Emulation)
  • Production mobile client for Android & iOS                    • Multi-hop academic simulation & evaluation
  • Point-to-point BLE GATT dual-role transport                   • 4-10 virtual wireless nodes in line/mesh topologies
  • X25519 ECDH + AES-GCM-256 authenticated encryption            • Dynamic route recovery, packet dropper analysis
  • Local on-device persistent history & Keystore                 • Privacy-preserving trust scoring & audit logs
```

1. **The Mobile Application (`nearby_chat/`):**  
   A cross-platform Flutter application implementing real-world BLE advertising, scanning, GATT server/client dual roles, on-device hardware-backed key management, and instant encrypted chat.
2. **The Research & Mesh Simulation (`mesh_simulation/`):**  
   An academic simulation framework evaluating multi-hop forwarding, route recovery, trust scoring heuristics, and security defense boundaries across virtual nodes running in Mininet-WiFi / Linux network namespaces.

---

## 3. Repository Directory Structure

```
NearbyChat/
├── README.md, PROJECT_CONTEXT.md, TEAM_GUIDE.md
├── nearbychat_demo.html                    # browser demo: two phones, discovery, E2EE chat
├── nearbychat_relay_demo.html              # browser demo: 3 device relay with packet inspection
├── tools/                                  # Windows helpers
│   ├── START_FLUTTER_TOOLS.bat             # installs Flutter, runs analyze/test
│   ├── BUILD_APK.bat                       # analyze, test and build the APK into FOR_ANDROID
│   ├── SETUP_ANDROID_SDK.bat               # installs JDK 17 + Android SDK tools
│   └── FIX_ANDROID_BUILD.bat               # network check, Android platform install, debug APK build
├── nearby_chat/                            # TRACK 1: Flutter app
│   ├── lib/models/                         # peer, chat_message, chat_envelope
│   ├── lib/services/                       # crypto_service, ble_service, frame_codec, storage_service
│   ├── lib/controllers/chat_controller.dart
│   ├── lib/screens/, lib/widgets/          # setup, nearby people, conversation, safety number dialog
│   ├── test/                               # 34 tests
│   └── android/, ios/, windows/            # platform hosts
└── mesh_simulation/                        # TRACK 2: Python mesh (see mesh_simulation/README.md)
    ├── node_app/                           # crypto, protocol, routing, trust registry, node, CLI
    ├── topology/                           # simulated network, line topology, Mininet-WiFi script
    ├── experiments/run_experiments.py      # E1 to E5 -> results/
    ├── dashboard/                          # Flask dashboard
    ├── scripts/enroll.py                   # trusted enrolment
    ├── tests/                              # 21 tests
    └── results/                            # CSV, charts/, SUMMARY.md
```

---

## 4. Mobile System Design & Subsystems (`nearby_chat`)

The Flutter application is structured in four decoupled layers:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        User Interface (UI) Layer                       │
│      SetupScreen       │     NearbyPeopleScreen     │  ConversationScreen  │
│  (Profile/Key Gen)     │     (BLE Scanning/Peers)   │  (Chat & Verification)│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│                        Chat Controller (State)                         │
│   StreamController<List<Peer>>   │   StreamController<List<ChatMessage>>│
└───────────────────┬───────────────────────────────┬────────────────────┘
                    │                               │
┌───────────────────▼──────────────┐ ┌──────────────▼────────────────────┐
│      Crypto & Security Layer     │ │      BLE Transport Layer          │
│ • X25519 Key Agreement (ECDH)    │ │ • Peripheral: GATT Server & Adv   │
│ • AES-GCM-256 Authenticated Enc  │ │ • Central: Scanner & Client       │
│ • HKDF-SHA256 Safety Numbers     │ │ • FrameCodec: Fragmentation/MTU   │
│ • Hardware Key Storage (Keystore)│ │ • Universal BLE Integration       │
└───────────────────┬──────────────┘ └──────────────┬────────────────────┘
                    │                               │
┌───────────────────▼───────────────────────────────▼────────────────────┐
│                        Persistence & Storage                           │
│  flutter_secure_storage (Keys/Secrets) │ shared_preferences (History)   │
└────────────────────────────────────────────────────────────────────────┘
```

### 4.1. Dual-Role BLE Transport Architecture
In a decentralized environment without master routers, both phones must be capable of discovering and being discovered:
- **Peripheral Role (GATT Server):**
  - Advertises with local name: `NC-<username>` (e.g., `NC-Alice`).
  - Advertises primary Service UUID: `c0de0001-beef-11e4-8998-0002a5d5c51b`.
  - Exposes two primary characteristics:
    1. **Identity Characteristic** (UUID: `c0de0002-...`, Permissions: `READ`):  
       Returns JSON containing `{ "username": "Alice", "publicKey": "<base64_pubkey>" }`.
    2. **Inbox Characteristic** (UUID: `c0de0003-...`, Permissions: `WRITE` / `WRITE_NO_RESPONSE`):  
       Receives binary frames from external senders.
- **Central Role (GATT Client):**
  - Scans for devices matching service `c0de0001-...` or prefix `NC-`.
  - On discovery, establishes a BLE connection, discovers services, and reads the **Identity Characteristic** to register the peer in the active peer list.

### 4.2. Frame Segmentation & MTU Handling (`FrameCodec`)
BLE guarantees only a 23 byte ATT MTU (20 bytes of data per write) until a larger MTU is negotiated. Encrypted envelopes are JSON of roughly 500 to 1200 bytes.
- **MTU negotiation:** after connecting, the sender calls `requestMtu(247)` and sizes frames as `MTU - 3` (max 512). Android starts every connection at 23; iOS negotiates by itself (usually 185). If the request fails the sender falls back to 20 byte frames, which every device accepts.
- **Frame structure:** `Header` (10 bytes): `[MessageHash: 4B] [FrameIndex: 2B] [TotalFrames: 2B] [PayloadLength: 2B]`, then the payload chunk.
- **Reassembly:** `FrameReassembler` buffers frames per (sender device, message hash), accepts them in any order, drops truncated or inconsistent frames, caps buffers (100) and frames per message (500), and expires incomplete buffers after 30 s.

### 4.3. End-to-End Cryptographic Protocol
NearbyChat enforces zero-server key exchange with Perfect Forward Secrecy (PFS) under **Protocol Version 2**:
1. **Static Identity Key Generation (Once on Install):**
   - Device generates an **X25519** static identity keypair via the Dart `cryptography` package.
   - Private key is stored securely in **Android Keystore** or **iOS Keychain** via `flutter_secure_storage`.
2. **Public Key Exchange:**
   - Exchanged directly during peer discovery via GATT Identity Characteristic read.
3. **Perfect Forward Secrecy (PFS) Message Encryption:**
   - For every outgoing message, the sender generates a one-time ephemeral keypair $(e_{\text{priv}}, e_{\text{pub}})$.
   - Ephemeral shared secret:
     $$\text{pfsSecret} = \text{X25519}(e_{\text{priv}}, \text{staticPub}_{\text{recipient}})$$
   - Message key derivation via **HKDF-SHA256**:
     $$\text{messageKey} = \text{HKDF}(\text{IKM}=\text{pfsSecret}, \text{salt}=\text{"nearbychat-pfs-v1"}, \text{info}=\text{messageId})$$
   - $e_{\text{priv}}$ is wiped from memory immediately after encryption.
4. **Authenticated Encryption (AES-GCM-256) & Protocol v2 AAD:**
   - Plaintext message is encrypted with `messageKey` using **AES-GCM-256** with a 12-byte unique random nonce.
   - Additional Authenticated Data (AAD) cryptographically binds all envelope metadata:
     $$\text{AAD} = \text{version (v2)} \parallel \text{messageId} \parallel \text{senderUsername} \parallel \text{senderPub} \parallel \text{recipientPub} \parallel \text{ephemeralPub} \parallel \text{timestamp} \parallel \text{isAck} \parallel \text{originalMessageId}$$
   - This prevents intermediate relays or eavesdroppers from altering envelope headers, flags, or claimed usernames in transit without failing MAC verification.
5. **Anti-Spoofing & Sender Identity Resolution:**
   - Display names are resolved strictly from local peer storage by `senderPublicKey`.
   - Incoming messages from unknown public keys are labeled as `Unverified (<fingerprint>)`, preventing arbitrary username impersonation even if an attacker crafts an envelope with an arbitrary `senderUsername`.
   - If two peers in BLE range advertise the same display name with differing public keys, the system flags a **Name Collision** warning badge in both the peer list and chat view.
6. **Cryptographically Authenticated Delivery Receipts (HMAC-SHA256 ACKs):**
   - Recipient computes $\text{HMAC-SHA256}(\text{messageKey}, \text{"ack:"} \parallel \text{originalMessageId})$ and transmits an ACK envelope (`isAck: true`).
   - Because only the true recipient possessing the corresponding static private key can derive `messageKey`, third-party BLE eavesdroppers cannot forge delivery receipts.
   - Sender verifies the HMAC against the retained message key before transitioning status from `sent` to `delivered`.
   - Early ACKs arriving while the sender's BLE radio transmission is still in flight are buffered in an `_earlyAcks` set to prevent state desynchronization races.
7. **Mutual Safety Number Verification (Out-of-Band MITM Defense):**
   - Derived exclusively from the static-static identity secret and lexicographically sorted raw public keys:
     $$\text{staticSecret} = \text{X25519}(\text{staticPriv}_{\text{local}}, \text{staticPub}_{\text{remote}})$$
     $$\text{sortedKeys} = \min(pk_{\text{local}}, pk_{\text{remote}}) \parallel \max(pk_{\text{local}}, pk_{\text{remote}})$$
     $$\text{safetyNumber} = \text{Truncate}_{6\text{-bytes}}(\text{HKDF}(\text{IKM}=\text{staticSecret}, \text{salt}=\text{"nearbychat-safety-v1"}, \text{info}=\text{sortedKeys}))$$
   - Both users compare this 6-byte hex sequence visually in person. If cryptographic derivation fails, the session displays an explicit error state and disables verification.

8. **Replay & Freshness:**
   - A message id that was already accepted is never stored or shown again; the receiver only re-sends the ACK (the sender may have missed it).
   - The timestamp is inside the AAD, so it is authentic. Messages more than 30 minutes away from local time are rejected.
9. **Resend:** a message whose BLE write failed is marked `failed`; tapping it re-encrypts it with a new ephemeral key under the same message id, so the receiver de-duplicates it if the first copy did arrive.

### 4.3.1. Protocol Security Limitations & Trade-offs
1. **PFS Post-Restart ACK Loss:**  
   To preserve forward secrecy, ephemeral `messageKey` instances retained for verifying incoming HMAC ACKs are stored strictly in volatile RAM with a 5-minute timeout and 200-key LRU cap. If the app process terminates before an ACK is received, unverified ACKs received after app restart cannot be validated against the wiped key, leaving the message status at `sent`. Ephemeral keys are intentionally never persisted to non-volatile flash storage.
2. **Plaintext `originalMessageId` in ACK Headers:**  
   The `originalMessageId` is transmitted in the clear within the ACK envelope header to allow the sender to locate the corresponding pending message key in memory. While delivery authenticity is cryptographically guaranteed by HMAC, passive eavesdroppers observing both outgoing messages and incoming ACKs can correlate message receipts to message transmissions via this plaintext identifier (traffic correlation limitation).
3. **AAD vs. Impersonation Defense Boundary:**  
   AES-GCM AAD prevents in-transit tampering of `senderUsername`, but cannot prevent an adversary from authoring a new message using their own key with an arbitrary claimed name. Hence, trust is never anchored to `envelope.senderUsername`; the client controller and UI bind display names strictly to local public keys.

### 4.4. Persistent Storage Strategy
- **Identity & Secrets (`flutter_secure_storage`):**
  - `nearbychat.identity.private_key` (Base64)
  - `nearbychat.identity.public_key` (Base64)
  - `nearbychat.storage.db_key` (256-bit AES master database key)
- **Profile and verification flags (`shared_preferences`):** `nearbychat.profile.username`, `nearbychat.verified_peers`.
- **Chat History at Rest (`shared_preferences`):**
  - Decrypted messages are **never** stored in plaintext on disk.
  - History is encrypted with **AES-GCM-256** using the local database key with a unique 12-byte nonce per write.
  - Legacy plaintext histories are automatically and transparently migrated to encrypted envelopes on app startup.
  - In-memory decrypted cache enforces a rolling retention cap of **500 messages** per peer.

---

## 5. Multi-Hop Mesh Network Scope & Architecture

1. **Mobile client (`nearby_chat`):** one hop BLE GATT messaging with PFS encryption and HMAC ACKs. Multi-hop relaying inside the app is future work.
2. **Mesh simulation (`mesh_simulation`):** implements the multi-hop design from the project plan with real sockets and real cryptography (PyNaCl):
   - signed HELLO discovery, neighbour table with timeout, trusted enrolment registry with short authentication strings;
   - SealedBox payloads for the destination only, Ed25519 signature over header and ciphertext, node id bound to the signing key;
   - signed message id, attempt, sequence, timestamp and expiry; bounded replay cache; TTL;
   - reverse path route learning with alternate next hops; `flood`, `shortest` and `trust` routing;
   - signed end to end ACKs, retransmission that avoids the failed next hop, relay trust score;
   - security on/off baseline, simulated radio range and loss, link cuts, controlled dropper;
   - experiments E1 to E5 with CSV and charts, Flask dashboard, CLI node, Mininet-WiFi script.

---

## 6. Comparative Literature Matrix

| Feature | Signal | Briar | Bridgefy | Meshtastic | Apple AirDrop | NearbyChat |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Fully Offline (Zero Internet)** | ❌ | ✅ | ✅ | ✅ | ✅ | **✅** |
| **No External Hardware Required** | ✅ | ✅ | ✅ | ❌ (LoRa) | ✅ | **✅ (BLE Only)** |
| **No Account / Phone Number** | ❌ | ✅ | ❌ | ✅ | ❌ (Apple ID) | **✅** |
| **True End-to-End Encryption** | ✅ | ✅ | ⚠️ (Proprietary) | ⚠️ (Pre-shared) | ⚠️ | **✅ (X25519 + GCM)** |
| **Cross-Platform (Android + iOS)**| ✅ | ❌ (Android only)| ✅ | ✅ | ❌ (Apple only)| **✅ (Flutter)** |
| **In-Person Identity Verification**| ✅ (Safety No.)| ✅ (QR Link)| ❌ | ❌ | ❌ | **✅ (Safety No.)** |
| **Store-and-Forward / History** | ✅ (Cloud) | ✅ (Local DB) | ❌ | ❌ | ❌ | **✅ (On-Device)** |
| **Single Shared Codebase** | ❌ | ❌ | ❌ | ❌ | ❌ | **✅ (Dart/Flutter)** |

---

## 7. Threat Model & Security Controls

| Threat | Mobile app control | Mesh simulation control |
| :--- | :--- | :--- |
| **Eavesdropping** | AES-GCM-256 with per message ephemeral key; plaintext never on the radio | SealedBox for the destination; relays see ciphertext only (test T4) |
| **MITM / key substitution** | In person Safety Number comparison | Trusted registry from out of band enrolment; substituted keys rejected |
| **Impersonation** | Names bound to locally known public keys; unknown keys shown as Unverified | Node id must equal SHA-256(signing key); unknown ids rejected (T7) |
| **Tampering** | GCM tag + AAD over every header field | Ed25519 signature over header and ciphertext (T5) |
| **Replay** | Seen message id set + 30 minute timestamp window | Signed id/attempt/expiry + bounded replay cache (T6) |
| **Dropper / black hole** | Delivery shown only after authenticated ACK; failed messages can be resent | ACK timeout, retransmission around the failed hop, trust score (T8, E5) |
| **Flooding** | Frame buffer and frame count caps | TTL, duplicate suppression, payload cap, per sender rate limit |
| **Key extraction** | Keys in Keystore / Keychain via flutter_secure_storage | Key files with mode 600, never logged or committed |

Out of scope: physical device compromise, jamming, global traffic analysis.

---

## 8. Technology Stack & Dependencies

| Layer / Subsystem | Package / Tool | Version | Purpose |
| :--- | :--- | :--- | :--- |
| **Core Language** | Dart | `^3.5.0` | Null-safe client runtime |
| **UI Framework** | Flutter | `3.44+` (tested 3.47.7) | Plain Material 3 light UI |
| **BLE Transport** | `universal_ble` | `^2.2.0` (locked 2.3.0) | Central and Peripheral GATT roles, MTU request |
| **Cryptography** | `cryptography` | `^2.7.0` | X25519, HKDF, AES-GCM-256, HMAC-SHA256 |
| **Key Persistence** | `flutter_secure_storage` | `^9.2.2` | Keystore / Keychain |
| **Message History** | `shared_preferences` | `^2.3.2` | Encrypted history blobs, profile |
| **Identifiers** | `dart:math` (built in) | | Random UUID v4 message ids |
| **Permissions** | `permission_handler` | `^11.3.1` | Bluetooth / location runtime permissions |
| **Laptop node** | bleak, cryptography | | BLE (WinRT) and the same crypto as the app; web page served with the Python standard library |
| **Simulation crypto** | PyNaCl (libsodium) | `>=1.5` | Ed25519, SealedBox |
| **Simulation dashboard** | Flask | `>=3.0` | Local dashboard |
| **Charts** | Matplotlib | `>=3.7` | Experiment charts |
| **Tests** | pytest / flutter_test | | 21 Python and 34 Flutter tests |
| **Emulation** | Mininet-WiFi | 2.6 | Optional wireless emulation (Ubuntu, root) |
| **Documents** | python-docx | `1.2` | Synopsis and project plan generator |

---

## 9. Implementation Roadmap & Current Status

| Phase | Content | Status |
| :--- | :--- | :--- |
| 1 Scaffold | Flutter project, dependencies, Android manifest and iOS Info.plist Bluetooth permissions | Done |
| 2 BLE transport | Advertising, GATT server, scanning, identity read, inbox writes, FrameCodec, MTU negotiation | Done |
| 3 Cryptography | X25519 identity, per message PFS keys, AES-GCM AAD, HMAC ACKs, Safety Numbers | Done |
| 4 UI and state | Setup, Nearby People, Conversation screens, ChatController, resend failed messages | Done |
| 5a Simulation | Mesh nodes, routing, security, experiments E1 to E5, dashboard | Done |
| 5b Device testing | Two phones (Android + iOS or two Android), MTU and range checks | To do |
| 5c Mininet-WiFi run | Run `mininet_topology.py` on Ubuntu and add the CSVs to results | To do |
| Future | Multi-hop relaying inside the app | Not started |

Checks: `flutter analyze` no issues, `flutter test` 34/34, `pytest mesh_simulation/tests` 21/21.

---

## 10. Developer Guide & Usage Commands

### Mobile app
```bash
cd nearby_chat
flutter pub get
flutter analyze
flutter test
flutter run                 # phone connected by USB with developer mode on
flutter build apk --debug   # needs the Android SDK (tools/SETUP_ANDROID_SDK.bat on Windows)
```

### Mesh simulation
```bash
pip install -r mesh_simulation/requirements.txt
python -m pytest mesh_simulation/tests -v
python -m mesh_simulation.experiments.run_experiments
python -m mesh_simulation.dashboard.app                 # http://127.0.0.1:5000
sudo python3 -m mesh_simulation.topology.mininet_topology --topology line   # Ubuntu + Mininet-WiFi
```

### Browser demos
Open `nearbychat_demo.html` (two phones) or `nearbychat_relay_demo.html` (three device relay) in a browser.

