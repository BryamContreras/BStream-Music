import 'dart:convert';
import 'dart:typed_data';

/// Decoded protobuf message — field number → list of values.
/// Repeated fields and sub-messages produce multiple entries.
class ProtoMap {
  final Map<int, List<ProtoValue>> _fields;

  ProtoMap(this._fields);

  int getVarint(int field, [int fallback = 0]) {
    final vals = _fields[field];
    if (vals == null || vals.isEmpty) return fallback;
    return vals.first.asVarint;
  }

  bool getBool(int field, [bool fallback = false]) =>
      getVarint(field, fallback ? 1 : 0) != 0;

  String getString(int field, [String fallback = '']) {
    final vals = _fields[field];
    if (vals == null || vals.isEmpty) return fallback;
    return vals.first.asString;
  }

  Uint8List getBytes(int field) {
    final vals = _fields[field];
    if (vals == null || vals.isEmpty) return Uint8List(0);
    return vals.first.asBytes;
  }

  ProtoMap? getMessage(int field) {
    final vals = _fields[field];
    if (vals == null || vals.isEmpty) return null;
    return vals.first.asMessage;
  }

  List<ProtoMap> getRepeatedMessage(int field) {
    final vals = _fields[field];
    if (vals == null) return [];
    return vals.map((v) => v.asMessage).whereType<ProtoMap>().toList();
  }

  List<int> getRepeatedVarint(int field) {
    final vals = _fields[field];
    if (vals == null) return [];
    return vals.map((v) => v.asVarint).toList();
  }

  List<String> getRepeatedString(int field) {
    final vals = _fields[field];
    if (vals == null) return [];
    return vals.map((v) => v.asString).toList();
  }

  Map<String, String> getStringMap(int field) {
    final entries = getRepeatedMessage(field);
    final map = <String, String>{};
    for (final entry in entries) {
      map[entry.getString(1)] = entry.getString(2);
    }
    return map;
  }

  bool has(int field) => _fields.containsKey(field);
}

class ProtoValue {
  final int wireType;
  final int _varint;
  final Uint8List _bytes;

  ProtoValue.varint(this._varint) : wireType = 0, _bytes = Uint8List(0);
  ProtoValue.bytes(this._bytes) : wireType = 2, _varint = 0;
  ProtoValue.fixed64(this._varint) : wireType = 1, _bytes = Uint8List(0);
  ProtoValue.fixed32(this._varint) : wireType = 5, _bytes = Uint8List(0);

  int get asVarint => _varint;
  String get asString => utf8.decode(_bytes, allowMalformed: true);
  Uint8List get asBytes => _bytes;

  ProtoMap? get asMessage {
    if (_bytes.isEmpty) return null;
    try {
      return protoRead(_bytes);
    } on FormatException {
      return null;
    }
  }
}

/// Decode a protobuf binary blob into a ProtoMap.
ProtoMap protoRead(Uint8List data) {
  final fields = <int, List<ProtoValue>>{};
  final reader = _Reader(data);

  while (reader.hasMore) {
    final tag = reader.readVarint();
    final fieldNum = tag >> 3;
    final wireType = tag & 0x7;

    if (fieldNum == 0) break;

    ProtoValue val;
    switch (wireType) {
      case 0: // varint
        val = ProtoValue.varint(reader.readVarint());
      case 1: // 64-bit
        val = ProtoValue.fixed64(reader.readFixed64());
      case 2: // length-delimited
        val = ProtoValue.bytes(reader.readLengthDelimited());
      case 5: // 32-bit
        val = ProtoValue.fixed32(reader.readFixed32());
      default:
        throw FormatException('unsupported wire type $wireType');
    }

    fields.putIfAbsent(fieldNum, () => []).add(val);
  }

  return ProtoMap(fields);
}

class _Reader {
  final Uint8List _data;
  int _pos = 0;

  _Reader(this._data);

  bool get hasMore => _pos < _data.length;

  int readVarint() {
    int result = 0;
    int shift = 0;
    while (_pos < _data.length) {
      final b = _data[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 64) throw const FormatException('varint too long');
    }
    throw const FormatException('truncated varint');
  }

  int readFixed64() {
    if (_pos + 8 > _data.length) {
      throw const FormatException('truncated fixed64');
    }
    final bd = ByteData.sublistView(_data, _pos, _pos + 8);
    _pos += 8;
    return bd.getInt64(0, Endian.little);
  }

  int readFixed32() {
    if (_pos + 4 > _data.length) {
      throw const FormatException('truncated fixed32');
    }
    final bd = ByteData.sublistView(_data, _pos, _pos + 4);
    _pos += 4;
    return bd.getInt32(0, Endian.little);
  }

  Uint8List readLengthDelimited() {
    final len = readVarint();
    if (_pos + len > _data.length) {
      throw const FormatException('truncated length-delimited field');
    }
    final slice = Uint8List.sublistView(_data, _pos, _pos + len);
    _pos += len;
    return slice;
  }
}

/// Protobuf writer — builds binary protobuf from field values.
class ProtoWriter {
  final _buf = BytesBuilder(copy: false);

  void writeVarintField(int field, int value) {
    _writeTag(field, 0);
    _writeRawVarint(value);
  }

  void writeBoolField(int field, bool value) {
    writeVarintField(field, value ? 1 : 0);
  }

  void writeStringField(int field, String value) {
    writeBytesField(field, Uint8List.fromList(utf8.encode(value)));
  }

  void writeBytesField(int field, Uint8List value) {
    _writeTag(field, 2);
    _writeRawVarint(value.length);
    _buf.add(value);
  }

  void writeMessageField(int field, Uint8List encoded) {
    writeBytesField(field, encoded);
  }

  void _writeTag(int field, int wireType) {
    _writeRawVarint((field << 3) | wireType);
  }

  void _writeRawVarint(int value) {
    var v = value;
    while (v > 0x7F || v < 0) {
      _buf.addByte((v & 0x7F) | 0x80);
      v >>>= 7; // unsigned right shift — no JS compat needed, dart:io only
    }
    _buf.addByte(v & 0x7F);
  }

  Uint8List toBytes() => _buf.toBytes();
}

/// Convenience: build protobuf bytes from a closure.
Uint8List protoWrite(void Function(ProtoWriter w) builder) {
  final w = ProtoWriter();
  builder(w);
  return w.toBytes();
}
