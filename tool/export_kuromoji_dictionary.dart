// Generates the runtime Kuromoji dictionary asset without embedding its
// base64 constants in the application AOT snapshot.
//
// Run after changing the pinned kuromoji dependency:
//   dart run tool/export_kuromoji_dictionary.dart
// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:kuromoji/src/dict/data/base.dat.dart';
import 'package:kuromoji/src/dict/data/cc.dat.dart';
import 'package:kuromoji/src/dict/data/char.dart';
import 'package:kuromoji/src/dict/data/check.dat.dart';
import 'package:kuromoji/src/dict/data/tid.dat.dart';
import 'package:kuromoji/src/dict/data/tid_map.dat.dart';
import 'package:kuromoji/src/dict/data/tid_pos.dat.dart';
import 'package:kuromoji/src/dict/data/unk.dat.dart';
import 'package:kuromoji/src/dict/data/unk_char.dat.dart';
import 'package:kuromoji/src/dict/data/unk_compat.dat.dart';
import 'package:kuromoji/src/dict/data/unk_invoke.dat.dart';
import 'package:kuromoji/src/dict/data/unk_map.dat.dart';
import 'package:kuromoji/src/dict/data/unk_pos.dat.dart';

void main(List<String> arguments) {
  final outputPath = arguments.isEmpty
      ? 'assets/dictionaries/kuromoji-ipadic.bin.bz2'
      : arguments.single;
  final gzip = GZipDecoder();
  final sources = <String, List<int>>{
    'base.dat': gzip.decodeBytes(baseData, verify: true),
    'cc.dat': gzip.decodeBytes(ccData, verify: true),
    'char.dat': charData,
    'check.dat': gzip.decodeBytes(checkData, verify: true),
    'tid.dat': gzip.decodeBytes(tidData, verify: true),
    'tid_map.dat': gzip.decodeBytes(tid_mapData, verify: true),
    'tid_pos.dat': gzip.decodeBytes(tid_posData, verify: true),
    'unk.dat': gzip.decodeBytes(unkData, verify: true),
    'unk_char.dat': gzip.decodeBytes(unk_charData, verify: true),
    'unk_compat.dat': gzip.decodeBytes(unk_compatData, verify: true),
    'unk_invoke.dat': gzip.decodeBytes(unk_invokeData, verify: true),
    'unk_map.dat': gzip.decodeBytes(unk_mapData, verify: true),
    'unk_pos.dat': gzip.decodeBytes(unk_posData, verify: true),
  };
  final packed = _packDictionary(sources);
  final encoded = BZip2Encoder().encodeBytes(packed);
  final output = File(outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(encoded, flush: true);
  stdout.writeln('Wrote ${encoded.length} bytes to ${output.path}.');
}

Uint8List _packDictionary(Map<String, List<int>> sources) {
  final entries = sources.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode('BSKRMJ01'))
    ..add(_uint32(entries.length));
  for (final entry in entries) {
    final name = utf8.encode(entry.key);
    if (name.length > 0xffff) {
      throw StateError('Dictionary entry name is too long: ${entry.key}');
    }
    output
      ..add(_uint16(name.length))
      ..add(_uint32(entry.value.length))
      ..add(name);
    while (output.length % 4 != 0) {
      output.addByte(0);
    }
    output.add(entry.value);
  }
  return output.takeBytes();
}

Uint8List _uint16(int value) =>
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List();

Uint8List _uint32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
