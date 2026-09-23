import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_envelope.dart';

class _PendingKeyEntry {
  final SecretKey key;
  final DateTime createdAt;

  _PendingKeyEntry(this.key, this.createdAt);
}

class CryptoService {
  static const String _privKeyStorageKey = 'nearbychat.identity.private_key';
  static const String _pubKeyStorageKey = 'nearbychat.identity.public_key';
  static const Duration pendingKeyTimeout = Duration(minutes: 5);

  final FlutterSecureStorage _storage;
  final X25519 _x25519 = X25519();
  final AesGcm _aesGcm = AesGcm.with256bits();
  final Uuid _uuid = const Uuid();

  SimpleKeyPair? _keyPair;
  String? _publicKeyBase64;

  final Map<String, _PendingKeyEntry> _pendingMessageKeys = {};

  CryptoService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Returns whether identity keypair has been loaded or generated.
  bool get isInitialized => _keyPair != null && _publicKeyBase64 != null;

  /// Public key encoded in standard Base64.
  String get publicKeyBase64 {
    if (_publicKeyBase64 == null) {
      throw StateError('CryptoService has not been initialized. Call init() first.');
    }
    return _publicKeyBase64!;
  }

  /// Short cryptographic fingerprint (first 12 characters of public key).
  String get fingerprint {
    final pk = publicKeyBase64;
    return pk.length > 12 ? pk.substring(0, 12) : pk;
  }

  /// Initializes cryptographic identity. Loads from Secure Storage, recovers from partial state, or generates a new X25519 pair.
  Future<void> init({SimpleKeyPair? testKeyPair}) async {
    if (testKeyPair != null) {
      _keyPair = testKeyPair;
      final pub = await testKeyPair.extractPublicKey();
      _publicKeyBase64 = base64Encode(pub.bytes);
      return;
    }

    final savedPriv = await _storage.read(key: _privKeyStorageKey);
    final savedPub = await _storage.read(key: _pubKeyStorageKey);

    if (savedPriv != null && savedPub != null) {
      final privBytes = base64Decode(savedPriv);
      final pubBytes = base64Decode(savedPub);
      _keyPair = SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
      _publicKeyBase64 = savedPub;
    } else if (savedPriv != null && savedPub == null) {
      // Recover public key from private key seed
      final privBytes = base64Decode(savedPriv);
      final newPair = await _x25519.newKeyPairFromSeed(privBytes);
      final pubKey = await newPair.extractPublicKey();
      final pubBytes = pubKey.bytes;
      final pubB64 = base64Encode(pubBytes);
      await _storage.write(key: _pubKeyStorageKey, value: pubB64);
      _keyPair = newPair;
      _publicKeyBase64 = pubB64;
      debugPrint('[CryptoService] Recovered missing public key from stored private key.');
    } else {
      // Generate new keypair
      final newPair = await _x25519.newKeyPair();
      final privBytes = await newPair.extractPrivateKeyBytes();
      final pubKey = await newPair.extractPublicKey();
      final pubBytes = pubKey.bytes;

      final privB64 = base64Encode(privBytes);
      final pubB64 = base64Encode(pubBytes);

      await _storage.write(key: _privKeyStorageKey, value: privB64);
      await _storage.write(key: _pubKeyStorageKey, value: pubB64);

      _keyPair = newPair;
      _publicKeyBase64 = pubB64;
    }
  }

  /// Derives static-static symmetric shared secret with remote party via X25519 ECDH.
  Future<Uint8List> deriveSharedSecret(String remotePublicKeyBase64) async {
    if (_keyPair == null) {
      throw StateError('CryptoService not initialized.');
    }
    final remotePubBytes = base64Decode(remotePublicKeyBase64);
    final remotePublicKey = SimplePublicKey(
      remotePubBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecretKey = await _x25519.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: remotePublicKey,
    );
    final secretBytes = await sharedSecretKey.extractBytes();
    return Uint8List.fromList(secretBytes);
  }

  /// Helper to compare byte lists lexicographically.
  static int _compareBytes(List<int> a, List<int> b) {
    final len = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < len; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return a.length.compareTo(b.length);
  }

  /// Computes the 6-byte hex Safety Number (out-of-band MITM verification).
  /// Uses static-static ECDH secret, lexicographically sorted raw public keys, and HKDF-SHA256.
  /// Format: "xx-xx-xx-xx-xx-xx". Returns null on any failure.
  Future<String?> deriveSafetyNumber(String remotePublicKeyBase64) async {
    try {
      final sharedSecret = await deriveSharedSecret(remotePublicKeyBase64);
      final rawLocal = base64Decode(publicKeyBase64);
      final rawRemote = base64Decode(remotePublicKeyBase64);
      final isLocalFirst = _compareBytes(rawLocal, rawRemote) <= 0;
      final sortedKeys = Uint8List.fromList(
        isLocalFirst ? (rawLocal + rawRemote) : (rawRemote + rawLocal),
      );

      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final derived = await hkdf.deriveKey(
        secretKey: SecretKey(sharedSecret),
        nonce: utf8.encode('nearbychat-safety-v1'),
        info: sortedKeys,
      );
      final bytes = await derived.extractBytes();
      final first6 = bytes.sublist(0, 6);
      return first6
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join('-');
    } catch (e) {
      debugPrint('[CryptoService] deriveSafetyNumber failed: $e');
      return null;
    }
  }

  // --- Pending Message Key Retention for ACKs ---

  void _prunePendingKeys() {
    final now = DateTime.now();
    _pendingMessageKeys.removeWhere((_, entry) => now.difference(entry.createdAt) > pendingKeyTimeout);
  }

  void _storePendingKey(String messageId, SecretKey key) {
    _prunePendingKeys();
    if (_pendingMessageKeys.length >= 200) {
      _pendingMessageKeys.remove(_pendingMessageKeys.keys.first);
    }
    _pendingMessageKeys[messageId] = _PendingKeyEntry(key, DateTime.now());
  }

  SecretKey? getPendingKey(String messageId) {
    _prunePendingKeys();
    return _pendingMessageKeys[messageId]?.key;
  }

  void removePendingKey(String messageId) {
    _pendingMessageKeys.remove(messageId);
  }

  /// Encrypts plaintext message with AES-GCM-256 using Perfect Forward Secrecy (ephemeral X25519 + HKDF).
  Future<ChatEnvelope> encryptMessage({
    required String plaintext,
    required String senderUsername,
    required String recipientPublicKeyBase64,
    String? messageId,
  }) async {
    final msgId = messageId ?? _uuid.v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // 1. Generate ephemeral keypair for Perfect Forward Secrecy
    final ephemeralPair = await _x25519.newKeyPair();
    final ephemeralPub = await ephemeralPair.extractPublicKey();
    final ephemeralPubB64 = base64Encode(ephemeralPub.bytes);

    // 2. Compute ephemeral-static shared secret
    final recipientPubBytes = base64Decode(recipientPublicKeyBase64);
    final recipientPubKey = SimplePublicKey(recipientPubBytes, type: KeyPairType.x25519);
    final sharedSecretKey = await _x25519.sharedSecretKey(
      keyPair: ephemeralPair,
      remotePublicKey: recipientPubKey,
    );
    final secretBytes = await sharedSecretKey.extractBytes();

    // 3. Derive 256-bit AES message key via HKDF-SHA256
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final messageKey = await hkdf.deriveKey(
      secretKey: SecretKey(secretBytes),
      nonce: utf8.encode('nearbychat-pfs-v1'),
      info: utf8.encode(msgId),
    );

    // 4. Retain messageKey in memory for pending ACK verification
    _storePendingKey(msgId, messageKey);

    // 5. Construct envelope to build canonical AAD
    final dummyEnvelope = ChatEnvelope(
      messageId: msgId,
      senderUsername: senderUsername,
      senderPublicKey: publicKeyBase64,
      recipientPublicKey: recipientPublicKeyBase64,
      ephemeralPublicKey: ephemeralPubB64,
      timestamp: timestamp,
      nonce: Uint8List(0),
      ciphertext: Uint8List(0),
      mac: Uint8List(0),
    );

    final clearTextBytes = utf8.encode(plaintext);
    final nonce = _aesGcm.newNonce();

    final secretBox = await _aesGcm.encrypt(
      clearTextBytes,
      secretKey: messageKey,
      nonce: nonce,
      aad: dummyEnvelope.aad,
    );

    return ChatEnvelope(
      version: 1,
      messageId: msgId,
      senderUsername: senderUsername,
      senderPublicKey: publicKeyBase64,
      recipientPublicKey: recipientPublicKeyBase64,
      ephemeralPublicKey: ephemeralPubB64,
      timestamp: timestamp,
      nonce: Uint8List.fromList(secretBox.nonce),
      ciphertext: Uint8List.fromList(secretBox.cipherText),
      mac: Uint8List.fromList(secretBox.mac.bytes),
    );
  }

  /// Decrypts a ChatEnvelope using AES-GCM-256 and derives the messageKey via recipient's static private key and envelope's ephemeral public key.
  /// Also returns the derived SecretKey so caller can generate an authenticated ACK.
  Future<({String plaintext, SecretKey messageKey})> decryptEnvelopeWithKey(ChatEnvelope envelope) async {
    if (envelope.ephemeralPublicKey.isEmpty) {
      throw ArgumentError('Envelope is missing ephemeral public key for PFS.');
    }
    if (_keyPair == null) {
      throw StateError('CryptoService not initialized.');
    }

    final ephemPubBytes = base64Decode(envelope.ephemeralPublicKey);
    final ephemPubKey = SimplePublicKey(ephemPubBytes, type: KeyPairType.x25519);
    final sharedSecretKey = await _x25519.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: ephemPubKey,
    );
    final secretBytes = await sharedSecretKey.extractBytes();

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final messageKey = await hkdf.deriveKey(
      secretKey: SecretKey(secretBytes),
      nonce: utf8.encode('nearbychat-pfs-v1'),
      info: utf8.encode(envelope.messageId),
    );

    final secretBox = SecretBox(
      envelope.ciphertext,
      nonce: envelope.nonce,
      mac: Mac(envelope.mac),
    );

    final decryptedBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: messageKey,
      aad: envelope.aad,
    );

    return (plaintext: utf8.decode(decryptedBytes), messageKey: messageKey);
  }

  /// Decrypts envelope and returns decrypted plaintext.
  Future<String> decryptEnvelope(ChatEnvelope envelope) async {
    final result = await decryptEnvelopeWithKey(envelope);
    return result.plaintext;
  }

  /// Creates a cryptographically authenticated delivery ACK envelope.
  /// Authenticated using HMAC-SHA256(messageKey, "ack:$originalMessageId").
  Future<ChatEnvelope> createAckEnvelope({
    required String originalMessageId,
    required String recipientPublicKeyBase64,
    required String senderUsername,
    required SecretKey messageKey,
  }) async {
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      utf8.encode('ack:$originalMessageId'),
      secretKey: messageKey,
    );

    return ChatEnvelope(
      version: 1,
      messageId: _uuid.v4(),
      senderUsername: senderUsername,
      senderPublicKey: publicKeyBase64,
      recipientPublicKey: recipientPublicKeyBase64,
      ephemeralPublicKey: '',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      nonce: Uint8List(0),
      ciphertext: Uint8List(0),
      mac: Uint8List.fromList(mac.bytes),
      isAck: true,
      originalMessageId: originalMessageId,
    );
  }

  /// Verifies an incoming ACK envelope using the retained pending message key.
  Future<bool> verifyAckEnvelope(ChatEnvelope ackEnvelope) async {
    if (!ackEnvelope.isAck || ackEnvelope.originalMessageId == null) {
      return false;
    }

    final originalId = ackEnvelope.originalMessageId!;
    final pendingKey = getPendingKey(originalId);
    if (pendingKey == null) {
      debugPrint('[CryptoService] No pending message key found for ACK of message $originalId');
      return false;
    }

    final hmac = Hmac.sha256();
    final expectedMac = await hmac.calculateMac(
      utf8.encode('ack:$originalId'),
      secretKey: pendingKey,
    );

    final isMatch = _constantTimeCompare(expectedMac.bytes, ackEnvelope.mac);
    if (isMatch) {
      removePendingKey(originalId);
    }
    return isMatch;
  }

  static bool _constantTimeCompare(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}
