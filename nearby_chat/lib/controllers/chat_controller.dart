import 'dart:async';
import 'dart:collection';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../services/ids.dart';
import '../models/chat_envelope.dart';
import '../models/chat_message.dart';
import '../models/mesh_packet.dart';
import '../models/peer.dart';
import '../services/ble_service.dart';
import '../services/crypto_service.dart';
import '../services/storage_service.dart';

String _fp(String publicKey) => publicKey.length > 12 ? publicKey.substring(0, 12) : publicKey;

class ChatController extends ChangeNotifier {
  ChatController({CryptoService? crypto, required StorageService storage, BleService? ble})
      : _crypto = crypto ?? CryptoService(),
        _storage = storage,
        _ble = ble ?? BleService();

  static const Duration announceInterval = Duration(seconds: 15);
  static const Duration meshPeerTimeout = Duration(seconds: 45);
  static const Duration directPeerTimeout = Duration(seconds: 20);
  static const Duration queueRetryGap = Duration(seconds: 30);

  /// The timestamp is inside the AEAD, so a relay can't change it; anything further off
  /// than this is treated as a replay.
  static const Duration maxClockSkew = Duration(minutes: 30);

  final CryptoService _crypto;
  final StorageService _storage;
  final BleService _ble;

  String? _username;
  Peer? _activePeer;
  final Map<String, Peer> _peers = {};
  final Map<String, List<ChatMessage>> _history = {};
  final Map<String, String?> _safetyNumbers = {};

  // X25519 key -> Ed25519 key, pinned the first time we see a valid signature.
  final Map<String, String> _signingKeys = {};
  final List<PublicMessage> _publicMessages = [];
  final Set<String> _seenPublicIds = {};
  final Map<String, DateTime> _lastQueueFlush = {};

  // ACKs that beat sendEnvelope() back (the receiver answered before our write returned).
  final LinkedHashSet<String> _earlyAcks = LinkedHashSet();
  final LinkedHashSet<String> _seenIncomingIds = LinkedHashSet();

  String? _securityAlert;
  int _securityAlertCount = 0;

  StreamSubscription<Peer>? _peerSub;
  StreamSubscription<ChatEnvelope>? _envelopeSub;
  StreamSubscription<ReceivedMeshPacket>? _meshSub;
  Timer? _staleTimer;
  Timer? _announceTimer;

  String? get username => _username;
  bool get isRegistered => _username?.isNotEmpty ?? false;
  String get localFingerprint => _crypto.fingerprint;
  List<Peer> get peers => _peers.values.toList();
  Peer? get activePeer => _activePeer;
  bool get isScanning => _ble.isScanning;
  List<PublicMessage> get publicMessages => List.unmodifiable(_publicMessages);
  int get relayedPackets => _ble.relayedPackets;

  /// Last security event (for example a tampered message), shown as a banner by the UI.
  String? get securityAlert => _securityAlert;
  int get securityAlertCount => _securityAlertCount;

  List<ChatMessage> get activeMessages {
    final peer = _activePeer;
    return peer == null ? const [] : _history[peer.fingerprint] ?? const [];
  }

  Future<void> init() async {
    _username = _storage.getUsername();
    if (isRegistered) await _start();
    notifyListeners();
  }

  Future<void> registerUser(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    await _storage.setUsername(clean);
    _username = clean;
    await _start();
    notifyListeners();
  }

  Future<void> _start() async {
    await _crypto.init();
    await _ble.init(localUsername: _username!, localPublicKeyBase64: _crypto.publicKeyBase64);

    await _peerSub?.cancel();
    await _envelopeSub?.cancel();
    await _meshSub?.cancel();
    _peerSub = _ble.onPeerDiscovered.listen(_onPeerDiscovered);
    _envelopeSub = _ble.onEnvelopeReceived.listen(_onEnvelope);
    _meshSub = _ble.onMeshPacket.listen((r) => handleMeshPacket(r.packet, hops: r.hops));

    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(announceInterval, (_) => sendAnnounce());
    _staleTimer?.cancel();
    _staleTimer = Timer.periodic(const Duration(seconds: 5), (_) => _expireStalePeers());

    await startDiscovery();
    unawaited(sendAnnounce());
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

  // ---------------------------------------------------------------- peers

  Future<String?> _safetyNumberFor(String publicKey) async {
    if (_safetyNumbers.containsKey(publicKey)) return _safetyNumbers[publicKey];
    return _safetyNumbers[publicKey] = await _crypto.deriveSafetyNumber(publicKey);
  }

  Peer? _peerByKey(String publicKey) {
    for (final p in _peers.values) {
      if (p.publicKey == publicKey) return p;
    }
    return null;
  }

  void _putPeer(Peer peer) {
    _peers[peer.deviceId] = peer;
    final active = _activePeer;
    if (active != null && (active.deviceId == peer.deviceId || active.publicKey == peer.publicKey)) {
      _activePeer = peer;
    }
  }

  Future<void> _onPeerDiscovered(Peer peer) async {
    // Same name, different key: either a new install or someone squatting on the name.
    // Flag both so the user checks the safety number before trusting either.
    var collision = false;
    for (final other in _peers.values.toList()) {
      if (other.publicKey != peer.publicKey &&
          !other.deviceId.startsWith('unpaired-') &&
          other.username.toLowerCase() == peer.username.toLowerCase()) {
        collision = true;
        _putPeer(other.copyWith(hasNameCollision: true));
        debugPrint('[chat] "${peer.username}" seen with two different keys');
      }
    }

    final enriched = peer.copyWith(
      safetyNumber: await _safetyNumberFor(peer.publicKey),
      isVerified: _storage.isPeerVerified(peer.fingerprint),
      hasNameCollision: collision,
    );

    // A direct link replaces the placeholder we made for a message or announce.
    _peers.removeWhere((id, p) =>
        id != peer.deviceId &&
        p.publicKey == peer.publicKey &&
        (id.startsWith('unpaired-') || (id.startsWith('mesh-') && !peer.isMeshOnly)));
    _putPeer(enriched);
    notifyListeners();
    _flushQueueFor(enriched);
  }

  void _expireStalePeers() {
    final now = DateTime.now();
    var changed = false;
    for (final p in _peers.values.toList()) {
      final timeout = p.isMeshOnly ? meshPeerTimeout : directPeerTimeout;
      if (p.isConnected && now.difference(p.lastSeen) > timeout) {
        _putPeer(p.copyWith(isConnected: false));
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> togglePeerVerification(Peer peer, bool verified) async {
    await _storage.setPeerVerified(peer.fingerprint, verified);
    _putPeer(peer.copyWith(isVerified: verified));
    notifyListeners();
  }

  // ------------------------------------------------------------- messages

  List<ChatMessage> _historyFor(String fingerprint) =>
      _history.putIfAbsent(fingerprint, () => _storage.getMessages(fingerprint));

  void selectPeer(Peer? peer) {
    _activePeer = peer;
    if (peer != null) _history[peer.fingerprint] = _storage.getMessages(peer.fingerprint);
    notifyListeners();
  }

  Future<bool> sendMessage(String text) async {
    final peer = _activePeer;
    final body = text.trim();
    if (peer == null || _username == null || body.isEmpty) return false;

    final msg = ChatMessage(
      id: newMessageId(),
      sender: _username!,
      recipient: peer.username,
      body: body,
      sentAt: DateTime.now(),
      isMine: true,
      peerFingerprint: peer.fingerprint,
      status: MessageStatus.sending,
    );
    await _storage.saveMessage(msg);
    final history = _historyFor(peer.fingerprint);
    if (!history.any((m) => m.id == msg.id)) history.add(msg);
    notifyListeners();
    return _transmit(peer, body, msg.id, history);
  }

  /// Retry a failed message. It keeps its id, so if the first copy did arrive the
  /// receiver drops this one and just ACKs again.
  Future<bool> resendMessage(String messageId) async {
    final peer = _activePeer;
    if (peer == null || _username == null) return false;
    final history = _history[peer.fingerprint];
    if (history == null) return false;
    final i = history.indexWhere((m) => m.id == messageId && m.isMine && m.status == MessageStatus.failed);
    if (i < 0) return false;

    history[i] = history[i].copyWith(status: MessageStatus.sending);
    await _storage.updateMessageStatus(messageId, peer.fingerprint, MessageStatus.sending);
    notifyListeners();
    return _transmit(peer, history[i].body, messageId, history);
  }

  Future<bool> _transmit(Peer peer, String text, String messageId, List<ChatMessage> history) async {
    final envelope = await _crypto.encryptMessage(
      plaintext: text,
      senderUsername: _username!,
      recipientPublicKeyBase64: peer.publicKey,
      messageId: messageId,
    );

    final bool ok;
    if (peer.isMeshOnly || peer.deviceId.startsWith('unpaired-')) {
      ok = await _ble.floodEnvelope(envelope);
    } else {
      ok = await _ble.sendEnvelope(peer.deviceId, envelope) || await _ble.floodEnvelope(envelope);
    }

    final MessageStatus status;
    if (_earlyAcks.remove(messageId)) {
      status = MessageStatus.delivered;
    } else {
      status = ok ? MessageStatus.sent : MessageStatus.failed;
    }
    // The message key is kept only while we still wait for an ACK.
    if (status != MessageStatus.sent) _crypto.removePendingKey(messageId);

    await _storage.updateMessageStatus(messageId, peer.fingerprint, status);
    final i = history.indexWhere((m) => m.id == messageId);
    if (i >= 0) {
      history[i] = history[i].copyWith(status: status);
      notifyListeners();
    }
    return ok;
  }

  Future<void> _onEnvelope(ChatEnvelope envelope) async {
    if (envelope.isAck) return _onAck(envelope);
    if (_crypto.isInitialized && envelope.recipientPublicKey != _crypto.publicKeyBase64) return;

    final sender = envelope.senderPublicKey;
    final senderFp = _fp(sender);
    try {
      final decrypted = await _crypto.decryptEnvelopeWithKey(envelope);

      final skew = DateTime.now().millisecondsSinceEpoch - envelope.timestamp;
      if (skew.abs() > maxClockSkew.inMilliseconds) {
        debugPrint('[chat] dropped ${envelope.messageId}: clock skew ${skew}ms');
        return;
      }

      final history = _historyFor(senderFp);
      final knownPeer = _peerByKey(sender);

      // Already have it: don't show it twice, but ACK again since ours may have been lost.
      if (_seenIncomingIds.contains(envelope.messageId) || history.any((m) => m.id == envelope.messageId)) {
        debugPrint('[chat] duplicate ${envelope.messageId}, re-sending ACK');
        await _sendAck(envelope, decrypted.messageKey, knownPeer);
        return;
      }
      _seenIncomingIds.add(envelope.messageId);
      if (_seenIncomingIds.length > 1000) _seenIncomingIds.remove(_seenIncomingIds.first);

      // The name inside the envelope is whatever the sender typed; only trust names we
      // learned together with the key.
      final senderName = knownPeer != null && !knownPeer.deviceId.startsWith('unpaired-')
          ? knownPeer.username
          : 'Unverified ($senderFp)';

      final msg = ChatMessage(
        id: envelope.messageId,
        sender: senderName,
        recipient: _username ?? 'Me',
        body: decrypted.plaintext,
        sentAt: DateTime.fromMillisecondsSinceEpoch(envelope.timestamp),
        isMine: false,
        peerFingerprint: senderFp,
        status: MessageStatus.delivered,
      );
      await _storage.saveMessage(msg);
      history.add(msg);

      if (knownPeer != null) {
        _putPeer(knownPeer.copyWith(lastSeen: DateTime.now(), isConnected: true));
      } else {
        _putPeer(Peer(
          deviceId: 'unpaired-$senderFp',
          username: senderName,
          publicKey: sender,
          lastSeen: DateTime.now(),
          safetyNumber: await _safetyNumberFor(sender),
          isVerified: _storage.isPeerVerified(senderFp),
          isConnected: true,
        ));
      }
      notifyListeners();
      await _sendAck(envelope, decrypted.messageKey, knownPeer);
    } on SecretBoxAuthenticationError {
      // The ciphertext or a header field was changed after it was encrypted.
      _raiseAlert('Message from ${_peerByKey(sender)?.username ?? senderFp} failed the AES-GCM '
          'integrity check (modified in transit). Dropped.');
    } catch (e) {
      debugPrint('[chat] could not decrypt message from $senderFp: $e');
    }
  }

  void _raiseAlert(String text) {
    debugPrint('[chat] $text');
    _securityAlert = text;
    _securityAlertCount++;
    notifyListeners();
  }

  Future<void> _sendAck(ChatEnvelope envelope, SecretKey messageKey, Peer? knownPeer) async {
    final ChatEnvelope ack;
    try {
      ack = await _crypto.createAckEnvelope(
        originalMessageId: envelope.messageId,
        recipientPublicKeyBase64: envelope.senderPublicKey,
        senderUsername: _username ?? 'Me',
        messageKey: messageKey,
      );
    } catch (e) {
      debugPrint('[chat] ACK not created: $e');
      return;
    }

    // Back the way the message came first (that is the relay for a 2-hop message),
    // then the address we scanned the sender at, then flood.
    final targets = <String>{
      if (_ble.getLastKnownDeviceId(envelope.senderPublicKey) case final hop?) hop,
      if (knownPeer != null && !knownPeer.deviceId.startsWith('unpaired-')) knownPeer.deviceId,
    };
    unawaited(() async {
      for (final t in targets) {
        try {
          if (await _ble.sendEnvelope(t, ack)) return;
        } catch (e) {
          debugPrint('[chat] ACK to $t failed: $e');
        }
      }
      try {
        await _ble.floodEnvelope(ack);
      } catch (_) {}
    }());
  }

  Future<void> _onAck(ChatEnvelope ack) async {
    final id = ack.originalMessageId;
    if (id == null) return;
    try {
      if (!await _crypto.verifyAckEnvelope(ack)) {
        debugPrint('[chat] ACK for $id failed authentication');
        return;
      }
    } catch (e) {
      debugPrint('[chat] bad ACK: $e');
      return;
    }

    final fp = _fp(ack.senderPublicKey);
    final history = _historyFor(fp);
    final i = history.indexWhere((m) => m.id == id);
    if (i < 0 || history[i].status == MessageStatus.sending) {
      // Still inside _transmit(); it picks this up when the write returns.
      _earlyAcks.add(id);
      if (_earlyAcks.length > 100) _earlyAcks.remove(_earlyAcks.first);
      return;
    }
    if (history[i].status != MessageStatus.sent) return;

    history[i] = history[i].copyWith(status: MessageStatus.delivered);
    _crypto.removePendingKey(id);
    await _storage.updateMessageStatus(id, fp, MessageStatus.delivered);
    notifyListeners();
  }

  /// Store and forward: when a peer shows up again, resend whatever failed earlier.
  void _flushQueueFor(Peer peer) {
    final last = _lastQueueFlush[peer.publicKey];
    if (last != null && DateTime.now().difference(last) < queueRetryGap) return;
    final history = _historyFor(peer.fingerprint);
    final failed = history.where((m) => m.isMine && m.status == MessageStatus.failed).toList();
    if (failed.isEmpty) return;
    _lastQueueFlush[peer.publicKey] = DateTime.now();
    debugPrint('[chat] ${peer.username} is back, resending ${failed.length}');

    unawaited(() async {
      for (final m in failed) {
        final i = history.indexWhere((x) => x.id == m.id);
        if (i >= 0) history[i] = history[i].copyWith(status: MessageStatus.sending);
        await _storage.updateMessageStatus(m.id, peer.fingerprint, MessageStatus.sending);
        notifyListeners();
        await _transmit(peer, m.body, m.id, history);
      }
    }());
  }

  // ----------------------------------------------------------------- mesh

  Future<void> sendAnnounce() async {
    if (!_crypto.isInitialized || _username == null) return;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final pk = _crypto.publicKeyBase64;
      final spk = _crypto.signingPublicKeyBase64;
      final sig = await _crypto.sign(MeshPacket.announceSigningString(_username!, pk, spk, ts));
      await _ble.broadcastPacket(MeshPacket.create(MeshPacket.kindAnnounce, {
        'u': _username, 'pk': pk, 'spk': spk, 'ts': ts, 'sig': sig,
      }));
    } catch (e) {
      debugPrint('[mesh] announce failed: $e');
    }
  }

  Future<bool> sendPublicMessage(String text) async {
    final body = text.trim();
    if (body.isEmpty || _username == null) return false;
    final id = newMessageId();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final pk = _crypto.publicKeyBase64;
    final spk = _crypto.signingPublicKeyBase64;
    final sig = await _crypto.sign(MeshPacket.publicSigningString(id, _username!, pk, spk, ts, body));

    _seenPublicIds.add(id);
    _addPublic(PublicMessage(
      id: id, senderName: _username!, senderPublicKey: pk, text: body,
      sentAt: DateTime.fromMillisecondsSinceEpoch(ts), isMine: true,
    ));
    notifyListeners();
    return _ble.broadcastPacket(MeshPacket.create(MeshPacket.kindPublic, {
      'id': id, 'u': _username, 'pk': pk, 'spk': spk, 'ts': ts, 'text': body, 'sig': sig,
    }));
  }

  void _addPublic(PublicMessage m) {
    _publicMessages.add(m);
    if (_publicMessages.length > 500) _publicMessages.removeAt(0);
  }

  /// Valid signature, and the signing key is the one we pinned for this identity. Without
  /// the second check anyone could re-announce a known X25519 key under their own Ed25519 key.
  Future<bool> _verifySigned(String pk, String spk, String sig, String signed) async {
    if (!await CryptoService.verifySignature(signed, sig, spk)) {
      debugPrint('[mesh] bad signature from ${_fp(pk)}');
      return false;
    }
    final pinned = _signingKeys.putIfAbsent(pk, () => spk);
    if (pinned != spk) {
      debugPrint('[mesh] ${_fp(pk)} came with a different signing key, dropped');
      return false;
    }
    return true;
  }

  @visibleForTesting
  Future<void> handleMeshPacket(MeshPacket packet, {int hops = 1}) async {
    final b = packet.body;
    final u = b['u'] as String? ?? '';
    final pk = b['pk'] as String? ?? '';
    final spk = b['spk'] as String? ?? '';
    final sig = b['sig'] as String? ?? '';
    final ts = b['ts'] is int ? b['ts'] as int : 0;
    if (pk.isEmpty || spk.isEmpty || sig.isEmpty) return;
    if (_crypto.isInitialized && pk == _crypto.publicKeyBase64) return;
    if ((DateTime.now().millisecondsSinceEpoch - ts).abs() > maxClockSkew.inMilliseconds) return;

    switch (packet.kind) {
      case MeshPacket.kindAnnounce:
        if (!await _verifySigned(pk, spk, sig, MeshPacket.announceSigningString(u, pk, spk, ts))) return;
        await _onAnnounce(u, pk, hops);
      case MeshPacket.kindPublic:
        final id = b['id'] as String? ?? '';
        final text = b['text'] as String? ?? '';
        if (id.isEmpty || text.isEmpty || _seenPublicIds.contains(id)) return;
        if (!await _verifySigned(pk, spk, sig, MeshPacket.publicSigningString(id, u, pk, spk, ts, text))) return;
        _seenPublicIds.add(id);
        _addPublic(PublicMessage(
          id: id, senderName: u.isEmpty ? 'Nearby User' : u, senderPublicKey: pk, text: text,
          sentAt: DateTime.fromMillisecondsSinceEpoch(ts), isMine: false, hops: hops,
        ));
        notifyListeners();
    }
  }

  Future<void> _onAnnounce(String name, String pk, int hops) async {
    final now = DateTime.now();
    final direct = _peers.values
        .where((p) => p.publicKey == pk && !p.isMeshOnly && !p.deviceId.startsWith('unpaired-'))
        .firstOrNull;
    if (direct != null) {
      _putPeer(direct.copyWith(lastSeen: now, isConnected: true));
      notifyListeners();
      return;
    }

    final fp = _fp(pk);
    final id = 'mesh-$fp';
    final peer = (_peers[id] ??
            Peer(
              deviceId: id,
              username: name.isEmpty ? 'Nearby User' : name,
              publicKey: pk,
              lastSeen: now,
              safetyNumber: await _safetyNumberFor(pk),
              isVerified: _storage.isPeerVerified(fp),
            ))
        .copyWith(username: name.isEmpty ? null : name, lastSeen: now, isConnected: true, hops: hops);
    _peers.removeWhere((key, p) => key.startsWith('unpaired-') && p.publicKey == pk);
    _putPeer(peer);
    notifyListeners();
    _flushQueueFor(peer);
  }

  @override
  void dispose() {
    _ble.stopScanning().catchError((Object e) => debugPrint('[chat] stopScanning: $e'));
    _ble.stopAdvertising().catchError((Object e) => debugPrint('[chat] stopAdvertising: $e'));
    _peerSub?.cancel();
    _envelopeSub?.cancel();
    _meshSub?.cancel();
    _staleTimer?.cancel();
    _announceTimer?.cancel();
    _ble.dispose();
    super.dispose();
  }
}
