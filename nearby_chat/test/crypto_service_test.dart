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

    test('Safety Number derivation matches on both sides', () async {
      final aliceSafety = await aliceCrypto.deriveSafetyNumber(bobCrypto.publicKeyBase64);
      final bobSafety = await bobCrypto.deriveSafetyNumber(aliceCrypto.publicKeyBase64);

      expect(aliceSafety, equals(bobSafety));
      // Format should be 6 two-digit hex values separated by hyphens
      expect(RegExp(r'^[0-9a-f]{2}(-[0-9a-f]{2}){5}$').hasMatch(aliceSafety), isTrue);
    });

    test('AES-GCM-256 encryption and decryption roundtrip succeeds', () async {
      const originalText = 'Hello Bob! This is an offline encrypted message.';

      final envelope = await aliceCrypto.encryptMessage(
        plaintext: originalText,
        senderUsername: 'Alice',
        recipientPublicKeyBase64: bobCrypto.publicKeyBase64,
      );

      expect(envelope.senderUsername, equals('Alice'));
      expect(envelope.ciphertext.isNotEmpty, isTrue);
      expect(envelope.mac.length, equals(16)); // 128-bit GCM MAC
      expect(envelope.nonce.length, equals(12)); // 96-bit GCM Nonce

      final decrypted = await bobCrypto.decryptEnvelope(envelope);
      expect(decrypted, equals(originalText));
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
        timestamp: envelope.timestamp,
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext..setRange(0, 1, [tamperedCiphertext[0]]),
        mac: envelope.mac,
      );

      expect(
        () async => await bobCrypto.decryptEnvelope(corruptedEnvelope),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('Tampering with AAD header causes authentication failure', () async {
      final envelope = await aliceCrypto.encryptMessage(
        plaintext: 'Transfer 100 credits',
        senderUsername: 'Alice',
        recipientPublicKeyBase64: bobCrypto.publicKeyBase64,
      );

      // Alter timestamp in metadata (part of AAD)
      final corruptedEnvelope = ChatEnvelope(
        version: envelope.version,
        messageId: envelope.messageId,
        senderUsername: envelope.senderUsername,
        senderPublicKey: envelope.senderPublicKey,
        recipientPublicKey: envelope.recipientPublicKey,
        timestamp: envelope.timestamp + 1000,
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
