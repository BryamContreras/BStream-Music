import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Technical details of the selected local file, not the device's audio output.
/// Missing values deliberately remain unknown rather than assuming stereo/48k.
class LocalAudioQuality {
  const LocalAudioQuality({
    this.codec,
    this.mimeType,
    this.sampleRate,
    this.bitrate,
    this.channels,
  });

  final String? codec;
  final String? mimeType;
  final int? sampleRate;
  final int? bitrate;
  final int? channels;

  static LocalAudioQuality? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    String? text(Object? value) {
      if (value is! String) return null;
      final result = value.trim().toLowerCase();
      return result.isEmpty ||
              result.length > 128 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(result)
          ? null
          : result;
    }

    int? integer(Object? value, int maximum) {
      if (value is! num ||
          !value.isFinite ||
          value != value.truncateToDouble()) {
        return null;
      }
      return value > 0 && value <= maximum ? value.toInt() : null;
    }

    final result = LocalAudioQuality(
      codec: text(map['codec']),
      mimeType: text(map['mimeType']),
      sampleRate: integer(map['sampleRate'], 0x7fffffff),
      bitrate: integer(map['bitrate'], 0x7fffffff),
      channels: integer(map['channels'], 64),
    );
    return result.codec == null &&
            result.mimeType == null &&
            result.sampleRate == null &&
            result.bitrate == null &&
            result.channels == null
        ? null
        : result;
  }

  Map<String, Object?> toMap() => {
    'codec': codec,
    'mimeType': mimeType,
    'sampleRate': sampleRate,
    'bitrate': bitrate,
    'channels': channels,
  };

  @override
  bool operator ==(Object other) =>
      other is LocalAudioQuality &&
      codec == other.codec &&
      mimeType == other.mimeType &&
      sampleRate == other.sampleRate &&
      bitrate == other.bitrate &&
      channels == other.channels;

  @override
  int get hashCode =>
      Object.hash(codec, mimeType, sampleRate, bitrate, channels);
}

/// No network streams, metadata requests or second decoder are used here.
bool isSupportedLocalAudioQualitySource(String source) =>
    _normalizeSource(source) != null;

typedef LocalAudioQualityLoader = Future<LocalAudioQuality?> Function(String);
typedef LocalAudioQualityFingerprintLoader = Future<Object?> Function(String);

/// A demand-driven cache for the active local song only. TTLs are checked when
/// requested; they create no timers, polling or background library scans.
class LocalAudioQualityService {
  LocalAudioQualityService({
    this.loader,
    LocalAudioQualityFingerprintLoader? fingerprintLoader,
    DateTime Function()? now,
    this.maxEntries = 16,
    this.contentCacheTtl = const Duration(seconds: 30),
    this.negativeCacheTtl = const Duration(seconds: 10),
    MethodChannel? methodChannel,
  }) : _fingerprintLoader = fingerprintLoader ?? _fileFingerprint,
       _now = now ?? DateTime.now,
       _channel =
           methodChannel ?? const MethodChannel('bstream/local_audio_quality') {
    if (maxEntries < 1 || maxEntries > 256) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
    if (contentCacheTtl <= Duration.zero || negativeCacheTtl <= Duration.zero) {
      throw ArgumentError('Cache lifetimes must be positive.');
    }
  }

  final int maxEntries;
  final Duration contentCacheTtl;
  final Duration negativeCacheTtl;
  final LocalAudioQualityLoader? loader;
  final LocalAudioQualityFingerprintLoader _fingerprintLoader;
  final DateTime Function() _now;
  final MethodChannel _channel;
  final _cache = <String, _QualityCacheEntry>{};
  final _inFlight = <String, Future<LocalAudioQuality?>>{};
  final _waiters = Queue<Completer<bool>>();
  int _active = 0;
  bool _disposed = false;

  Future<LocalAudioQuality?> read(String source) {
    final local = _normalizeSource(source);
    if (_disposed || local == null) return Future.value(null);
    final pending = _inFlight[local.source];
    if (pending != null) return pending;
    // Fast repeated skips must not create an unbounded native work queue.
    if (_inFlight.length >= maxEntries * 2) return Future.value(null);
    late final Future<LocalAudioQuality?> request;
    request = _read(local).whenComplete(() {
      if (identical(_inFlight[local.source], request)) {
        _inFlight.remove(local.source);
      }
    });
    _inFlight[local.source] = request;
    return request;
  }

  Future<LocalAudioQuality?> _read(_LocalSource source) async {
    if (!await _acquire()) return null;
    try {
      Object? fingerprint;
      if (source.isFile) {
        try {
          fingerprint = await _fingerprintLoader(source.source);
        } catch (_) {
          // Permission/provider failures are optional information, never a
          // playback error. A short-lived result can be retried on re-entry.
        }
      }
      if (_disposed) return null;
      final cached = _cache.remove(source.source);
      final now = _now();
      if (cached != null &&
          cached.fingerprint == fingerprint &&
          (cached.expiresAt == null || now.isBefore(cached.expiresAt!))) {
        _cache[source.source] = cached;
        return cached.value;
      }
      LocalAudioQuality? value;
      try {
        final loaded = await (loader?.call(source.source) ?? _load(source));
        value = LocalAudioQuality.fromMap(loaded?.toMap());
      } catch (_) {
        // Bad headers, inaccessible files and a missing platform bridge all
        // leave the optional label unknown without interrupting playback.
      }
      if (_disposed) return null;
      final lifetime = value == null
          ? negativeCacheTtl
          : (!source.isFile || fingerprint == null ? contentCacheTtl : null);
      _cache[source.source] = _QualityCacheEntry(
        value,
        fingerprint,
        lifetime == null ? null : _now().add(lifetime),
      );
      while (_cache.length > maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      return value;
    } finally {
      _release();
    }
  }

  Future<LocalAudioQuality?> _load(_LocalSource source) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final result = await _channel
          .invokeMapMethod<Object?, Object?>('read', <String, Object>{
            'source': source.source,
          })
          .timeout(const Duration(seconds: 6));
      return LocalAudioQuality.fromMap(result);
    }
    if (!source.isFile) return null;
    final path = source.source;
    return Isolate.run(() => _probeLocalFile(path));
  }

  Future<bool> _acquire() {
    if (_disposed) return Future.value(false);
    if (_active < 2) {
      _active++;
      return Future.value(true);
    }
    final waiter = Completer<bool>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (!_disposed && _waiters.isNotEmpty) {
      _waiters.removeFirst().complete(true);
    } else {
      _active--;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cache.clear();
    _inFlight.clear();
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(false);
    }
  }
}

class _QualityCacheEntry {
  const _QualityCacheEntry(this.value, this.fingerprint, this.expiresAt);
  final LocalAudioQuality? value;
  final Object? fingerprint;
  final DateTime? expiresAt;
}

class _LocalSource {
  const _LocalSource(this.source, {required this.isFile});
  final String source;
  final bool isFile;
}

_LocalSource? _normalizeSource(String source) {
  final text = source.trim();
  if (text.isEmpty || text.length > 16384 || text.contains('\u0000')) {
    return null;
  }
  if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(text)) {
    return _LocalSource(p.normalize(File(text).absolute.path), isFile: true);
  }
  // Windows Uri parsing can canonicalize `file:relative` into an apparently
  // absolute URI. Validate the original spelling before that normalization.
  if (text.toLowerCase().startsWith('file:') &&
      !text.substring(5).startsWith('/')) {
    return null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'content' || scheme == 'ipod-library') {
    if (!uri.hasAuthority || uri.host.isEmpty) return null;
    return _LocalSource(uri.replace(scheme: scheme).toString(), isFile: false);
  }
  if (scheme.isNotEmpty && scheme != 'file') return null;
  if (scheme == 'file' &&
      (!uri.hasAbsolutePath || uri.hasQuery || uri.hasFragment)) {
    return null;
  }
  try {
    final path = scheme == 'file' ? uri.toFilePath() : text;
    if (path.isEmpty) return null;
    return _LocalSource(p.normalize(File(path).absolute.path), isFile: true);
  } on ArgumentError {
    return null;
  } on UnsupportedError {
    return null;
  }
}

Future<Object?> _fileFingerprint(String path) async {
  final stat = await File(path).stat();
  return (
    stat.type,
    stat.size,
    stat.modified.microsecondsSinceEpoch,
    stat.changed.microsecondsSinceEpoch,
  );
}

// Header-only desktop probing runs in its own isolate. The reader bounds total
// bytes and iterations and seeks past tags/artwork instead of loading them.
LocalAudioQuality? _probeLocalFile(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final reader = _HeaderReader(file, file.lengthSync());
    final first = reader.read(0, reader.length < 12 ? reader.length : 12);
    if (first == null || first.length < 4) return null;
    if (_ascii(first, 0, 4) == 'RIFF' ||
        _ascii(first, 0, 4) == 'RIFX' ||
        _ascii(first, 0, 4) == 'RF64') {
      return _readWave(reader, first);
    }
    var offset = 0;
    if (_ascii(first, 0, 3) == 'ID3' && first.length >= 10) {
      if (first.sublist(6, 10).any((value) => value > 127)) return null;
      offset =
          10 + (first[6] << 21 | first[7] << 14 | first[8] << 7 | first[9]);
      if (first[5] & 0x10 != 0) offset += 10;
    }
    final signature = reader.read(offset, 4);
    if (signature == null) return null;
    if (_ascii(signature, 0, 4) == 'fLaC') return _readFlac(reader, offset);
    if (_ascii(signature, 0, 4) == 'OggS') return _readOgg(reader, offset);
    if (first.length >= 8 && _ascii(first, 4, 4) == 'ftyp') {
      return _readMp4(reader);
    }
    return _readMpegAudio(reader, offset);
  } catch (_) {
    return null;
  } finally {
    file?.closeSync();
  }
}

class _HeaderReader {
  _HeaderReader(this.file, this.length);
  final RandomAccessFile file;
  final int length;
  int remaining = 256 * 1024;
  int reads = 0;

  Uint8List? read(int offset, int count) {
    if (offset < 0 ||
        count < 0 ||
        count > 65536 ||
        count > remaining ||
        offset + count > length ||
        ++reads > 1024) {
      return null;
    }
    remaining -= count;
    file.setPositionSync(offset);
    final data = file.readSync(count);
    return data.length == count ? data : null;
  }
}

String _ascii(Uint8List bytes, int offset, int length) =>
    offset < 0 || offset + length > bytes.length
    ? ''
    : String.fromCharCodes(bytes.sublist(offset, offset + length));

ByteData _data(Uint8List bytes) => ByteData.sublistView(bytes);

LocalAudioQuality? _readWave(_HeaderReader reader, Uint8List signature) {
  if (_ascii(signature, 8, 4) != 'WAVE') return null;
  final endian = _ascii(signature, 0, 4) == 'RIFX' ? Endian.big : Endian.little;
  var offset = 12;
  for (var chunks = 0; chunks < 256; chunks++) {
    final header = reader.read(offset, 8);
    if (header == null) return null;
    final size = _data(header).getUint32(4, endian);
    if (_ascii(header, 0, 4) == 'fmt ') {
      if (size < 16) return null;
      final fmt = reader.read(offset + 8, size >= 40 ? 40 : 16);
      if (fmt == null) return null;
      final data = _data(fmt);
      var format = data.getUint16(0, endian);
      if (format == 0xfffe && fmt.length >= 40) {
        format = data.getUint16(24, endian);
      }
      final bits = data.getUint16(14, endian);
      final suffix = endian == Endian.little ? 'le' : 'be';
      final codec = switch (format) {
        1 => bits == 8 ? 'pcm_u8' : 'pcm_s$bits$suffix',
        3 => 'pcm_f$bits$suffix',
        6 => 'alaw',
        7 => 'mulaw',
        _ => null,
      };
      return LocalAudioQuality.fromMap({
        'codec': codec,
        'mimeType': 'audio/wav',
        'channels': data.getUint16(2, endian),
        'sampleRate': data.getUint32(4, endian),
        'bitrate': data.getUint32(8, endian) * 8,
      });
    }
    offset += 8 + size + (size & 1);
  }
  return null;
}

LocalAudioQuality? _readFlac(_HeaderReader reader, int offset) {
  final header = reader.read(offset + 4, 4);
  if (header == null || header[0] & 0x7f != 0) return null;
  final size = header[1] << 16 | header[2] << 8 | header[3];
  if (size != 34) return null;
  final info = reader.read(offset + 8, 34);
  return info == null ? null : _flacInfo(info);
}

LocalAudioQuality _flacInfo(Uint8List info) {
  final packed = _data(info).getUint64(10);
  return LocalAudioQuality(
    codec: 'flac',
    mimeType: 'audio/flac',
    sampleRate: (packed >> 44) & 0xfffff,
    channels: ((packed >> 41) & 7) + 1,
    // STREAMINFO has no compressed average bitrate. PCM bit depth times rate
    // is not the bitrate of the FLAC stream, particularly with embedded covers.
  );
}

LocalAudioQuality? _readOgg(_HeaderReader reader, int offset) {
  final header = reader.read(offset, 27);
  if (header == null || header[4] != 0 || header[5] & 1 != 0) return null;
  final lacing = reader.read(offset + 27, header[26]);
  if (lacing == null || lacing.isEmpty) return null;
  var packetLength = 0;
  for (final size in lacing) {
    packetLength += size;
    if (size < 255) break;
  }
  final packet = reader.read(
    offset + 27 + lacing.length,
    packetLength.clamp(0, 64),
  );
  if (packet == null) return null;
  if (_ascii(packet, 0, 8) == 'OpusHead' && packet.length >= 19) {
    return LocalAudioQuality(
      codec: 'opus',
      mimeType: 'audio/ogg',
      channels: packet[9],
      // OpusHead's input sample rate is advisory original-source metadata.
      // Opus's coded playback timebase is 48 kHz, not that input field.
      sampleRate: 48000,
    );
  }
  if (packet.length >= 30 &&
      packet[0] == 1 &&
      _ascii(packet, 1, 6) == 'vorbis') {
    final data = _data(packet);
    if (data.getUint32(7, Endian.little) != 0) return null;
    return LocalAudioQuality.fromMap({
      'codec': 'vorbis',
      'mimeType': 'audio/ogg',
      'channels': packet[11],
      'sampleRate': data.getUint32(12, Endian.little),
      'bitrate': data.getInt32(20, Endian.little),
    });
  }
  return const LocalAudioQuality(mimeType: 'audio/ogg');
}

const _aacRates = [
  96000,
  88200,
  64000,
  48000,
  44100,
  32000,
  24000,
  22050,
  16000,
  12000,
  11025,
  8000,
  7350,
];
const _aacChannels = [0, 1, 2, 3, 4, 5, 6, 8];

LocalAudioQuality? _readMpegAudio(_HeaderReader reader, int offset) {
  final count = (reader.length - offset).clamp(0, 8192);
  final bytes = reader.read(offset, count);
  if (bytes == null) return null;
  for (var i = 0; i + 7 <= bytes.length; i++) {
    if (bytes[i] != 0xff || bytes[i + 1] & 0xe0 != 0xe0) continue;
    final b1 = bytes[i + 1], b2 = bytes[i + 2], b3 = bytes[i + 3];
    if (b1 & 0xf6 == 0xf0) {
      final rateIndex = (b2 >> 2) & 15;
      if (rateIndex >= _aacRates.length) continue;
      final configuration = (b2 & 1) << 2 | b3 >> 6;
      final frameLength =
          (b3 & 3) << 11 | bytes[i + 4] << 3 | bytes[i + 5] >> 5;
      final minimumFrameLength = b1 & 1 == 0 ? 9 : 7;
      if (frameLength < minimumFrameLength ||
          offset + i + frameLength > reader.length) {
        continue;
      }
      return LocalAudioQuality(
        codec: 'aac',
        mimeType: 'audio/aac',
        sampleRate: _aacRates[rateIndex],
        channels: configuration > 0 && configuration < _aacChannels.length
            ? _aacChannels[configuration]
            : null,
      );
    }
    final version = (b1 >> 3) & 3, layer = (b1 >> 1) & 3;
    final rateIndex = (b2 >> 2) & 3, bitrateIndex = b2 >> 4;
    if (version == 1 ||
        layer == 0 ||
        rateIndex == 3 ||
        bitrateIndex == 0 ||
        bitrateIndex == 15) {
      continue;
    }
    final sampleRate =
        [44100, 48000, 32000][rateIndex] ~/
        (version == 3 ? 1 : (version == 2 ? 2 : 4));
    final table = version == 3
        ? (layer == 3
              ? [
                  0,
                  32,
                  64,
                  96,
                  128,
                  160,
                  192,
                  224,
                  256,
                  288,
                  320,
                  352,
                  384,
                  416,
                  448,
                ]
              : (layer == 2
                    ? [
                        0,
                        32,
                        48,
                        56,
                        64,
                        80,
                        96,
                        112,
                        128,
                        160,
                        192,
                        224,
                        256,
                        320,
                        384,
                      ]
                    : [
                        0,
                        32,
                        40,
                        48,
                        56,
                        64,
                        80,
                        96,
                        112,
                        128,
                        160,
                        192,
                        224,
                        256,
                        320,
                      ]))
        : (layer == 3
              ? [
                  0,
                  32,
                  48,
                  56,
                  64,
                  80,
                  96,
                  112,
                  128,
                  144,
                  160,
                  176,
                  192,
                  224,
                  256,
                ]
              : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]);
    final bitrate = table[bitrateIndex] * 1000;
    final channels = b3 >> 6 == 3 ? 1 : 2;
    final frameLength = layer == 3
        ? ((12 * bitrate ~/ sampleRate) + ((b2 >> 1) & 1)) * 4
        : ((version != 3 && layer == 1 ? 72 : 144) * bitrate ~/ sampleRate) +
              ((b2 >> 1) & 1);
    if (frameLength < 4 || offset + i + frameLength > reader.length) continue;
    // A single MPEG frame's bitrate does not establish the song's average.
    // Only an explicit CBR Info marker or complete Xing/VBRI stream counters
    // establish a value; otherwise bitrate deliberately stays unknown.
    final frameEnd = (i + frameLength).clamp(i, bytes.length);
    final frame = bytes.sublist(i, frameEnd);
    final samplesPerFrame = layer == 3
        ? 384
        : (layer == 1 && version != 3 ? 576 : 1152);
    final sideInfo = version == 3
        ? (channels == 1 ? 17 : 32)
        : (channels == 1 ? 9 : 17);
    final markerOffset = 4 + (b1 & 1 == 0 ? 2 : 0) + sideInfo;
    final marker = _ascii(frame, markerOffset, 4);
    int? averageBitrate;
    if ((marker == 'Xing' || marker == 'Info') &&
        frame.length >= markerOffset + 8) {
      final data = _data(frame), flags = data.getUint32(markerOffset + 4);
      if (flags & 3 == 3 && frame.length >= markerOffset + 16) {
        averageBitrate = _mpegAverageBitrate(
          bytes: data.getUint32(markerOffset + 12),
          frames: data.getUint32(markerOffset + 8),
          sampleRate: sampleRate,
          samplesPerFrame: samplesPerFrame,
        );
      } else if (marker == 'Info') {
        averageBitrate = bitrate;
      }
    } else if (_ascii(frame, 36, 4) == 'VBRI' && frame.length >= 54) {
      final data = _data(frame);
      averageBitrate = _mpegAverageBitrate(
        bytes: data.getUint32(46),
        frames: data.getUint32(50),
        sampleRate: sampleRate,
        samplesPerFrame: samplesPerFrame,
      );
    }
    return LocalAudioQuality(
      codec: layer == 1 ? 'mp3' : (layer == 2 ? 'mp2' : 'mp1'),
      mimeType: 'audio/mpeg',
      sampleRate: sampleRate,
      bitrate: averageBitrate,
      channels: channels,
    );
  }
  return null;
}

int? _mpegAverageBitrate({
  required int bytes,
  required int frames,
  required int sampleRate,
  required int samplesPerFrame,
}) => bytes > 0 && frames > 0
    ? (bytes * 8 * sampleRate / (frames * samplesPerFrame)).round()
    : null;

class _Atom {
  const _Atom(this.type, this.payload, this.end);
  final String type;
  final int payload;
  final int end;
}

_Atom? _atom(_HeaderReader reader, int offset, int end) {
  if (offset + 8 > end) return null;
  final header = reader.read(offset, 8);
  if (header == null) return null;
  var size = _data(header).getUint32(0), headerSize = 8;
  if (size == 1) {
    final extended = reader.read(offset + 8, 8);
    if (extended == null) return null;
    size = _data(extended).getUint64(0);
    headerSize = 16;
  } else if (size == 0) {
    size = end - offset;
  }
  if (size < headerSize || offset + size > end) return null;
  return _Atom(_ascii(header, 4, 4), offset + headerSize, offset + size);
}

LocalAudioQuality? _readMp4(_HeaderReader reader) {
  final formats = <LocalAudioQuality>[];
  var boxes = 0;
  void walk(int start, int end, int depth) {
    if (depth > 8) return;
    for (var offset = start; offset + 8 <= end && boxes++ < 512;) {
      final atom = _atom(reader, offset, end);
      if (atom == null) return;
      if (const {'moov', 'trak', 'mdia', 'minf', 'stbl'}.contains(atom.type)) {
        walk(atom.payload, atom.end, depth + 1);
      } else if (atom.type == 'stsd') {
        final header = reader.read(atom.payload, 8);
        if (header == null) return;
        var entryOffset = atom.payload + 8;
        final count = _data(header).getUint32(4).clamp(0, 32);
        for (var i = 0; i < count && boxes++ < 512; i++) {
          final entry = _atom(reader, entryOffset, atom.end);
          if (entry == null) break;
          final quality = _readAudioSampleEntry(reader, entry);
          if (quality != null) formats.add(quality);
          entryOffset = entry.end;
        }
      }
      offset = atom.end;
    }
  }

  walk(0, reader.length, 0);
  // A file can contain multiple audio tracks/sample descriptions. Without
  // knowing the selected decoder track, do not choose one arbitrarily.
  return formats.length == 1
      ? formats.single
      : const LocalAudioQuality(mimeType: 'audio/mp4');
}

LocalAudioQuality? _readAudioSampleEntry(_HeaderReader reader, _Atom entry) {
  if (!const {
    'mp4a',
    'alac',
    'Opus',
    'fLaC',
    '.mp3',
    'mp3 ',
  }.contains(entry.type)) {
    return null;
  }
  final header = reader.read(entry.payload, 28);
  if (header == null || entry.payload + 28 > entry.end) return null;
  final data = _data(header), version = data.getUint16(8);
  String? codec = switch (entry.type) {
    'alac' => 'alac',
    'Opus' => 'opus',
    'fLaC' => 'flac',
    '.mp3' || 'mp3 ' => 'mp3',
    _ => null,
  };
  if (version > 1) {
    return LocalAudioQuality(codec: codec, mimeType: 'audio/mp4');
  }
  var channels = data.getUint16(16);
  var sampleRate = data.getUint32(24) >> 16;
  int? bitrate;
  var offset = entry.payload + (version == 1 ? 44 : 28);
  for (var count = 0; offset + 8 <= entry.end && count < 64; count++) {
    final atom = _atom(reader, offset, entry.end);
    if (atom == null) break;
    if (atom.type == 'esds') {
      final bytes = reader.read(
        atom.payload,
        (atom.end - atom.payload).clamp(0, 4096),
      );
      final config = bytes == null ? null : _decoderConfig(bytes);
      if (config != null) {
        codec = config.codec;
        bitrate = config.bitrate;
        sampleRate = config.sampleRate ?? sampleRate;
        channels = config.channels ?? channels;
      }
    } else if (atom.type == 'dOps') {
      final bytes = reader.read(atom.payload, 11);
      if (bytes != null) channels = bytes[1];
      sampleRate = 48000;
    } else if (atom.type == 'btrt' && bitrate == null) {
      final bytes = reader.read(atom.payload, 12);
      if (bytes != null) bitrate = _data(bytes).getUint32(8);
    }
    offset = atom.end;
  }
  return LocalAudioQuality.fromMap({
    'codec': codec,
    'mimeType': 'audio/mp4',
    'sampleRate': sampleRate,
    'channels': channels,
    'bitrate': bitrate,
  });
}

class _DecoderConfig {
  const _DecoderConfig(
    this.codec,
    this.bitrate,
    this.sampleRate,
    this.channels,
  );
  final String? codec;
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
}

_DecoderConfig? _decoderConfig(Uint8List bytes) {
  _DecoderConfig? walk(int start, int end, int depth) {
    if (depth > 4) return null;
    for (
      var offset = start, count = 0;
      offset + 2 <= end && count < 32;
      count++
    ) {
      final tag = bytes[offset++];
      var length = 0, finished = false;
      for (var i = 0; i < 4 && offset < end; i++) {
        final next = bytes[offset++];
        length = length << 7 | next & 127;
        if (next & 128 == 0) {
          finished = true;
          break;
        }
      }
      if (!finished || offset + length > end) return null;
      final limit = offset + length;
      if (tag == 3 && length >= 3) {
        final flags = bytes[offset + 2];
        var nested = offset + 3;
        if (flags & 128 != 0) nested += 2;
        if (flags & 64 != 0) {
          if (nested >= limit) return null;
          nested += 1 + bytes[nested];
        }
        if (flags & 32 != 0) nested += 2;
        final result = nested <= limit ? walk(nested, limit, depth + 1) : null;
        if (result != null) return result;
      } else if (tag == 4 && length >= 13) {
        final objectType = bytes[offset];
        final codec = switch (objectType) {
          0x40 || 0x66 || 0x67 || 0x68 => 'aac',
          0x69 || 0x6b => 'mp3',
          _ => null,
        };
        final bitrate = _data(bytes).getUint32(offset + 9);
        int? rate, channels;
        final nested = offset + 13;
        if (codec == 'aac' && nested + 2 < limit && bytes[nested] == 5) {
          var pos = nested + 1, configLength = 0;
          for (var i = 0; i < 4 && pos < limit; i++) {
            final next = bytes[pos++];
            configLength = configLength << 7 | next & 127;
            if (next & 128 == 0) break;
          }
          if (pos + configLength <= limit) {
            final config = _aacConfig(
              Uint8List.sublistView(bytes, pos, pos + configLength),
            );
            rate = config?.$1;
            channels = config?.$2;
          }
        }
        return _DecoderConfig(
          codec,
          bitrate > 0 ? bitrate : null,
          rate,
          channels,
        );
      }
      offset = limit;
    }
    return null;
  }

  return bytes.length < 6 ? null : walk(4, bytes.length, 0);
}

(int?, int?)? _aacConfig(Uint8List bytes) {
  var position = 0;
  int? bits(int count) {
    if (position + count > bytes.length * 8) return null;
    var result = 0;
    for (var i = 0; i < count; i++, position++) {
      result =
          result << 1 | ((bytes[position >> 3] >> (7 - (position & 7))) & 1);
    }
    return result;
  }

  int? frequency() {
    final index = bits(4);
    if (index == 15) return bits(24);
    return index != null && index < _aacRates.length ? _aacRates[index] : null;
  }

  var objectType = bits(5);
  if (objectType == 31) {
    final extension = bits(6);
    if (extension == null) return null;
    objectType = extension + 32;
  }
  var rate = frequency();
  final configuration = bits(4);
  int? channels =
      configuration != null &&
          configuration > 0 &&
          configuration < _aacChannels.length
      ? _aacChannels[configuration]
      : null;
  if (objectType == 5 || objectType == 29) {
    rate = frequency() ?? rate;
    if (objectType == 29) channels = 2;
  }
  return (rate, channels);
}
