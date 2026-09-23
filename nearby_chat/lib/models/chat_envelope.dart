import 'dart:convert';
import 'dart:typed_data';

class ChatEnvelope {
  final int version;
  final String messageId;
  final String senderUsername;
  final String senderPublicKey;
  final String recipientPublicKey;
  final int timestamp;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;

  const ChatEnvelope({
    this.version = 1,
    required this.messageId,
    required this.senderUsername,
    required this.senderPublicKey,
    required this.recipientPublicKey,
    required this.timestamp,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  /// Canonical Additional Authenticated Data (AAD) for AES-GCM.
  /// Binds header metadata to the ciphertext so tampering is rejected.
  Uint8List get aad {
    final aadString = '$version:$messageId:$senderPublicKey:$recipientPublicKey:$timestamp';
    return Uint8List.fromList(utf8.encode(aadString));
  }

  Map<String, dynamic> toJson() {
    return {
      'v': version,
      'id': messageId,
      'u': senderUsername,
      'spk': senderPublicKey,
      'rpk': recipientPublicKey,
      't': timestamp,
      'n': base64Encode(nonce),
      'c': base64Encode(ciphertext),
      'm': base64Encode(mac),
    };
  }

  factory ChatEnvelope.fromJson(Map<String, dynamic> json) {
    return ChatEnvelope(
      version: json['v'] as int? ?? 1,
      messageId: json['id'] as String,
      senderUsername: json['u'] as String,
      senderPublicKey: json['spk'] as String,
      recipientPublicKey: json['rpk'] as String,
      timestamp: json['t'] as int,
      nonce: base64Decode(json['n'] as String),
      ciphertext: base64Decode(json['c'] as String),
      mac: base64Decode(json['m'] as String),
    );
  }

  Uint8List toBinary() {
    return Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
  }

  factory ChatEnvelope.fromBinary(Uint8List bytes) {
    final jsonStr = utf8.decode(bytes);
    return ChatEnvelope.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
  }
}
