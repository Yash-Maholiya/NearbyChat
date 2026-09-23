import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/services/frame_codec.dart';

void main() {
  group('FrameCodec & FrameReassembler Tests', () {
    test('Fragment empty data returns empty list', () {
      final frames = FrameCodec.fragment(Uint8List(0));
      expect(frames, isEmpty);
    });

    test('Data smaller than MTU yields single frame', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final frames = FrameCodec.fragment(data, maxFrameSize: 20);

      expect(frames.length, equals(1));
      expect(frames[0].length, equals(FrameCodec.headerSize + data.length));
    });

    test('Large payload is correctly sliced and reassembled in-order', () {
      // 1000 bytes of arbitrary data
      final random = Random(42);
      final originalData = Uint8List.fromList(List.generate(1000, (_) => random.nextInt(256)));

      // Fragment into 50-byte MTU frames
      final frames = FrameCodec.fragment(originalData, maxFrameSize: 50, messageIdHash: 1234);
      expect(frames.length, equals((1000 / (50 - FrameCodec.headerSize)).ceil()));

      final reassembler = FrameReassembler();
      Uint8List? assembled;

      for (int i = 0; i < frames.length; i++) {
        final result = reassembler.processFrame(frames[i]);
        if (i == frames.length - 1) {
          assembled = result;
        } else {
          expect(result, isNull);
        }
      }

      expect(assembled, isNotNull);
      expect(assembled, equals(originalData));
    });

    test('Out-of-order frame arrival reassembles into correct byte sequence', () {
      final data = Uint8List.fromList(List.generate(300, (i) => i % 256));

      // Slice into 30-byte frames
      final frames = FrameCodec.fragment(data, maxFrameSize: 30, messageIdHash: 999);
      expect(frames.length, greaterThan(2));

      // Shuffle frames
      final shuffled = List<Uint8List>.from(frames)..shuffle(Random(123));

      final reassembler = FrameReassembler();
      Uint8List? assembled;

      for (final frame in shuffled) {
        final result = reassembler.processFrame(frame);
        if (result != null) {
          assembled = result;
        }
      }

      expect(assembled, isNotNull);
      expect(assembled, equals(data));
    });

    test('Corrupted frames with truncated payload are safely discarded', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      final frames = FrameCodec.fragment(data, maxFrameSize: 20);

      final reassembler = FrameReassembler();

      // Truncate frame to fewer bytes than specified in header
      final truncated = frames[0].sublist(0, frames[0].length - 2);
      final result = reassembler.processFrame(truncated);

      expect(result, isNull);
    });
  });
}
