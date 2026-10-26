import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ids.dart';
import '../models/chat_envelope.dart';

/// Device identity and message crypto.
///
/// * identity: static X25519 key (encryption) + Ed25519 key (mesh signatures)
/// * message:  fresh X25519 key per message -> HKDF-SHA256 -> AES-256-GCM, header in the AAD
/// * ACK:      HMAC-SHA256(message key, `"ack:" + id`), so only the real recipient can produce it
class CryptoService {
  CryptoService({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _privKeyName = 'nearbychat.identity.private_key';
  static const _pubKeyName = 'nearbychat.identity.public_key';
  static const _signSeedName = 'nearbychat.identity.signing_seed';
  static const Duration pendingKeyTimeout = Duration(minutes: 5);
  static const _maxPendingKeys = 200;

  static final _x25519 = X25519();
  static final _ed25519 = Ed25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _pfsSalt = utf8.encode('nearbychat-pfs-v1');
  static final _safetySalt = utf8.encode('nearbychat-safety-v1');

  final FlutterSecureStorage _storage;

  SimpleKeyPair? _keyPair;
  String? _publicKey;
  SimpleKeyPair? _signingKeyPair;
  String? _signingPublicKey;

  // Message keys of sent messages, kept until the ACK arrives (or they time out).
  final Map<String, (SecretKey, DateTime)> _pending = {};

  bool get isInitialized => _keyPair != null;

  String get publicKeyBase64 => _publicKey ?? (throw StateError('CryptoService.init() not called'));

  String get signingPublicKeyBase64 =>
      _signingPublicKey ?? (throw StateError('CryptoService.init() not called'));

  String get fingerprint {
    final pk = publicKeyBase64;
    return pk.length > 12 ? pk.substring(0, 12) : pk;
  }

  Future<void> init({SimpleKeyPair? testKeyPair, SimpleKeyPair? testSigningKeyPair}) async {
    if (testKeyPair != null) {
      _keyPair = testKeyPair;
      _publicKey = base64Encode((await testKeyPair.extractPublicKey()).bytes);
      _signingKeyPair = testSigningKeyPair ?? await _ed25519.newKeyPair();
    } else {
      _keyPair = await _loadOrCreateX25519();
      _publicKey = base64Encode((await _keyPair!.extractPublicKey()).bytes);
      _signingKeyPair = await _loadOrCreateEd25519();
    }
    _signingPublicKey = base64Encode((await _signingKeyPair!.extractPublicKey()).bytes);
  }

  Future<SimpleKeyPair> _loadOrCreateX25519() async {
    final priv = await _storage.read(key: _privKeyName);
    final pub = await _storage.read(key: _pubKeyName);
    if (priv != null && pub != null) {
      return SimpleKeyPairData(
        base64Decode(priv),
        publicKey: SimplePublicKey(base64Decode(pub), type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    }
    if (priv != null) {
      // Public half missing (interrupted first run): it can be recomputed.
      final pair = await _x25519.newKeyPairFromSeed(base64Decode(priv));
      await _storage.write(key: _pubKeyName, value: base64Encode((await pair.extractPublicKey()).bytes));
      return pair;
    }
    final pair = await _x25519.newKeyPair();
    await _storage.write(key: _privKeyName, value: base64Encode(await pair.extractPrivateKeyBytes()));
    await _storage.write(key: _pubKeyName, value: base64Encode((await pair.extractPublicKey()).bytes));
    return pair;
  }

  Future<SimpleKeyPair> _loadOrCreateEd25519() async {
    final seed = await _storage.read(key: _signSeedName);
    if (seed != null) return _ed25519.newKeyPairFromSeed(base64Decode(seed));
    final pair = await _ed25519.newKeyPair();
    await _storage.write(key: _signSeedName, value: base64Encode(await pair.extractPrivateKeyBytes()));
    return pair;
  }

  // ------------------------------------------------------------ signatures

  Future<String> sign(String message) async =>
      base64Encode((await _ed25519.sign(utf8.encode(message), keyPair: _signingKeyPair!)).bytes);

  static Future<bool> verifySignature(String message, String signatureB64, String signingPublicKeyB64) async {
    try {
      final pub = SimplePublicKey(base64Decode(signingPublicKeyB64), type: KeyPairType.ed25519);
      return await _ed25519.verify(utf8.encode(message), signature: Signature(base64Decode(signatureB64), publicKey: pub));
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------- key agreement

  static Future<List<int>> _dh(KeyPair own, String remoteB64) async {
    final remote = SimplePublicKey(base64Decode(remoteB64), type: KeyPairType.x25519);
    return (await _x25519.sharedSecretKey(keyPair: own, remotePublicKey: remote)).extractBytes();
  }

  static Future<SecretKey> _messageKey(List<int> secret, String messageId) =>
      _hkdf.deriveKey(secretKey: SecretKey(secret), nonce: _pfsSalt, info: utf8.encode(messageId));

  /// Static-static X25519 secret with [remotePublicKeyBase64].
  Future<Uint8List> deriveSharedSecret(String remotePublicKeyBase64) async {
    final own = _keyPair ?? (throw StateError('CryptoService.init() not called'));
    return Uint8List.fromList(await _dh(own, remotePublicKeyBase64));
  }

  /// Six bytes both sides compute identically, shown as "xx-xx-xx-xx-xx-xx" and compared
  /// in person. A key swapped in by a man in the middle gives a different number.
  Future<String?> deriveSafetyNumber(String remotePublicKeyBase64) async {
    try {
      final secret = await deriveSharedSecret(remotePublicKeyBase64);
      final a = base64Decode(publicKeyBase64);
      final b = base64Decode(remotePublicKeyBase64);
      final keys = _compare(a, b) <= 0 ? [...a, ...b] : [...b, ...a];
      final out = await (await _hkdf.deriveKey(secretKey: SecretKey(secret), nonce: _safetySalt, info: keys))
          .extractBytes();
      return out.take(6).map((x) => x.toRadixString(16).padLeft(2, '0')).join('-');
    } catch (e) {
      debugPrint('[CryptoService] safety number failed: $e');
      return null;
    }
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  // ----------------------------------------------------------- pending keys

  void _prune() {
    final now = DateTime.now();
    _pending.removeWhere((_, e) => now.difference(e.$2) > pendingKeyTimeout);
  }

  SecretKey? getPendingKey(String messageId) {
    _prune();
    return _pending[messageId]?.$1;
  }

  void removePendingKey(String messageId) => _pending.remove(messageId);

  // -------------------------------------------------------------- messages

  Future<ChatEnvelope> encryptMessage({
    required String plaintext,
    required String senderUsername,
    required String recipientPublicKeyBase64,
    String? messageId,
    @visibleForTesting int? timestampOverride,
  }) async {
    final id = messageId ?? newMessageId();
    final ephemeral = await _x25519.newKeyPair();
    final key = await _messageKey(await _dh(ephemeral, recipientPublicKeyBase64), id);

    _prune();
    if (_pending.length >= _maxPendingKeys) _pending.remove(_pending.keys.first);
    _pending[id] = (key, DateTime.now());

    final header = ChatEnvelope(
      version: 2,
      messageId: id,
      senderUsername: senderUsername,
      senderPublicKey: publicKeyBase64,
      recipientPublicKey: recipientPublicKeyBase64,
      ephemeralPublicKey: base64Encode((await ephemeral.extractPublicKey()).bytes),
      timestamp: timestampOverride ?? DateTime.now().millisecondsSinceEpoch,
      nonce: Uint8List(0),
      ciphertext: Uint8List(0),
      mac: Uint8List(0),
    );
    final box = await _aes.encrypt(utf8.encode(plaintext), secretKey: key, nonce: _aes.newNonce(), aad: header.aad);
    return header.copyWith(
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Decrypts and also returns the message key, which the caller needs to sign the ACK.
  /// Throws if the envelope was modified anywhere (ciphertext or header).
  Future<({String plaintext, SecretKey messageKey})> decryptEnvelopeWithKey(ChatEnvelope envelope) async {
    if (envelope.ephemeralPublicKey.isEmpty) throw ArgumentError('envelope has no ephemeral key');
    final own = _keyPair ?? (throw StateError('CryptoService.init() not called'));
    final key = await _messageKey(await _dh(own, envelope.ephemeralPublicKey), envelope.messageId);
    final clear = await _aes.decrypt(
      SecretBox(envelope.ciphertext, nonce: envelope.nonce, mac: Mac(envelope.mac)),
      secretKey: key,
      aad: envelope.aad,
    );
    return (plaintext: utf8.decode(clear), messageKey: key);
  }

  Future<String> decryptEnvelope(ChatEnvelope envelope) async => (await decryptEnvelopeWithKey(envelope)).plaintext;

  // ------------------------------------------------------------------ ACKs

  static Future<List<int>> _ackMac(String messageId, SecretKey key) async =>
      (await Hmac.sha256().calculateMac(utf8.encode('ack:$messageId'), secretKey: key)).bytes;

  Future<ChatEnvelope> createAckEnvelope({
    required String originalMessageId,
    required String recipientPublicKeyBase64,
    required String senderUsername,
    required SecretKey messageKey,
  }) async {
    return ChatEnvelope(
      version: 2,
      messageId: newMessageId(),
      senderUsername: senderUsername,
      senderPublicKey: publicKeyBase64,
      recipientPublicKey: recipientPublicKeyBase64,
      ephemeralPublicKey: '',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      nonce: Uint8List(0),
      ciphertext: Uint8List(0),
      mac: Uint8List.fromList(await _ackMac(originalMessageId, messageKey)),
      isAck: true,
      originalMessageId: originalMessageId,
    );
  }

  /// Checks the ACK against the key we kept for that message. Does not remove the key;
  /// the controller does that once it has updated the message.
  Future<bool> verifyAckEnvelope(ChatEnvelope ack) async {
    final id = ack.originalMessageId;
    if (!ack.isAck || id == null) return false;
    final key = getPendingKey(id);
    if (key == null) return false;
    final expected = await _ackMac(id, key);
    if (expected.length != ack.mac.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ ack.mac[i];
    }
    return diff == 0;
  }
}
