import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_audio_quality.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('known stream details use the requested compact order', () {
    const strings = AppStrings(AppLanguage.spanish);
    expect(
      playbackAudioQualityLabel(
        codec: 'opus',
        sampleRate: 48000,
        bitrate: 141000,
        channels: 2,
        stereoLabel: strings.audioQualityStereo,
      ),
      'Opus · 48 kHz · 141 kbps - Estéreo',
    );
  });

  test('fractional sample rates retain their precision', () {
    for (final sample in [
      (rate: 44100, label: '44.1 kHz'),
      (rate: 22050, label: '22.05 kHz'),
      (rate: 11025, label: '11.025 kHz'),
      (rate: 88200, label: '88.2 kHz'),
      (rate: 96000, label: '96 kHz'),
    ]) {
      expect(playbackAudioQualityLabel(sampleRate: sample.rate), sample.label);
    }
  });

  test('missing or invalid details never infer stereo or a sample rate', () {
    expect(playbackAudioQualityLabel(), isNull);
    expect(
      playbackAudioQualityLabel(
        codec: 'opus',
        sampleRate: 0,
        channels: -1,
        bitrate: -1,
      ),
      'Opus',
    );
    expect(
      playbackAudioQualityLabel(sampleRate: -48000, channels: 0, bitrate: 0),
      isNull,
    );
    expect(playbackAudioQualityLabel(codec: 'opus'), 'Opus');
    expect(playbackAudioQualityLabel(bitrate: 141000), '141 kbps');
    expect(playbackAudioQualityLabel(channels: 2), 'Stereo');
    expect(
      playbackAudioQualityLabel(sampleRate: 44100, channels: 1),
      '44.1 kHz - Mono',
    );
  });

  test(
    'channel count is localized without mislabeling multichannel as stereo',
    () {
      const spanish = AppStrings(AppLanguage.spanish);
      const english = AppStrings(AppLanguage.english);
      expect(
        playbackAudioQualityLabel(
          codec: 'flac',
          channels: 6,
          channelCountLabel: spanish.audioQualityChannels,
        ),
        'FLAC - 6 canales',
      );
      expect(playbackAudioQualityLabel(channels: 8), '8 channels');
      expect(
        playbackAudioQualityLabel(channels: 1, monoLabel: 'Single channel'),
        'Single channel',
      );
      expect(spanish.audioQualityStereo, 'Estéreo');
      expect(english.audioQualityStereo, 'Stereo');
      expect(spanish.audioQualityMono, 'Mono');
      expect(english.audioQualityChannels(6), '6 channels');
    },
  );

  test('codec priority and existing format-only fallbacks are preserved', () {
    expect(
      playbackAudioQualityLabel(codec: 'mp4a.40.2', extension: 'webm'),
      'AAC',
    );
    expect(
      playbackAudioQualityLabel(mimeType: 'audio/flac', sampleRate: 44100),
      'FLAC · 44.1 kHz',
    );
    expect(
      playbackAudioQualityLabel(
        localSource: r'C:\Music\song.mp3',
        bitrate: 320000,
      ),
      'MP3 · 320 kbps',
    );
    expect(playbackAudioQualityLabel(extension: '.m4a'), 'M4A');
  });

  test('known native and desktop codec names remain visible', () {
    for (final (codec, label) in [
      ('AC-3', 'AC-3'),
      ('E-AC-3', 'E-AC-3'),
      ('AMR', 'AMR'),
      ('AMR-WB', 'AMR-WB'),
      ('mp1', 'MP1'),
      ('mp2', 'MP2'),
      ('alaw', 'A-law'),
      ('mulaw', '\u00b5-law'),
    ]) {
      expect(playbackAudioQualityLabel(codec: codec), label);
      expect(
        playbackAudioQualityLabel(codec: codec, sampleRate: 48000),
        '$label · 48 kHz',
      );
    }
  });

  test('unknown codecs do not become plausible-looking invented labels', () {
    for (final codec in ['ac-3-unknown', 'amr-mystery', 'mp2x', 'unknown']) {
      expect(playbackAudioQualityLabel(codec: codec), isNull);
      expect(
        playbackAudioQualityLabel(codec: codec, sampleRate: 44100),
        '44.1 kHz',
      );
    }
  });
}
