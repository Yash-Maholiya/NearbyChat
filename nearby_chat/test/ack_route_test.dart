// ACK routing: the ACK first goes back along the path the message came from (the relay),
// and if that fails it falls back to the address the sender was discovered at.
import 'dart:async';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/controllers/chat_controller.dart';
import 'package:nearby_chat/models/chat_envelope.dart';
import 'package:nearby_chat/models/peer.dart';
import 'package:nearby_chat/services/ble_service.dart';
import 'package:nearby_chat/services/crypto_service.dart';
import 'package:nearby_chat/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RouteFakeBle extends BleService {
  final peerController = StreamController<Peer>.broadcast();
  final envelopeController = StreamController<ChatEnvelope>.broadcast();
  String? lastHop;
  final Set<String> reachable = {};
  final List<String> attempts = [];

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
  String? getLastKnownDeviceId(String publicKey) => lastHop;
  @override
  Future<bool> sendEnvelope(String deviceId, ChatEnvelope envelope) async {
    attempts.add(deviceId);
    return reachable.contains(deviceId);
  }
  @override
  Future<void> dispose() async {
    await peerController.close();
    await envelopeController.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CryptoService alice;
  late CryptoService bob;
  late RouteFakeBle ble;
  late ChatController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final storage = await StorageService.create();
    alice = CryptoService();
    await alice.init(testKeyPair: await Cryptography.instance.x25519().newKeyPair());
    bob = CryptoService();
    await bob.init(testKeyPair: await Cryptography.instance.x25519().newKeyPair());
    ble = RouteFakeBle();
    controller = ChatController(crypto: alice, storage: storage, ble: ble);
    await controller.registerUser('Alice');
    ble.peerController.add(Peer(
      deviceId: 'bob-scanned',
      username: 'Bob',
      publicKey: bob.publicKeyBase64,
      lastSeen: DateTime.now(),
    ));
    await pumpEventQueue();
  });

  tearDown(() => controller.dispose());

  Future<void> receiveFromBob() async {
    final env = await bob.encryptMessage(
      plaintext: 'hi',
      senderUsername: 'Bob',
      recipientPublicKeyBase64: alice.publicKeyBase64,
    );
    ble.envelopeController.add(env);
    await pumpEventQueue();
  }

  test('ACK goes to the relay (last hop) first', () async {
    ble.lastHop = 'relay-laptop';
    ble.reachable.add('relay-laptop');
    await receiveFromBob();
    expect(ble.attempts, ['relay-laptop']);
  });

  test('ACK falls back to the scanned address when the last hop fails', () async {
    ble.lastHop = 'bob-as-central';
    ble.reachable.add('bob-scanned');
    await receiveFromBob();
    expect(ble.attempts, ['bob-as-central', 'bob-scanned']);
  });
}
