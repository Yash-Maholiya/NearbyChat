# NearbyChat — Secure Peer-to-Peer Mesh Communication System

[![Flutter Tests](https://img.shields.io/badge/Flutter%20Tests-17%2F17%20Passing-brightgreen)]()
[![Python Tests](https://img.shields.io/badge/Python%20Tests-9%2F9%20Passing-brightgreen)]()
[![Analyze](https://img.shields.io/badge/Flutter%20Analyze-0%20Issues-brightgreen)]()
[![License](https://img.shields.io/badge/License-MIT-blue.svg)]()

> **Academic Project:** Design and Security Analysis of a Secure Peer-to-Peer Mesh Communication System  
> **Authors:** Yash (Reg. No. 24BCT0155) & Rohan (Reg. No. 24BKT0060)  
> **Target Platforms:** Android 7.0+ (API 21) & iOS 13.0+ (Flutter 3.44+)  
> **Transports:** Bluetooth Low Energy (BLE) Dual-Role (Mobile App) & Mininet-WiFi / UDP Sockets (Simulation Suite)

---

## 1. Executive Summary

**NearbyChat** is an infrastructure-independent, serverless, off-grid communication platform designed for scenarios where cellular towers, internet services, and centralized infrastructure are unavailable (natural disasters, network blackouts, remote facilities, high-privacy environments).

NearbyChat bridges two complementary engineering tracks:
1. **Production Mobile Application (`nearby_chat/`):** A cross-platform Flutter application for Android and iOS providing direct, zero-server encrypted messaging over native Bluetooth Low Energy (BLE) Dual-Role GATT connections.
2. **Academic Simulation Prototype (`mesh_simulation/`):** A Python-based multi-hop mesh network prototype supporting store-and-forward relaying over untrusted nodes, dynamic route recovery, and relay trust scoring (executable via local sockets or Mininet-WiFi).

---

## 2. Repository Layout

```
d:/NearbyChat/
│
├── README.md                           # Master project documentation (This file)
├── PROJECT_CONTEXT.md                  # Comprehensive architectural & cryptographic context
├── NearbyChat_Presentation.pdf         # 14-slide academic / technical presentation (PDF)
├── NearbyChat_Presentation.pptx        # 14-slide academic / technical presentation (PowerPoint)
├── nearbychat_demo.html                # Interactive dual-phone BLE discovery & E2EE simulator
├── nearbychat_relay_demo.html          # Interactive 3-device multi-hop BLE mesh relay simulator
├── build_mesh_documents.py             # Word document generator for project plan & synopsis
│
├── nearby_chat/                        # [TRACK 1] Production Flutter Mobile Application
│   ├── lib/                            # Dart source code (models, crypto, BLE, controllers, UI)
│   ├── test/                           # 17 automated unit and widget tests (100% passing)
│   ├── android/                        # Android host configurations & BLE permissions
│   └── ios/                            # iOS host configurations & Bluetooth usage descriptions
│
├── mesh_simulation/                    # [TRACK 2] Academic Python Mesh Simulation Suite
│   ├── node_app/                       # PyNaCl crypto, packet protocol, routing & Node daemon
│   ├── topology/                       # 4-node line topology (A <-> B <-> C <-> D)
│   ├── tests/                          # 9 automated pytest test scenarios (100% passing)
│   └── requirements.txt                # Python dependencies (PyNaCl, pytest)
│
└── project_documents/                  # Generated academic deliverables
    ├── Complete_Project_Plan_Secure_Mesh_System.docx
    └── Project_Synopsis_Secure_Mesh_System.docx
```

---

## 3. Cryptographic Architecture

NearbyChat enforces zero-knowledge, end-to-end security without a central key authority:

```
[Alice]                                                                     [Bob]
   │                                                                          │
   ├────────── X25519 Public Key Exchange (via BLE Identity Read) ───────────►│
   │◄─────────────────────────────────────────────────────────────────────────┤
   │                                                                          │
   ▼                                                                          ▼
sharedSecret = X25519(privA, pubB)                         sharedSecret = X25519(privB, pubA)
                               (Identical Shared Secret)
   │                                                                          │
   ▼                                                                          ▼
messageKey = SHA-256("nearbychat-v1" || secret)            messageKey = SHA-256("nearbychat-v1" || secret)
Safety No = SHA-256(secret)[0..5] ("a3-f7-2c-10-b8-44")    Safety No = SHA-256(secret)[0..5] ("a3-f7-2c-10-b8-44")
   │                                                                          │
   ├── Encrypt: AES-GCM-256(plaintext, messageKey, Nonce, AAD) ──────────────►│
   │                                                              Decrypt & Verify MAC Tag
```

- **Confidentiality:** **AES-GCM-256** with unique 12-byte initialization vectors per message.
- **Authenticity & Integrity:** 128-bit GCM MAC tag with canonical Additional Authenticated Data (AAD) binding message IDs, timestamps, and participant keys.
- **MITM Defense:** In-person visual/spoken comparison of the 6-byte hex **Safety Number**.
- **Untrusted Relays:** Intermediary nodes observe only outer routing headers (TTL, hops, destination); the payload remains completely unreadable and tamper-evident.

---

## 4. Verification & Automated Test Status

### Track 1: Flutter Mobile App
```bash
cd nearby_chat
flutter analyze
flutter test
```
- **Static Analysis:** `No issues found! (0 errors, 0 warnings)`
- **Automated Tests:** **`17/17 PASSED`**
  - Identities initialized with valid base64 keys and fingerprints
  - X25519 shared secret derivation is symmetric
  - Safety Number derivation matches on both sides
  - AES-GCM-256 encryption and decryption roundtrip succeeds
  - Tampering with ciphertext causes authentication failure
  - Tampering with AAD header causes authentication failure
  - Large payloads correctly sliced and reassembled across 20-byte MTUs
  - Out-of-order frame arrival reassembles correctly
  - Corrupted and truncated frames are safely discarded
  - Strict rolling 500-message history cap enforced
  - Message delivery status updates
  - Setup screen launches correctly on clean start

### Track 2: Python Mesh Network Simulation
```bash
pytest mesh_simulation/tests/ -v
```
- **Automated Tests:** **`9/9 PASSED`**
  - Key generation and 12-char fingerprint derivation
  - Ed25519 digital signature generation and verification
  - SealedBox Curve25519 encryption and decryption
  - Tampered ciphertext rejection
  - 3-hop multi-hop relaying across NodeA -> NodeB -> NodeC -> NodeD
  - End-to-end delivery acknowledgements (D -> C -> B -> A)
  - Intermediary relays cannot read plaintext payloads
  - Tampered signature packets dropped at relay
  - ReplayCache duplicate suppression and timestamp expiry

---

## 5. Interactive Web Demos

Experience the dual-role BLE and multi-hop mesh workflows directly in any web browser without installation:

1. **[nearbychat_demo.html](file:///d:/NearbyChat/nearbychat_demo.html):**  
   Simulates two phones (Alice and Bob) side-by-side. Demonstrates identity setup, BLE scanning/discovery, X25519 ECDH shared secret derivation, and step-by-step AES-GCM-256 encrypted chat.
2. **[nearbychat_relay_demo.html](file:///d:/NearbyChat/nearbychat_relay_demo.html):**  
   Simulates a 3-device multi-hop BLE mesh relay (Alice $\to$ Relay $\to$ Bob). Features a Deep Packet Inspection (DPI) panel demonstrating how relays forward ciphertext without the ability to decrypt the payload.

---

## 6. How to Run & Build

### Mobile App (Flutter)
```bash
cd nearby_chat
flutter pub get
flutter run
```

### Python Mesh Simulation (Sockets / Local Topology)
```bash
python -m mesh_simulation.topology.line_topology
```

### Generate Academic Word Documents
```bash
python build_mesh_documents.py
```
Outputs generated in `project_documents/`:
- `Complete_Project_Plan_Secure_Mesh_System.docx`
- `Project_Synopsis_Secure_Mesh_System.docx`
