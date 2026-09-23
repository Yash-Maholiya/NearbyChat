# NearbyChat — Mobile Application

[![Flutter](https://img.shields.io/badge/Flutter-3.44+-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platform](https://img.shields.io/badge/Platforms-Android%20%7C%20iOS-green)]()
[![Encryption](https://img.shields.io/badge/E2EE-X25519%20%2B%20AES--GCM--256-blue)]()

**NearbyChat** is a cross-platform, serverless, off-grid direct messaging app for Android and iOS. It enables two or more devices within Bluetooth Low Energy (BLE) range to exchange end-to-end encrypted messages without internet access, cellular networks, external hardware, or centralized accounts.

---

## Key Features

- **Zero Server / Zero Internet:** Operates purely using the phone's native BLE radio.
- **Dual-Role BLE Architecture:** Simultaneously functions as a GATT Server (Peripheral advertising `NC-<username>`) and GATT Client (Central scanning and transmitting).
- **End-to-End Encryption:**
  - **X25519** Elliptic Curve Diffie-Hellman (ECDH) key agreement.
  - **AES-GCM-256** authenticated encryption with 128-bit MAC tags and AAD binding.
  - **Safety Numbers:** 6-byte hex fingerprint (`xx-xx-xx-xx-xx-xx`) for in-person visual verification against Man-in-the-Middle (MITM) attacks.
- **Hardware-Backed Keystore:** Private keys are generated on-device and stored in Android Keystore / iOS Keychain via `flutter_secure_storage`.
- **ATT MTU Fragmentation:** Custom `FrameCodec` fragments envelopes into chunks safe for the 20-byte ATT MTU minimum and reassembles out-of-order packets.
- **Local Rolling History:** Chat history is retained locally in `SharedPreferences` with a strict rolling 500-message limit per peer to prevent unbounded memory growth.
- **Material 3 Dark UI:** Sleek, high-contrast dark theme with radar peer discovery, signal strength (RSSI) indicators, and delivery status receipts.

---

## Architecture

```
lib/
├── main.dart                                 # App bootstrapper, Material 3 Dark theme & routing
├── models/
│   ├── peer.dart                             # Peer model with RSSI, key fingerprint & verification
│   ├── chat_message.dart                     # Chat message model with delivery status & JSON serialization
│   └── chat_envelope.dart                    # Encrypted wire packet (IV, ciphertext, GCM tag, AAD)
├── services/
│   ├── crypto_service.dart                   # X25519 ECDH, SHA-256 KDF, AES-GCM-256, Safety Numbers
│   ├── frame_codec.dart                      # BLE MTU fragmentation & out-of-order reassembler
│   ├── storage_service.dart                  # Hardware Keystore + rolling 500-msg history window
│   └── ble_service.dart                      # Dual-role Peripheral (GATT server) & Central manager
├── controllers/
│   └── chat_controller.dart                  # ChangeNotifier orchestrator for UI, BLE & Cryptography
├── screens/
│   ├── setup_screen.dart                     # First-run onboarding & on-device keypair generation
│   ├── nearby_people_screen.dart             # Peer radar view with RSSI indicators & verified badges
│   └── conversation_screen.dart              # Real-time chat with Safety Number banner & message bubbles
└── widgets/
    ├── chat_bubble.dart                      # Encrypted message bubble with delivery receipt icons
    └── safety_number_dialog.dart             # Out-of-band MITM visual verification modal
```

---

## Getting Started

### Prerequisites
- Flutter SDK `^3.44.0`
- Android Studio / Xcode

### Setup & Run
```bash
# 1. Install dependencies
flutter pub get

# 2. Run static analysis
flutter analyze

# 3. Run automated unit test suite
flutter test

# 4. Run on a connected device
flutter run
```

---

## Security & Privacy Model

| Threat | Defensive Countermeasure |
| :--- | :--- |
| **Eavesdropping on BLE Radio** | Plaintext never touches the radio; payloads are encrypted with AES-GCM-256 using ephemeral IVs. |
| **Man-in-the-Middle (MITM)** | In-person comparison of the 6-byte hex Safety Number (`SHA-256(sharedSecret)[0..5]`). |
| **Packet Tampering** | 128-bit GCM authentication tags + canonical AAD binding message IDs and timestamps to ciphertext. |
| **Replay Attacks** | Unique UUIDv4 identifiers, epoch timestamps, validity windows, and local duplicate suppression. |
| **Key Extraction** | Private keys are locked in Android Keystore / iOS Secure Enclave hardware storage. |
