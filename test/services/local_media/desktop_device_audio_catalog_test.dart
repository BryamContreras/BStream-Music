import 'dart:io';
import 'dart:typed_data';

import 'package:bstream_music/services/local_media/desktop_device_audio_catalog.dart';
import 'package:bstream_music/services/local_media/device_audio_catalog.dart';
import 'package:bstream_music/services/local_media/device_audio_filter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('scans Music recursively and prunes the managed BStream root', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'bstream-device-audio-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final music = Directory(p.join(temporary.path, 'Music'));
    final album = Directory(p.join(music.path, 'Album'));
    final managed = Directory(
      p.join(music.path, 'Downloads', 'BStream-Music', 'audio'),
    );
    await album.create(recursive: true);
    await managed.create(recursive: true);
    await File(
      p.join(album.path, 'Artist - Clear Title.mp3'),
    ).writeAsBytes(const <int>[1]);
    await File(p.join(album.path, 'ignore.txt')).writeAsString('not audio');
    await File(
      p.join(managed.path, 'Managed - Hidden.m4a'),
    ).writeAsBytes(const <int>[1]);

    var rootsCalls = 0;
    final catalog = DesktopDeviceAudioCatalog(() async {
      rootsCalls += 1;
      return <Directory>[music];
    });
    final result = await catalog.load(
      bstreamRoot: p.join(music.path, 'Downloads', 'BStream-Music'),
    );

    expect(result.status, DeviceAudioPermissionStatus.notRequired);
    expect(result.tracks, hasLength(1));
    final track = result.tracks.single;
    expect(track.title, 'Clear Title');
    expect(track.artist, 'Artist');
    expect(track.folderName, 'Album');
    expect(track.relativePath, 'Album');
    expect(track.duration, isNull);
    expect(track.uri, p.join(album.path, 'Artist - Clear Title.mp3'));

    await catalog.load();
    expect(rootsCalls, 2, reason: 'changing the excluded root rescans safely');
    await catalog.load();
    expect(rootsCalls, 2, reason: 'the raw session snapshot is reused');
    await catalog.refresh();
    expect(rootsCalls, 3, reason: 'only refresh forces a new filesystem scan');
  });

  test(
    'reads desktop duration without loading audio into the catalog',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'bstream-device-audio-metadata-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final music = Directory(p.join(temporary.path, 'Music'));
      await music.create(recursive: true);
      await File(
        p.join(music.path, 'Tone.wav'),
      ).writeAsBytes(_pcmWave(duration: const Duration(seconds: 2)));

      final result = await DesktopDeviceAudioCatalog(
        () async => <Directory>[music],
      ).load(options: const DeviceAudioFilterOptions(excludeShortAudio: false));

      expect(result.tracks, hasLength(1));
      expect(result.tracks.single.title, 'Tone');
      expect(result.tracks.single.duration, const Duration(seconds: 2));
    },
  );
}

Uint8List _pcmWave({required Duration duration}) {
  const sampleRate = 8000;
  const channelCount = 1;
  const bitsPerSample = 8;
  const blockAlign = channelCount * bitsPerSample ~/ 8;
  const byteRate = sampleRate * blockAlign;
  final dataLength = byteRate * duration.inMilliseconds ~/ 1000;
  final data = ByteData(44 + dataLength);

  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      data.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channelCount, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, byteRate, Endian.little);
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  return data.buffer.asUint8List();
}
