// Interop test: these vectors were produced by the Python laptop node (laptop_node/protocol.py).
// If this test passes, the phone app and the laptop node agree on X25519, HKDF-SHA256, AES-GCM-256,
// the AAD string, the envelope JSON, the HMAC ACK, the safety number and the frame format.
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/models/chat_envelope.dart';
import 'package:nearby_chat/models/mesh_packet.dart';
import 'package:nearby_chat/services/crypto_service.dart';
import 'package:nearby_chat/services/frame_codec.dart';

void main() {
  const bobSeed = [100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131];
  const bobPub = 'fZwkMWU5glwYluV/KBl3Rnk85gy+461H2p0HuF+lXio=';
  const alicePub = 'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=';
  const envelopeJson = r'{"v":2,"id":"11111111-2222-4333-8444-555555555555","u":"LaptopA","spk":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=","rpk":"fZwkMWU5glwYluV/KBl3Rnk85gy+461H2p0HuF+lXio=","epk":"TVuribBzPZ2Nzs8E8yHJC3Ybd2WmvbK92/rT56vfH2Y=","t":1792000000000,"n":"AAECAwQFBgcICQoL","c":"TWm3T9j0axHfTxG5wECxggSa0/6iIX4jUjuTxaPmhaGq","m":"o9bs45TKoMkx3fyPtLfiqA==","ack":false}';
  const ackMac = 'oNbY2Y0jBcRcU6TPUUbeLEO/iRXx++1OMKnsfKJiInI=';
  const safety = 'fe-b0-a9-e8-07-ee';
  const frames = [
      'obLD1AAAACQACnsidiI6MiwiaWQ=',
      'obLD1AABACQACiI6IjExMTExMTE=',
      'obLD1AACACQACjEtMjIyMi00MzM=',
      'obLD1AADACQACjMtODQ0NC01NTU=',
      'obLD1AAEACQACjU1NTU1NTU1NSI=',
      'obLD1AAFACQACiwidSI6IkxhcHQ=',
      'obLD1AAGACQACm9wQSIsInNwayI=',
      'obLD1AAHACQACjoiQjZOOHZCUWc=',
      'obLD1AAIACQACms4aTNWZHdiRU8=',
      'obLD1AAJACQACmhzdENZM1N0RnE=',
      'obLD1AAKACQACnFGUHRDOS9Bc3I=',
      'obLD1AALACQACmh0SEh3PSIsInI=',
      'obLD1AAMACQACnBrIjoiZlp3a00=',
      'obLD1AANACQACldVNWdsd1lsdVY=',
      'obLD1AAOACQACi9LQmwzUm5rODU=',
      'obLD1AAPACQACmd5KzQ2MUgycDA=',
      'obLD1AAQACQACkh1RitsWGlvPSI=',
      'obLD1AARACQACiwiZXBrIjoiVFY=',
      'obLD1AASACQACnVyaWJCelBaMk4=',
      'obLD1AATACQACnpzOEU4eUhKQzM=',
      'obLD1AAUACQAClliZDJXbXZiSzk=',
      'obLD1AAVACQACjIvclQ1NnZmSDI=',
      'obLD1AAWACQAClk9IiwidCI6MTc=',
      'obLD1AAXACQACjkyMDAwMDAwMDA=',
      'obLD1AAYACQACjAsIm4iOiJBQUU=',
      'obLD1AAZACQACkNBd1FGQmdjSUM=',
      'obLD1AAaACQAClFvTCIsImMiOiI=',
      'obLD1AAbACQAClRXbTNUOWowYXg=',
      'obLD1AAcACQACkhmVHhHNXdFQ3g=',
      'obLD1AAdACQACmdnU2EwLzZpSVg=',
      'obLD1AAeACQACjRqVWp1VHhhUG0=',
      'obLD1AAfACQACmhhR3EiLCJtIjo=',
      'obLD1AAgACQACiJvOWJzNDVUS28=',
      'obLD1AAhACQACk1reDNmeVB0TGY=',
      'obLD1AAiACQACmlxQT09IiwiYWM=',
      'obLD1AAjACQACWsiOmZhbHNlfQ=='
  ];

  late CryptoService bob;

  setUp(() async {
    bob = CryptoService();
    await bob.init(testKeyPair: await X25519().newKeyPairFromSeed(bobSeed));
  });

  test('Same key pair from the same seed as Python', () {
    expect(bob.publicKeyBase64, bobPub);
  });

  test('Decrypts an envelope encrypted by the Python node', () async {
    final env = ChatEnvelope.fromBinary(Uint8List.fromList(utf8.encode(envelopeJson)));
    final result = await bob.decryptEnvelopeWithKey(env);
    expect(result.plaintext, 'Hello from the Python laptop node');
    expect(env.senderPublicKey, alicePub);

    final ack = await bob.createAckEnvelope(
      originalMessageId: env.messageId,
      recipientPublicKeyBase64: env.senderPublicKey,
      senderUsername: 'Bob',
      messageKey: result.messageKey,
    );
    expect(base64Encode(ack.mac), ackMac);
  });

  test('Safety number matches the Python node', () async {
    expect(await bob.deriveSafetyNumber(alicePub), safety);
  });

  test('Reassembles 20 byte frames produced by the Python node', () {
    final r = FrameReassembler();
    Uint8List? out;
    for (final f in frames) {
      out = r.processFrame(base64Decode(f), senderId: 'laptop') ?? out;
    }
    expect(utf8.decode(out!), envelopeJson);
  });

  // Mesh layer: an announce and a public room message signed (Ed25519) by the Python node.
  const announceJson = r'{"mesh":1,"pid":"fadb7a85526bc59a","ttl":7,"kind":"ann","u":"LaptopA","pk":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=","spk":"iOR2lURJQLw8airG/1LqCPq+vNh8WdWK1Lkw1genYNE=","ts":1792942821087,"sig":"0LQ8VCQZ4NLZrYBIeOPyO0PiPt7d9FIHs78uASpVEek9hvq1oYKoMDhMg/g5TdGhr4K9YJCqFFIFq6ycDwOpDQ=="}';
  const publicJson = r'{"mesh":1,"pid":"cf51a55212d57faa","ttl":7,"kind":"pub","id":"22222222-3333-4444-8555-666666666666","u":"LaptopA","pk":"B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=","spk":"iOR2lURJQLw8airG/1LqCPq+vNh8WdWK1Lkw1genYNE=","ts":1792942821087,"text":"hello #nearby from Python","sig":"CSt8cHp9QJp4ZNz9ZfbfAKmEAkqeX2zhOkLP38RWSRnr5VDqGmK449AVHJhpNYE+ZwpxWL2K0+YUx26SCVT8Aw=="}';

  test('Verifies an Ed25519 signed announce from the Python node', () async {
    final p = MeshPacket.fromJson(jsonDecode(announceJson) as Map<String, dynamic>)!;
    expect(p.kind, MeshPacket.kindAnnounce);
    expect(p.ttl, MeshPacket.defaultTtl);
    final b = p.body;
    final signed = MeshPacket.announceSigningString(b['u'], b['pk'], b['spk'], b['ts']);
    expect(await CryptoService.verifySignature(signed, b['sig'], b['spk']), isTrue);
    expect(await CryptoService.verifySignature('${signed}x', b['sig'], b['spk']), isFalse);
  });

  test('Verifies a signed public room message from the Python node', () async {
    final p = MeshPacket.fromJson(jsonDecode(publicJson) as Map<String, dynamic>)!;
    final b = p.body;
    expect(b['text'], 'hello #nearby from Python');
    final signed = MeshPacket.publicSigningString(b['id'], b['u'], b['pk'], b['spk'], b['ts'], b['text']);
    expect(await CryptoService.verifySignature(signed, b['sig'], b['spk']), isTrue);
  });
}
