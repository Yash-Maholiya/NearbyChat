// Mesh layer: relaying with TTL, duplicate suppression, signed announces and the public room.
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/controllers/chat_controller.dart';
import 'package:nearby_chat/models/chat_envelope.dart';
import 'package:nearby_chat/models/mesh_packet.dart';
import 'package:nearby_chat/models/peer.dart';
import 'package:nearby_chat/services/ble_service.dart';
import 'package:nearby_chat/services/crypto_service.dart';
import 'package:nearby_chat/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real mesh logic, fake radio: records what would be sent to which neighbour.
class RadioFakeBle extends BleService {
  final List<(String, MeshPacket?)> sent = [];

  @override
  Future<bool> sendRaw(String deviceId, Uint8List binaryData) async {
    final json = jsonDecode(utf8.decode(binaryData)) as Map<String, dynamic>;
    sent.add((deviceId, MeshPacket.fromJson(json)));
    return true;
  }

  @override
  Future<void> init({required String localUsername, required String localPublicKeyBase64}) async {
    debugSetIdentity(localUsername, localPublicKeyBase64);
  }

  @override
  Future<void> startScanning() async {}
  @override
  Future<void> startAdvertising() async {}
  @override
  Future<void> stopScanning() async {}
  @override
  Future<void> stopAdvertising() async {}
}

Future<CryptoService> newIdentity() async {
  final c = CryptoService();
  await c.init(testKeyPair: await X25519().newKeyPair());
  return c;
}

Peer neighbour(String id, String pk) =>
    Peer(deviceId: id, username: id, publicKey: pk, lastSeen: DateTime.now(), isConnected: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BleService mesh routing', () {
    late RadioFakeBle ble;
    late CryptoService me, a, b;

    setUp(() async {
      me = await newIdentity();
      a = await newIdentity();
      b = await newIdentity();
      ble = RadioFakeBle();
      ble.debugSetIdentity('Me', me.publicKeyBase64);
      ble.debugAddNeighbour(neighbour('devA', a.publicKeyBase64));
      ble.debugAddNeighbour(neighbour('devB', b.publicKeyBase64));
    });

    Future<MeshPacket> envPacket(CryptoService from, CryptoService to, {int ttl = 7}) async {
      final env = await from.encryptMessage(plaintext: 'hi', senderUsername: 'x', recipientPublicKeyBase64: to.publicKeyBase64);
      return MeshPacket.create(MeshPacket.kindEnvelope, {'env': env.toJson()}, ttl: ttl);
    }

    test('Envelope for a neighbour is relayed straight to it with ttl - 1', () async {
      final p = await envPacket(a, b);
      ble.handleIncomingBytes(p.toBytes(), 'devA');
      await pumpEventQueue();
      expect(ble.sent.length, 1);
      expect(ble.sent.single.$1, 'devB');
      expect(ble.sent.single.$2!.ttl, 6);
      expect(ble.sent.single.$2!.pid, p.pid);
    });

    test('Envelope for an unknown destination is flooded to everyone except the sender', () async {
      final stranger = await newIdentity();
      final p = await envPacket(a, stranger);
      ble.handleIncomingBytes(p.toBytes(), 'devA');
      await pumpEventQueue();
      expect(ble.sent.map((e) => e.$1), ['devB']);
    });

    test('Duplicates are dropped and ttl 1 is not relayed', () async {
      final stranger = await newIdentity();
      final p = await envPacket(a, stranger);
      ble.handleIncomingBytes(p.toBytes(), 'devA');
      ble.handleIncomingBytes(p.toBytes(), 'devB');
      await pumpEventQueue();
      expect(ble.sent.length, 1);
      expect(ble.droppedDuplicates, 1);

      final last = await envPacket(a, stranger, ttl: 1);
      ble.handleIncomingBytes(last.toBytes(), 'devA');
      await pumpEventQueue();
      expect(ble.sent.length, 1);
    });

    test('Envelope addressed to us is delivered, not relayed', () async {
      final got = <ChatEnvelope>[];
      final sub = ble.onEnvelopeReceived.listen(got.add);
      final p = await envPacket(a, me);
      ble.handleIncomingBytes(p.toBytes(), 'devA');
      await pumpEventQueue();
      expect(got.length, 1);
      expect(ble.sent, isEmpty);
      await sub.cancel();
    });

    test('Legacy bare envelopes (no mesh wrapper) are still delivered', () async {
      final got = <ChatEnvelope>[];
      final sub = ble.onEnvelopeReceived.listen(got.add);
      final env = await a.encryptMessage(plaintext: 'old', senderUsername: 'A', recipientPublicKeyBase64: me.publicKeyBase64);
      ble.handleIncomingBytes(env.toBinary(), 'devA');
      await pumpEventQueue();
      expect(got.length, 1);
      await sub.cancel();
    });

    test('Announces are surfaced with hop count and relayed', () async {
      final got = <ReceivedMeshPacket>[];
      final sub = ble.onMeshPacket.listen(got.add);
      final p = MeshPacket.create(MeshPacket.kindAnnounce, {'u': 'Carol'}, ttl: 5);
      ble.handleIncomingBytes(p.toBytes(), 'devA');
      await pumpEventQueue();
      expect(got.single.hops, 3);
      expect(ble.sent.map((e) => e.$1), ['devB']);
      await sub.cancel();
    });

    test('Our own broadcast echoed back is ignored', () async {
      final p = MeshPacket.create(MeshPacket.kindPublic, {'text': 'x'});
      await ble.broadcastPacket(p);
      expect(ble.sent.length, 2);
      ble.handleIncomingBytes(p.withTtl(6).toBytes(), 'devA');
      await pumpEventQueue();
      expect(ble.sent.length, 2);
    });
  });

  group('ChatController mesh features', () {
    late CryptoService alice, carol;
    late RadioFakeBle ble;
    late ChatController controller;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final storage = await StorageService.create();
      alice = await newIdentity();
      carol = await newIdentity();
      ble = RadioFakeBle();
      controller = ChatController(crypto: alice, storage: storage, ble: ble);
      await controller.registerUser('Alice');
    });

    tearDown(() => controller.dispose());

    Future<MeshPacket> announce(CryptoService who, String name, {String? sigOverride}) async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final pk = who.publicKeyBase64;
      final spk = who.signingPublicKeyBase64;
      final sig = sigOverride ?? await who.sign(MeshPacket.announceSigningString(name, pk, spk, ts));
      return MeshPacket.create(MeshPacket.kindAnnounce, {'u': name, 'pk': pk, 'spk': spk, 'ts': ts, 'sig': sig});
    }

    test('A signed announce adds a mesh peer with its hop count', () async {
      await controller.handleMeshPacket(await announce(carol, 'Carol'), hops: 2);
      final p = controller.peers.single;
      expect(p.username, 'Carol');
      expect(p.isMeshOnly, isTrue);
      expect(p.hops, 2);
      expect(p.safetyNumber, isNotNull);
    });

    test('An announce with a forged signature is ignored', () async {
      final mallory = await newIdentity();
      final forged = await mallory.sign('something else');
      await controller.handleMeshPacket(await announce(carol, 'Carol', sigOverride: forged));
      expect(controller.peers, isEmpty);
    });

    test('Re-announcing a known key with a different signing key is rejected', () async {
      await controller.handleMeshPacket(await announce(carol, 'Carol'));
      // Mallory copies Carol's X25519 key but signs with her own Ed25519 key.
      final mallory = await newIdentity();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final spk = mallory.signingPublicKeyBase64;
      final sig = await mallory.sign(MeshPacket.announceSigningString('Carol (real)', carol.publicKeyBase64, spk, ts));
      await controller.handleMeshPacket(MeshPacket.create(MeshPacket.kindAnnounce,
          {'u': 'Carol (real)', 'pk': carol.publicKeyBase64, 'spk': spk, 'ts': ts, 'sig': sig}));
      expect(controller.peers.single.username, 'Carol');
    });

    test('Public room: signed messages are shown once, tampered ones dropped', () async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final pk = carol.publicKeyBase64;
      final spk = carol.signingPublicKeyBase64;
      final sig = await carol.sign(MeshPacket.publicSigningString('m1', 'Carol', pk, spk, ts, 'hello all'));
      final good = MeshPacket.create(MeshPacket.kindPublic,
          {'id': 'm1', 'u': 'Carol', 'pk': pk, 'spk': spk, 'ts': ts, 'text': 'hello all', 'sig': sig});
      await controller.handleMeshPacket(good, hops: 2);
      await controller.handleMeshPacket(good, hops: 2);
      final tampered = MeshPacket.create(MeshPacket.kindPublic,
          {'id': 'm2', 'u': 'Carol', 'pk': pk, 'spk': spk, 'ts': ts, 'text': 'send me money', 'sig': sig});
      await controller.handleMeshPacket(tampered);
      expect(controller.publicMessages.map((m) => m.text), ['hello all']);
      expect(controller.publicMessages.single.hops, 2);
    });

    test('Sending to the public room broadcasts a signed packet', () async {
      ble.debugAddNeighbour(neighbour('devX', carol.publicKeyBase64));
      ble.sent.clear();
      expect(await controller.sendPublicMessage('hi #nearby'), isTrue);
      // (the startup announce may also go out to the new neighbour; look at the public packet)
      final pkt = ble.sent.map((e) => e.$2!).singleWhere((p) => p.kind == MeshPacket.kindPublic);
      expect(pkt.kind, MeshPacket.kindPublic);
      final b = pkt.body;
      expect(
        await CryptoService.verifySignature(
          MeshPacket.publicSigningString(b['id'], b['u'], b['pk'], b['spk'], b['ts'], b['text']),
          b['sig'], b['spk']),
        isTrue,
      );
      expect(controller.publicMessages.single.isMine, isTrue);
    });

    test('A message to a mesh-only peer is flooded to the neighbours', () async {
      final relay = await newIdentity();
      ble.debugAddNeighbour(neighbour('devRelay', relay.publicKeyBase64));
      await controller.handleMeshPacket(await announce(carol, 'Carol'), hops: 2);
      final carolPeer = controller.peers.firstWhere((p) => p.publicKey == carol.publicKeyBase64);
      controller.selectPeer(carolPeer);
      ble.sent.clear();
      expect(await controller.sendMessage('two hops away'), isTrue);
      final envSends = ble.sent.where((e) => e.$2!.kind == MeshPacket.kindEnvelope).toList();
      expect(envSends.single.$1, 'devRelay');
      final env = ChatEnvelope.fromJson(Map<String, dynamic>.from(envSends.single.$2!.body['env'] as Map));
      expect(env.recipientPublicKey, carol.publicKeyBase64);
      expect(await carol.decryptEnvelope(env), 'two hops away');
    });
  });
}
