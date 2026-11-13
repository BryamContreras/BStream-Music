import 'dart:convert';
import 'dart:typed_data';

List<int> mp4Atom(String type, List<int> payload) => [
  ...mp4Uint32(payload.length + 8),
  ...ascii.encode(type),
  ...payload,
];
List<int> mp4Uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

Uint8List aacMoov({
  int bitrate = 312999,
  List<int> config = const [0x12, 0x10], // AAC-LC, 44.1 kHz, stereo.
}) {
  List<int> descriptor(int tag, List<int> bytes) => [
    tag,
    bytes.length,
    ...bytes,
  ];
  final decoder = descriptor(4, [
    0x40,
    0x15,
    0,
    0,
    0,
    ...mp4Uint32(320000),
    ...mp4Uint32(bitrate),
    ...descriptor(5, config),
  ]);
  final esds = mp4Atom('esds', [
    0,
    0,
    0,
    0,
    ...descriptor(3, [
      0,
      1,
      0,
      ...decoder,
      ...descriptor(6, [2]),
    ]),
  ]);
  // The real codec configuration must override these misleading defaults.
  final header = ByteData(28)
    ..setUint16(6, 1)
    ..setUint16(16, 6)
    ..setUint16(18, 16)
    ..setUint32(24, 32000 << 16);
  var bytes = mp4Atom('stsd', [
    0,
    0,
    0,
    0,
    ...mp4Uint32(1),
    ...mp4Atom('mp4a', [...header.buffer.asUint8List(), ...esds]),
  ]);
  for (final type in ['stbl', 'minf', 'mdia', 'trak', 'moov']) {
    bytes = mp4Atom(type, bytes);
  }
  return Uint8List.fromList(bytes);
}

Uint8List mp4Prefix({Uint8List? moov, int? tailOffset}) {
  final bytes = Uint8List(4096);
  final ftyp = mp4Atom('ftyp', [
    ...ascii.encode('M4A '),
    ...mp4Uint32(0),
    ...ascii.encode('M4A isom'),
  ]);
  bytes.setAll(0, ftyp);
  if (moov != null) bytes.setAll(ftyp.length, moov);
  if (tailOffset != null) {
    bytes.setAll(ftyp.length, [
      ...mp4Uint32(tailOffset - ftyp.length),
      ...ascii.encode('mdat'),
    ]);
  }
  return bytes;
}
