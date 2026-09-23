import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_envelope.dart';
import '../models/chat_message.dart';
import '../models/peer.dart';
import '../services/ble_service.dart';
import '../services/crypto_service.dart';
import '../services/storage_service.dart';

class ChatController extends ChangeNotifier {
  final CryptoService _crypto;
  final StorageService _storage;
  final BleService _ble;
  final Uuid _uuid = const Uuid();

  String? _username;
  final Map<String, Peer> _peers = {};
  final Map<String, List<ChatMessage>> _conversationHistory = {};
  Peer? _activePeer;
  bool _isInitialized = false;

  StreamSubscription<Peer>? _peerSub;
  StreamSubscription<ChatEnvelope>? _envelopeSub;
  Timer? _staleCheckTimer;

  ChatController({
    CryptoService? crypto,
    required StorageService storage,
    BleService? ble,
  })  : _crypto = crypto ?? CryptoService(),
        _storage = storage,
        _ble = ble ?? BleService();

  String? get username => _username;
  bool get isRegistered => _username != null && _username!.isNotEmpty;
  bool get isInitialized => _isInitialized;
  String get localPublicKeyBase64 => _crypto.publicKeyBase64;
  String get localFingerprint => _crypto.fingerprint;
  List<Peer> get peers => _peers.values.toList();
  Peer? get activePeer => _activePeer;
  bool get isScanning => _ble.isScanning;
  bool get isAdvertising => _ble.isAdvertising;

  List<ChatMessage> get activeMessages {
    if (_activePeer == null) return [];
    return _conversationHistory[_activePeer!.fingerprint] ?? [];
  }

  Future<void> init() async {
    _username = _storage.getUsername();

    if (isRegistered) {
      await _setupIdentityAndBle();
    }

    _isInitialized = true;
    notifyListeners();
  }

  Future<void> registerUser(String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return;

    await _storage.setUsername(cleanName);
    _username = cleanName;

    await _setupIdentityAndBle();
    notifyListeners();
  }

  Future<void> _setupIdentityAndBle() async {
    await _crypto.init();
    await _ble.init(
      localUsername: _username!,
      localPublicKeyBase64: _crypto.publicKeyBase64,
    );

    _peerSub?.cancel();
    _envelopeSub?.cancel();

    _peerSub = _ble.onPeerDiscovered.listen((peer) async {
      final safetyNumber = await _crypto.deriveSafetyNumber(peer.publicKey);
      final isVerified = _storage.isPeerVerified(peer.fingerprint);

      final enrichedPeer = peer.copyWith(
        safetyNumber: safetyNumber,
        isVerified: isVerified,
      );

      // Clean up any placeholder peer (e.g. unknown-Alice) with matching public key
      _peers.removeWhere((id, p) => id.startsWith('unknown-') && p.publicKey == peer.publicKey);

      _peers[peer.deviceId] = enrichedPeer;

      // Update active peer reference if currently chatting
      if (_activePeer?.deviceId == peer.deviceId || _activePeer?.publicKey == peer.publicKey) {
        _activePeer = enrichedPeer;
      }

      notifyListeners();
    });

    _envelopeSub = _ble.onEnvelopeReceived.listen((envelope) async {
      await _handleIncomingEnvelope(envelope);
    });

    _staleCheckTimer?.cancel();
    _staleCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      bool changed = false;
      final now = DateTime.now();
      for (final key in _peers.keys.toList()) {
        final p = _peers[key]!;
        if (p.isConnected && now.difference(p.lastSeen).inSeconds > 20) {
          _peers[key] = p.copyWith(isConnected: false);
          if (_activePeer?.deviceId == p.deviceId) {
            _activePeer = _peers[key];
          }
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });

    // Automatically request permissions and start discovery
    await startDiscovery();
  }

  Future<void> startDiscovery() async {
    await _ble.startScanning();
    await _ble.startAdvertising();
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    await _ble.stopScanning();
    await _ble.stopAdvertising();
    notifyListeners();
  }

  void selectPeer(Peer? peer) {
    _activePeer = peer;
    if (peer != null) {
      // Load saved message history into memory
      _conversationHistory[peer.fingerprint] = _storage.getMessages(peer.fingerprint);
    }
    notifyListeners();
  }

  Future<bool> sendMessage(String text) async {
    final currentPeer = _activePeer;
    if (currentPeer == null || _username == null || text.trim().isEmpty) {
      return false;
    }

    final plaintext = text.trim();
    final messageId = _uuid.v4();

    // 1. Encrypt message payload
    final envelope = await _crypto.encryptMessage(
      plaintext: plaintext,
      senderUsername: _username!,
      recipientPublicKeyBase64: currentPeer.publicKey,
      messageId: messageId,
    );

    // 2. Create local message record
    final localMessage = ChatMessage(
      id: messageId,
      sender: _username!,
      recipient: currentPeer.username,
      body: plaintext,
      sentAt: DateTime.now(),
      isMine: true,
      peerFingerprint: currentPeer.fingerprint,
      status: MessageStatus.sending,
    );

    // 3. Save locally
    await _storage.saveMessage(localMessage);
    final history = _conversationHistory.putIfAbsent(currentPeer.fingerprint, () => []);
    final existingIdx = history.indexWhere((m) => m.id == messageId);
    if (existingIdx < 0) {
      history.add(localMessage);
    }
    notifyListeners();

    // 4. Transmit via BLE
    final success = await _ble.sendEnvelope(currentPeer.deviceId, envelope);
    final newStatus = success ? MessageStatus.delivered : MessageStatus.failed;

    await _storage.updateMessageStatus(messageId, currentPeer.fingerprint, newStatus);
    final idx = history.indexWhere((m) => m.id == messageId);
    if (idx >= 0) {
      history[idx] = history[idx].copyWith(status: newStatus);
      notifyListeners();
    }

    return success;
  }

  Future<void> _handleIncomingEnvelope(ChatEnvelope envelope) async {
    try {
      // Validate recipient public key
      if (_crypto.isInitialized && envelope.recipientPublicKey != _crypto.publicKeyBase64) {
        debugPrint('[Controller] Envelope addressed to different recipient; ignoring.');
        return;
      }

      final decryptedText = await _crypto.decryptEnvelope(envelope);
      final senderFingerprint = envelope.senderPublicKey.length > 12
          ? envelope.senderPublicKey.substring(0, 12)
          : envelope.senderPublicKey;

      final incomingMessage = ChatMessage(
        id: envelope.messageId,
        sender: envelope.senderUsername,
        recipient: _username ?? 'Me',
        body: decryptedText,
        sentAt: DateTime.fromMillisecondsSinceEpoch(envelope.timestamp),
        isMine: false,
        peerFingerprint: senderFingerprint,
        status: MessageStatus.delivered,
      );

      await _storage.saveMessage(incomingMessage);
      final history = _conversationHistory.putIfAbsent(senderFingerprint, () => []);
      final existingIndex = history.indexWhere((m) => m.id == incomingMessage.id);
      if (existingIndex >= 0) {
        history[existingIndex] = incomingMessage;
      } else {
        history.add(incomingMessage);
      }

      // If sender peer is in list, update lastSeen and isConnected
      final existingKey = _peers.keys.firstWhere(
        (key) => _peers[key]!.publicKey == envelope.senderPublicKey,
        orElse: () => '',
      );

      if (existingKey.isNotEmpty) {
        final existingPeer = _peers[existingKey]!;
        final updatedPeer = existingPeer.copyWith(
          lastSeen: DateTime.now(),
          isConnected: true,
        );
        _peers[existingKey] = updatedPeer;
        if (_activePeer?.deviceId == existingPeer.deviceId || _activePeer?.publicKey == envelope.senderPublicKey) {
          _activePeer = updatedPeer;
        }
      } else {
        // Peer not yet discovered via scanning — create enriched placeholder
        final safetyNumber = await _crypto.deriveSafetyNumber(envelope.senderPublicKey);
        final newPeer = Peer(
          deviceId: 'unknown-${envelope.senderUsername}',
          username: envelope.senderUsername,
          publicKey: envelope.senderPublicKey,
          lastSeen: DateTime.now(),
          safetyNumber: safetyNumber,
          isVerified: _storage.isPeerVerified(senderFingerprint),
          isConnected: true,
        );
        _peers[newPeer.deviceId] = newPeer;
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[Controller] Failed to decrypt incoming envelope: $e');
    }
  }

  Future<void> togglePeerVerification(Peer peer, bool verified) async {
    await _storage.setPeerVerified(peer.fingerprint, verified);
    final updatedPeer = peer.copyWith(isVerified: verified);
    _peers[peer.deviceId] = updatedPeer;

    if (_activePeer?.deviceId == peer.deviceId) {
      _activePeer = updatedPeer;
    }

    notifyListeners();
  }

  @override
  void dispose() {
    // Fire and forget, catching any errors since dispose is synchronous
    stopDiscovery().catchError((e) {
      debugPrint('[ChatController] Error stopping discovery during dispose: $e');
    });
    _peerSub?.cancel();
    _envelopeSub?.cancel();
    _staleCheckTimer?.cancel();
    _ble.dispose();
    super.dispose();
  }
}
