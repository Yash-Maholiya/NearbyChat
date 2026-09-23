import 'dart:typed_data';

class FrameCodec {
  static const int headerSize = 10;
  static const int defaultMaxFrameSize = 180; // Safe for negotiated BLE MTUs
  static int _hashCounter = 0;

  /// Slices serialized binary data into MTU-sized frames.
  static List<Uint8List> fragment(
    Uint8List data, {
    int? messageIdHash,
    int maxFrameSize = defaultMaxFrameSize,
  }) {
    if (data.isEmpty) return [];

    final hash = messageIdHash ?? (_hashCounter = (_hashCounter + 1) & 0xFFFFFFFF);
    final payloadChunkSize = maxFrameSize - headerSize;
    if (payloadChunkSize <= 0) {
      throw ArgumentError('maxFrameSize must be greater than headerSize ($headerSize)');
    }

    final totalFrames = (data.length + payloadChunkSize - 1) ~/ payloadChunkSize;
    final List<Uint8List> frames = [];

    for (int i = 0; i < totalFrames; i++) {
      final start = i * payloadChunkSize;
      final end = (start + payloadChunkSize < data.length) ? start + payloadChunkSize : data.length;
      final chunk = data.sublist(start, end);

      final frame = Uint8List(headerSize + chunk.length);
      final byteData = ByteData.sublistView(frame);

      byteData.setUint32(0, hash);
      byteData.setUint16(4, i);
      byteData.setUint16(6, totalFrames);
      byteData.setUint16(8, chunk.length);

      frame.setRange(headerSize, headerSize + chunk.length, chunk);
      frames.add(frame);
    }

    return frames;
  }
}

class _FrameBuffer {
  final int messageIdHash;
  final int totalFrames;
  final Map<int, Uint8List> chunks = {};
  final DateTime createdAt = DateTime.now();

  _FrameBuffer({
    required this.messageIdHash,
    required this.totalFrames,
  });

  bool get isComplete => chunks.length == totalFrames;

  Uint8List assemble() {
    int totalLen = 0;
    for (int i = 0; i < totalFrames; i++) {
      final chunk = chunks[i];
      if (chunk == null) {
        throw StateError('Cannot assemble incomplete message, missing chunk $i');
      }
      totalLen += chunk.length;
    }

    final result = Uint8List(totalLen);
    int offset = 0;
    for (int i = 0; i < totalFrames; i++) {
      final chunk = chunks[i]!;
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }
}

/// Thread-safe in-memory reassembler for incoming BLE packet chunks.
class FrameReassembler {
  final Duration timeout;
  final Map<int, _FrameBuffer> _buffers = {};

  FrameReassembler({this.timeout = const Duration(seconds: 30)});

  /// Processes an incoming raw frame. Returns fully assembled bytes if all frames
  /// have been received, or `null` if more frames are still pending.
  Uint8List? processFrame(Uint8List rawFrame) {
    _pruneStale();

    if (rawFrame.length < FrameCodec.headerSize) {
      return null;
    }

    final byteData = ByteData.sublistView(rawFrame);
    final hash = byteData.getUint32(0);
    final frameIndex = byteData.getUint16(4);
    final totalFrames = byteData.getUint16(6);
    final payloadLength = byteData.getUint16(8);

    if (totalFrames == 0 || frameIndex >= totalFrames) {
      return null;
    }

    if (rawFrame.length < FrameCodec.headerSize + payloadLength) {
      return null;
    }

    final payload = rawFrame.sublist(
      FrameCodec.headerSize,
      FrameCodec.headerSize + payloadLength,
    );

    final buffer = _buffers.putIfAbsent(
      hash,
      () => _FrameBuffer(messageIdHash: hash, totalFrames: totalFrames),
    );

    if (buffer.totalFrames != totalFrames) {
      return null;
    }

    buffer.chunks[frameIndex] = payload;

    if (buffer.isComplete) {
      _buffers.remove(hash);
      return buffer.assemble();
    }

    return null;
  }

  void _pruneStale() {
    final now = DateTime.now();
    _buffers.removeWhere((_, buf) => now.difference(buf.createdAt) > timeout);
  }

  void reset() {
    _buffers.clear();
  }
}
