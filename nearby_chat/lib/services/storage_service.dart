import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';

/// Profile, verified peers and chat history. History is stored AES-GCM encrypted in
/// shared_preferences; the key lives in the platform keystore (flutter_secure_storage).
/// Everything is decrypted once at startup and served from memory after that.
class StorageService {
  StorageService(this._prefs, this._key);

  static const _usernameKey = 'nearbychat.profile.username';
  static const _verifiedKey = 'nearbychat.verified_peers';
  static const _historyPrefix = 'nearbychat.history.';
  static const _dbKeyName = 'nearbychat.storage.db_key';
  static const int maxHistoryPerPeer = 500;

  final SharedPreferences _prefs;
  final SecretKey _key;
  final _aes = AesGcm.with256bits();

  // Each list is kept sorted by sentAt.
  final Map<String, List<ChatMessage>> _cache = {};
  Set<String>? _verified;

  static Future<StorageService> create({
    SharedPreferences? prefs,
    FlutterSecureStorage? secureStorage,
    SecretKey? storageKey,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final key = storageKey ?? await _loadOrCreateKey(secureStorage ?? const FlutterSecureStorage());
    final s = StorageService(p, key);
    await s._loadAll();
    return s;
  }

  static Future<SecretKey> _loadOrCreateKey(FlutterSecureStorage secure) async {
    try {
      final existing = await secure.read(key: _dbKeyName);
      if (existing != null && existing.isNotEmpty) return SecretKey(base64Decode(existing));
      final key = await AesGcm.with256bits().newSecretKey();
      await secure.write(key: _dbKeyName, value: base64Encode(await key.extractBytes()));
      return key;
    } catch (e) {
      // A throwaway key would make the saved history unreadable on the next start,
      // so refuse to run instead.
      throw StateError('Cannot read or store the history key: $e');
    }
  }

  Future<void> _loadAll() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith(_historyPrefix)).toList()) {
      final fp = k.substring(_historyPrefix.length);
      final raw = _prefs.getString(k);
      if (raw == null || raw.isEmpty) continue;
      try {
        if (raw.trimLeft().startsWith('[')) {
          // Older builds saved plain JSON.
          _cache[fp] = _decodeList(raw);
          await _persist(fp);
          debugPrint('[StorageService] Migrated plaintext history to encrypted for $fp');
        } else {
          final env = jsonDecode(raw) as Map<String, dynamic>;
          final box = SecretBox(
            base64Decode(env['c'] as String),
            nonce: base64Decode(env['n'] as String),
            mac: Mac(base64Decode(env['m'] as String)),
          );
          _cache[fp] = _decodeList(utf8.decode(await _aes.decrypt(box, secretKey: _key)));
        }
      } catch (e) {
        debugPrint('[StorageService] history for $fp unreadable: $e');
        _cache[fp] = [];
      }
    }
  }

  static List<ChatMessage> _decodeList(String json) =>
      (jsonDecode(json) as List).map((m) => ChatMessage.fromJson(m as Map<String, dynamic>)).toList()
        ..sort((a, b) => a.sentAt.compareTo(b.sentAt));

  Future<void> _persist(String fp) async {
    final clear = utf8.encode(jsonEncode(_cache[fp]!.map((m) => m.toJson()).toList()));
    final box = await _aes.encrypt(clear, secretKey: _key, nonce: _aes.newNonce());
    await _prefs.setString(
      '$_historyPrefix$fp',
      jsonEncode({
        'n': base64Encode(box.nonce),
        'c': base64Encode(box.cipherText),
        'm': base64Encode(box.mac.bytes),
      }),
    );
  }

  // ------------------------------------------------------------- profile

  String? getUsername() => _prefs.getString(_usernameKey);

  Future<void> setUsername(String username) => _prefs.setString(_usernameKey, username.trim());

  Set<String> get _verifiedSet => _verified ??= (_prefs.getStringList(_verifiedKey) ?? []).toSet();

  Set<String> getVerifiedPeers() => {..._verifiedSet};

  bool isPeerVerified(String fp) => _verifiedSet.contains(fp);

  Future<void> setPeerVerified(String fp, bool verified) async {
    final set = _verifiedSet;
    if (verified) {
      set.add(fp);
    } else {
      set.remove(fp);
    }
    await _prefs.setStringList(_verifiedKey, set.toList());
  }

  // ------------------------------------------------------------- history

  /// A copy, oldest first. Callers may change it freely.
  List<ChatMessage> getMessages(String fp) => List.of(_cache[fp] ?? const []);

  Future<void> saveMessage(ChatMessage message) async {
    final fp = message.peerFingerprint;
    final list = _cache.putIfAbsent(fp, () => []);
    final i = list.indexWhere((m) => m.id == message.id);
    if (i >= 0) {
      list[i] = message;
    } else if (list.isEmpty || !message.sentAt.isBefore(list.last.sentAt)) {
      list.add(message);
    } else {
      final at = list.indexWhere((m) => m.sentAt.isAfter(message.sentAt));
      list.insert(at, message);
    }
    if (list.length > maxHistoryPerPeer) list.removeRange(0, list.length - maxHistoryPerPeer);
    await _persist(fp);
  }

  Future<void> updateMessageStatus(String messageId, String fp, MessageStatus status) async {
    final list = _cache[fp];
    final i = list?.indexWhere((m) => m.id == messageId) ?? -1;
    if (i < 0) return;
    list![i] = list[i].copyWith(status: status);
    await _persist(fp);
  }

  Future<void> clearHistory(String fp) async {
    _cache.remove(fp);
    await _prefs.remove('$_historyPrefix$fp');
  }
}
