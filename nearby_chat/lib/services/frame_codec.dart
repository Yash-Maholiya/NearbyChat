import 'dart:typed_data';

/// Splits a packet into BLE-sized frames and puts it back together.
///
/// Header, 10 bytes big endian: hash u32 | index u16 | total u16 | payload length u16.
/// The hash only groups frames of one packet; it is not a checksum.
class FrameCodec {
  static const int headerSize = 10;
  static const int defaultMaxFrameSize = 180;
  static const int minAttMtu = 23;
  static const int maxFrameSize = 512; // largest ATT attribute value

  static int _counter = 0;

  /// One ATT write carries MTU - 3 bytes. At the default MTU of 23 that leaves 10 bytes
  /// of payload per frame, slow but it still works.
  static int frameSizeForMtu(int mtu) => (mtu - 3).clamp(minAttMtu - 3, maxFrameSize);

  static List<Uint8List> fragment(Uint8List data, {int? messageIdHash, int maxFrameSize = defaultMaxFrameSize}) {
    final chunk = maxFrameSize - headerSize;
    if (chunk <= 0) throw ArgumentError('maxFrameSize must be larger than $headerSize');
    final hash = messageIdHash ?? (_counter = (_counter + 1) & 0xFFFFFFFF);
    final total = data.isEmpty ? 1 : (data.length + chunk - 1) ~/ chunk;

    return List.generate(total, (i) {
      final start = i * chunk;
      final end = (start + chunk).clamp(0, data.length);
      final frame = Uint8List(headerSize + end - start);
      ByteData.sublistView(frame)
        ..setUint32(0, hash)
        ..setUint16(4, i)
        ..setUint16(6, total)
        ..setUint16(8, end - start);
      frame.setRange(headerSize, frame.length, data, start);
      return frame;
    });
  }
}

class _Partial {
  _Partial(this.total) : parts = List.filled(total, null);
  final int total;
  final List<Uint8List?> parts;
  int received = 0;
  final DateTime started = DateTime.now();
}

/// Buffers are keyed by (sender, hash) so two devices can't corrupt each other's
/// packets, and both the number of buffers and frames per packet are capped.
class FrameReassembler {
  FrameReassembler({this.timeout = const Duration(seconds: 30)});

  static const int maxActiveBuffers = 100;
  static const int maxFramesPerMessage = 500;

  final Duration timeout;
  final Map<String, _Partial> _buffers = {};
  DateTime _lastPrune = DateTime.now();

  /// Returns the whole packet once its last frame arrives, otherwise null.
  Uint8List? processFrame(Uint8List frame, {String senderId = 'default'}) {
    final now = DateTime.now();
    if (now.difference(_lastPrune) >= const Duration(seconds: 5)) {
      _buffers.removeWhere((_, b) => now.difference(b.started) > timeout);
      _lastPrune = now;
    }
    if (frame.length < FrameCodec.headerSize) return null;

    final h = ByteData.sublistView(frame);
    final hash = h.getUint32(0);
    final index = h.getUint16(4);
    final total = h.getUint16(6);
    final len = h.getUint16(8);
    if (total == 0 || total > maxFramesPerMessage || index >= total) return null;
    if (frame.length < FrameCodec.headerSize + len) return null;
    final payload = frame.sublist(FrameCodec.headerSize, FrameCodec.headerSize + len);

    final key = '$senderId:$hash';
    var buf = _buffers[key];
    if (buf == null) {
      if (_buffers.length >= maxActiveBuffers) _buffers.remove(_buffers.keys.first);
      buf = _buffers[key] = _Partial(total);
    } else if (buf.total != total) {
      _buffers.remove(key);
      return null;
    }

    if (buf.parts[index] == null) buf.received++;
    buf.parts[index] = payload;
    if (buf.received < total) return null;

    _buffers.remove(key);
    final out = BytesBuilder(copy: false);
    for (final p in buf.parts) {
      out.add(p!);
    }
    return out.takeBytes();
  }

  void reset() => _buffers.clear();
}
