import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/services/frame_codec.dart';

void main() {
  group('FrameCodec & FrameReassembler Tests', () {
    test('Fragment empty data returns single empty frame and reassembles safely', () {
      final frames = FrameCodec.fragment(Uint8List(0));
      expect(frames.length, equals(1));
      expect(frames[0].length, equals(FrameCodec.headerSize));

      final reassembler = FrameReassembler();
      final assembled = reassembler.processFrame(frames[0]);
      expect(assembled, isNotNull);
      expect(assembled!.isEmpty, isTrue);
    });

    test('Data smaller than MTU yields single frame', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final frames = FrameCodec.fragment(data, maxFrameSize: 20);

      expect(frames.length, equals(1));
      expect(frames[0].length, equals(FrameCodec.headerSize + data.length));
    });

    test('Large payload is correctly sliced and reassembled in-order', () {
      final random = Random(42);
      final originalData = Uint8List.fromList(List.generate(1000, (_) => random.nextInt(256)));

      // Fragment into 50-byte MTU frames
      final frames = FrameCodec.fragment(originalData, maxFrameSize: 50, messageIdHash: 1234);
      expect(frames.length, equals((1000 / (50 - FrameCodec.headerSize)).ceil()));

      final reassembler = FrameReassembler();
      Uint8List? assembled;

      for (int i = 0; i < frames.length; i++) {
        final result = reassembler.processFrame(frames[i], senderId: 'deviceA');
        if (i == frames.length - 1) {
          assembled = result;
        } else {
          expect(result, isNull);
        }
      }

      expect(assembled, isNotNull);
      expect(assembled, equals(originalData));
    });

    test('Different senders with colliding hash do not corrupt each other', () {
      final dataA = Uint8List.fromList([10, 20, 30, 40]);
      final dataB = Uint8List.fromList([99, 88, 77, 66]);

      // Both use same messageIdHash: 777
      final framesA = FrameCodec.fragment(dataA, maxFrameSize: 12, messageIdHash: 777);
      final framesB = FrameCodec.fragment(dataB, maxFrameSize: 12, messageIdHash: 777);

      final reassembler = FrameReassembler();

      // Interleave frames from senderA and senderB
      reassembler.processFrame(framesA[0], senderId: 'senderA');
      reassembler.processFrame(framesB[0], senderId: 'senderB');

      final resultA = reassembler.processFrame(framesA[1], senderId: 'senderA');
      final resultB = reassembler.processFrame(framesB[1], senderId: 'senderB');

      expect(resultA, equals(dataA));
      expect(resultB, equals(dataB));
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
        final result = reassembler.processFrame(frame, senderId: 'device1');
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
      final result = reassembler.processFrame(truncated, senderId: 'device1');

      expect(result, isNull);
    });

    test('Total frames mismatch evicts buffer and discards corrupted sequence', () {
      final data = Uint8List.fromList(List.generate(50, (i) => i));
      final frames = FrameCodec.fragment(data, maxFrameSize: 20, messageIdHash: 42);

      final reassembler = FrameReassembler();
      // Send first frame
      reassembler.processFrame(frames[0], senderId: 'dev1');

      // Craft an inconsistent frame with same hash but totalFrames = 10
      final badFrame = Uint8List.fromList(frames[1]);
      final byteData = ByteData.sublistView(badFrame);
      byteData.setUint16(6, 10); // totalFrames = 10

      final mismatchResult = reassembler.processFrame(badFrame, senderId: 'dev1');
      expect(mismatchResult, isNull);

      // Subsequent fresh sequence with same hash should start fresh and reassemble
      Uint8List? assembled;
      for (final frame in frames) {
        final res = reassembler.processFrame(frame, senderId: 'dev1');
        if (res != null) assembled = res;
      }
      expect(assembled, equals(data));
    });

    test('Frame size follows the negotiated MTU', () {
      expect(FrameCodec.frameSizeForMtu(23), 20);
      expect(FrameCodec.frameSizeForMtu(185), 182);
      expect(FrameCodec.frameSizeForMtu(247), 244);
      expect(FrameCodec.frameSizeForMtu(10), 20);
      expect(FrameCodec.frameSizeForMtu(1000), 512);
    });

    test('Default 23 byte MTU still carries a full envelope in 20 byte writes', () {
      final data = Uint8List.fromList(List.generate(700, (i) => i % 251));
      final frames = FrameCodec.fragment(data, maxFrameSize: FrameCodec.frameSizeForMtu(23));
      expect(frames.every((f) => f.length <= 20), isTrue);
      expect(frames.length, 70);
      final reassembler = FrameReassembler();
      Uint8List? out;
      for (final f in frames.reversed) {
        out = reassembler.processFrame(f, senderId: 'android-peer') ?? out;
      }
      expect(out, equals(data));
    });
  });
}
