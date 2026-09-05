import 'dart:async';

import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/sharing/bstream_track_link.dart';
import 'package:bstream_music/services/sharing/incoming_track_link_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ignores invalid links and removes only immediate duplicate activations',
    () async {
      final service = _FakeIncomingTrackLinkService();
      final container = ProviderContainer(
        overrides: [
          incomingTrackLinkServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(service.close);

      final emitted = <BStreamTrackLink>[];
      final subscription = container.listen<AsyncValue<BStreamTrackLink>>(
        incomingTrackLinkProvider,
        (_, next) => next.whenData(emitted.add),
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await pumpEventQueue();

      service.add(Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'));
      await pumpEventQueue();
      expect(
        emitted,
        isEmpty,
        reason: 'ordinary YouTube links are not app links',
      );

      service.add(Uri.parse('bstreammusic://track/dQw4w9WgXcQ'));
      await pumpEventQueue();
      expect(emitted.map((link) => link.videoId), ['dQw4w9WgXcQ']);

      service.add(Uri.parse('bstreammusic://track/dQw4w9WgXcQ'));
      await pumpEventQueue();
      expect(emitted.map((link) => link.videoId), [
        'dQw4w9WgXcQ',
      ], reason: 'cold/warm duplicate delivery must not autoplay twice');

      service.add(Uri.parse('bstreammusic://track/M7lc1UVf-VE'));
      await pumpEventQueue();
      expect(emitted.map((link) => link.videoId), [
        'dQw4w9WgXcQ',
        'M7lc1UVf-VE',
      ], reason: 'deduplication must not discard a different song');
    },
  );
}

final class _FakeIncomingTrackLinkService implements IncomingTrackLinkService {
  final StreamController<Uri> _controller = StreamController<Uri>();

  @override
  Stream<Uri> get links => _controller.stream;

  void add(Uri uri) => _controller.add(uri);

  Future<void> close() => _controller.close();
}
