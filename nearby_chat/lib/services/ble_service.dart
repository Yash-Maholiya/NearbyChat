import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_ble/universal_ble.dart';
import '../models/chat_envelope.dart';
import '../models/peer.dart';
import 'frame_codec.dart';
import 'platform_util.dart';

class _DeviceBinding {
  final String deviceId;
  final DateTime lastSeen;

  _DeviceBinding(this.deviceId, this.lastSeen);
}

class BleService {
  static const String serviceUuid = 'c0de0001-beef-11e4-8998-0002a5d5c51b';
  static const String identityCharacteristicUuid = 'c0de0002-beef-11e4-8998-0002a5d5c51b';
  static const String inboxCharacteristicUuid = 'c0de0003-beef-11e4-8998-0002a5d5c51b';
  static const String peerNamePrefix = 'NC-';
  static const Duration _deviceBindingTtl = Duration(minutes: 10);

  final FrameReassembler _reassembler = FrameReassembler();
  final StreamController<Peer> _peerDiscoveredController = StreamController<Peer>.broadcast();
  final StreamController<ChatEnvelope> _envelopeReceivedController = StreamController<ChatEnvelope>.broadcast();
  final StreamController<bool> _scanningStateController = StreamController<bool>.broadcast();
  final StreamController<bool> _advertisingStateController = StreamController<bool>.broadcast();

  final Map<String, Peer> _discoveredPeers = {};
  final Set<String> _connectedDevices = {};
  final Set<String> _resolvingDevices = {};
  final Map<String, _DeviceBinding> _lastKnownDeviceIdByPublicKey = {};

  String? _localUsername;
  String? _localPublicKeyBase64;
  final Map<String, Future<void>> _deviceQueues = {};
  bool _isScanning = false;
  bool _isAdvertising = false;
  bool _peripheralSupported = true;
  bool _isDisposed = false;

  /// Serializes BLE operations per device to prevent overlapping connect/disconnect race conditions.
  Future<T> _enqueueOperation<T>(String deviceId, Future<T> Function() operation) {
    if (_isDisposed) {
      return Future.error(StateError('BleService is disposed'));
    }

    final previous = _deviceQueues[deviceId] ?? Future.value();
    final completer = Completer<void>();

    _deviceQueues[deviceId] = completer.future;

    return previous.then((_) async {
      try {
        if (_isDisposed) {
          throw StateError('BleService was disposed while operation was queued');
        }
        return await operation();
      } finally {
        completer.complete();
      }
    }).whenComplete(() {
      if (_deviceQueues[deviceId] == completer.future) {
        _deviceQueues.remove(deviceId);
      }
    });
  }

  Stream<Peer> get onPeerDiscovered => _peerDiscoveredController.stream;
  Stream<ChatEnvelope> get onEnvelopeReceived => _envelopeReceivedController.stream;
  Stream<bool> get onScanningStateChanged => _scanningStateController.stream;
  Stream<bool> get onAdvertisingStateChanged => _advertisingStateController.stream;

  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;
  bool get isPeripheralSupported => _peripheralSupported;
  Map<String, Peer> get discoveredPeers => Map.unmodifiable(_discoveredPeers);

  /// Gets the last known BLE deviceId for a peer's public key (useful for sending ACKs).
  /// Expired entries (> 10 mins) return null to avoid connecting to rotated or dead device IDs.
  String? getLastKnownDeviceId(String publicKey) {
    final binding = _lastKnownDeviceIdByPublicKey[publicKey];
    if (binding == null) return null;
    if (DateTime.now().difference(binding.lastSeen) > _deviceBindingTtl) {
      _lastKnownDeviceIdByPublicKey.remove(publicKey);
      return null;
    }
    return binding.deviceId;
  }

  void _recordDeviceBinding(String publicKey, String deviceId) {
    if (publicKey.isNotEmpty && deviceId.isNotEmpty) {
      _lastKnownDeviceIdByPublicKey[publicKey] = _DeviceBinding(deviceId, DateTime.now());
    }
  }

  /// Initializes BLE listeners and handlers.
  Future<void> init({
    required String localUsername,
    required String localPublicKeyBase64,
  }) async {
    _localUsername = localUsername;
    _localPublicKeyBase64 = localPublicKeyBase64;

    _setupCentralCallbacks();
    _setupPeripheralHandlers();
  }

  /// Request runtime permissions for Bluetooth and Location across platforms.
  Future<bool> requestPermissions() async {
    try {
      if (kIsWeb) return true;

      if (isAndroid) {
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
          Permission.location,
        ].request();

        final btScanGranted = statuses[Permission.bluetoothScan]?.isGranted == true;
        final btConnectGranted = statuses[Permission.bluetoothConnect]?.isGranted == true;
        final locGranted = statuses[Permission.location]?.isGranted == true ||
            statuses[Permission.location]?.isLimited == true;

        // Android 12+ (API 31+) requires bluetoothScan & bluetoothConnect.
        if (btScanGranted && btConnectGranted) return true;
        // Legacy Android (<= 11) requires location permission for scanning.
        return locGranted;
      } else if (isIOS) {
        final status = await Permission.bluetooth.request();
        return status.isGranted || status.isLimited;
      }
      return true;
    } catch (e) {
      debugPrint('[BLE] Permission request error: $e');
      return false;
    }
  }

  void _setupCentralCallbacks() {
    UniversalBle.onScanResult = (BleDevice device) {
      _handleDiscoveredDevice(device);
    };

    UniversalBle.onConnectionChange = (String deviceId, bool isConnected, String? error) {
      debugPrint('[BLE] Connection changed: $deviceId, connected=$isConnected, error=$error');
      if (isConnected) {
        _connectedDevices.add(deviceId);
      } else {
        _connectedDevices.remove(deviceId);
      }

      // Update peer status if known
      for (final entry in _discoveredPeers.entries) {
        if (entry.value.deviceId == deviceId) {
          final updated = entry.value.copyWith(isConnected: isConnected);
          _discoveredPeers[entry.key] = updated;
          if (!_peerDiscoveredController.isClosed) {
            _peerDiscoveredController.add(updated);
          }
        }
      }
    };
  }

  void _setupPeripheralHandlers() {
    try {
      UniversalBlePeripheral.setReadRequestHandlers((
        String deviceId,
        String characteristicId,
        int offset,
        Uint8List? value,
      ) {
        if (characteristicId.toLowerCase().contains('c0de0002') ||
            characteristicId == identityCharacteristicUuid) {
          final identityJson = jsonEncode({
            'username': _localUsername ?? 'Unknown',
            'publicKey': _localPublicKeyBase64 ?? '',
          });
          final bytes = Uint8List.fromList(utf8.encode(identityJson));

          // Honor GATT read offset to support long reads / MTU chunking
          if (offset >= bytes.length) {
            return PeripheralReadRequestResult(value: Uint8List(0));
          }
          return PeripheralReadRequestResult(value: bytes.sublist(offset));
        }
        return PeripheralReadRequestResult(value: Uint8List(0));
      });

      UniversalBlePeripheral.setWriteRequestHandlers((
        String deviceId,
        String characteristicId,
        int offset,
        Uint8List? value,
      ) {
        if (value != null && value.isNotEmpty &&
            (characteristicId.toLowerCase().contains('c0de0003') ||
             characteristicId == inboxCharacteristicUuid)) {
          final fullBytes = _reassembler.processFrame(value, senderId: deviceId);
          if (fullBytes != null) {
            try {
              final envelope = ChatEnvelope.fromBinary(fullBytes);
              // Associate sender's public key with this BLE deviceId for ACK routing with TTL
              _recordDeviceBinding(envelope.senderPublicKey, deviceId);
              if (!_envelopeReceivedController.isClosed) {
                _envelopeReceivedController.add(envelope);
              }
            } catch (e) {
              debugPrint('[BLE Peripheral] Failed to parse received envelope: $e');
            }
          }
        }
        return PeripheralWriteRequestResult(status: 0);
      });
    } catch (e) {
      debugPrint('[BLE Peripheral] Handler setup error: $e');
      _peripheralSupported = false;
    }
  }

  /// Starts Peripheral advertising with GATT Service and Characteristics.
  Future<void> startAdvertising() async {
    if (_localUsername == null || _localPublicKeyBase64 == null) {
      throw StateError('BleService must be initialized with username and publicKey before advertising.');
    }

    try {
      // Configure GATT Service
      final identityChar = BlePeripheralCharacteristic(
        uuid: identityCharacteristicUuid,
        properties: [CharacteristicProperty.read],
        permissions: [PeripheralAttributePermission.readable],
      );

      final inboxChar = BlePeripheralCharacteristic(
        uuid: inboxCharacteristicUuid,
        properties: [
          CharacteristicProperty.write,
          CharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [PeripheralAttributePermission.writeable],
      );

      final service = BlePeripheralService(
        uuid: serviceUuid,
        primary: true,
        characteristics: [identityChar, inboxChar],
      );

      try {
        await UniversalBlePeripheral.clearServices();
        await UniversalBlePeripheral.addService(service);
      } catch (e) {
        debugPrint('[BLE Peripheral] AddService failed: $e');
        _isAdvertising = false;
        if (!_advertisingStateController.isClosed) {
          _advertisingStateController.add(false);
        }
        _peripheralSupported = false;
        return;
      }

      await UniversalBlePeripheral.startAdvertising(
        services: [serviceUuid],
        localName: '$peerNamePrefix$_localUsername',
      );

      _isAdvertising = true;
      if (!_advertisingStateController.isClosed) {
        _advertisingStateController.add(true);
      }
      debugPrint('[BLE Peripheral] Advertising started as NC-$_localUsername');
    } catch (e) {
      debugPrint('[BLE Peripheral] Advertising failed: $e');
      _isAdvertising = false;
      if (!_advertisingStateController.isClosed) {
        _advertisingStateController.add(false);
      }
      _peripheralSupported = false;
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await UniversalBlePeripheral.stopAdvertising();
      _isAdvertising = false;
      if (!_advertisingStateController.isClosed) {
        _advertisingStateController.add(false);
      }
    } catch (e) {
      debugPrint('[BLE Peripheral] Stop advertising error: $e');
    }
  }

  /// Starts Central BLE scanning for nearby NearbyChat devices.
  Future<void> startScanning() async {
    final granted = await requestPermissions();
    if (!granted) {
      debugPrint('[BLE Central] Permissions not granted for scanning.');
      return;
    }

    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(
          withServices: [serviceUuid],
          withNamePrefix: [peerNamePrefix],
        ),
      );

      _isScanning = true;
      if (!_scanningStateController.isClosed) {
        _scanningStateController.add(true);
      }
      debugPrint('[BLE Central] Scanning started');
    } catch (e) {
      debugPrint('[BLE Central] Start scan error: $e');
      _isScanning = false;
      if (!_scanningStateController.isClosed) {
        _scanningStateController.add(false);
      }
    }
  }

  Future<void> stopScanning() async {
    try {
      await UniversalBle.stopScan();
      _isScanning = false;
      if (!_scanningStateController.isClosed) {
        _scanningStateController.add(false);
      }
      debugPrint('[BLE Central] Scanning stopped');
    } catch (e) {
      debugPrint('[BLE Central] Stop scan error: $e');
    }
  }

  Future<void> _handleDiscoveredDevice(BleDevice device) async {
    final name = device.name ?? device.rawName ?? '';
    final hasService = device.services.any((s) => s.toLowerCase().contains('c0de0001') || s == serviceUuid);
    final hasPrefix = name.startsWith(peerNamePrefix);

    if (!hasService && !hasPrefix) return;

    // Guard against repeated redundant resolution attempts while scan result fires repeatedly
    if (_resolvingDevices.contains(device.deviceId)) return;

    final displayName = hasPrefix ? name.substring(peerNamePrefix.length) : (name.isNotEmpty ? name : 'Nearby User');

    // Attempt to read peer's public identity if not yet resolved
    if (!_discoveredPeers.containsKey(device.deviceId) || _discoveredPeers[device.deviceId]?.publicKey.isEmpty == true) {
      _resolvePeerIdentity(device.deviceId, displayName, device.rssi);
    } else {
      // Update RSSI and last seen
      final existing = _discoveredPeers[device.deviceId]!;
      final updated = existing.copyWith(
        rssi: device.rssi ?? existing.rssi,
        lastSeen: DateTime.now(),
      );
      _discoveredPeers[device.deviceId] = updated;
      if (!_peerDiscoveredController.isClosed) {
        _peerDiscoveredController.add(updated);
      }
    }
  }

  Future<void> _resolvePeerIdentity(String deviceId, String defaultName, int? rssi) {
    if (_resolvingDevices.contains(deviceId)) return Future.value();
    _resolvingDevices.add(deviceId);

    return _enqueueOperation(deviceId, () async {
      try {
        if (_discoveredPeers.containsKey(deviceId) && _discoveredPeers[deviceId]?.publicKey.isNotEmpty == true) {
          return;
        }

        await UniversalBle.connect(deviceId, timeout: const Duration(seconds: 10));
        await UniversalBle.discoverServices(deviceId, timeout: const Duration(seconds: 10));

        final rawData = await UniversalBle.read(
          deviceId,
          serviceUuid,
          identityCharacteristicUuid,
          timeout: const Duration(seconds: 8),
        );

        if (rawData.isNotEmpty) {
          final jsonStr = utf8.decode(rawData);
          final Map<String, dynamic> data = jsonDecode(jsonStr);
          final username = (data['username'] as String?)?.isNotEmpty == true ? data['username'] as String : defaultName;
          final publicKey = data['publicKey'] as String? ?? '';

          if (publicKey.isNotEmpty) {
            _recordDeviceBinding(publicKey, deviceId);
            final peer = Peer(
              deviceId: deviceId,
              username: username,
              publicKey: publicKey,
              rssi: rssi,
              lastSeen: DateTime.now(),
              isConnected: true,
            );
            _discoveredPeers[deviceId] = peer;
            if (!_peerDiscoveredController.isClosed) {
              _peerDiscoveredController.add(peer);
            }
            debugPrint('[BLE Central] Successfully resolved peer identity: $username ($publicKey)');
          }
        }
      } catch (e) {
        debugPrint('[BLE Central] Resolve identity notice for $deviceId: $e');
      } finally {
        _resolvingDevices.remove(deviceId);
        // Always disconnect after identity resolution to prevent BLE connection leak
        try {
          await UniversalBle.disconnect(deviceId);
        } catch (_) {
          // Disconnect may fail if already disconnected — ignore
        }
      }
    });
  }

  /// Transmits an encrypted message envelope to a peer's inbox characteristic.
  Future<bool> sendEnvelope(String deviceId, ChatEnvelope envelope) {
    return _enqueueOperation(deviceId, () async {
      bool didConnect = false;
      try {
        // Connect if not already connected
        final isConnected = _connectedDevices.contains(deviceId);
        if (!isConnected) {
          await UniversalBle.connect(deviceId, timeout: const Duration(seconds: 10));
          didConnect = true;
          await UniversalBle.discoverServices(deviceId, timeout: const Duration(seconds: 10));
        }

        final binaryData = envelope.toBinary();
        final frames = FrameCodec.fragment(binaryData);

        debugPrint('[BLE Central] Sending ${frames.length} frames (${binaryData.length} bytes) to $deviceId');

        for (int i = 0; i < frames.length; i++) {
          await UniversalBle.write(
            deviceId,
            serviceUuid,
            inboxCharacteristicUuid,
            frames[i],
            withoutResponse: true,
          );
          // Small interval to prevent BLE buffer congestion on Android/iOS
          if (frames.length > 1) {
            await Future.delayed(const Duration(milliseconds: 25));
          }
        }

        return true;
      } catch (e) {
        debugPrint('[BLE Central] Error sending envelope to $deviceId: $e');
        return false;
      } finally {
        // Disconnect if we initiated the connection to prevent BLE connection leak
        if (didConnect) {
          try {
            await UniversalBle.disconnect(deviceId);
          } catch (_) {}
        }
      }
    });
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _deviceQueues.clear();
    try {
      await stopScanning();
    } catch (_) {}
    try {
      await stopAdvertising();
    } catch (_) {}
    if (!_peerDiscoveredController.isClosed) _peerDiscoveredController.close();
    if (!_envelopeReceivedController.isClosed) _envelopeReceivedController.close();
    if (!_scanningStateController.isClosed) _scanningStateController.close();
    if (!_advertisingStateController.isClosed) _advertisingStateController.close();
  }
}
