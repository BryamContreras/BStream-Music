import 'dart:async';
import 'dart:typed_data';

import 'package:bstream_music/services/jiosaavn/jiosaavn_audio_format_probe.dart';
import 'package:bstream_music/services/jiosaavn/jiosaavn_http_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mp4_fixture.dart';

final _uri = Uri.parse('https://aac.saavncdn.com/fixture_320.mp4');
const _length = 7200000;

void main() {
  test(
    'a complete moov reuses the prefix and reports actual AAC details',
    () async {
      final prefix = mp4Prefix(moov: aacMoov());
      final transport = _Ranges();
      final result = await probeJioSaavnAudioFormat(
        _uri,
        transport: transport,
        prefix: _response(prefix),
        fileLength: _length,
        shouldContinue: () => true,
      );
      expect(result?.codec, 'aac');
      expect(result?.sampleRate, 44100);
      expect(result?.channels, 2);
      expect(result?.bitrate, 312999);
      expect(transport.requests, isEmpty);
    },
  );

  test('a tail moov seeks over mdat and preserves mono and 48 kHz', () async {
    final moov = aacMoov(config: [0x11, 0x88]); // AAC-LC, 48 kHz, mono.
    final offset = _length - moov.length;
    final transport = _Ranges(moov: moov, offset: offset);
    final result = await probeJioSaavnAudioFormat(
      _uri,
      transport: transport,
      prefix: _response(mp4Prefix(tailOffset: offset)),
      fileLength: _length,
      shouldContinue: () => true,
    );
    expect(result?.sampleRate, 48000);
    expect(result?.channels, 1);
    expect(transport.requests, hasLength(2));
    expect(transport.requests.every((request) => request.$1 >= offset), isTrue);
    expect(
      transport.requests.fold(4096, (int n, item) => n + item.$2),
      lessThanOrEqualTo(256 * 1024),
    );
  });

  test(
    'a partial fast-start moov fetches only bytes absent from the prefix',
    () async {
      final moov = Uint8List.fromList(
        mp4Atom('moov', [
          ...mp4Atom('free', Uint8List(5000)),
          ...aacMoov().sublist(8),
        ]),
      );
      final initial = mp4Prefix();
      const offset = 24;
      initial.setRange(offset, initial.length, moov);
      final transport = _Ranges(moov: moov, offset: offset);
      final result = await probeJioSaavnAudioFormat(
        _uri,
        transport: transport,
        prefix: _response(initial),
        fileLength: _length,
        shouldContinue: () => true,
      );
      expect(result?.channels, 2);
      expect(transport.requests, [(4096, moov.length - (4096 - offset))]);
    },
  );

  test(
    'untrusted ranges and oversized moov leave optional facts unknown',
    () async {
      for (final mode in ['ignored', 'wrong-total', 'oversized', 'throws']) {
        final moov = mode == 'oversized'
            ? Uint8List.fromList([...mp4Uint32(300000), ...'moov'.codeUnits])
            : aacMoov();
        const offset = 6500000;
        final transport = _Ranges(moov: moov, offset: offset, mode: mode);
        final result = await probeJioSaavnAudioFormat(
          _uri,
          transport: transport,
          prefix: _response(mp4Prefix(tailOffset: offset)),
          fileLength: _length,
          shouldContinue: () => true,
        );
        expect(result, isNull, reason: mode);
        expect(transport.requests, hasLength(1), reason: mode);
      }
    },
  );

  test('obsolete work stops before any additional header request', () async {
    final transport = _Ranges();
    final result = await probeJioSaavnAudioFormat(
      _uri,
      transport: transport,
      prefix: _response(mp4Prefix(tailOffset: 6500000)),
      fileLength: _length,
      shouldContinue: () => false,
    );
    expect(result, isNull);
    expect(transport.requests, isEmpty);
  });

  test('an exhausted range deadline stops further optional requests', () async {
    final transport = _Ranges(
      moov: aacMoov(),
      offset: 6500000,
      mode: 'timeout',
    );
    final result = await probeJioSaavnAudioFormat(
      _uri,
      transport: transport,
      prefix: _response(mp4Prefix(tailOffset: 6500000)),
      fileLength: _length,
      shouldContinue: () => true,
    );
    expect(result, isNull);
    expect(transport.requests, hasLength(1));
    expect(transport.timeouts.single, isNotNull);
    expect(
      transport.timeouts.single,
      lessThanOrEqualTo(const Duration(seconds: 2)),
    );
  });
}

JioSaavnHttpResponse _response(Uint8List bytes) => JioSaavnHttpResponse(
  statusCode: 206,
  body: bytes,
  headers: {'content-range': 'bytes 0-${bytes.length - 1}/$_length'},
);

class _Ranges implements JioSaavnHttpTransport {
  _Ranges({this.moov, this.offset = 0, this.mode});
  final Uint8List? moov;
  final int offset;
  final String? mode;
  final requests = <(int, int)>[];
  final timeouts = <Duration?>[];

  @override
  Future<JioSaavnHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maximumBytes = 512 * 1024,
    bool readPrefix = false,
    Duration? timeout,
  }) async {
    final range = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(headers['Range']!)!;
    final start = int.parse(range.group(1)!), end = int.parse(range.group(2)!);
    final count = end - start + 1;
    requests.add((start, count));
    timeouts.add(timeout);
    expect(
      headers.keys.any(
        (key) => key.contains('Forwarded') || key.contains('Real-IP'),
      ),
      isFalse,
    );
    expect(maximumBytes, count);
    expect(readPrefix, isTrue);
    if (mode == 'throws') throw StateError('Header unavailable');
    if (mode == 'timeout') throw TimeoutException('Header deadline', timeout);
    expect(start, greaterThanOrEqualTo(offset));
    final bytes = Uint8List.sublistView(
      moov!,
      start - offset,
      end - offset + 1,
    );
    return JioSaavnHttpResponse(
      statusCode: mode == 'ignored' ? 200 : 206,
      body: bytes,
      headers: {
        'content-range':
            'bytes $start-$end/${mode == 'wrong-total' ? 9000000 : _length}',
      },
    );
  }

  @override
  Future<void> close() async {}
}
