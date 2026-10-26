import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Bitchat style mesh packet. Every device floods packets it is not the final recipient of,
/// decrementing [ttl], and drops packet ids it has already seen.
///
/// Wire format (JSON, then fragmented into BLE frames by FrameCodec):
/// `{"mesh":1, "pid":"(random packet id)", "ttl":7, "kind":"env"|"ann"|"pub", ...body}`
///
///   env  `{"env": (ChatEnvelope JSON)}`        private message or ACK, end to end encrypted
///   ann  {"u","pk","spk","ts","sig"}            signed announce: name, X25519 key, Ed25519 key
///   pub  {"id","u","pk","spk","ts","text","sig"} signed public room (#nearby) message
///
/// The pid and ttl are not authenticated (relays must change ttl). Everything that matters is:
/// env by AES-GCM (AAD), ann and pub by an Ed25519 signature over [announceSigningString] /
/// [publicSigningString].
class MeshPacket {
  static const int defaultTtl = 7;
  static const String kindEnvelope = 'env';
  static const String kindAnnounce = 'ann';
  static const String kindPublic = 'pub';

  final String pid;
  final int ttl;
  final String kind;
  final Map<String, dynamic> body;

  MeshPacket({required this.pid, required this.ttl, required this.kind, required this.body});

  factory MeshPacket.create(String kind, Map<String, dynamic> body, {int ttl = defaultTtl}) =>
      MeshPacket(pid: newPacketId(), ttl: ttl, kind: kind, body: body);

  static final Random _rng = Random.secure();

  static String newPacketId() {
    final b = List<int>.generate(8, (_) => _rng.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  MeshPacket withTtl(int newTtl) => MeshPacket(pid: pid, ttl: newTtl, kind: kind, body: body);

  Map<String, dynamic> toJson() => {'mesh': 1, 'pid': pid, 'ttl': ttl, 'kind': kind, ...body};

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Returns null if [json] is not a mesh packet.
  static MeshPacket? fromJson(Map<String, dynamic> json) {
    if (json['mesh'] != 1) return null;
    final pid = json['pid'];
    final kind = json['kind'];
    if (pid is! String || kind is! String) return null;
    final body = Map<String, dynamic>.from(json)
      ..remove('mesh')
      ..remove('pid')
      ..remove('ttl')
      ..remove('kind');
    final ttl = json['ttl'] is int ? json['ttl'] as int : 0;
    return MeshPacket(pid: pid, ttl: ttl, kind: kind, body: body);
  }

  static String announceSigningString(String username, String pk, String spk, int ts) =>
      'nearbychat-ann-v1|$username|$pk|$spk|$ts';

  static String publicSigningString(String id, String username, String pk, String spk, int ts, String text) =>
      'nearbychat-pub-v1|$id|$username|$pk|$spk|$ts|$text';
}

/// A message in the public #nearby room.
class PublicMessage {
  final String id;
  final String senderName;
  final String senderPublicKey;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final int hops;

  const PublicMessage({
    required this.id,
    required this.senderName,
    required this.senderPublicKey,
    required this.text,
    required this.sentAt,
    required this.isMine,
    this.hops = 0,
  });

  String get senderFingerprint =>
      senderPublicKey.length > 12 ? senderPublicKey.substring(0, 12) : senderPublicKey;
}
