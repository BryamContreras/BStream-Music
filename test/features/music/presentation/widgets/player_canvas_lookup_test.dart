import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/spotify_canvas_provider.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/spotify_canvas/spotify_canvas_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final configuration in [
    (name: 'enabled', enabled: true, active: true, expectedRequests: 1),
    (name: 'disabled', enabled: false, active: true, expectedRequests: 0),
    (name: 'inactive', enabled: true, active: false, expectedRequests: 0),
  ]) {
    testWidgets(
      'player ${configuration.name} handles Canvas with unknown duration',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final resolver = _RecordingCanvasResolver();
        final container = ProviderContainer(
          overrides: [
            databaseServiceProvider.overrideWith(
              (ref) =>
                  throw StateError('Canvas lookup must not use a database'),
            ),
            spotifyCanvasResolverProvider.overrideWithValue(resolver),
            playerServiceProvider.overrideWithValue(_CanvasAudioStub()),
            playerControllerProvider.overrideWith(_CanvasPlayer.new),
            settingsControllerProvider.overrideWith(_CanvasSettings.new),
            playlistsControllerProvider.overrideWith(_CanvasPlaylists.new),
            libraryTracksProvider.overrideWith(
              (ref) async => const <LocalTrack>[],
            ),
            favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: PlayerPanel(
                  active: configuration.active,
                  spotifyCanvasEnabled: configuration.enabled,
                  animatedArtworkEnabled: false,
                  drawBackground: false,
                  trackTransitionsEnabled: false,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(resolver.requests, hasLength(configuration.expectedRequests));
        if (configuration.expectedRequests > 0) {
          expect(
            resolver.requests.single,
            const SpotifyCanvasTrack(
              'vampire',
              'Olivia Rodrigo',
              Duration.zero,
            ),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      // Production deliberately disables remote video on Linux.
      skip: AppPlatform.current == AppPlatformType.linux,
    );
  }
}

const _snapshot = PlayerSnapshot(
  status: PlayerStatus.playing,
  title: 'vampire',
  artist: 'Olivia Rodrigo',
  trackId: 'canvas-lookup-fixture',
);

class _RecordingCanvasResolver extends SpotifyCanvasResolver {
  final requests = <SpotifyCanvasTrack>[];

  @override
  Future<Uri?> resolve(SpotifyCanvasTrack track) async {
    requests.add(track);
    // Test lookup eligibility without network or a native video decoder.
    return null;
  }
}

class _CanvasPlayer extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => _snapshot;
}

class _CanvasSettings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '',
    language: AppLanguage.spanish,
    spotifyCanvasEnabled: true,
  );
}

class _CanvasPlaylists extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => const [];
}

class _CanvasAudioStub implements PlayerService {
  @override
  Stream<PlayerSnapshot> get snapshotStream => Stream.value(_snapshot);

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
