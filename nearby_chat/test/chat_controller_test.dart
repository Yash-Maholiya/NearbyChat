import 'dart:async';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/controllers/chat_controller.dart';
import 'package:nearby_chat/models/chat_envelope.dart';
import 'package:nearby_chat/models/chat_message.dart';
import 'package:nearby_chat/models/peer.dart';
import 'package:nearby_chat/services/ble_service.dart';
import 'package:nearby_chat/services/crypto_service.dart';
import 'package:nearby_chat/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeBleService extends BleService {
  final StreamController<Peer> peerController = StreamController<Peer>.broadcast();
  final StreamController<ChatEnvelope> envelopeController = StreamController<ChatEnvelope>.broadcast();
  Future<bool> Function(String deviceId, ChatEnvelope envelope)? onSendEnvelope;

  @override
  Stream<Peer> get onPeerDiscovered => peerController.stream;

  @override
  Stream<ChatEnvelope> get onEnvelopeReceived => envelopeController.stream;

  @override
  Future<void> init({required String localUsername, required String localPublicKeyBase64}) async {}

  @override
  Future<void> startScanning() async {}

  @override
  Future<void> startAdvertising() async {}

  @override
  Future<void> stopScanning() async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<bool> sendEnvelope(String deviceId, ChatEnvelope envelope) async {
    if (onSendEnvelope != null) {
      return await onSendEnvelope!(deviceId, envelope);
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    await peerController.close();
    await envelopeController.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;
  late CryptoService aliceCrypto;
  late CryptoService bobCrypto;
  late FakeBleService ble;
  late ChatController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storage = await StorageService.create();
    aliceCrypto = CryptoService();
    final aliceKey = await Cryptography.instance.x25519().newKeyPair();
    await aliceCrypto.init(testKeyPair: aliceKey);

    bobCrypto = CryptoService();
    final bobKey = await Cryptography.instance.x25519().newKeyPair();
    await bobCrypto.init(testKeyPair: bobKey);

    ble = FakeBleService();

    controller = ChatController(
      crypto: aliceCrypto,
      storage: storage,
      ble: ble,
    );
    await controller.registerUser('Alice');
  });

  tearDown(() {
    controller.dispose();
  });

  test('Name collision detection marks both colliding peers with hasNameCollision', () async {
    final peerA = Peer(
      deviceId: 'device-1',
      username: 'Bob',
      publicKey: bobCrypto.publicKeyBase64,
      lastSeen: DateTime.now(),
    );

    ble.peerController.add(peerA);
    await pumpEventQueue();

    expect(controller.peers.length, 1);
    expect(controller.peers.first.hasNameCollision, isFalse);

    // Charlie also advertises as 'Bob' but with different public key
    final charlieCrypto = CryptoService();
    final charlieKey = await Cryptography.instance.x25519().newKeyPair();
    await charlieCrypto.init(testKeyPair: charlieKey);

    final peerB = Peer(
      deviceId: 'device-2',
      username: 'Bob',
      publicKey: charlieCrypto.publicKeyBase64,
      lastSeen: DateTime.now(),
    );

    ble.peerController.add(peerB);
    await pumpEventQueue();

    expect(controller.peers.length, 2);
    final p1 = controller.peers.firstWhere((p) => p.deviceId == 'device-1');
    final p2 = controller.peers.firstWhere((p) => p.deviceId == 'device-2');

    expect(p1.hasNameCollision, isTrue);
    expect(p2.hasNameCollision, isTrue);
  });

  test('Normal ACK flow transitions message from sent to delivered and cleans up key', () async {
    final bobPeer = Peer(
      deviceId: 'device-bob',
      username: 'Bob',
      publicKey: bobCrypto.publicKeyBase64,
      lastSeen: DateTime.now(),
    );
    ble.peerController.add(bobPeer);
    await pumpEventQueue();

    final activeBob = controller.peers.first;
    controller.selectPeer(activeBob);

    ChatEnvelope? capturedSentEnvelope;
    ble.onSendEnvelope = (deviceId, env) async {
      capturedSentEnvelope = env;
      return true;
    };

    final sendSuccess = await controller.sendMessage('Hello Bob!');
    expect(sendSuccess, isTrue);
    expect(capturedSentEnvelope, isNotNull);

    final msgId = capturedSentEnvelope!.messageId;
    expect(controller.activeMessages.first.status, MessageStatus.sent);
    expect(aliceCrypto.getPendingKey(msgId), isNotNull);

    // Bob receives and creates an authenticated ACK
    final decrypted = await bobCrypto.decryptEnvelopeWithKey(capturedSentEnvelope!);
    final ackEnvelope = await bobCrypto.createAckEnvelope(
      originalMessageId: msgId,
      recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
      senderUsername: 'Bob',
      messageKey: decrypted.messageKey,
    );

    // Alice receives Bob's ACK
    ble.envelopeController.add(ackEnvelope);
    await pumpEventQueue();

    expect(controller.activeMessages.first.status, MessageStatus.delivered);
    expect(aliceCrypto.getPendingKey(msgId), isNull);
  });

  test('Early ACK race: ACK received during transmission sets delivered and removes key', () async {
    final bobPeer = Peer(
      deviceId: 'device-bob',
      username: 'Bob',
      publicKey: bobCrypto.publicKeyBase64,
      lastSeen: DateTime.now(),
    );
    ble.peerController.add(bobPeer);
    await pumpEventQueue();

    controller.selectPeer(controller.peers.first);

    ble.onSendEnvelope = (deviceId, env) async {
      // Bob processes envelope and sends ACK while Alice is still in sendEnvelope!
      final decrypted = await bobCrypto.decryptEnvelopeWithKey(env);
      final ackEnvelope = await bobCrypto.createAckEnvelope(
        originalMessageId: env.messageId,
        recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
        senderUsername: 'Bob',
        messageKey: decrypted.messageKey,
      );

      ble.envelopeController.add(ackEnvelope);
      // Allow microtask to process the incoming ACK stream event
      await pumpEventQueue();

      // Complete transmission
      return true;
    };

    final sendSuccess = await controller.sendMessage('Fast ACK message');
    expect(sendSuccess, isTrue);

    // Message must transition directly to delivered
    expect(controller.activeMessages.first.status, MessageStatus.delivered);
    // Key should have been cleaned up
    expect(aliceCrypto.getPendingKey(controller.activeMessages.first.id), isNull);
  });

  test('Incoming message from unknown public key resolves as Unverified (<fingerprint>)', () async {
    final unknownCrypto = CryptoService();
    final unknownKey = await Cryptography.instance.x25519().newKeyPair();
    await unknownCrypto.init(testKeyPair: unknownKey);

    // Mallory claims she is "Bob" in the envelope
    final malloryEnvelope = await unknownCrypto.encryptMessage(
      plaintext: 'I am an impostor',
      senderUsername: 'Bob',
      recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
    );

    ble.envelopeController.add(malloryEnvelope);
    await pumpEventQueue();

    final expectedFingerprint = unknownCrypto.fingerprint;
    final placeholder = controller.peers.firstWhere((p) => p.publicKey == unknownCrypto.publicKeyBase64);
    expect(placeholder.username, 'Unverified ($expectedFingerprint)');
    expect(placeholder.deviceId, 'unpaired-$expectedFingerprint');

    controller.selectPeer(placeholder);
    expect(controller.activeMessages.first.sender, 'Unverified ($expectedFingerprint)');
    expect(controller.activeMessages.first.body, 'I am an impostor');
  });

  Future<Peer> addBob() async {
    ble.peerController.add(Peer(
      deviceId: 'device-bob',
      username: 'Bob',
      publicKey: bobCrypto.publicKeyBase64,
      lastSeen: DateTime.now(),
    ));
    await pumpEventQueue();
    return controller.peers.first;
  }

  test('Replayed message is stored once but ACKed every time', () async {
    final bob = await addBob();
    final sentAcks = <ChatEnvelope>[];
    ble.onSendEnvelope = (deviceId, env) async {
      if (env.isAck) sentAcks.add(env);
      return true;
    };

    final envelope = await bobCrypto.encryptMessage(
      plaintext: 'pay 10 rupees',
      senderUsername: 'Bob',
      recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
    );

    ble.envelopeController.add(envelope);
    await pumpEventQueue();
    ble.envelopeController.add(envelope); // attacker replays the captured frame
    await pumpEventQueue();

    controller.selectPeer(bob);
    expect(controller.activeMessages.where((m) => m.body == 'pay 10 rupees').length, 1);
    expect(sentAcks.length, 2);
  });

  test('Message with a stale authenticated timestamp is rejected', () async {
    final bob = await addBob();
    final old = DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
    final envelope = await bobCrypto.encryptMessage(
      plaintext: 'old news',
      senderUsername: 'Bob',
      recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
      timestampOverride: old,
    );

    ble.envelopeController.add(envelope);
    await pumpEventQueue();

    controller.selectPeer(bob);
    expect(controller.activeMessages, isEmpty);
  });

  test('Failed message can be resent with the same id', () async {
    final bob = await addBob();
    controller.selectPeer(bob);

    var radioUp = false;
    final sentIds = <String>[];
    ble.onSendEnvelope = (deviceId, env) async {
      sentIds.add(env.messageId);
      return radioUp;
    };

    expect(await controller.sendMessage('are you there?'), isFalse);
    final failed = controller.activeMessages.single;
    expect(failed.status, MessageStatus.failed);

    radioUp = true;
    expect(await controller.resendMessage(failed.id), isTrue);
    expect(controller.activeMessages.single.status, MessageStatus.sent);
    expect(sentIds, [failed.id, failed.id]);

    // Only failed messages can be resent
    expect(await controller.resendMessage(failed.id), isFalse);
  });

  test('A tampered message is dropped and raises a security alert', () async {
    final env = await bobCrypto.encryptMessage(
      plaintext: 'secret',
      senderUsername: 'Bob',
      recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
    );
    final ct = Uint8List.fromList(env.ciphertext)..[0] ^= 1;
    ble.envelopeController.add(env.copyWith(ciphertext: ct));
    await pumpEventQueue();

    expect(controller.securityAlertCount, 1);
    expect(controller.securityAlert, contains('integrity check'));
    expect(controller.peers, isEmpty);

    ble.envelopeController.add(await bobCrypto.encryptMessage(
      plaintext: 'clean',
      senderUsername: 'Bob',
      recipientPublicKeyBase64: aliceCrypto.publicKeyBase64,
    ));
    await pumpEventQueue();
    expect(controller.securityAlertCount, 1);
    expect(controller.peers, hasLength(1));
  });
}
