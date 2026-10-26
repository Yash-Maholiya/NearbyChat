import 'dart:convert';
import 'dart:typed_data';

class ChatEnvelope {
  final int version;
  final String messageId;
  final String senderUsername;
  final String senderPublicKey;
  final String recipientPublicKey;
  final String ephemeralPublicKey;
  final int timestamp;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;
  final bool isAck;
  final String? originalMessageId;

  const ChatEnvelope({
    this.version = 2,
    required this.messageId,
    required this.senderUsername,
    required this.senderPublicKey,
    required this.recipientPublicKey,
    this.ephemeralPublicKey = '',
    required this.timestamp,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
    this.isAck = false,
    this.originalMessageId,
  });

  ChatEnvelope copyWith({Uint8List? nonce, Uint8List? ciphertext, Uint8List? mac}) => ChatEnvelope(
        version: version,
        messageId: messageId,
        senderUsername: senderUsername,
        senderPublicKey: senderPublicKey,
        recipientPublicKey: recipientPublicKey,
        ephemeralPublicKey: ephemeralPublicKey,
        timestamp: timestamp,
        nonce: nonce ?? this.nonce,
        ciphertext: ciphertext ?? this.ciphertext,
        mac: mac ?? this.mac,
        isAck: isAck,
        originalMessageId: originalMessageId,
      );

  /// Every header field goes into the AES-GCM AAD, so a relay that edits any of them
  /// (sender name, timestamp, ACK flag...) makes decryption fail.
  Uint8List get aad => utf8.encode('$version:$messageId:$senderUsername:$senderPublicKey:$recipientPublicKey:'
      '$ephemeralPublicKey:$timestamp:${isAck ? 1 : 0}:${originalMessageId ?? ''}');

  Map<String, dynamic> toJson() {
    return {
      'v': version,
      'id': messageId,
      'u': senderUsername,
      'spk': senderPublicKey,
      'rpk': recipientPublicKey,
      'epk': ephemeralPublicKey,
      't': timestamp,
      'n': base64Encode(nonce),
      'c': base64Encode(ciphertext),
      'm': base64Encode(mac),
      'ack': isAck,
      if (originalMessageId != null) 'origId': originalMessageId,
    };
  }

  factory ChatEnvelope.fromJson(Map<String, dynamic> json) {
    return ChatEnvelope(
      version: json['v'] as int? ?? 2,
      messageId: json['id'] as String,
      senderUsername: json['u'] as String,
      senderPublicKey: json['spk'] as String,
      recipientPublicKey: json['rpk'] as String,
      ephemeralPublicKey: json['epk'] as String? ?? '',
      timestamp: json['t'] as int,
      nonce: json['n'] != null ? base64Decode(json['n'] as String) : Uint8List(0),
      ciphertext: json['c'] != null ? base64Decode(json['c'] as String) : Uint8List(0),
      mac: json['m'] != null ? base64Decode(json['m'] as String) : Uint8List(0),
      isAck: json['ack'] as bool? ?? false,
      originalMessageId: json['origId'] as String?,
    );
  }

  Uint8List toBinary() => utf8.encode(jsonEncode(toJson()));

  factory ChatEnvelope.fromBinary(Uint8List bytes) =>
      ChatEnvelope.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
}
