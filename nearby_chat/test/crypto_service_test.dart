import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/models/chat_envelope.dart';
import 'package:nearby_chat/services/crypto_service.dart';

void main() {
  group('CryptoService Tests', () {
    late CryptoService aliceCrypto;
    late CryptoService bobCrypto;

    setUp(() async {
      aliceCrypto = CryptoService();
      bobCrypto = CryptoService();

      final x25519 = X25519();
      final alicePair = await x25519.newKeyPair();
      final bobPair = await x25519.newKeyPair();

      await aliceCrypto.init(testKeyPair: alicePair);
      await bobCrypto.init(testKeyPair: bobPair);
    });

    test('Identities are initialized with valid base64 keys and fingerprints', () {
      expect(aliceCrypto.isInitialized, isTrue);
      expect(bobCrypto.isInitialized, isTrue);
      expect(aliceCrypto.publicKeyBase64.isNotEmpty, isTrue);
      expect(bobCrypto.publicKeyBase64.isNotEmpty, isTrue);
      expect(aliceCrypto.fingerprint.length, equals(12));
      expect(bobCrypto.fingerprint.length, equals(12));
    });

    test('X25519 shared secret derivation is symmetric', () async {
      final aliceSecret = await aliceCrypto.deriveSharedSecret(bobCrypto.publicKeyBase64);
      final bobSecret = await bobCrypto.deriveSharedSecret(aliceCrypto.publicKeyBase64);

      expect(aliceSecret, equals(bobSecret));
      expect(aliceSecret.length, equals(32));
    });

    test('Safety Number derivation matches symmetrically and formats as 6-byte hex', () async {
      final aliceSafety = await aliceCrypto.deriveSafetyNumber(bobCrypto.publicKeyBase64);
      final bobSafety = await bobCrypto.deriveSafetyNumber(aliceCrypto.publicKeyBase64);

      expect(aliceSafety, isNotNull);
      expect(bobSafety, isNotNull);
      expect(aliceSafety, equals(bobSafety));
      expect(RegExp(r'^[0-9a-f]{2}(-[0-9a-f]{2}){5}$').hasMatch(aliceSafety!), isTrue);
    });

    test('Safety Number returns null on invalid key (never 00-00-00-00-00-00)', () async {
      final safety = await aliceCrypto.deriveSafetyNumber('invalid-base-64-key');
      expect(safety, isNull);
    });

    test('AES-GCM-256 with Perfect Forward Secrecy roundtrip succeeds', () async {
      const originalText = 'Hello Bob! This is an offline encrypted message.';

      final envelope = await aliceCrypto.encryptMessage(
        plaintext: originalText,
        senderUsername: 'Alice',
        recipientPublicKeyBase64: bobCrypto.publicKeyBase64,
      );

      expect(envelope.senderUsername, equals('Alice'));
      expect(envelope.ephemeralPublicKey.isNotEmpty, isTrue);
      expect(envelope.ciphertext.isNotEmpty, isTrue);
      expect(envelope.mac.length, equals(16)); // 128-bit GCM MAC
      expect(envelope.nonce.length, equals(12)); // 96-bit GCM Nonce

      final decrypted = await bobCrypto.decryptEnvelope(envelope);
      expect(decrypted, equals(originalText));
    });

    test('Authenticated HMAC ACK generation and verification succeeds', () async {
      final envelope = await aliceCrypto.encryptMessage(
        plaintext: 'Test message requiring ACK',
        senderUsername: 'Alice',
        recipientPublicKeyBase64: bobCrypto.publicKeyBase64,
      );

      final decrypted = await bobCrypto.decryptEnvelopeWithKey(envelope);
      expect(decrypted.plaintext, equals('Test message requiring ACK'));

      // Bob generates authenticated ACK using the derived messageKey
      final ack = await bobCrypto.createAckEnvelope(
        originalMessageId: envelope.messageId,
        recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
        senderUsername: 'Bob',
        messageKey: decrypted.messageKey,
      );

      expect(ack.isAck, isTrue);
      expect(ack.originalMessageId, equals(envelope.messageId));

      // Alice verifies ACK using her retained pending messageKey
      final isVerified = await aliceCrypto.verifyAckEnvelope(ack);
      expect(isVerified, isTrue);
    });

    test('Forged or altered ACK fails verification', () async {
      final envelope = await aliceCrypto.encryptMessage(
        plaintext: 'Important transfer',
        senderUsername: 'Alice',
        recipientPublicKeyBase64: bobCrypto.publicKeyBase64,
      );

      // Mallory attempts to forge an ACK without the messageKey
      final bogusKey = SecretKey(List<int>.generate(32, (i) => i));
      final forgedAck = await bobCrypto.createAckEnvelope(
        originalMessageId: envelope.messageId,
        recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
        senderUsername: 'Mallory',
        messageKey: bogusKey,
      );

      final isVerified = await aliceCrypto.verifyAckEnvelope(forgedAck);
      expect(isVerified, isFalse);
    });

    test('Tampering with ciphertext causes authentication failure', () async {
      final envelope = await aliceCrypto.encryptMessage(
        plaintext: 'Top secret data',
        senderUsername: 'Alice',
        recipientPublicKeyBase64: bobCrypto.publicKeyBase64,
      );

      // Flip one byte in ciphertext
      final tamperedCiphertext = List<int>.from(envelope.ciphertext);
      tamperedCiphertext[0] ^= 0xFF;

      final corruptedEnvelope = ChatEnvelope(
        version: envelope.version,
        messageId: envelope.messageId,
        senderUsername: envelope.senderUsername,
        senderPublicKey: envelope.senderPublicKey,
        recipientPublicKey: envelope.recipientPublicKey,
        ephemeralPublicKey: envelope.ephemeralPublicKey,
        timestamp: envelope.timestamp,
        nonce: envelope.nonce,
        ciphertext: Uint8List.fromList(tamperedCiphertext),
        mac: envelope.mac,
      );

      expect(
        () async => await bobCrypto.decryptEnvelope(corruptedEnvelope),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('ACK flag and original message id are bound into the AAD', () async {
      final envelope = await aliceCrypto.encryptMessage(
        plaintext: 'bound header',
        senderUsername: 'Alice',
        recipientPublicKeyBase64: bobCrypto.publicKeyBase64,
      );
      final flipped = ChatEnvelope(
        version: envelope.version,
        messageId: envelope.messageId,
        senderUsername: envelope.senderUsername,
        senderPublicKey: envelope.senderPublicKey,
        recipientPublicKey: envelope.recipientPublicKey,
        ephemeralPublicKey: envelope.ephemeralPublicKey,
        timestamp: envelope.timestamp,
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext,
        mac: envelope.mac,
        originalMessageId: 'injected',
      );
      expect(await bobCrypto.decryptEnvelope(envelope), 'bound header');
      expect(() => bobCrypto.decryptEnvelope(flipped), throwsA(isA<SecretBoxAuthenticationError>()));
    });

    test('Tampering with AAD header (senderUsername) causes authentication failure', () async {
      final envelope = await aliceCrypto.encryptMessage(
        plaintext: 'Transfer 100 credits',
        senderUsername: 'Alice',
        recipientPublicKeyBase64: bobCrypto.publicKeyBase64,
      );

      // Attacker attempts to change username in header from Alice -> Mallory
      final corruptedEnvelope = ChatEnvelope(
        version: envelope.version,
        messageId: envelope.messageId,
        senderUsername: 'Mallory',
        senderPublicKey: envelope.senderPublicKey,
        recipientPublicKey: envelope.recipientPublicKey,
        ephemeralPublicKey: envelope.ephemeralPublicKey,
        timestamp: envelope.timestamp,
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext,
        mac: envelope.mac,
      );

      expect(
        () async => await bobCrypto.decryptEnvelope(corruptedEnvelope),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });
}
