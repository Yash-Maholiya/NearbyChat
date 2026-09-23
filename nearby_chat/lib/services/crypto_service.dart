import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_envelope.dart';

class CryptoService {
  static const String _privKeyStorageKey = 'nearbychat.identity.private_key';
  static const String _pubKeyStorageKey = 'nearbychat.identity.public_key';
  static const String _kdfSalt = 'nearbychat-v1';

  final FlutterSecureStorage _storage;
  final X25519 _x25519 = X25519();
  final Sha256 _sha256 = Sha256();
  final AesGcm _aesGcm = AesGcm.with256bits();
  final Uuid _uuid = const Uuid();

  SimpleKeyPair? _keyPair;
  String? _publicKeyBase64;

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

  /// Initializes cryptographic identity. Loads from Secure Storage or generates a new X25519 pair.
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

  /// Derives symmetric shared secret with remote party via X25519 ECDH.
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

  /// Computes the 6-byte hex Safety Number (out-of-band MITM verification).
  /// Format: "xx-xx-xx-xx-xx-xx"
  Future<String> deriveSafetyNumber(String remotePublicKeyBase64) async {
    try {
      final sharedSecret = await deriveSharedSecret(remotePublicKeyBase64);
      final hash = await _sha256.hash(sharedSecret);
      final first6 = hash.bytes.sublist(0, 6);
      return first6
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join('-');
    } catch (_) {
      return '00-00-00-00-00-00';
    }
  }

  /// Derives 256-bit AES-GCM encryption key from ECDH shared secret using SHA-256 KDF.
  Future<SecretKey> _deriveMessageKey(String remotePublicKeyBase64) async {
    final sharedSecret = await deriveSharedSecret(remotePublicKeyBase64);
    final kdfInput = utf8.encode(_kdfSalt) + sharedSecret;
    final digest = await _sha256.hash(kdfInput);
    return SecretKey(digest.bytes);
  }

  /// Encrypts plaintext message with AES-GCM-256 and packages into ChatEnvelope.
  Future<ChatEnvelope> encryptMessage({
    required String plaintext,
    required String senderUsername,
    required String recipientPublicKeyBase64,
    String? messageId,
  }) async {
    final messageKey = await _deriveMessageKey(recipientPublicKeyBase64);
    final msgId = messageId ?? _uuid.v4();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Temporary envelope to build canonical AAD
    final dummyEnvelope = ChatEnvelope(
      messageId: msgId,
      senderUsername: senderUsername,
      senderPublicKey: publicKeyBase64,
      recipientPublicKey: recipientPublicKeyBase64,
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
      timestamp: timestamp,
      nonce: Uint8List.fromList(secretBox.nonce),
      ciphertext: Uint8List.fromList(secretBox.cipherText),
      mac: Uint8List.fromList(secretBox.mac.bytes),
    );
  }

  /// Decrypts a ChatEnvelope using AES-GCM-256 and verifies authentication tag and AAD.
  Future<String> decryptEnvelope(ChatEnvelope envelope) async {
    final messageKey = await _deriveMessageKey(envelope.senderPublicKey);

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

    return utf8.decode(decryptedBytes);
  }
}
