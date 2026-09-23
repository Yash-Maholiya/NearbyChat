class Peer {
  final String deviceId;
  final String username;
  final String publicKey;
  final int? rssi;
  final DateTime lastSeen;
  final String? safetyNumber;
  final bool isVerified;
  final bool isConnected;
  final bool hasNameCollision;

  const Peer({
    required this.deviceId,
    required this.username,
    required this.publicKey,
    this.rssi,
    required this.lastSeen,
    this.safetyNumber,
    this.isVerified = false,
    this.isConnected = false,
    this.hasNameCollision = false,
  });

  /// Short cryptographic identifier derived from the public key.
  String get fingerprint {
    if (publicKey.length <= 12) return publicKey;
    return publicKey.substring(0, 12);
  }

  Peer copyWith({
    String? deviceId,
    String? username,
    String? publicKey,
    int? rssi,
    bool clearRssi = false,
    DateTime? lastSeen,
    String? safetyNumber,
    bool clearSafetyNumber = false,
    bool? isVerified,
    bool? isConnected,
    bool? hasNameCollision,
  }) {
    return Peer(
      deviceId: deviceId ?? this.deviceId,
      username: username ?? this.username,
      publicKey: publicKey ?? this.publicKey,
      rssi: clearRssi ? null : (rssi ?? this.rssi),
      lastSeen: lastSeen ?? this.lastSeen,
      safetyNumber: clearSafetyNumber ? null : (safetyNumber ?? this.safetyNumber),
      isVerified: isVerified ?? this.isVerified,
      isConnected: isConnected ?? this.isConnected,
      hasNameCollision: hasNameCollision ?? this.hasNameCollision,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'username': username,
      'publicKey': publicKey,
      'rssi': rssi,
      'lastSeen': lastSeen.toIso8601String(),
      'safetyNumber': safetyNumber,
      'isVerified': isVerified,
      'isConnected': isConnected,
      'hasNameCollision': hasNameCollision,
    };
  }

  factory Peer.fromJson(Map<String, dynamic> json) {
    return Peer(
      deviceId: json['deviceId'] as String,
      username: json['username'] as String,
      publicKey: json['publicKey'] as String,
      rssi: json['rssi'] as int?,
      lastSeen: DateTime.parse(json['lastSeen'] as String),
      safetyNumber: json['safetyNumber'] as String?,
      isVerified: json['isVerified'] as bool? ?? false,
      isConnected: json['isConnected'] as bool? ?? false,
      hasNameCollision: json['hasNameCollision'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Peer &&
          runtimeType == other.runtimeType &&
          publicKey == other.publicKey;

  @override
  int get hashCode => publicKey.hashCode;
}
