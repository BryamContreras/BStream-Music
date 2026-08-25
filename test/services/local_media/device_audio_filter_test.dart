import 'package:bstream_music/features/music/domain/entities/device_audio_track.dart';
import 'package:bstream_music/services/local_media/device_audio_filter.dart';
import 'package:bstream_music/services/local_media/device_audio_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('filters messaging audio, recordings, short audio, and BStream paths', () {
    final tracks = <DeviceAudioTrack>[
      _track(
        'song',
        path: r'C:\Music\song.mp3',
        duration: const Duration(minutes: 3),
      ),
      _track(
        'whatsapp',
        path:
            r'C:\Android\media\com.whatsapp\WhatsApp\Media\WhatsApp Audio\a.opus',
        relativePath:
            'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Audio/',
        duration: const Duration(minutes: 2),
      ),
      _track(
        'short',
        path: r'C:\Music\short.m4a',
        duration: const Duration(milliseconds: 29999),
      ),
      _track(
        'telegram',
        relativePath: 'Telegram/Telegram Audio/',
        duration: const Duration(minutes: 2),
      ),
      _track(
        'voice-recorder',
        relativePath: 'Recordings/Voice Recorder/',
        duration: const Duration(minutes: 2),
      ),
      _track(
        'boundary',
        path: r'C:\Music\boundary.m4a',
        duration: const Duration(seconds: 30),
      ),
      _track('unknown-duration', path: r'C:\Music\unknown.m4a'),
      _track('managed', path: r'C:\Downloads\BStream-Music\audio\managed.m4a'),
      _track(
        'similar-root',
        path: r'C:\Downloads\BStream-Music-Other\kept.m4a',
      ),
    ];

    final filtered = filterDeviceAudioTracks(
      tracks,
      bstreamRoot: r'c:\downloads\bstream-music',
    );

    expect(filtered.map((track) => track.id), <String>[
      'song',
      'boundary',
      'unknown-duration',
      'similar-root',
    ]);
  });

  test('individual filters can be disabled', () {
    final tracks = <DeviceAudioTrack>[
      _track(
        'whatsapp',
        relativePath: 'WhatsApp/Media/WhatsApp Voice Notes/',
        duration: const Duration(seconds: 5),
      ),
    ];

    expect(
      filterDeviceAudioTracks(
        tracks,
        options: const DeviceAudioFilterOptions(
          excludeWhatsAppAudio: false,
          excludeTelegramAudio: false,
          excludeAudioRecordings: false,
          excludeShortAudio: false,
        ),
      ),
      tracks,
    );
  });

  test('messaging and recording filters can be selected independently', () {
    final tracks = <DeviceAudioTrack>[
      _track(
        'whatsapp',
        relativePath:
            'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Audio/',
      ),
      _track(
        'telegram',
        relativePath:
            'Android/media/org.telegram.messenger/Telegram/Telegram Voice/',
      ),
      _track('pixel-recorder', relativePath: 'Recordings/'),
      _track('xiaomi-recorder', relativePath: 'MIUI/sound_recorder/'),
      _track('studio-album', relativePath: 'Music/Studio Recordings/'),
    ];

    final filtered = filterDeviceAudioTracks(
      tracks,
      options: const DeviceAudioFilterOptions(
        excludeWhatsAppAudio: false,
        excludeTelegramAudio: true,
        excludeAudioRecordings: true,
        excludeShortAudio: false,
      ),
    );

    expect(filtered.map((track) => track.id), <String>[
      'whatsapp',
      'studio-album',
    ]);
  });

  test('scoped-storage relative paths still exclude the BStream root', () {
    final tracks = <DeviceAudioTrack>[
      _track('managed-relative', relativePath: 'BStream-Music/audio/'),
      _track('similar-relative', relativePath: 'BStream-Music-Other/audio/'),
    ];

    final filtered = filterDeviceAudioTracks(
      tracks,
      bstreamRoot: '/storage/emulated/0/BStream-Music',
    );

    expect(filtered.map((track) => track.id), <String>['similar-relative']);
  });

  test('device track becomes a transient external playback item', () {
    final local =
        _track(
          'local-1',
          artist: 'Device Artist',
          duration: const Duration(minutes: 4),
        ).toTransientLocalTrack(
          unknownArtist: 'Unknown',
          addedAt: DateTime.utc(2026),
        );

    expect(local.id, 'local-1');
    expect(local.artist, 'Device Artist');
    expect(local.isExternal, isTrue);
    expect(local.filePath, 'content://media/local-1');
  });

  test('groups same-named folders by stable folder id', () {
    final folders = groupDeviceAudioTracksByFolder(<DeviceAudioTrack>[
      _track('b', relativePath: 'SD/Music/'),
      DeviceAudioTrack(
        id: 'a',
        uri: 'content://media/a',
        title: 'A',
        folderId: 'other-volume:music',
        folderName: 'Music',
      ),
    ]);

    expect(folders, hasLength(2));
    expect(folders.every((folder) => folder.name == 'Music'), isTrue);
    expect(folders.expand((folder) => folder.tracks), hasLength(2));
  });
}

DeviceAudioTrack _track(
  String id, {
  String? path,
  String? relativePath,
  String? artist,
  Duration? duration,
}) {
  return DeviceAudioTrack(
    id: id,
    uri: 'content://media/$id',
    title: id,
    artist: artist,
    duration: duration,
    folderId: 'folder-$id',
    folderName: 'Music',
    relativePath: relativePath,
    absolutePath: path,
  );
}
