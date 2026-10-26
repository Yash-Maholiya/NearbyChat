# NearbyChat Mobile App

Flutter app for Android and iOS. Two phones within Bluetooth Low Energy range find each other and
exchange end to end encrypted messages with no internet, no server and no account.

## Features

* **No server, no internet.** Uses only the phone's BLE radio.
* **Dual role BLE.** Each phone is a GATT server (advertises `NC-<username>`) and a GATT client
  (scans, reads the peer's identity, writes to its inbox) at the same time.
* **Encryption with forward secrecy.** A fresh X25519 ephemeral key per message, HKDF-SHA256
  message key, AES-GCM-256 with every header field in the AAD.
* **Authenticated delivery receipts.** HMAC-SHA256 ACKs that only the real recipient can make.
* **Safety numbers.** 6 byte fingerprint (`xx-xx-xx-xx-xx-xx`) to compare in person against MITM.
* **Replay protection.** Duplicate messages are never shown twice; stale messages are rejected.
* **MTU aware framing.** Negotiates a larger MTU and falls back to 20 byte writes when it cannot.
* **Resend.** Tap a failed message to send it again.
* **Encrypted history.** AES-GCM-256 at rest, rolling 500 messages per peer.

## Architecture

```
lib/
  main.dart                       bootstraps services, dark Material 3 theme, first screen
  models/
    peer.dart                     peer with RSSI, fingerprint, safety number, verification flags
    chat_message.dart             message with delivery status
    chat_envelope.dart            wire packet (ephemeral key, nonce, ciphertext, tag, AAD)
  services/
    crypto_service.dart           identity keys, PFS encryption, ACK HMAC, safety numbers
    frame_codec.dart              fragmentation by MTU and out of order reassembly
    storage_service.dart          secure storage keys, encrypted history
    ble_service.dart              peripheral (GATT server) and central roles, MTU request
  controllers/
    chat_controller.dart          ties UI, BLE and crypto together; replay checks; resend
  screens/                        setup, nearby people, conversation
  widgets/                        chat bubble, safety number dialog
test/                             34 tests
```

## Run

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

## Security model

| Threat | Countermeasure |
| :--- | :--- |
| Eavesdropping on the radio | AES-GCM-256 with a per message key; plaintext never leaves the phone |
| Man in the middle | In person comparison of the Safety Number (HKDF over the static X25519 secret and both keys) |
| Tampering | 128 bit GCM tag; AAD covers ids, keys, timestamp and ACK fields |
| Replay | Seen message ids are not stored again; 30 minute timestamp window |
| Impersonation | Names come from the locally known public key; unknown keys are shown as Unverified |
| Key extraction | Private key in Android Keystore / iOS Keychain via flutter_secure_storage |
