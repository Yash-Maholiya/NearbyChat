import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';

class StorageService {
  static const String _usernameKey = 'nearbychat.profile.username';
  static const String _verifiedPeersKey = 'nearbychat.verified_peers';
  static const String _historyPrefix = 'nearbychat.history.';
  static const int maxHistoryPerPeer = 500;

  final SharedPreferences _prefs;

  /// Write-through cache to avoid repeated JSON deserialization.
  final Map<String, List<ChatMessage>> _cache = {};

  StorageService(this._prefs);

  static Future<StorageService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return StorageService(prefs);
  }

  // --- Profile Management ---

  String? getUsername() {
    return _prefs.getString(_usernameKey);
  }

  Future<void> setUsername(String username) async {
    await _prefs.setString(_usernameKey, username.trim());
  }

  // --- Verified Peers Management ---

  Set<String> getVerifiedPeers() {
    final list = _prefs.getStringList(_verifiedPeersKey) ?? [];
    return list.toSet();
  }

  bool isPeerVerified(String peerFingerprint) {
    return getVerifiedPeers().contains(peerFingerprint);
  }

  Future<void> setPeerVerified(String peerFingerprint, bool verified) async {
    final peers = getVerifiedPeers();
    if (verified) {
      peers.add(peerFingerprint);
    } else {
      peers.remove(peerFingerprint);
    }
    await _prefs.setStringList(_verifiedPeersKey, peers.toList());
  }

  // --- Message History Management ---

  String _getHistoryKey(String peerFingerprint) => '$_historyPrefix$peerFingerprint';

  List<ChatMessage> getMessages(String peerFingerprint) {
    // Return from cache if available
    if (_cache.containsKey(peerFingerprint)) {
      final cached = List<ChatMessage>.from(_cache[peerFingerprint]!)
        ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      return cached;
    }

    final key = _getHistoryKey(peerFingerprint);
    final rawJson = _prefs.getString(key);
    if (rawJson == null || rawJson.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> decoded = jsonDecode(rawJson) as List<dynamic>;
      final messages = decoded
          .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      _cache[peerFingerprint] = messages;
      return List<ChatMessage>.from(messages);
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessage(ChatMessage message) async {
    final messages = getMessages(message.peerFingerprint);

    // Update if already exists, else append
    final index = messages.indexWhere((m) => m.id == message.id);
    if (index >= 0) {
      messages[index] = message;
    } else {
      messages.add(message);
    }

    // Enforce rolling 500-message window
    List<ChatMessage> trimmed = messages;
    if (trimmed.length > maxHistoryPerPeer) {
      trimmed = trimmed.sublist(trimmed.length - maxHistoryPerPeer);
    }

    // Update cache
    _cache[message.peerFingerprint] = trimmed;

    final key = _getHistoryKey(message.peerFingerprint);
    final rawJson = jsonEncode(trimmed.map((m) => m.toJson()).toList());
    await _prefs.setString(key, rawJson);
  }

  Future<void> updateMessageStatus(
    String messageId,
    String peerFingerprint,
    MessageStatus status,
  ) async {
    final messages = getMessages(peerFingerprint);
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index >= 0) {
      messages[index] = messages[index].copyWith(status: status);

      // Update cache
      _cache[peerFingerprint] = messages;

      final key = _getHistoryKey(peerFingerprint);
      final rawJson = jsonEncode(messages.map((m) => m.toJson()).toList());
      await _prefs.setString(key, rawJson);
    }
  }

  Future<void> clearHistory(String peerFingerprint) async {
    _cache.remove(peerFingerprint);
    final key = _getHistoryKey(peerFingerprint);
    await _prefs.remove(key);
  }
}
