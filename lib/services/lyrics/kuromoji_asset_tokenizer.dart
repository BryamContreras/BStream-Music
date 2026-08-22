// Kuromoji 1.0.5 exposes dictionary construction only through src/. Keeping
// these implementation imports isolated here prevents its 22 MiB of embedded
// base64 constants from entering the app snapshot. The compatibility tests
// protect this adapter when the pinned package version changes.
// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:kuromoji/src/dict/dynamic_dictionaries.dart';
import 'package:kuromoji/src/tokenizer.dart';

typedef JapaneseTokenizer = List<Map<String, dynamic>> Function(String input);

const _requiredDictionaryFiles = <String>{
  'base.dat',
  'cc.dat',
  'char.dat',
  'check.dat',
  'tid.dat',
  'tid_map.dat',
  'tid_pos.dat',
  'unk.dat',
  'unk_char.dat',
  'unk_compat.dat',
  'unk_invoke.dat',
  'unk_map.dat',
  'unk_pos.dat',
};

const _maximumDictionaryEntryBytes = 48 * 1024 * 1024;
const _maximumExpandedDictionaryBytes = 112 * 1024 * 1024;
const _maximumCompressedDictionaryBytes = 32 * 1024 * 1024;
const _dictionaryMagic = 'BSKRMJ01';

JapaneseTokenizer buildKuromojiTokenizer(Uint8List archiveBytes) {
  if (archiveBytes.isEmpty ||
      archiveBytes.length > _maximumCompressedDictionaryBytes) {
    throw const FormatException('The Kuromoji dictionary asset is empty.');
  }
  final output = _DictionaryOutput();
  final decoded = BZip2Decoder().decodeStream(
    InputMemoryStream(archiveBytes),
    output,
    verify: true,
  );
  if (!decoded) {
    throw const FormatException('Invalid Kuromoji dictionary compression.');
  }
  final data = output.finish();

  final charDefinition = data.remove('char.dat')!;
  final tokenizer = Tokenizer(DynamicDictionaries(data, charDefinition));
  return tokenizer.tokenize;
}

enum _ContainerPhase { preamble, entryHeader, entryName, padding, data, done }

/// Parses the solid BZip2 stream directly into per-entry buffers. Kuromoji's
/// internal ByteBuffer assumes every Uint8List starts at offset zero, so this
/// avoids both invalid shared views and a second 100 MiB expanded copy.
class _DictionaryOutput extends OutputStream {
  _DictionaryOutput() : super(byteOrder: ByteOrder.littleEndian);

  final Map<String, Uint8List> _data = <String, Uint8List>{};
  final List<int> _metadata = <int>[];
  _ContainerPhase _phase = _ContainerPhase.preamble;
  int _length = 0;
  int _entryCount = 0;
  int _entriesRead = 0;
  int _nameLength = 0;
  int _dataLength = 0;
  int _paddingRemaining = 0;
  int _expandedDataBytes = 0;
  String? _entryName;
  Uint8List? _entryData;
  int _entryDataOffset = 0;

  @override
  int get length => _length;

  @override
  void writeByte(int value) {
    if (_phase == _ContainerPhase.done) {
      throw const FormatException('Trailing Kuromoji dictionary data.');
    }
    _length++;
    if (_length > _maximumExpandedDictionaryBytes) {
      throw const FormatException(
        'Kuromoji dictionary expands beyond its limit.',
      );
    }

    switch (_phase) {
      case _ContainerPhase.preamble:
        _metadata.add(value);
        if (_metadata.length == 12) {
          final bytes = Uint8List.fromList(_metadata);
          if (ascii.decode(bytes.sublist(0, 8), allowInvalid: true) !=
              _dictionaryMagic) {
            throw const FormatException(
              'Invalid Kuromoji dictionary container.',
            );
          }
          _entryCount = ByteData.sublistView(bytes).getUint32(8, Endian.little);
          if (_entryCount != _requiredDictionaryFiles.length) {
            throw const FormatException(
              'The Kuromoji dictionary asset is incomplete.',
            );
          }
          _metadata.clear();
          _phase = _ContainerPhase.entryHeader;
        }
        break;
      case _ContainerPhase.entryHeader:
        _metadata.add(value);
        if (_metadata.length == 6) {
          final view = ByteData.sublistView(Uint8List.fromList(_metadata));
          _nameLength = view.getUint16(0, Endian.little);
          _dataLength = view.getUint32(2, Endian.little);
          if (_nameLength == 0 ||
              _dataLength == 0 ||
              _dataLength > _maximumDictionaryEntryBytes) {
            throw const FormatException(
              'Invalid Kuromoji dictionary entry header.',
            );
          }
          _metadata.clear();
          _phase = _ContainerPhase.entryName;
        }
        break;
      case _ContainerPhase.entryName:
        _metadata.add(value);
        if (_metadata.length == _nameLength) {
          final name = utf8.decode(_metadata);
          if (!_requiredDictionaryFiles.contains(name) ||
              _data.containsKey(name)) {
            throw FormatException(
              'Unexpected Kuromoji dictionary entry: $name',
            );
          }
          _entryName = name;
          final expandedDataBytes = _expandedDataBytes + _dataLength;
          if (expandedDataBytes > _maximumExpandedDictionaryBytes) {
            throw const FormatException(
              'Kuromoji dictionary expands beyond its limit.',
            );
          }
          _expandedDataBytes = expandedDataBytes;
          _entryData = Uint8List(_dataLength);
          _entryDataOffset = 0;
          _metadata.clear();
          _paddingRemaining = (4 - (_length % 4)) % 4;
          _phase = _paddingRemaining == 0
              ? _ContainerPhase.data
              : _ContainerPhase.padding;
        }
        break;
      case _ContainerPhase.padding:
        if (value != 0) {
          throw const FormatException('Invalid Kuromoji dictionary padding.');
        }
        _paddingRemaining--;
        if (_paddingRemaining == 0) {
          _phase = _ContainerPhase.data;
        }
        break;
      case _ContainerPhase.data:
        final entryData = _entryData!;
        entryData[_entryDataOffset++] = value;
        if (_entryDataOffset == entryData.length) {
          _data[_entryName!] = entryData;
          _entryData = null;
          _entryName = null;
          _entriesRead++;
          _phase = _entriesRead == _entryCount
              ? _ContainerPhase.done
              : _ContainerPhase.entryHeader;
        }
        break;
      case _ContainerPhase.done:
        throw const FormatException('Trailing Kuromoji dictionary data.');
    }
  }

  Map<String, Uint8List> finish() {
    if (_phase != _ContainerPhase.done ||
        _data.length != _requiredDictionaryFiles.length ||
        !_data.keys.toSet().containsAll(_requiredDictionaryFiles)) {
      throw const FormatException(
        'The Kuromoji dictionary asset is incomplete.',
      );
    }
    return _data;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    for (var index = 0; index < count; index++) {
      writeByte(bytes[index]);
    }
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeByte(stream.readByte());
    }
  }

  @override
  void flush() {}

  @override
  void clear() => throw UnsupportedError('Dictionary output cannot reset.');

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('Dictionary output has no contiguous buffer.');
}
