import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/spotify_canvas/spotify_canvas_resolver.dart';

final spotifyCanvasResolverProvider = Provider<SpotifyCanvasResolver>(
  (ref) => SpotifyCanvasResolver(),
);

final spotifyCanvasUrlProvider = FutureProvider.autoDispose
    .family<Uri?, SpotifyCanvasTrack>((ref, track) async {
      if (track.duration <= Duration.zero) {
        // Native desktop decoders may publish title/artist before duration,
        // or never report duration for some streams. Allow the latter too,
        // while avoiding two requests when metadata arrives during startup.
        final ready = Completer<void>();
        final timer = Timer(const Duration(milliseconds: 400), ready.complete);
        ref.onDispose(() {
          timer.cancel();
          if (!ready.isCompleted) ready.complete();
        });
        await ready.future;
        if (!ref.mounted) return null;
      }
      return ref.read(spotifyCanvasResolverProvider).resolve(track);
    });
