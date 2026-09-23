import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';

class StorageService {
  static const String _usernameKey = 'nearbychat.profile.username';
  static const String _verifiedPeersKey = 'nearbychat.verified_peers';
  static const String _historyPrefix = 'nearbychat.history.';
  static const String _storageEncryptionKeyName = 'nearbychat.storage.db_key';
  static const int maxHistoryPerPeer = 500;

  final SharedPreferences _prefs;
  final SecretKey _storageKey;
  final AesGcm _aesGcm = AesGcm.with256bits();

  /// Write-through in-memory cache of decrypted messages.
  final Map<String, List<ChatMessage>> _cache = {};

  StorageService(this._prefs, this._storageKey);

  /// Initializes StorageService, loads or creates database encryption key,
  /// and transparently decrypts and migrates existing message histories.
  static Future<StorageService> create({
    SharedPreferences? prefs,
    FlutterSecureStorage? secureStorage,
    SecretKey? storageKey,
  }) async {
    final preferences = prefs ?? await SharedPreferences.getInstance();
    final secStorage = secureStorage ?? const FlutterSecureStorage();

    SecretKey key;
    if (storageKey != null) {
      key = storageKey;
    } else {
      key = await _getOrCreateStorageKey(secStorage);
    }

    final service = StorageService(preferences, key);
    await service._preloadAndMigrate();
    return service;
  }

  static Future<SecretKey> _getOrCreateStorageKey(FlutterSecureStorage secureStorage) async {
    try {
      final existingB64 = await secureStorage.read(key: _storageEncryptionKeyName);
      if (existingB64 != null && existingB64.isNotEmpty) {
        return SecretKey(base64Decode(existingB64));
      }
      final newKey = await AesGcm.with256bits().newSecretKey();
      final keyBytes = await newKey.extractBytes();
      await secureStorage.write(
        key: _storageEncryptionKeyName,
        value: base64Encode(keyBytes),
      );
      return newKey;
    } catch (e) {
      debugPrint('[StorageService] Critical error accessing SecureStorage: $e');
      throw StateError(
        'Failed to securely retrieve or persist encryption key: $e. '
        'Refusing to initialize with a temporary unpersisted key to prevent permanent message history loss.',
      );
    }
  }

  /// Scans all saved histories, transparently migrates plaintext -> encrypted,
  /// and preloads decrypted messages into memory.
  Future<void> _preloadAndMigrate() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith(_historyPrefix));
    for (final key in keys) {
      final peerFingerprint = key.substring(_historyPrefix.length);
      final raw = _prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;

      try {
        if (raw.trimLeft().startsWith('[')) {
          // Legacy plaintext JSON array -> migrate to encrypted
          final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
          final messages = decoded
              .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
          _cache[peerFingerprint] = messages;

          // Re-save in encrypted format
          await _writeEncryptedHistory(peerFingerprint, messages);
          debugPrint('[StorageService] Migrated plaintext history to encrypted for $peerFingerprint');
        } else {
          // Encrypted JSON envelope: { "n": base64, "c": base64, "m": base64 }
          final Map<String, dynamic> env = jsonDecode(raw);
          final nonce = base64Decode(env['n'] as String);
          final ciphertext = base64Decode(env['c'] as String);
          final mac = base64Decode(env['m'] as String);

          final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
          final clearBytes = await _aesGcm.decrypt(secretBox, secretKey: _storageKey);
          final clearJson = utf8.decode(clearBytes);

          final List<dynamic> decoded = jsonDecode(clearJson) as List<dynamic>;
          final messages = decoded
              .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
          _cache[peerFingerprint] = messages;
        }
      } catch (e) {
        debugPrint('[StorageService] Error loading/decrypting history for $peerFingerprint: $e');
        _cache[peerFingerprint] = [];
      }
    }
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

  /// Synchronously returns messages from memory cache.
  List<ChatMessage> getMessages(String peerFingerprint) {
    if (_cache.containsKey(peerFingerprint)) {
      final cached = List<ChatMessage>.from(_cache[peerFingerprint]!)
        ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      return cached;
    }
    return [];
  }

  /// Encrypts and writes history list for a peer using AES-GCM-256 with a unique nonce.
  Future<void> _writeEncryptedHistory(String peerFingerprint, List<ChatMessage> messages) async {
    final rawJson = jsonEncode(messages.map((m) => m.toJson()).toList());
    final clearBytes = utf8.encode(rawJson);
    final nonce = _aesGcm.newNonce();

    final secretBox = await _aesGcm.encrypt(
      clearBytes,
      secretKey: _storageKey,
      nonce: nonce,
    );

    final payload = jsonEncode({
      'n': base64Encode(secretBox.nonce),
      'c': base64Encode(secretBox.cipherText),
      'm': base64Encode(secretBox.mac.bytes),
    });

    final key = _getHistoryKey(peerFingerprint);
    await _prefs.setString(key, payload);
  }

  Future<void> saveMessage(ChatMessage message) async {
    final messages = getMessages(message.peerFingerprint);

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

    // Encrypt and persist
    await _writeEncryptedHistory(message.peerFingerprint, trimmed);
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
      _cache[peerFingerprint] = messages;
      await _writeEncryptedHistory(peerFingerprint, messages);
    }
  }

  Future<void> clearHistory(String peerFingerprint) async {
    _cache.remove(peerFingerprint);
    final key = _getHistoryKey(peerFingerprint);
    await _prefs.remove(key);
  }
}
