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
  /// Reached over a connection the peer opened to us (it has no GATT server of its own).
  final bool isReverseLink;
  /// 0 = direct BLE neighbour, n = learned from a signed announce that crossed n devices.
  final int hops;

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
    this.isReverseLink = false,
    this.hops = 0,
  });

  /// Known only from relayed announces, no direct BLE link right now.
  bool get isMeshOnly => deviceId.startsWith('mesh-');

  /// First 12 base64 chars of the X25519 key; used as the storage key for this peer.
  String get fingerprint => publicKey.length > 12 ? publicKey.substring(0, 12) : publicKey;

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
    bool? isReverseLink,
    int? hops,
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
      isReverseLink: isReverseLink ?? this.isReverseLink,
      hops: hops ?? this.hops,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Peer && publicKey == other.publicKey;

  @override
  int get hashCode => publicKey.hashCode;
}
