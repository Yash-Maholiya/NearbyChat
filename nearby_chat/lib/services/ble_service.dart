import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_ble/universal_ble.dart';

import '../models/chat_envelope.dart';
import '../models/mesh_packet.dart';
import '../models/peer.dart';
import 'frame_codec.dart';
import 'platform_util.dart';

/// Announce or public-room packet that got past duplicate suppression.
/// [hops] = devices crossed to reach us (1 = a direct neighbour).
class ReceivedMeshPacket {
  final MeshPacket packet;
  final String fromDeviceId;
  final int hops;
  ReceivedMeshPacket(this.packet, this.fromDeviceId, this.hops);
}

/// BLE transport plus the mesh layer (flooding, ttl, dedup).
///
/// Every device is both a GATT server and a client:
///   c0de0002 identity  read    {username, publicKey}
///   c0de0003 inbox     write   framed packets
///   c0de0004 outbox    notify  packets for centrals that can't host a server ("reverse links",
///                              e.g. Windows laptops). They subscribe, write a hello, and we
///                              answer on the same connection.
class BleService {
  static const serviceUuid = 'c0de0001-beef-11e4-8998-0002a5d5c51b';
  static const identityCharacteristicUuid = 'c0de0002-beef-11e4-8998-0002a5d5c51b';
  static const inboxCharacteristicUuid = 'c0de0003-beef-11e4-8998-0002a5d5c51b';
  static const outboxCharacteristicUuid = 'c0de0004-beef-11e4-8998-0002a5d5c51b';
  static const peerNamePrefix = 'NC-';

  static const neighbourTimeout = Duration(seconds: 60);
  static const _bindingTtl = Duration(minutes: 10);
  static const _idleDisconnect = Duration(seconds: 15);
  static const _connectTimeout = Duration(seconds: 10);
  static const _seenCapacity = 2000;

  final _reassembler = FrameReassembler();
  final _peerCtrl = StreamController<Peer>.broadcast();
  final _envelopeCtrl = StreamController<ChatEnvelope>.broadcast();
  final _meshCtrl = StreamController<ReceivedMeshPacket>.broadcast();

  final Map<String, Peer> _peers = {}; // deviceId -> peer we can send to
  final Map<String, ({String deviceId, DateTime at})> _lastHop = {}; // publicKey -> device
  final Map<String, int> _mtu = {};
  final Map<String, Timer> _idleTimers = {};
  final Map<String, Future<void>> _queues = {};
  final Set<String> _connected = {};
  final Set<String> _resolving = {};
  final Set<String> _reverseLinks = {};
  final LinkedHashSet<String> _seen = LinkedHashSet();
  final List<StreamSubscription<dynamic>> _subs = [];

  String? _username;
  String? _publicKey;
  bool _isScanning = false;
  bool _isAdvertising = false;
  bool _disposed = false;

  int relayedPackets = 0;
  int droppedDuplicates = 0;

  Stream<Peer> get onPeerDiscovered => _peerCtrl.stream;
  Stream<ChatEnvelope> get onEnvelopeReceived => _envelopeCtrl.stream;
  Stream<ReceivedMeshPacket> get onMeshPacket => _meshCtrl.stream;
  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;

  Future<void> init({required String localUsername, required String localPublicKeyBase64}) async {
    _username = localUsername;
    _publicKey = localPublicKeyBase64;
    _setupCentral();
    _setupPeripheral();
  }

  /// Device that last delivered something from [publicKey]; used to route ACKs back.
  String? getLastKnownDeviceId(String publicKey) {
    final b = _lastHop[publicKey];
    if (b == null) return null;
    if (DateTime.now().difference(b.at) > _bindingTtl) {
      _lastHop.remove(publicKey);
      return null;
    }
    return b.deviceId;
  }

  void _bind(String publicKey, String deviceId) {
    if (publicKey.isNotEmpty && deviceId.isNotEmpty) {
      _lastHop[publicKey] = (deviceId: deviceId, at: DateTime.now());
    }
  }

  void _emitPeer(Peer p) {
    _peers[p.deviceId] = p;
    if (!_peerCtrl.isClosed) _peerCtrl.add(p);
  }

  /// One BLE operation per device at a time, otherwise connect/disconnect calls race.
  Future<T> _serial<T>(String deviceId, Future<T> Function() op) {
    if (_disposed) return Future.error(StateError('BleService disposed'));
    final prev = _queues[deviceId] ?? Future.value();
    final done = Completer<void>();
    _queues[deviceId] = done.future;
    return prev.then((_) => op()).whenComplete(() {
      done.complete();
      if (_queues[deviceId] == done.future) _queues.remove(deviceId);
    });
  }

  // ---------------------------------------------------------------- permissions

  Future<bool> requestPermissions() async {
    if (kIsWeb) return true;
    try {
      if (isAndroid) {
        final s = await [
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
          Permission.location,
        ].request();
        // Android 12+ needs scan + connect; older versions need location for scanning.
        if (s[Permission.bluetoothScan]?.isGranted == true &&
            s[Permission.bluetoothConnect]?.isGranted == true) {
          return true;
        }
        final loc = s[Permission.location];
        return loc?.isGranted == true || loc?.isLimited == true;
      }
      if (isIOS) {
        final s = await Permission.bluetooth.request();
        return s.isGranted || s.isLimited;
      }
      return true;
    } catch (e) {
      debugPrint('[ble] permission request failed: $e');
      return false;
    }
  }

  // ------------------------------------------------------------------- central

  void _setupCentral() {
    UniversalBle.onScanResult = _onScanResult;
    UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
      if (isConnected) {
        _connected.add(deviceId);
      } else {
        _connected.remove(deviceId);
        _idleTimers.remove(deviceId)?.cancel();
      }
      final p = _peers[deviceId];
      if (p != null && !p.isReverseLink) _emitPeer(p.copyWith(isConnected: isConnected));
    };
  }

  Future<void> startScanning() async {
    if (!await requestPermissions()) {
      debugPrint('[ble] permissions not granted, not scanning');
      return;
    }
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [serviceUuid], withNamePrefix: [peerNamePrefix]),
      );
      _isScanning = true;
    } catch (e) {
      debugPrint('[ble] start scan failed: $e');
      _isScanning = false;
    }
  }

  Future<void> stopScanning() async {
    try {
      await UniversalBle.stopScan();
      _isScanning = false;
    } catch (e) {
      debugPrint('[ble] stop scan failed: $e');
    }
  }

  void _onScanResult(BleDevice device) {
    final name = device.name ?? device.rawName ?? '';
    final hasService = device.services.any((s) => s.toLowerCase().contains('c0de0001'));
    final hasPrefix = name.startsWith(peerNamePrefix);
    if (!hasService && !hasPrefix) return;

    final known = _peers[device.deviceId];
    if (known != null && known.publicKey.isNotEmpty) {
      _emitPeer(known.copyWith(rssi: device.rssi ?? known.rssi, lastSeen: DateTime.now()));
      return;
    }
    if (!_resolving.add(device.deviceId)) return;
    final fallbackName = hasPrefix ? name.substring(peerNamePrefix.length) : (name.isEmpty ? 'Nearby User' : name);
    _resolveIdentity(device.deviceId, fallbackName, device.rssi);
  }

  Future<void> _resolveIdentity(String deviceId, String fallbackName, int? rssi) {
    return _serial(deviceId, () async {
      try {
        await _ensureConnected(deviceId);
        final raw = await UniversalBle.read(
          deviceId, serviceUuid, identityCharacteristicUuid,
          timeout: const Duration(seconds: 8),
        );
        final data = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
        final publicKey = data['publicKey'] as String? ?? '';
        if (publicKey.isEmpty) return;
        final username = data['username'] as String?;
        _bind(publicKey, deviceId);
        _emitPeer(Peer(
          deviceId: deviceId,
          username: (username == null || username.isEmpty) ? fallbackName : username,
          publicKey: publicKey,
          rssi: rssi,
          lastSeen: DateTime.now(),
          isConnected: true,
        ));
      } catch (e) {
        debugPrint('[ble] identity read from $deviceId failed: $e');
      } finally {
        _resolving.remove(deviceId);
        _releaseLater(deviceId);
      }
    });
  }

  /// Connects if needed and negotiates the MTU. Android starts every connection at 23 bytes, so
  /// without asking for more only 20 byte writes are safe; iOS negotiates by itself.
  Future<int> _ensureConnected(String deviceId) async {
    _idleTimers.remove(deviceId)?.cancel();
    if (_connected.contains(deviceId) && _mtu.containsKey(deviceId)) return _mtu[deviceId]!;
    if (!_connected.contains(deviceId)) {
      await UniversalBle.connect(deviceId, timeout: _connectTimeout);
      _connected.add(deviceId);
      await UniversalBle.discoverServices(deviceId, timeout: _connectTimeout);
    }
    int mtu;
    try {
      mtu = await UniversalBle.requestMtu(deviceId, 247);
    } catch (_) {
      mtu = isIOS ? 185 : FrameCodec.minAttMtu;
    }
    return _mtu[deviceId] = mtu < FrameCodec.minAttMtu ? FrameCodec.minAttMtu : mtu;
  }

  /// Keep the link for a few seconds: relays and ACKs usually follow right away, and a BLE
  /// connect costs far more than the write itself.
  void _releaseLater(String deviceId) {
    _idleTimers.remove(deviceId)?.cancel();
    _idleTimers[deviceId] = Timer(_idleDisconnect, () {
      _idleTimers.remove(deviceId);
      _serial(deviceId, () async {
        _connected.remove(deviceId);
        _mtu.remove(deviceId);
        try {
          await UniversalBle.disconnect(deviceId);
        } catch (_) {}
      }).catchError((_) {});
    });
  }

  // ---------------------------------------------------------------- peripheral

  void _setupPeripheral() {
    try {
      UniversalBlePeripheral.setReadRequestHandlers((deviceId, characteristicId, offset, value) {
        if (!characteristicId.toLowerCase().contains('c0de0002')) {
          return PeripheralReadRequestResult(value: Uint8List(0));
        }
        final bytes = utf8.encode(jsonEncode({'username': _username ?? 'Unknown', 'publicKey': _publicKey ?? ''}));
        // honour the offset so long reads work at small MTUs
        return PeripheralReadRequestResult(
          value: offset >= bytes.length ? Uint8List(0) : Uint8List.fromList(bytes.sublist(offset)),
        );
      });

      UniversalBlePeripheral.setWriteRequestHandlers((deviceId, characteristicId, offset, value) {
        if (value != null && value.isNotEmpty && characteristicId.toLowerCase().contains('c0de0003')) {
          final packet = _reassembler.processFrame(value, senderId: deviceId);
          if (packet != null) handleIncomingBytes(packet, deviceId);
        }
        return PeripheralWriteRequestResult(status: 0);
      });

      for (final s in _subs) {
        s.cancel();
      }
      _subs
        ..clear()
        ..add(UniversalBlePeripheral.characteristicSubscriptionStream.listen((e) {
          if (!e.characteristicId.toLowerCase().contains('c0de0004')) return;
          if (e.isSubscribed) {
            _reverseLinks.add(e.deviceId);
          } else {
            _reverseLinks.remove(e.deviceId);
          }
        }))
        ..add(UniversalBlePeripheral.connectionStateStream.listen((e) {
          if (e.connected) return;
          _reverseLinks.remove(e.deviceId);
          final p = _peers[e.deviceId];
          if (p != null && p.isReverseLink) _emitPeer(p.copyWith(isConnected: false));
        }));
    } catch (e) {
      debugPrint('[ble] peripheral setup failed: $e');
    }
  }

  Future<void> startAdvertising() async {
    if (_username == null || _publicKey == null) {
      throw StateError('call init() before startAdvertising()');
    }
    try {
      await UniversalBlePeripheral.clearServices();
      await UniversalBlePeripheral.addService(BlePeripheralService(
        uuid: serviceUuid,
        primary: true,
        characteristics: [
          BlePeripheralCharacteristic(
            uuid: identityCharacteristicUuid,
            properties: [CharacteristicProperty.read],
            permissions: [PeripheralAttributePermission.readable],
          ),
          BlePeripheralCharacteristic(
            uuid: inboxCharacteristicUuid,
            properties: [CharacteristicProperty.write, CharacteristicProperty.writeWithoutResponse],
            permissions: [PeripheralAttributePermission.writeable],
          ),
          BlePeripheralCharacteristic(
            uuid: outboxCharacteristicUuid,
            properties: [CharacteristicProperty.read, CharacteristicProperty.notify],
            permissions: [PeripheralAttributePermission.readable],
          ),
        ],
      ));
      await UniversalBlePeripheral.startAdvertising(
        services: [serviceUuid],
        localName: '$peerNamePrefix$_username',
      );
      _isAdvertising = true;
    } catch (e) {
      debugPrint('[ble] advertising failed: $e');
      _isAdvertising = false;
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await UniversalBlePeripheral.stopAdvertising();
      _isAdvertising = false;
    } catch (e) {
      debugPrint('[ble] stop advertising failed: $e');
    }
  }

  /// {"hello":1,"username","publicKey"} from a central that can't be connected to.
  bool _handleHello(Map<String, dynamic> data, String deviceId) {
    if (data['hello'] == null) return false;
    final publicKey = data['publicKey'] as String? ?? '';
    if (publicKey.isEmpty || publicKey == _publicKey) return true;
    final name = data['username'] as String?;
    _bind(publicKey, deviceId);
    _emitPeer(Peer(
      deviceId: deviceId,
      username: (name == null || name.isEmpty) ? 'Nearby User' : name,
      publicKey: publicKey,
      rssi: _peers[deviceId]?.rssi,
      lastSeen: DateTime.now(),
      isConnected: true,
      isReverseLink: true,
    ));
    return true;
  }

  // ---------------------------------------------------------------------- mesh

  @visibleForTesting
  void debugSetIdentity(String username, String publicKeyBase64) {
    _username = username;
    _publicKey = publicKeyBase64;
  }

  @visibleForTesting
  void debugAddNeighbour(Peer peer) {
    _peers[peer.deviceId] = peer;
    _bind(peer.publicKey, peer.deviceId);
  }

  bool _isFresh(Peer p, DateTime now) => p.publicKey.isNotEmpty && now.difference(p.lastSeen) < neighbourTimeout;

  /// Devices we can send to right now.
  List<String> neighbourIds() {
    final now = DateTime.now();
    return [for (final e in _peers.entries) if (_isFresh(e.value, now)) e.key];
  }

  String? directDeviceFor(String publicKey) {
    final now = DateTime.now();
    for (final e in _peers.entries) {
      if (e.value.publicKey == publicKey && _isFresh(e.value, now)) return e.key;
    }
    return null;
  }

  bool _markSeen(String pid) {
    if (!_seen.add(pid)) return false;
    if (_seen.length > _seenCapacity) _seen.remove(_seen.first);
    return true;
  }

  /// Every complete packet goes through here: inbox writes and outbox notifications.
  void handleIncomingBytes(Uint8List bytes, String fromDeviceId) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[mesh] bad packet from $fromDeviceId: $e');
      return;
    }
    if (_handleHello(json, fromDeviceId)) return;

    final packet = MeshPacket.fromJson(json);
    if (packet == null) {
      // bare envelope from a pre-mesh client: deliver, never relay
      try {
        final env = ChatEnvelope.fromJson(json);
        _bind(env.senderPublicKey, fromDeviceId);
        if (!_envelopeCtrl.isClosed) _envelopeCtrl.add(env);
      } catch (e) {
        debugPrint('[mesh] bad envelope: $e');
      }
      return;
    }
    if (!_markSeen(packet.pid)) {
      droppedDuplicates++;
      return;
    }

    if (packet.kind == MeshPacket.kindEnvelope) {
      final ChatEnvelope env;
      try {
        env = ChatEnvelope.fromJson(Map<String, dynamic>.from(packet.body['env'] as Map));
      } catch (e) {
        debugPrint('[mesh] bad envelope in ${packet.pid}: $e');
        return;
      }
      // whoever handed it to us is the way back to the sender
      if (directDeviceFor(env.senderPublicKey) == null) _bind(env.senderPublicKey, fromDeviceId);
      if (env.recipientPublicKey == _publicKey) {
        if (!_envelopeCtrl.isClosed) _envelopeCtrl.add(env);
      } else {
        _relay(packet, fromDeviceId, target: env.recipientPublicKey);
      }
      return;
    }

    final hops = (MeshPacket.defaultTtl - packet.ttl + 1).clamp(1, 64);
    if (!_meshCtrl.isClosed) _meshCtrl.add(ReceivedMeshPacket(packet, fromDeviceId, hops));
    _relay(packet, fromDeviceId);
  }

  /// ttl - 1, straight to [target] if it's a neighbour, else to everyone but the sender.
  void _relay(MeshPacket packet, String fromDeviceId, {String? target}) {
    if (packet.ttl <= 1) return;
    final direct = target == null ? null : directDeviceFor(target);
    final targets = (direct != null && direct != fromDeviceId)
        ? [direct]
        : neighbourIds().where((id) => id != fromDeviceId).toList();
    if (targets.isEmpty) return;
    relayedPackets++;
    final bytes = packet.withTtl(packet.ttl - 1).toBytes();
    for (final t in targets) {
      sendRaw(t, bytes).catchError((_) => false);
    }
  }

  /// Sends a packet we originated to every neighbour. True if at least one send worked.
  Future<bool> broadcastPacket(MeshPacket packet) async {
    _markSeen(packet.pid);
    final targets = neighbourIds();
    if (targets.isEmpty) return false;
    final bytes = packet.toBytes();
    final results = await Future.wait(targets.map((t) => sendRaw(t, bytes).catchError((_) => false)));
    return results.contains(true);
  }

  Future<bool> floodEnvelope(ChatEnvelope envelope) =>
      broadcastPacket(MeshPacket.create(MeshPacket.kindEnvelope, {'env': envelope.toJson()}));

  Future<bool> sendEnvelope(String deviceId, ChatEnvelope envelope) {
    final packet = MeshPacket.create(MeshPacket.kindEnvelope, {'env': envelope.toJson()});
    _markSeen(packet.pid);
    return sendRaw(deviceId, packet.toBytes());
  }

  /// Write to the device's inbox, or notify it on our outbox if it's a reverse link.
  Future<bool> sendRaw(String deviceId, Uint8List data) {
    if (_reverseLinks.contains(deviceId)) return _serial(deviceId, () => _notify(deviceId, data));
    return _serial(deviceId, () async {
      try {
        final mtu = await _ensureConnected(deviceId);
        final frames = FrameCodec.fragment(data, maxFrameSize: FrameCodec.frameSizeForMtu(mtu));
        for (final f in frames) {
          await UniversalBle.write(deviceId, serviceUuid, inboxCharacteristicUuid, f, withoutResponse: true);
          // give the controller's buffer a moment between frames
          if (frames.length > 1) await Future.delayed(const Duration(milliseconds: 25));
        }
        _releaseLater(deviceId);
        return true;
      } catch (e) {
        debugPrint('[ble] send to $deviceId failed: $e');
        _connected.remove(deviceId);
        _mtu.remove(deviceId);
        try {
          await UniversalBle.disconnect(deviceId);
        } catch (_) {}
        return false;
      }
    });
  }

  Future<bool> _notify(String deviceId, Uint8List data) async {
    try {
      var max = await UniversalBlePeripheral.getMaximumNotifyLength(deviceId) ?? 20;
      max = max.clamp(20, FrameCodec.maxFrameSize);
      for (final f in FrameCodec.fragment(data, maxFrameSize: max)) {
        await UniversalBlePeripheral.updateCharacteristicValue(
          characteristicId: outboxCharacteristicUuid,
          value: f,
          deviceId: deviceId,
        );
        // Android queues notifications without waiting; too fast and some get dropped
        await Future.delayed(const Duration(milliseconds: 40));
      }
      return true;
    } catch (e) {
      debugPrint('[ble] notify to $deviceId failed: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    for (final t in _idleTimers.values) {
      t.cancel();
    }
    _idleTimers.clear();
    _queues.clear();
    await stopScanning();
    await stopAdvertising();
    await _peerCtrl.close();
    await _envelopeCtrl.close();
    await _meshCtrl.close();
  }
}
