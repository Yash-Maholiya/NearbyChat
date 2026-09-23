enum MessageStatus {
  sending,
  sent,
  delivered,
  failed,
}

class ChatMessage {
  final String id;
  final String sender;
  final String recipient;
  final String body;
  final DateTime sentAt;
  final bool isMine;
  final String peerFingerprint;
  final MessageStatus status;

  const ChatMessage({
    required this.id,
    required this.sender,
    required this.recipient,
    required this.body,
    required this.sentAt,
    required this.isMine,
    required this.peerFingerprint,
    this.status = MessageStatus.delivered,
  });

  ChatMessage copyWith({
    String? id,
    String? sender,
    String? recipient,
    String? body,
    DateTime? sentAt,
    bool? isMine,
    String? peerFingerprint,
    MessageStatus? status,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      sender: sender ?? this.sender,
      recipient: recipient ?? this.recipient,
      body: body ?? this.body,
      sentAt: sentAt ?? this.sentAt,
      isMine: isMine ?? this.isMine,
      peerFingerprint: peerFingerprint ?? this.peerFingerprint,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender': sender,
      'recipient': recipient,
      'body': body,
      'sentAt': sentAt.toIso8601String(),
      'isMine': isMine,
      'peerFingerprint': peerFingerprint,
      'status': status.name,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      sender: json['sender'] as String,
      recipient: json['recipient'] as String,
      body: json['body'] as String,
      sentAt: DateTime.parse(json['sentAt'] as String),
      isMine: json['isMine'] as bool,
      peerFingerprint: json['peerFingerprint'] as String,
      status: MessageStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => MessageStatus.delivered,
      ),
    );
  }
}
