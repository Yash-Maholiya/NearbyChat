# Project Context: NearbyChat (Secure Peer-to-Peer Mesh Communication System)

> **Document Type:** System Architecture, Technical Context & Development Guide  
> **Project Name:** NearbyChat  
> **Academic Title:** Design and Security Analysis of a Secure Peer-to-Peer Mesh Communication System  
> **Authors:** Yash (Reg. No. 24BCT0155) & Rohan (Reg. No. 24BKT0060)  
> **Target Platforms:** Android 7.0+ (API 21) & iOS 13.0+ (Flutter 3.44+, Dart 3.x)  
> **Network Transport:** Bluetooth Low Energy (BLE) Dual-Role (Central + Peripheral)  
> **Last Updated:** September 2026  

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
  • Point-to-point BLE GATT dual-role transport                   • 4–10 virtual wireless nodes in line/mesh topologies
  • X25519 ECDH + AES-GCM-256 authenticated encryption            • Dynamic route recovery, packet dropper analysis
  • Local on-device persistent history & Keystore                 • Privacy-preserving trust scoring & audit logs
```

1. **The Mobile Application (`nearby_chat/`):**  
   A cross-platform Flutter application implementing real-world BLE advertising, scanning, GATT server/client dual roles, on-device hardware-backed key management, and instant encrypted chat.
2. **The Research & Mesh Simulation (`project_documents/`, `build_mesh_documents.py`):**  
   An academic simulation framework evaluating multi-hop forwarding, route recovery, trust scoring heuristics, and security defense boundaries across virtual nodes running in Mininet-WiFi / Linux network namespaces.

---

## 3. Repository Directory Structure

```
d:/NearbyChat/
│
├── PROJECT_CONTEXT.md                  # Comprehensive project context & architecture guide (This file)
├── build_mesh_documents.py             # Automated docx builder for project synopsis & plan
├── NearbyChat_Presentation.pdf         # 14-slide academic / technical presentation (PDF)
├── NearbyChat_Presentation.pptx        # 14-slide academic / technical presentation (PowerPoint)
├── nearbychat_demo.html                # Interactive dual-phone BLE discovery & E2EE simulator
├── nearbychat_relay_demo.html          # Interactive 3-device multi-hop BLE mesh relay simulator
│
├── .tools/                             # Local development tooling
│   └── flutter/                        # Embedded Flutter SDK runtime
│
├── project_documents/                  # Academic specifications, research guides, and test plans
│   ├── Complete_Project_Plan_Secure_Mesh_System.docx   # Full implementation guide & test methodology
│   ├── Project_Synopsis_Secure_Mesh_System.docx        # Condensed academic project synopsis
│   ├── qa_full/                        # Quality assurance and verification logs (Full)
│   └── qa_synopsis/                    # Quality assurance and verification logs (Synopsis)
│
└── nearby_chat/                        # Production Flutter mobile codebase
    ├── pubspec.yaml                    # Dart SDK 3.5.0+, dependencies, assets definition
    ├── pubspec.lock                    # Resolved package dependency lockfile
    ├── analysis_options.yaml           # Linting rules (`flutter_lints ^5.0.0`)
    ├── README.md                       # Mobile app getting started guide
    ├── android/                        # Android host project (Gradle, API 21+, Kotlin)
    │   └── app/src/main/AndroidManifest.xml  # Android permissions & BLE configurations
    ├── ios/                            # iOS host project (Xcode, CocoaPods, Swift)
    ├── test/                           # Flutter unit and widget tests
    └── lib/                            # Application source code
        └── main.dart                   # Application entry point & screen router
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
│ • SHA-256 Safety Number Derivation│ │ • FrameCodec: Fragmentation/MTU   │
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
Standard BLE ATT MTU guarantees as low as **23 bytes** (3 bytes ATT header + 20 bytes data payload). Encrypted envelopes with ciphertext, IVs, tags, and metadata span 300–1200 bytes.
- **Packet Structure:**
  - `Header` (8 bytes): `[MessageID: 2B] [FrameIndex: 2B] [TotalFrames: 2B] [PayloadLength: 2B]`
  - `Payload` (variable, typically 12–180 bytes depending on negotiated MTU).
- **Reassembly:**  
  The receiver’s `FrameReassembler` buffers frames indexed by `MessageID`. Once all `TotalFrames` are collected, the payload is concatenated and passed to the crypto decoding pipeline.

### 4.3. End-to-End Cryptographic Protocol
NearbyChat enforces zero-server key exchange with Perfect Forward Secrecy (PFS):
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
4. **Authenticated Encryption (AES-GCM-256) & AAD:**
   - Plaintext message is encrypted with `messageKey` using **AES-GCM-256** with a 12-byte unique random nonce.
   - Additional Authenticated Data (AAD) cryptographically binds:
     $$\text{AAD} = \text{version} \parallel \text{messageId} \parallel \text{senderUsername} \parallel \text{senderPub} \parallel \text{recipientPub} \parallel \text{ephemeralPub} \parallel \text{timestamp}$$
   - This ensures intermediate relays or transport layers cannot alter message headers or usernames in transit without failing MAC authentication.
5. **Anti-Spoofing & Sender Identity Resolution:**
   - Display names are resolved strictly from local peer storage by `senderPublicKey`.
   - Incoming messages from unknown public keys are labeled as `Unverified (<fingerprint>)`, preventing arbitrary username impersonation.
6. **Authenticated Delivery Receipts (HMAC-SHA256 ACKs):**
   - Recipient computes $\text{HMAC-SHA256}(\text{messageKey}, \text{"ack:"} \parallel \text{messageId})$ and transmits an ACK envelope.
   - Sender verifies the HMAC against the retained message key before transitioning status from `sent` to `delivered`.
   - ACKs are never ACKed (preventing loops) and only apply to messages in the `sent` state.
7. **Mutual Safety Number Verification (Out-of-Band MITM Defense):**
   - Derived exclusively from the static-static identity secret and lexicographically sorted raw public keys:
     $$\text{staticSecret} = \text{X25519}(\text{staticPriv}_{\text{local}}, \text{staticPub}_{\text{remote}})$$
     $$\text{sortedKeys} = \min(pk_{\text{local}}, pk_{\text{remote}}) \parallel \max(pk_{\text{local}}, pk_{\text{remote}})$$
     $$\text{safetyNumber} = \text{Truncate}_{6\text{-bytes}}(\text{HKDF}(\text{IKM}=\text{staticSecret}, \text{salt}=\text{"nearbychat-safety-v1"}, \text{info}=\text{sortedKeys}))$$
   - Both users compare this 6-byte hex sequence visually in person. If cryptographic derivation fails, the session displays an explicit error state and disables verification.

### 4.4. Persistent Storage Strategy
- **Identity & Secrets (`flutter_secure_storage`):**
  - `nearbychat.identity.private_key` (Base64)
  - `nearbychat.identity.public_key` (Base64)
  - `nearbychat.profile.username`
  - `nearbychat.storage.db_key` (256-bit AES master database key)
- **Chat History at Rest (`shared_preferences`):**
  - Decrypted messages are **never** stored in plaintext on disk.
  - History is encrypted with **AES-GCM-256** using the local database key with a unique 12-byte nonce per write.
  - Legacy plaintext histories are automatically and transparently migrated to encrypted envelopes on app startup.
  - In-memory decrypted cache enforces a rolling retention cap of **500 messages** per peer.

---

## 5. Multi-Hop Mesh Network Scope & Architecture

NearbyChat bridges two architectural dimensions:
1. **Production Mobile Client (`nearby_chat`):**  
   Implements a hardened, zero-infrastructure **1-hop Point-to-Point BLE GATT transport** with dual-role Central/Peripheral discovery, PFS encryption, and HMAC ACKs. Multi-hop mesh relay is deferred to Phase 5 / Future Work to ensure production stability.
2. **Academic Mesh Emulation & Research (`project_documents`, `mesh_simulation`):**  
   Academic simulation framework modeling multi-hop store-and-forward mesh routing, TTL, packet dropper analysis, and trust scoring heuristics in Mininet-WiFi / virtual network namespaces.

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

| Threat Vector | Unmitigated Impact | NearbyChat Defensive Control |
| :--- | :--- | :--- |
| **Radio Eavesdropping** | Attacker sniffing BLE traffic captures message text. | Payloads encrypted via **AES-GCM-256** with unique IVs; plaintext never touches radio hardware. |
| **Man-in-the-Middle (MITM)** | Attacker injects their public key during discovery. | **Safety Number verification**: Out-of-band visual/spoken fingerprint match catches key substitution. |
| **Replay Attacks** | Attacker replays captured packets to duplicate actions. | Unique UUIDv4, sequence number, millisecond timestamp, validity window, and bounded replay cache. |
| **Packet Tampering** | Relays alter payload or headers in transit. | 128-bit **GCM authentication tag** + sender **Ed25519 signature** verify byte-exact integrity. |
| **Packet Dropper / Black Hole** | Malicious relay accepts and silently drops traffic. | End-to-end signed delivery ACKs; missing ACKs trigger dynamic relay rerouting and trust score penalty. |
| **Device Key Extraction** | Malware extracts keys from device flash memory. | Keys stored in hardware-backed storage (**Android Keystore** / **iOS Secure Enclave**). |

---

## 8. Technology Stack & Dependencies

| Layer / Subsystem | Package / Tool | Version | Purpose |
| :--- | :--- | :--- | :--- |
| **Core Language** | Dart | `^3.5.0` | Strongly typed, null-safe client runtime |
| **UI Framework** | Flutter | `3.44+` | Declarative UI, Material Design 3, Dark Mode |
| **BLE Transport** | `universal_ble` | `^2.2.0` | Cross-platform BLE Central & Peripheral GATT roles |
| **Cryptography** | `cryptography` | `^2.7.0` | X25519 key agreement, AES-GCM-256, SHA-256, Ed25519 |
| **Key Persistence** | `flutter_secure_storage` | `^9.2.2` | Keystore / Keychain hardware-backed key persistence |
| **Message History** | `shared_preferences` | `^2.3.2` | Fast, lightweight on-device JSON history store |
| **Identifiers** | `uuid` | `^4.5.1` | RFC4122 v4 unique identifier generation |
| **Permissions** | `permission_handler` | `^11.3.1` | Android/iOS runtime permission negotiation |
| **Document Generator**| `python-docx` | `^1.2.0` | Generates standardized academic reports and synopses |
| **Mesh Emulation** | Mininet-WiFi & Python | `3.10+` | Virtual wireless station emulation, mobility & loss testing |

---

## 9. Implementation Roadmap & Current Status

```
[Phase 1: Scaffold] ──► [Phase 2: BLE Transport] ──► [Phase 3: Crypto Engine] ──► [Phase 4: UI] ──► [Phase 5: Test & Mesh]
   (IN PROGRESS)             (QUEUED)                     (QUEUED)                  (QUEUED)            (QUEUED)
```

1. **Phase 1: Project Scaffold & OS Permissions** *(In Progress)*
   - [x] Flutter project initialization (`nearby_chat/`).
   - [x] Dependencies added to `pubspec.yaml`.
   - [ ] Android manifest permissions (`BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION`).
   - [ ] iOS Info.plist declarations (`NSBluetoothAlwaysUsageDescription`, `NSBluetoothPeripheralUsageDescription`).
2. **Phase 2: BLE Transport Engine**
   - [ ] Peripheral mode: GATT server setup, identity service advertising (`NC-<username>`).
   - [ ] Central mode: BLE scanner, connection manager, characteristic discovery.
   - [ ] `FrameCodec`: Fragmentation and reassembly over 20-byte to 512-byte ATT MTU.
3. **Phase 3: Cryptography Services**
   - [ ] Key generation & hardware keystore integration (`flutter_secure_storage`).
   - [ ] X25519 ECDH key exchange & shared secret derivation.
   - [ ] AES-GCM-256 envelope encryption/decryption with AAD.
   - [ ] Safety number generation and visual comparison widget.
4. **Phase 4: User Interface & State Management**
   - [ ] `SetupScreen`: First-launch username configuration & key initialization.
   - [ ] `NearbyPeopleScreen`: Radar/List of discovered peers with signal indicators.
   - [ ] `ConversationScreen`: Real-time chat bubbles, delivery receipt markers, safety number viewer.
   - [ ] `ChatController`: Stream-based reactive orchestration between UI, BLE, and crypto.
5. **Phase 5: Evaluation & Multi-Hop Extensions**
   - [ ] Integration testing with two physical devices (Android + iOS).
   - [ ] Mininet-WiFi line-topology and mesh-topology script execution.
   - [ ] Store-and-forward mesh routing algorithm integration.

---

## 10. Developer Guide & Usage Commands

### Running Interactive Web Simulators
Two full-featured web simulators are available directly in the project root:
- **Direct P2P E2EE Simulator:** Open `nearbychat_demo.html` in any modern browser to test dual-phone key generation, BLE discovery, and interactive AES-GCM message exchange.
- **Multi-Hop Relay Simulator:** Open `nearbychat_relay_demo.html` to simulate 3-device multi-hop routing, packet forwarding, deep packet inspection (DPI), and packet tampering.

### Generating Academic Documentation
To regenerate the Word documentation for the project synopsis and plan:
```bash
python build_mesh_documents.py
```
Outputs generated in `d:/NearbyChat/project_documents/`:
- `Complete_Project_Plan_Secure_Mesh_System.docx`
- `Project_Synopsis_Secure_Mesh_System.docx`

### Developing the Mobile Application
Navigate to the Flutter directory and ensure dependencies are installed:
```bash
cd nearby_chat
flutter pub get
flutter analyze
flutter test
```
To run on a connected Android or iOS device:
```bash
flutter run
```
