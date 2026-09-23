import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/models/chat_message.dart';
import 'package:nearby_chat/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StorageService Tests', () {
    late StorageService storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      storage = await StorageService.create();
    });

    test('Username get and set', () async {
      expect(storage.getUsername(), isNull);
      await storage.setUsername('Alice');
      expect(storage.getUsername(), equals('Alice'));
    });

    test('Peer verification toggle', () async {
      const fingerprint = 'a1b2c3d4e5f6';
      expect(storage.isPeerVerified(fingerprint), isFalse);

      await storage.setPeerVerified(fingerprint, true);
      expect(storage.isPeerVerified(fingerprint), isTrue);

      await storage.setPeerVerified(fingerprint, false);
      expect(storage.isPeerVerified(fingerprint), isFalse);
    });

    test('Save and retrieve messages sorted by timestamp', () async {
      const peer = 'peer_123';
      final now = DateTime.now();

      final msg1 = ChatMessage(
        id: '1',
        sender: 'Alice',
        recipient: 'Bob',
        body: 'First message',
        sentAt: now.subtract(const Duration(minutes: 5)),
        isMine: true,
        peerFingerprint: peer,
      );

      final msg2 = ChatMessage(
        id: '2',
        sender: 'Bob',
        recipient: 'Alice',
        body: 'Second message',
        sentAt: now,
        isMine: false,
        peerFingerprint: peer,
      );

      // Save out of chronological order
      await storage.saveMessage(msg2);
      await storage.saveMessage(msg1);

      final retrieved = storage.getMessages(peer);
      expect(retrieved.length, equals(2));
      expect(retrieved[0].id, equals('1'));
      expect(retrieved[1].id, equals('2'));
    });

    test('Strict rolling 500-message window is enforced', () async {
      const peer = 'peer_busy';
      final baseTime = DateTime.now();

      // Insert 550 messages
      for (int i = 0; i < 550; i++) {
        final msg = ChatMessage(
          id: 'msg_$i',
          sender: 'Alice',
          recipient: 'Bob',
          body: 'Message number $i',
          sentAt: baseTime.add(Duration(seconds: i)),
          isMine: true,
          peerFingerprint: peer,
        );
        await storage.saveMessage(msg);
      }

      final messages = storage.getMessages(peer);
      expect(messages.length, equals(StorageService.maxHistoryPerPeer));
      expect(messages.length, equals(500));

      // Earliest 50 messages (0..49) should have been pruned
      expect(messages.first.id, equals('msg_50'));
      expect(messages.last.id, equals('msg_549'));
    });

    test('Message status can be updated', () async {
      const peer = 'peer_status';
      final msg = ChatMessage(
        id: 'status_test',
        sender: 'Alice',
        recipient: 'Bob',
        body: 'Pending message',
        sentAt: DateTime.now(),
        isMine: true,
        peerFingerprint: peer,
        status: MessageStatus.sending,
      );

      await storage.saveMessage(msg);
      expect(storage.getMessages(peer).first.status, equals(MessageStatus.sending));

      await storage.updateMessageStatus('status_test', peer, MessageStatus.sent);
      expect(storage.getMessages(peer).first.status, equals(MessageStatus.sent));

      await storage.updateMessageStatus('status_test', peer, MessageStatus.delivered);
      expect(storage.getMessages(peer).first.status, equals(MessageStatus.delivered));
    });

    test('Chat history is encrypted at rest in SharedPreferences', () async {
      const peer = 'peer_crypto';
      const secretBody = 'Very sensitive medical or private data';

      final msg = ChatMessage(
        id: 'enc_1',
        sender: 'Alice',
        recipient: 'Bob',
        body: secretBody,
        sentAt: DateTime.now(),
        isMine: true,
        peerFingerprint: peer,
      );

      await storage.saveMessage(msg);

      // Directly inspect the raw value in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final rawStored = prefs.getString('nearbychat.history.$peer');

      expect(rawStored, isNotNull);
      // Plaintext must NOT appear in the stored string
      expect(rawStored!.contains(secretBody), isFalse);
      expect(rawStored.contains('Alice'), isFalse);

      // Stored format must be an encrypted envelope with nonce, ciphertext, and mac
      final Map<String, dynamic> env = jsonDecode(rawStored);
      expect(env.containsKey('n'), isTrue);
      expect(env.containsKey('c'), isTrue);
      expect(env.containsKey('m'), isTrue);
    });

    test('Transparent migration of legacy plaintext history', () async {
      const peer = 'legacy_peer';
      final now = DateTime.now();

      // Simulate legacy unencrypted plaintext stored as raw JSON array
      final legacyList = [
        {
          'id': 'leg_1',
          'sender': 'LegacyUser',
          'recipient': 'Me',
          'body': 'Old unencrypted message',
          'sentAt': now.toIso8601String(),
          'isMine': false,
          'peerFingerprint': peer,
          'status': 'delivered',
        }
      ];

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nearbychat.history.$peer', jsonEncode(legacyList));

      // Re-create storage service to trigger preload & migration
      final newStorage = await StorageService.create(prefs: prefs);

      // Verify messages are decrypted and available in memory
      final messages = newStorage.getMessages(peer);
      expect(messages.length, equals(1));
      expect(messages.first.body, equals('Old unencrypted message'));

      // Verify that disk storage was migrated to encrypted format
      final migratedRaw = prefs.getString('nearbychat.history.$peer')!;
      expect(migratedRaw.contains('Old unencrypted message'), isFalse);
      expect(migratedRaw.startsWith('{'), isTrue);
    });
  });
}
