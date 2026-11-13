import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/core/widgets/marquee_text.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/audio_source_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/local_audio_quality_provider.dart';
import 'package:bstream_music/features/music/presentation/widgets/animated_artwork_motion.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_controls_capsule.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_dismiss_region.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_gradient_background.dart';
import 'package:bstream_music/features/music/presentation/providers/artwork_progress_color_provider.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/features/music/presentation/widgets/uniform_playback_slider_track_shape.dart';
import 'package:bstream_music/features/music/presentation/widgets/wavy_playback_seek_bar.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/player/local_audio_quality_service.dart';
import 'package:bstream_music/services/sharing/track_share_service.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const trackId = 'player-controls-track';
  final localTrack = LocalTrack(
    id: trackId,
    title: 'Cancion de prueba',
    artist: 'BStream Music',
    filePath: '/tmp/player-controls-track.m4a',
    addedAt: DateTime(2026),
  );
  const snapshot = PlayerSnapshot(
    status: PlayerStatus.paused,
    title: 'Cancion de prueba',
    artist: 'BStream Music',
    trackId: trackId,
    duration: Duration(minutes: 3),
    volume: 0.72,
  );

  for (final style in [
    PlayerStyle.bstreamMusic,
    PlayerStyle.spotifyMusic,
    PlayerStyle.classicVinyl,
  ]) {
    testWidgets(
      '${style.name} balances transport between progress and utilities',
      (tester) async {
        for (final frame in const [
          (platform: TargetPlatform.android, size: Size(390, 844)),
          (platform: TargetPlatform.iOS, size: Size(390, 844)),
          (platform: TargetPlatform.android, size: Size(320, 568)),
          (platform: TargetPlatform.windows, size: Size(960, 720)),
          (platform: TargetPlatform.windows, size: Size(1440, 900)),
        ]) {
          _configureView(tester, frame.size);
          await tester.pumpWidget(
            _playerHarness(
              key: ValueKey('balanced-$style-$frame'),
              platform: frame.platform,
              snapshot: snapshot,
              localTrack: localTrack,
              playlists: _TestPlaylistsController(),
              style: style,
              disableAnimations: true,
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          final progress = style == PlayerStyle.bstreamMusic
              ? find.byType(WavyPlaybackSeekBar)
              : find.byKey(
                  ValueKey(
                    style == PlayerStyle.spotifyMusic
                        ? 'spotify-player-linear-seek'
                        : 'classic-vinyl-player-linear-seek',
                  ),
                );
          final lineY = tester.getRect(progress).center.dy;
          final primary = tester.getRect(
            find.byKey(const ValueKey('player-primary-control')),
          );
          final utility = tester.getRect(
            find.byKey(const ValueKey('player-utility-controls')),
          );
          expect(primary.top, greaterThanOrEqualTo(lineY));
          expect(primary.bottom, lessThanOrEqualTo(utility.top));
          expect(
            primary.center.dy,
            closeTo((lineY + utility.top) / 2, frame.size.height < 650 ? 9 : 3),
            reason: '$style / $frame should visually center the transport row',
          );
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'Spotify Style uses circular playback actions and opens the mobile queue',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      final controller = _TestPlayerController(snapshot);
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
          style: PlayerStyle.spotifyMusic,
          playbackQueue: const PlaybackQueueState(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final primary = find.byKey(const ValueKey('player-primary-control'));
      expect(
        find.byKey(const ValueKey('player-utility-capsule')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('player-utility-controls')),
        findsOneWidget,
      );
      final primaryButton = tester.widget<IconButton>(primary);
      expect(primaryButton.style!.shape!.resolve({}), isA<CircleBorder>());
      expect(
        primaryButton.style!.backgroundColor!.resolve({}),
        isNot(Colors.transparent),
      );
      await tester.tap(primary);
      await tester.pump();
      expect(controller.togglePlayPauseCalls, 1);
      await tester.tap(find.byKey(const ValueKey('player-next-control')));
      await tester.pump();
      expect(controller.playNextCalls, 1);
      await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('queue-close')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('queue-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.byKey(const ValueKey('spotify-player-layout')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final frame in const [
      (size: Size(390, 820), topPadding: 44.0),
      (size: Size(320, 568), topPadding: 56.0),
    ]) {
      testWidgets(
        '$platform Spotify expands its cover under the status bar over a full viewport backdrop at ${frame.size.width.toInt()}px',
        (tester) async {
          const bottomPadding = 24.0;
          _configureView(
            tester,
            frame.size,
            topPadding: frame.topPadding,
            bottomPadding: bottomPadding,
          );
          final trackWithArtwork = LocalTrack(
            id: trackId,
            title: 'Cancion de prueba',
            artist: 'BStream Music',
            filePath: '/tmp/player-controls-track.m4a',
            thumbnailPath: '/tmp/spotify-expanded-cover.jpg',
            addedAt: DateTime(2026),
          );
          final measurements =
              <
                PlayerArtworkStyle,
                ({Rect artwork, Rect title, Rect primary})
              >{};

          for (final artworkStyle in PlayerArtworkStyle.values) {
            await tester.pumpWidget(
              _playerHarness(
                key: ValueKey('spotify-$platform-${frame.size}-$artworkStyle'),
                platform: platform,
                snapshot: snapshot,
                localTrack: trackWithArtwork,
                playlists: _TestPlaylistsController(),
                style: PlayerStyle.spotifyMusic,
                artworkStyle: artworkStyle,
                drawBackground: true,
                disableAnimations: true,
                brightness: Brightness.light,
                onCollapse: () {},
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));

            final artwork = find.byKey(const ValueKey('player-large-artwork'));
            final primary = find.byKey(
              const ValueKey('player-primary-control'),
            );
            measurements[artworkStyle] = (
              artwork: tester.getRect(artwork),
              title: tester.getRect(
                find.byKey(const ValueKey('player-track-title')),
              ),
              primary: tester.getRect(primary),
            );
            final hero = find.byKey(
              const ValueKey('player-expanded-artwork-hero'),
            );
            final backdrop = find.byType(PlaybackArtworkBackdrop);
            final backdropWidget = tester.widget<PlaybackArtworkBackdrop>(
              backdrop,
            );
            if (artworkStyle == PlayerArtworkStyle.classic) {
              expect(hero, findsNothing);
              expect(backdropWidget.reflectionArtworkRect, isNull);
              expect(tester.getRect(artwork).left, greaterThan(0));
              expect(tester.getRect(artwork).right, lessThan(frame.size.width));
            } else {
              expect(hero, findsOneWidget);
              final heroRect = tester.getRect(hero);
              expect(heroRect.left, closeTo(0, 0.001));
              expect(heroRect.right, closeTo(frame.size.width, 0.001));
              expect(heroRect.top, closeTo(frame.topPadding - 24, 0.001));
              expect(heroRect.bottom, lessThanOrEqualTo(frame.size.height));
              final focusedImageRect = tester.getRect(
                find.byKey(
                  const ValueKey('player-expanded-artwork-focused-image'),
                ),
              );
              expect(focusedImageRect.width, greaterThan(frame.size.width));
              expect(
                focusedImageRect.width,
                closeTo(focusedImageRect.height, 0.001),
              );
              expect(
                focusedImageRect.top,
                closeTo(frame.topPadding - 24, 0.001),
              );
              expect(backdropWidget.reflectionArtworkRect, isNotNull);
              final reflectedImageRect = backdropWidget.reflectionArtworkRect!
                  .shift(tester.getRect(backdrop).topLeft);
              for (final edges in [
                (reflectedImageRect.left, focusedImageRect.left),
                (reflectedImageRect.top, focusedImageRect.top),
                (reflectedImageRect.right, focusedImageRect.right),
                (reflectedImageRect.bottom, focusedImageRect.bottom),
              ]) {
                expect(edges.$1, closeTo(edges.$2, 0.001));
              }
              expect(
                find.byKey(const ValueKey('player-expanded-artwork-blur')),
                findsNothing,
              );
              expect(
                find.byKey(const ValueKey('player-artwork-presentation-scale')),
                findsNothing,
              );
            }

            expect(
              tester
                  .getRect(find.byKey(const ValueKey('spotify-player-grabber')))
                  .top,
              greaterThanOrEqualTo(frame.topPadding),
            );
            expect(
              Theme.of(tester.element(primary)).brightness,
              Brightness.dark,
            );
            expect(
              tester.widget<IconButton>(primary).style!.shape!.resolve({}),
              isA<CircleBorder>(),
            );
            expect(
              find.byKey(const ValueKey('player-utility-capsule')),
              findsNothing,
            );
            for (final key in [
              'player-primary-control',
              'player-utility-controls',
            ]) {
              final control = find.byKey(ValueKey(key));
              await tester.ensureVisible(control);
              await tester.pump();
              final rect = tester.getRect(control);
              expect(rect.top, greaterThanOrEqualTo(frame.topPadding));
              expect(
                rect.bottom,
                lessThanOrEqualTo(frame.size.height - bottomPadding + 0.1),
              );
            }
            expect(tester.takeException(), isNull);
          }

          final classic = measurements[PlayerArtworkStyle.classic]!;
          final expanded = measurements[PlayerArtworkStyle.expanded]!;
          expect(expanded.artwork, classic.artwork);
          expect(expanded.title, classic.title);
          expect(expanded.primary, classic.primary);
        },
      );
    }
  }

  testWidgets('Spotify keeps expanded artwork bounded outside phone portrait', (
    tester,
  ) async {
    _configureView(tester, const Size(820, 390));
    final trackWithArtwork = LocalTrack(
      id: trackId,
      title: 'Cancion de prueba',
      artist: 'BStream Music',
      filePath: '/tmp/player-controls-track.m4a',
      thumbnailPath: '/tmp/spotify-expanded-bounded-cover.jpg',
      addedAt: DateTime(2026),
    );

    for (final scenario in const [
      (platform: TargetPlatform.android, size: Size(820, 390)),
      (platform: TargetPlatform.android, size: Size(768, 1024)),
      (platform: TargetPlatform.windows, size: Size(1280, 900)),
      (platform: TargetPlatform.windows, size: Size(720, 1100)),
    ]) {
      tester.view.physicalSize = scenario.size;
      await tester.pumpWidget(
        _playerHarness(
          key: ValueKey('spotify-expanded-bounded-$scenario'),
          platform: scenario.platform,
          snapshot: snapshot,
          localTrack: trackWithArtwork,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.spotifyMusic,
          artworkStyle: PlayerArtworkStyle.expanded,
          drawBackground: true,
          disableAnimations: true,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final layout = find.byKey(const ValueKey('spotify-player-layout'));
      expect(layout, findsOneWidget);
      expect(
        find.descendant(
          of: layout,
          matching: find.byKey(const ValueKey('player-expanded-artwork-hero')),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<PlaybackArtworkBackdrop>(
              find.descendant(
                of: layout,
                matching: find.byType(PlaybackArtworkBackdrop),
              ),
            )
            .reflectionArtworkRect,
        isNull,
      );
      final scaleFinder = find.descendant(
        of: layout,
        matching: find.byKey(
          const ValueKey('player-artwork-presentation-scale'),
        ),
      );
      final scale = tester
          .widget<Transform>(scaleFinder)
          .transform
          .getMaxScaleOnAxis();
      expect(scale, inInclusiveRange(1.0, 1.181));
      final artworkRect = tester.getRect(scaleFinder);
      expect(artworkRect.left, greaterThanOrEqualTo(0));
      expect(artworkRect.top, greaterThanOrEqualTo(0));
      expect(artworkRect.right, lessThanOrEqualTo(scenario.size.width));
      expect(artworkRect.bottom, lessThanOrEqualTo(scenario.size.height));
      for (final key in ['player-primary-control', 'player-utility-controls']) {
        final control = find.byKey(ValueKey(key));
        await tester.ensureVisible(control);
        await tester.pump();
        final rect = tester.getRect(control);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(scenario.size.height));
      }
      expect(tester.takeException(), isNull, reason: '$scenario');
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'Spotify seek thumb stays visible and commits a drag once in $brightness',
      (tester) async {
        _configureView(tester, const Size(390, 820));
        final controller = _TestPlayerController(snapshot);
        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            playerController: controller,
            style: PlayerStyle.spotifyMusic,
            brightness: brightness,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final seek = find.byKey(const ValueKey('spotify-player-linear-seek'));
        final theme = SliderTheme.of(tester.element(seek));
        final thumb = theme.thumbShape! as RoundSliderThumbShape;
        expect(thumb.enabledThumbRadius, greaterThan(0));
        expect(theme.thumbColor!.a, 1);
        final rect = tester.getRect(seek);
        final gesture = await tester.startGesture(
          Offset(rect.left + 12, rect.center.dy),
        );
        await gesture.moveTo(Offset(rect.center.dx, rect.center.dy));
        await tester.pump();
        expect(controller.seekCalls, 0);
        await gesture.up();
        await tester.pump();
        expect(controller.seekCalls, 1);
        expect(controller.lastSeek, isNotNull);
        expect(controller.lastSeek!, greaterThan(Duration.zero));
        expect(tester.takeException(), isNull);
      },
    );
  }

  const qualityTrack = TrackInfo(
    id: 'quality0001',
    title: 'Calidad de audio',
    artist: 'Artista de prueba',
    url: 'https://www.youtube.com/watch?v=quality0001',
    streamUrl: 'https://example.invalid/quality.webm',
    streamCodec: 'opus',
    streamMimeType: 'audio/webm',
    streamExtension: 'webm',
    streamBitrate: 141000,
    streamSampleRate: 48000,
    streamChannels: 2,
  );
  const qualitySnapshot = PlayerSnapshot(
    status: PlayerStatus.paused,
    title: 'Calidad de audio',
    artist: 'Artista de prueba',
    trackId: 'quality0001',
    sourceUrl: 'https://www.youtube.com/watch?v=quality0001',
    duration: Duration(minutes: 3),
    isRemote: true,
  );
  const stereoQuality = 'Opus \u00b7 48 kHz \u00b7 141 kbps - Est\u00e9reo';

  for (final style in PlayerStyle.values) {
    testWidgets('${style.name} shows headphone quality in its time row', (
      tester,
    ) async {
      _configureView(tester, const Size(600, 900));
      final active = qualitySnapshot.copyWith(queueEntryId: 'quality-entry');
      final player = _TestPlayerController(
        active,
        canonicalRemoteTrack: qualityTrack.copyWith(streamSource: 'innerTube'),
      );
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: active,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: player,
          style: style,
          showAudioQuality: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final tier = find.byKey(const ValueKey('player-audio-quality-tier'));
      expect(tester.widget<Text>(tier).data, 'Calidad estándar');
      final provider = find.byKey(
        const ValueKey('player-audio-quality-source'),
      );
      // Vinyl reserves a narrower lane for its controls even on tall screens.
      if (style == PlayerStyle.classicVinyl) {
        expect(provider, findsNothing);
      } else {
        expect(tester.widget<Text>(provider).data, '\u00b7 YouTube Music');
      }
      final capsule = find.byKey(
        const ValueKey('player-audio-quality-capsule'),
      );
      expect(tester.widget(capsule), isA<PlayerControlsCapsule>());
      expect(find.descendant(of: capsule, matching: tier), findsOneWidget);
      final headphones = find.byKey(
        const ValueKey('player-audio-quality-headphones'),
      );
      expect(tester.widget<Icon>(headphones).icon, Icons.headphones_rounded);
      expect(
        tester.getCenter(headphones).dx,
        lessThan(tester.getTopLeft(tier).dx),
      );
      final position = find.byKey(
        ValueKey(
          style == PlayerStyle.bstreamMusic
              ? 'player-position'
              : 'apple-player-position',
        ),
      );
      final duration = find.byKey(
        ValueKey(
          style == PlayerStyle.bstreamMusic
              ? 'player-duration'
              : 'apple-player-duration',
        ),
      );
      final timeRow = find.byKey(const ValueKey('player-timeline-time-row'));
      expect(find.descendant(of: timeRow, matching: capsule), findsOneWidget);
      expect(
        tester.getCenter(capsule).dy,
        closeTo(tester.getCenter(duration).dy, .1),
      );
      expect(
        tester.getCenter(capsule).dy,
        closeTo(tester.getCenter(position).dy, .1),
      );
      expect(
        tester.getTopLeft(capsule).dx,
        greaterThan(tester.getTopRight(position).dx),
      );
      expect(
        tester.getTopRight(capsule).dx,
        lessThan(tester.getTopLeft(duration).dx),
      );
      expect(
        find.descendant(of: capsule, matching: find.byType(BackdropFilter)),
        findsNothing,
      );
      final progress = switch (style) {
        PlayerStyle.bstreamMusic => find.byType(WavyPlaybackSeekBar),
        PlayerStyle.appleMusic => find.byKey(
          const ValueKey('apple-player-linear-seek'),
        ),
        PlayerStyle.classicVinyl => find.byKey(
          const ValueKey('classic-vinyl-player-linear-seek'),
        ),
        PlayerStyle.spotifyMusic => find.byKey(
          const ValueKey('spotify-player-linear-seek'),
        ),
      };
      if (style == PlayerStyle.bstreamMusic ||
          style == PlayerStyle.classicVinyl) {
        expect(
          tester.getBottomLeft(timeRow).dy,
          lessThanOrEqualTo(tester.getTopLeft(progress).dy),
        );
      } else {
        expect(
          tester.getTopLeft(timeRow).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(progress).dy),
        );
      }

      player.canonicalRemoteTrack = qualityTrack.copyWith(
        streamCodec: 'mp4a.40.2',
        streamMimeType: 'audio/mp4',
        streamBitrate: 320000,
        streamSource: 'jioSaavn',
      );
      player.emit(active.copyWith(position: const Duration(seconds: 1)));
      await tester.pump();
      expect(tester.widget<Text>(tier).data, 'Alta calidad');
      if (provider.evaluate().isNotEmpty) {
        expect(tester.widget<Text>(provider).data, '\u00b7 JioSaavn');
      }
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerPanel)),
      );
      final upgrades = container.read(
        audioQualityUpgradeStateProvider.notifier,
      );
      upgrades.begin('obsolete-entry');
      await tester.pump();
      final improving = find.byKey(
        const ValueKey('player-audio-quality-upgrading'),
      );
      expect(improving, findsNothing);
      upgrades.begin('quality-entry');
      await tester.pump();
      expect(improving, findsOneWidget);
      expect(tester.widget<Text>(improving).data, 'Mejorando calidad…');

      await container
          .read(settingsControllerProvider.notifier)
          .setShowAudioQuality(false);
      await tester.pump();
      expect(tier, findsNothing);
      expect(improving, findsOneWidget);
      player.emit(active.copyWith(queueEntryId: 'next-entry'));
      await tester.pump();
      expect(improving, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final variant in const [
    (size: Size(320, 568), textScale: 1.0),
    (size: Size(320, 568), textScale: 2.0),
    (size: Size(568, 320), textScale: 1.5),
  ]) {
    testWidgets(
      'time-row quality capsule fits ${variant.size} at ${variant.textScale}',
      (tester) async {
        _configureView(
          tester,
          variant.size,
          textScaleFactor: variant.textScale,
        );
        for (final style in PlayerStyle.values) {
          final active = qualitySnapshot.copyWith(
            queueEntryId: 'compact-quality',
          );
          final player = _TestPlayerController(
            active,
            canonicalRemoteTrack: qualityTrack.copyWith(
              streamSource: 'innerTube',
            ),
          );
          await tester.pumpWidget(
            _playerHarness(
              key: ValueKey('${style.name}-${variant.size}'),
              platform: TargetPlatform.android,
              snapshot: active,
              localTrack: localTrack,
              playlists: _TestPlaylistsController(),
              playerController: player,
              style: style,
              showAudioQuality: true,
              disableAnimations: true,
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          final capsule = find.byKey(
            const ValueKey('player-audio-quality-capsule'),
          );
          final capsuleRect = tester.getRect(capsule);
          expect(capsuleRect.left, greaterThanOrEqualTo(0), reason: '$style');
          expect(
            capsuleRect.right,
            lessThanOrEqualTo(variant.size.width),
            reason: '$style',
          );
          expect(find.byIcon(Icons.headphones_rounded), findsOneWidget);
          final timeRow = find.byKey(
            const ValueKey('player-timeline-time-row'),
          );
          final inlineCapsule = find.descendant(of: timeRow, matching: capsule);
          if (variant.textScale < 2) {
            expect(inlineCapsule, findsOneWidget, reason: '$style');
          }
          final duration = find.byKey(
            ValueKey(
              style == PlayerStyle.bstreamMusic
                  ? 'player-duration'
                  : 'apple-player-duration',
            ),
          );
          if (inlineCapsule.evaluate().isNotEmpty) {
            expect(
              tester.getCenter(capsule).dy,
              closeTo(tester.getCenter(duration).dy, .1),
              reason: '$style',
            );
          } else {
            expect(
              capsuleRect.top,
              greaterThanOrEqualTo(tester.getBottomLeft(timeRow).dy),
              reason: 'Large text keeps the clock labels readable in $style',
            );
          }
          expect(tester.takeException(), isNull, reason: '$style');
          final container = ProviderScope.containerOf(
            tester.element(find.byType(PlayerPanel)),
          );
          container
              .read(audioQualityUpgradeStateProvider.notifier)
              .begin('compact-quality');
          await tester.pump();
          expect(
            find.byKey(const ValueKey('player-audio-quality-upgrading')),
            findsOneWidget,
          );
          expect(
            tester.getRect(capsule).width,
            lessThanOrEqualTo(variant.size.width),
            reason: '$style',
          );
          expect(tester.takeException(), isNull, reason: '$style');
        }
      },
    );
  }

  for (final variant in const [
    (platform: TargetPlatform.android, size: Size(390, 820)),
    (platform: TargetPlatform.android, size: Size(360, 640)),
    (platform: TargetPlatform.iOS, size: Size(820, 390)),
    (platform: TargetPlatform.windows, size: Size(960, 600)),
  ]) {
    testWidgets(
      '${variant.platform} ${variant.size} player styles share Apple metadata sizing and aligned margins',
      (tester) async {
        _configureView(tester, variant.size);
        double? referenceTitleSize;
        double? referenceArtistSize;
        FontWeight? referenceTitleWeight;
        FontWeight? referenceArtistWeight;

        for (final style in const [
          PlayerStyle.appleMusic,
          PlayerStyle.bstreamMusic,
          PlayerStyle.classicVinyl,
        ]) {
          await tester.pumpWidget(
            _playerHarness(
              key: ValueKey('metadata-margins-${variant.platform}-$style'),
              platform: variant.platform,
              snapshot: snapshot.copyWith(
                title:
                    'Una canción con un nombre largo para comprobar sus márgenes',
                artist: 'Artista principal, Artista invitado y otro artista',
              ),
              localTrack: localTrack,
              playlists: _TestPlaylistsController(),
              style: style,
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();

          final titleFinder = find.byKey(const ValueKey('player-track-title'));
          final artistFinder = find.byKey(
            const ValueKey('player-track-artist'),
          );
          final title = tester.widget<MarqueeText>(titleFinder);
          final artist = tester.widget<Text>(artistFinder);
          if (style == PlayerStyle.appleMusic) {
            referenceTitleSize = title.style!.fontSize!;
            referenceArtistSize = artist.style!.fontSize!;
            referenceTitleWeight = title.style!.fontWeight;
            referenceArtistWeight = artist.style!.fontWeight;
          } else {
            expect(
              title.style!.fontSize,
              closeTo(referenceTitleSize!, 0.01),
              reason: '$style should use the same title scale as Apple Music.',
            );
            expect(
              artist.style!.fontSize,
              closeTo(referenceArtistSize!, 0.01),
              reason: '$style should use the same artist scale as Apple Music.',
            );
            expect(title.style!.fontWeight, referenceTitleWeight);
            expect(artist.style!.fontWeight, referenceArtistWeight);
          }

          final timeline = tester.getRect(
            find.byKey(
              ValueKey(switch (style) {
                PlayerStyle.appleMusic => 'apple-player-timeline',
                PlayerStyle.bstreamMusic => 'player-timeline',
                PlayerStyle.classicVinyl => 'classic-vinyl-player-timeline',
                PlayerStyle.spotifyMusic => 'apple-player-timeline',
              }),
            ),
          );
          final titleRect = tester.getRect(titleFinder);
          final artistRect = tester.getRect(artistFinder);
          expect(titleRect.left, closeTo(timeline.left, 0.1), reason: '$style');
          expect(
            artistRect.left,
            closeTo(timeline.left, 0.1),
            reason: '$style',
          );
          expect(titleRect.right, lessThanOrEqualTo(timeline.right + 0.1));
          expect(artistRect.right, lessThanOrEqualTo(timeline.right + 0.1));
          expect(timeline.left, greaterThan(0));
          expect(timeline.right, lessThan(variant.size.width));
          if (style != PlayerStyle.appleMusic) {
            final inset = tester.getRect(
              find.byKey(
                ValueKey(
                  style == PlayerStyle.bstreamMusic
                      ? 'bstream-player-controls-inset'
                      : 'classic-vinyl-player-controls-inset',
                ),
              ),
            );
            final mobileLandscape =
                variant.platform != TargetPlatform.windows &&
                variant.size.width > variant.size.height;
            final expectedInset = mobileLandscape ? 6.0 : 8.0;
            expect(timeline.left - inset.left, closeTo(expectedInset, 0.1));
            expect(inset.right - timeline.right, closeTo(expectedInset, 0.1));
          }
          expect(
            tester.takeException(),
            isNull,
            reason: '$style ${variant.size}',
          );
        }
      },
    );
  }

  for (final style in PlayerStyle.values) {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final viewport in const [Size(390, 820), Size(820, 390)]) {
        testWidgets(
          '${style.name} $platform $viewport top handle taps and drags back without changing playback',
          (tester) async {
            _configureView(tester, viewport);
            var collapses = 0;
            var controller = _TestPlayerController(snapshot);

            Future<void> showPlayer(String operation) async {
              controller = _TestPlayerController(snapshot);
              await tester.pumpWidget(
                _playerHarness(
                  key: ValueKey(
                    'collapse-$style-$platform-$viewport-$operation',
                  ),
                  platform: platform,
                  snapshot: snapshot,
                  localTrack: localTrack,
                  playlists: _TestPlaylistsController(),
                  playerController: controller,
                  style: style,
                  onCollapse: () => collapses++,
                ),
              );
              await tester.pump(const Duration(milliseconds: 500));
              await tester.pump();
            }

            final handle = find.byType(PlayerCollapseHandle);
            await showPlayer('tap');
            expect(handle, findsOneWidget);
            final handleRect = tester.getRect(handle);
            expect(handleRect.center.dx, closeTo(viewport.width / 2, 0.1));
            expect(handleRect.top, greaterThanOrEqualTo(0));
            expect(handleRect.bottom, lessThanOrEqualTo(60));

            await tester.tap(handle);
            await tester.pump();
            expect(collapses, 1);
            expect(controller.togglePlayPauseCalls, 0);
            expect(controller.playNextCalls, 0);
            expect(controller.seekCalls, 0);
            expect(controller.volumeCalls, 0);

            await showPlayer('drag');
            expect(handle, findsOneWidget);
            final gesture = await tester.startGesture(tester.getCenter(handle));
            await gesture.moveBy(const Offset(0, 40));
            await tester.pump(const Duration(milliseconds: 300));
            await gesture.moveBy(const Offset(0, 40));
            await tester.pump(const Duration(milliseconds: 300));
            final translation = tester.widget<Transform>(
              find.byKey(const ValueKey('player-dismiss-translation')),
            );
            expect(translation.transform.getTranslation().y, greaterThan(64));
            expect(collapses, 1, reason: 'Only releasing the drag returns.');
            await gesture.up();
            await tester.pump();
            expect(
              collapses,
              2,
              reason: 'A slow drag must not require a fling.',
            );
            expect(controller.togglePlayPauseCalls, 0);
            expect(controller.playNextCalls, 0);
            expect(controller.seekCalls, 0);
            expect(controller.volumeCalls, 0);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets(
      '${style.name} short top drag returns to its original position',
      (tester) async {
        _configureView(tester, const Size(390, 820));
        var collapses = 0;
        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: style,
            onCollapse: () => collapses++,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final handle = find.byType(PlayerCollapseHandle);
        final originalRect = tester.getRect(handle);
        final gesture = await tester.startGesture(originalRect.center);
        await gesture.moveBy(const Offset(0, 28));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.getRect(handle).top, greaterThan(originalRect.top));
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();
        expect(collapses, 0);
        expect(tester.getRect(handle), originalRect);
        expect(
          tester
              .widget<Transform>(
                find.byKey(const ValueKey('player-dismiss-translation')),
              )
              .transform
              .getTranslation()
              .y,
          closeTo(0, 0.001),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${style.name} top handle remains decorative without a return callback',
      (tester) async {
        _configureView(tester, const Size(390, 820));
        final controller = _TestPlayerController(snapshot);
        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            playerController: controller,
            style: style,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final handle = find.byType(PlayerCollapseHandle);
        expect(handle, findsOneWidget);
        expect(
          find.descendant(of: handle, matching: find.byType(GestureDetector)),
          findsNothing,
        );
        expect(controller.togglePlayPauseCalls, 0);
        expect(controller.playNextCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final style in PlayerStyle.values) {
    testWidgets('$style quality uses player text color and only tiny shadows', (
      tester,
    ) async {
      _configureView(tester, const Size(390, 820));
      for (final brightness in Brightness.values) {
        for (final accent in [AppAccent.red, AppAccent.purple]) {
          await tester.pumpWidget(
            _playerHarness(
              key: ValueKey('quality-foreground-$style-$brightness-$accent'),
              platform: TargetPlatform.android,
              snapshot: qualitySnapshot,
              localTrack: localTrack,
              playlists: _TestPlaylistsController(),
              canonicalRemoteTrack: qualityTrack,
              style: style,
              showAudioQuality: true,
              brightness: brightness,
              accent: accent,
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
          final quality = find.byKey(const ValueKey('player-audio-quality'));
          final overlay = find.byKey(
            const ValueKey('player-audio-quality-overlay'),
          );
          final textStyle = tester.widget<Text>(quality).style!;
          expect(
            textStyle.color,
            ColorScheme.fromSeed(
              seedColor: accent.seedColor,
              brightness: Brightness.dark,
            ).onSurfaceVariant,
          );
          expect(textStyle.color, isNot(accent.seedColor));
          final shadows = textStyle.shadows!;
          expect(shadows, hasLength(2));
          expect(shadows[0].blurRadius, 2);
          expect(shadows[0].offset, const Offset(0, 1));
          expect(shadows[1].blurRadius, 4);
          for (final shadow in shadows) {
            expect(shadow.color.withValues(alpha: 1), Colors.black);
          }
          for (final widgetType in [
            ShaderMask,
            BackdropFilter,
            Opacity,
            FadeTransition,
          ]) {
            expect(
              find.descendant(of: overlay, matching: find.byType(widgetType)),
              findsNothing,
              reason: 'The quality footer must not add $widgetType effects.',
            );
          }
          final gradientBackgrounds = find.descendant(
            of: overlay,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).gradient != null,
            ),
          );
          expect(gradientBackgrounds, findsNothing);
          expect(tester.takeException(), isNull);
        }
      }
    });

    for (final artworkStyle in PlayerArtworkStyle.values) {
      testWidgets(
        '${style.name} ${artworkStyle.name} keeps audio quality centered inside the artwork on compact, landscape and desktop',
        (tester) async {
          const viewports = [
            (TargetPlatform.android, Size(320, 568)),
            (TargetPlatform.android, Size(740, 360)),
            (TargetPlatform.iOS, Size(390, 844)),
            (TargetPlatform.windows, Size(1366, 768)),
          ];
          _configureView(tester, viewports.first.$2);
          for (final (platform, size) in viewports) {
            tester.view.physicalSize = size;
            await tester.pumpWidget(
              _playerHarness(
                key: ValueKey(
                  'quality-${style.name}-${artworkStyle.name}-$size',
                ),
                platform: platform,
                snapshot: qualitySnapshot,
                localTrack: localTrack,
                playlists: _TestPlaylistsController(),
                canonicalRemoteTrack: qualityTrack,
                style: style,
                artworkStyle: artworkStyle,
                showAudioQuality: true,
              ),
            );
            await tester.pump(const Duration(milliseconds: 500));
            await tester.pump();

            final slot = find.byKey(
              const ValueKey('player-artwork-quality-slot'),
            );
            final overlay = find.byKey(
              const ValueKey('player-audio-quality-overlay'),
            );
            final quality = find.byKey(const ValueKey('player-audio-quality'));
            expect(slot, findsOneWidget, reason: '$style $artworkStyle $size');
            expect(overlay, findsOneWidget);
            expect(quality, findsOneWidget);
            expect(find.text(stereoQuality), findsOneWidget);
            expect(
              find.descendant(of: slot, matching: quality),
              findsOneWidget,
            );
            final qualityText = tester.widget<Text>(quality);
            expect(qualityText.textAlign, TextAlign.center);
            expect(qualityText.maxLines, 2);
            final slotRect = tester.getRect(slot);
            final overlayRect = tester.getRect(overlay);
            final textRect = tester.getRect(quality);
            expect(overlayRect.bottom, closeTo(slotRect.bottom, 0.1));
            expect(overlayRect.top, greaterThanOrEqualTo(slotRect.top - 0.1));
            expect(textRect.left, greaterThanOrEqualTo(slotRect.left));
            expect(textRect.right, lessThanOrEqualTo(slotRect.right));
            expect(textRect.center.dx, closeTo(slotRect.center.dx, 0.1));
            expect(textRect.top, greaterThan(slotRect.center.dy));
            expect(textRect.bottom, lessThanOrEqualTo(slotRect.bottom));

            for (final timelineKey in const [
              'player-timeline',
              'apple-player-timeline',
              'classic-vinyl-player-timeline',
            ]) {
              expect(
                find.descendant(
                  of: find.byKey(ValueKey(timelineKey)),
                  matching: quality,
                ),
                findsNothing,
                reason: 'Quality belongs to the artwork, not $timelineKey',
              );
            }
            expect(tester.takeException(), isNull, reason: '$size');
          }
        },
      );
    }
  }

  testWidgets(
    'audio quality is hidden by default and toggles without reopening the player',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      final settings = _PlayerFontSettingsController(PlayerFont.lora);
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: qualitySnapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          canonicalRemoteTrack: qualityTrack,
          settingsController: settings,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final quality = find.byKey(const ValueKey('player-audio-quality'));
      expect(quality, findsNothing);
      expect(
        find.byKey(const ValueKey('player-audio-quality-overlay')),
        findsNothing,
      );

      await settings.setShowAudioQuality(true);
      await tester.pump();
      expect(find.text(stereoQuality), findsOneWidget);
      expect(
        tester
            .widget<MarqueeText>(
              find.byKey(const ValueKey('player-track-title')),
            )
            .style
            ?.fontFamily,
        'Lora',
      );
      await settings.setShowAudioQuality(false);
      await tester.pump();
      expect(quality, findsNothing);
      expect(find.byType(PlayerPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final bitrate in [128000, 320000]) {
    testWidgets(
      'downloaded quality uses stored $bitrate format without file reads',
      (tester) async {
        _configureView(tester, const Size(960, 720));
        final downloaded = localTrack.copyWith(
          sourceUrl: qualityTrack.url,
          filePath: '/tmp/downloaded.webm',
          audioFormat: LocalAudioQuality(
            codec: 'opus',
            mimeType: 'audio/webm',
            bitrate: bitrate,
            sampleRate: 48000,
            channels: 2,
          ),
        );
        var reads = 0;
        final service = LocalAudioQualityService(
          fingerprintLoader: (_) async {
            reads++;
            return 'unused';
          },
          loader: (_) async {
            reads++;
            return null;
          },
        );
        addTearDown(service.dispose);
        final active = snapshot.copyWith(sourceUrl: downloaded.filePath);
        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.windows,
            snapshot: active,
            localTrack: downloaded,
            playerController: _TestPlayerController(
              active,
              localTrack: downloaded,
            ),
            playlists: _TestPlaylistsController(),
            showAudioQuality: true,
            localAudioQualityService: service,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.text(
            'Opus \u00b7 48 kHz \u00b7 ${bitrate ~/ 1000} kbps - Est\u00e9reo',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            bitrate == 320000 ? 'Alta calidad' : 'Calidad est\u00e1ndar',
          ),
          findsOneWidget,
        );
        expect(reads, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final downloaded in [false, true]) {
    testWidgets(
      '${downloaded ? 'downloaded' : 'local'} artwork quality reads actual file metadata once',
      (tester) async {
        _configureView(tester, const Size(390, 820));
        final fileTrack = localTrack.copyWith(
          id: 'local-quality-${downloaded ? 'download' : 'import'}',
          filePath: '/tmp/local-quality.m4a',
          sourceUrl: downloaded
              ? 'https://www.youtube.com/watch?v=quality0001'
              : null,
          isExternal: !downloaded,
        );
        final fileSnapshot = snapshot.copyWith(
          trackId: fileTrack.id,
          sourceUrl: fileTrack.filePath,
          isRemote: false,
          isExternal: !downloaded,
        );
        final player = _TestPlayerController(
          fileSnapshot,
          localTrack: fileTrack,
        );
        final calls = <String>[];
        var fingerprints = 0;
        final service = LocalAudioQualityService(
          fingerprintLoader: (_) async {
            fingerprints++;
            return 'stable';
          },
          loader: (source) async {
            calls.add(source);
            return const LocalAudioQuality(
              codec: 'aac',
              mimeType: 'audio/mp4',
              sampleRate: 44100,
              bitrate: 256000,
              channels: 2,
            );
          },
        );
        addTearDown(service.dispose);
        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: fileSnapshot,
            localTrack: fileTrack,
            playlists: _TestPlaylistsController(),
            playerController: player,
            showAudioQuality: true,
            localAudioQualityService: service,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(
          find.text('AAC · 44.1 kHz · 256 kbps - Estéreo'),
          findsOneWidget,
        );
        expect(
          calls.map((source) => source.replaceAll('\\', '/').split('/').last),
          ['local-quality.m4a'],
        );
        final originalFingerprints = fingerprints;
        final initialTextElement = tester.element(
          find.byKey(const ValueKey('player-audio-quality')),
        );
        for (var second = 1; second <= 12; second++) {
          player.emit(
            fileSnapshot.copyWith(position: Duration(seconds: second)),
          );
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(calls, hasLength(1));
        expect(fingerprints, originalFingerprints);
        expect(
          tester.element(find.byKey(const ValueKey('player-audio-quality'))),
          same(initialTextElement),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('disabled local quality does not start metadata requests', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final fileSnapshot = snapshot.copyWith(sourceUrl: localTrack.filePath);
    final player = _TestPlayerController(fileSnapshot, localTrack: localTrack);
    final settings = _PlayerFontSettingsController(defaultPlayerFont);
    final pending = Completer<LocalAudioQuality?>();
    var calls = 0;
    var fingerprints = 0;
    final service = LocalAudioQualityService(
      fingerprintLoader: (_) async {
        fingerprints++;
        return 'stable';
      },
      loader: (_) {
        calls++;
        return pending.future;
      },
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: fileSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: player,
        settingsController: settings,
        localAudioQualityService: service,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls, 0);
    expect(fingerprints, 0);
    await settings.setShowAudioQuality(true);
    await tester.pump();
    await tester.pump();
    expect(calls, 1);
    await settings.setShowAudioQuality(false);
    await tester.pump();
    pending.complete(
      const LocalAudioQuality(
        codec: 'aac',
        sampleRate: 44100,
        bitrate: 256000,
        channels: 2,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('player-audio-quality')), findsNothing);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late local metadata never replaces the newly selected track', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final first = localTrack.copyWith(filePath: '/tmp/first-quality.m4a');
    final second = localTrack.copyWith(
      id: 'second-quality',
      title: 'Segunda canción',
      filePath: '/tmp/second-quality.flac',
    );
    final firstSnapshot = snapshot.copyWith(sourceUrl: first.filePath);
    final secondSnapshot = snapshot.copyWith(
      title: second.title,
      trackId: second.id,
      sourceUrl: second.filePath,
    );
    final firstPending = Completer<LocalAudioQuality?>();
    final secondPending = Completer<LocalAudioQuality?>();
    final calls = <String>[];
    final service = LocalAudioQualityService(
      fingerprintLoader: (_) async => 'stable',
      loader: (source) {
        calls.add(source);
        return source.replaceAll('\\', '/').endsWith('/first-quality.m4a')
            ? firstPending.future
            : secondPending.future;
      },
    );
    addTearDown(service.dispose);
    final player = _TestPlayerController(firstSnapshot, localTrack: first);
    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: firstSnapshot,
        localTrack: first,
        playlists: _TestPlaylistsController(),
        playerController: player,
        showAudioQuality: true,
        localAudioQualityService: service,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      calls.map((source) => source.replaceAll('\\', '/').split('/').last),
      ['first-quality.m4a'],
    );
    player.localTrack = second;
    player.emit(secondSnapshot);
    await tester.pump();
    await tester.pump();
    expect(
      calls.map((source) => source.replaceAll('\\', '/').split('/').last),
      ['first-quality.m4a', 'second-quality.flac'],
    );
    firstPending.complete(
      const LocalAudioQuality(
        codec: 'aac',
        sampleRate: 44100,
        bitrate: 256000,
        channels: 2,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('AAC · 44.1 kHz · 256 kbps - Estéreo'), findsNothing);
    secondPending.complete(
      const LocalAudioQuality(
        codec: 'flac',
        sampleRate: 96000,
        bitrate: 1500000,
        channels: 2,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('FLAC · 96 kHz · 1500 kbps - Estéreo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable local metadata keeps an honest container fallback', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final fileSnapshot = snapshot.copyWith(sourceUrl: localTrack.filePath);
    final service = LocalAudioQualityService(
      fingerprintLoader: (_) async => 'stable',
      loader: (_) async => null,
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: fileSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: _TestPlayerController(
          fileSnapshot,
          localTrack: localTrack,
        ),
        showAudioQuality: true,
        localAudioQualityService: service,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final quality = tester.widget<Text>(
      find.byKey(const ValueKey('player-audio-quality')),
    );
    expect(quality.data, 'M4A');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'audio quality follows the active source and omits unknown or loading details',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      final controller = _TestPlayerController(
        qualitySnapshot,
        canonicalRemoteTrack: qualityTrack,
      );
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: qualitySnapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
          showAudioQuality: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(stereoQuality), findsOneWidget);

      controller.emit(qualitySnapshot.copyWith(status: PlayerStatus.loading));
      await tester.pump();
      expect(find.byKey(const ValueKey('player-audio-quality')), findsNothing);

      final nextSnapshot = qualitySnapshot.copyWith(
        title: 'Segunda fuente',
        trackId: 'quality0002',
        sourceUrl: 'https://www.youtube.com/watch?v=quality0002',
      );
      controller.emit(nextSnapshot);
      await tester.pump();
      expect(find.text(stereoQuality), findsNothing);
      expect(find.byKey(const ValueKey('player-audio-quality')), findsNothing);

      controller.canonicalRemoteTrack = qualityTrack.copyWith(
        id: 'quality0002',
        title: 'Segunda fuente',
        url: 'https://www.youtube.com/watch?v=quality0002',
        streamCodec: 'aac',
        streamSampleRate: 44100,
        streamBitrate: 256000,
        streamChannels: 1,
      );
      controller.emit(
        nextSnapshot.copyWith(position: const Duration(seconds: 1)),
      );
      await tester.pump();
      expect(
        find.text('AAC \u00b7 44.1 kHz \u00b7 256 kbps - Mono'),
        findsOneWidget,
      );
      expect(find.text(stereoQuality), findsNothing);

      controller.canonicalRemoteTrack = const TrackInfo(
        id: 'quality0002',
        title: 'Segunda fuente',
        artist: 'Artista de prueba',
        url: 'https://www.youtube.com/watch?v=quality0002',
      );
      controller.emit(
        nextSnapshot.copyWith(position: const Duration(seconds: 2)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('player-audio-quality')), findsNothing);
      expect(find.textContaining('48 kHz'), findsNothing);
      expect(find.textContaining('Est\u00e9reo'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'audio quality uses the prepared source of a native queued track',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      const catalogTrack = TrackInfo(
        id: 'quality0001',
        title: 'Calidad de audio',
        artist: 'Artista de prueba',
        url: 'https://www.youtube.com/watch?v=quality0001',
      );
      final controller = _TestPlayerController(
        qualitySnapshot,
        canonicalRemoteTrack: catalogTrack,
        preparedAudioSource: RemotePlaybackSource(
          track: qualityTrack,
          uri: Uri.parse(qualityTrack.streamUrl!),
          queueEntryId: 'quality-prepared-entry',
        ),
      );
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: qualitySnapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
          showAudioQuality: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(stereoQuality), findsOneWidget);
      controller.emit(
        qualitySnapshot.copyWith(
          trackId: 'another-source',
          sourceUrl: 'https://www.youtube.com/watch?v=other-source',
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('player-audio-quality')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('catalog playback of a downloaded file uses its stored format', (
    tester,
  ) async {
    _configureView(tester, const Size(960, 720));
    final downloaded = qualityTrack.copyWith(
      streamUrl: File('/tmp/offline.m4a').uri.toString(),
      streamCodec: 'aac',
      streamMimeType: 'audio/mp4',
      streamExtension: 'm4a',
      streamBitrate: 320000,
      streamSampleRate: 44100,
      streamChannels: 2,
    );
    final player = _TestPlayerController(
      qualitySnapshot,
      canonicalRemoteTrack: qualityTrack,
      preparedAudioSource: RemotePlaybackSource(
        track: downloaded,
        uri: Uri.parse(downloaded.streamUrl!),
        queueEntryId: 'downloaded-quality',
      ),
    );
    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: qualitySnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: player,
        showAudioQuality: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.text('AAC \u00b7 44.1 kHz \u00b7 320 kbps - Est\u00e9reo'),
      findsOneWidget,
    );
    expect(find.text('Alta calidad'), findsOneWidget);
    expect(find.text(stereoQuality), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'audio quality never guesses between conflicting current and prepared formats',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      final aac = qualityTrack.copyWith(
        streamUrl: 'https://example.invalid/new-source.m4a',
        streamCodec: 'aac',
        streamMimeType: 'audio/mp4',
        streamExtension: 'm4a',
        streamSampleRate: 44100,
        streamBitrate: 256000,
        streamChannels: 1,
      );
      final sameFacts = qualityTrack.copyWith(
        streamUrl: 'https://example.invalid/refreshed-source.webm',
      );
      final cases = [
        (current: qualityTrack, prepared: aac, visible: false),
        (current: aac, prepared: qualityTrack, visible: false),
        (current: qualityTrack, prepared: sameFacts, visible: true),
      ];
      for (final (index, sample) in cases.indexed) {
        final controller = _TestPlayerController(
          qualitySnapshot,
          canonicalRemoteTrack: sample.current,
          preparedAudioSource: RemotePlaybackSource(
            track: sample.prepared,
            uri: Uri.parse(sample.prepared.streamUrl!),
            queueEntryId: 'quality-prepared-entry',
          ),
        );
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('conflicting-quality-$index'),
            platform: TargetPlatform.android,
            snapshot: qualitySnapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            playerController: controller,
            showAudioQuality: true,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.byKey(const ValueKey('player-audio-quality')),
          sample.visible ? findsOneWidget : findsNothing,
        );
        if (sample.visible) expect(find.text(stereoQuality), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  // Artwork presentation modes belong to the two cover-based layouts. The
  // Classic Vinyl layout renders the cover as the record label and has its
  // own responsive/animation contract below.
  for (final style in const [
    PlayerStyle.bstreamMusic,
    PlayerStyle.appleMusic,
  ]) {
    for (final viewport in const [Size(320, 568), Size(390, 820)]) {
      testWidgets(
        '${style.name} reflects the actual expanded cover crop at ${viewport.width.toInt()}px',
        (tester) async {
          _configureView(tester, viewport);
          final trackWithArtwork = LocalTrack(
            id: trackId,
            title: 'Cancion de prueba',
            artist: 'BStream Music',
            filePath: '/tmp/player-controls-track.m4a',
            thumbnailPath: '/tmp/player-reflection-cover.jpg',
            addedAt: DateTime(2026),
          );
          await tester.pumpWidget(
            _playerHarness(
              platform: TargetPlatform.android,
              snapshot: snapshot,
              localTrack: trackWithArtwork,
              playlists: _TestPlaylistsController(),
              style: style,
              artworkStyle: PlayerArtworkStyle.expanded,
              drawBackground: true,
              disableAnimations: true,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          final backdropFinder = find.byType(PlaybackArtworkBackdrop);
          expect(backdropFinder, findsOneWidget);
          final backdrop = tester.widget<PlaybackArtworkBackdrop>(
            backdropFinder,
          );
          final backdropRect = tester.getRect(backdropFinder);
          final actualCoverRect = tester.getRect(
            find.byKey(const ValueKey('player-expanded-artwork-focused-image')),
          );
          expect(backdrop.reflectionArtworkRect, isNotNull);
          final reflectedCoverRect = backdrop.reflectionArtworkRect!.shift(
            backdropRect.topLeft,
          );

          // Match the real overscanned cover extending under the system bar. A
          // full-screen flip has a different crop and cannot join its bottom.
          expect(reflectedCoverRect.left, closeTo(actualCoverRect.left, 0.001));
          expect(reflectedCoverRect.top, closeTo(actualCoverRect.top, 0.001));
          expect(
            reflectedCoverRect.right,
            closeTo(actualCoverRect.right, 0.001),
          );
          expect(
            reflectedCoverRect.bottom,
            closeTo(actualCoverRect.bottom, 0.001),
          );
          expect(backdropRect.top, closeTo(0, 0.001));
          expect(actualCoverRect.top, closeTo(0, 0.001));
          expect(actualCoverRect.width, greaterThan(backdropRect.width));
          expect(actualCoverRect.width, closeTo(actualCoverRect.height, 0.001));
          expect(actualCoverRect.bottom, lessThan(backdropRect.bottom));
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final scenario in const [
      (
        name: 'classic portrait artwork',
        viewport: Size(390, 820),
        artworkStyle: PlayerArtworkStyle.classic,
      ),
      (
        name: 'expanded landscape artwork',
        viewport: Size(820, 390),
        artworkStyle: PlayerArtworkStyle.expanded,
      ),
    ]) {
      testWidgets(
        '${style.name} keeps ${scenario.name} without a reflected hero crop',
        (tester) async {
          _configureView(tester, scenario.viewport);
          final trackWithArtwork = LocalTrack(
            id: trackId,
            title: 'Cancion de prueba',
            artist: 'BStream Music',
            filePath: '/tmp/player-controls-track.m4a',
            thumbnailPath: '/tmp/player-reflection-cover.jpg',
            addedAt: DateTime(2026),
          );
          await tester.pumpWidget(
            _playerHarness(
              platform: TargetPlatform.android,
              snapshot: snapshot,
              localTrack: trackWithArtwork,
              playlists: _TestPlaylistsController(),
              style: style,
              artworkStyle: scenario.artworkStyle,
              drawBackground: true,
              disableAnimations: true,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          final backdropFinder = find.byType(PlaybackArtworkBackdrop);
          expect(backdropFinder, findsOneWidget);
          expect(
            tester
                .widget<PlaybackArtworkBackdrop>(backdropFinder)
                .reflectionArtworkRect,
            isNull,
          );
          expect(
            find.byKey(const ValueKey('player-expanded-artwork-hero')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '${style.name} applies the animated artwork preference to the large cover',
      (tester) async {
        _configureView(tester, const Size(390, 820));
        final trackWithArtwork = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: '/tmp/player-controls-cover.jpg',
          addedAt: DateTime(2026),
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
            animatedArtworkEnabled: true,
          ),
        );
        await tester.pump();
        await tester.pump();

        final artwork = find.byKey(const ValueKey('player-large-artwork'));
        final motion = find.descendant(
          of: artwork,
          matching: find.byType(AnimatedArtworkMotion),
        );
        expect(motion, findsOneWidget);
        expect(tester.widget<AnimatedArtworkMotion>(motion).enabled, isTrue);
        expect(tester.widget<AnimatedArtworkMotion>(motion).isPlaying, isFalse);
        expect(
          find.descendant(
            of: artwork,
            matching: find.byKey(const ValueKey('animated-artwork-particles')),
          ),
          findsNothing,
        );

        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('${style.name}-playing-artwork-disabled'),
            platform: TargetPlatform.android,
            snapshot: snapshot.copyWith(status: PlayerStatus.playing),
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
            animatedArtworkEnabled: false,
          ),
        );
        await tester.pump();

        expect(
          tester
              .widget<AnimatedArtworkMotion>(
                find.descendant(
                  of: find.byKey(const ValueKey('player-large-artwork')),
                  matching: find.byType(AnimatedArtworkMotion),
                ),
              )
              .enabled,
          isFalse,
        );
        expect(
          tester
              .widget<AnimatedArtworkMotion>(
                find.descendant(
                  of: find.byKey(const ValueKey('player-large-artwork')),
                  matching: find.byType(AnimatedArtworkMotion),
                ),
              )
              .isPlaying,
          isTrue,
        );
        expect(
          find.byKey(const ValueKey('animated-artwork-particles')),
          findsNothing,
        );

        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('${style.name}-reduced-motion-artwork'),
            platform: TargetPlatform.android,
            snapshot: snapshot.copyWith(status: PlayerStatus.playing),
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
            animatedArtworkEnabled: true,
            disableAnimations: true,
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const ValueKey('animated-artwork-particles')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${style.name} keeps classic artwork and fades expanded artwork without a second blur',
      (tester) async {
        _configureView(tester, const Size(390, 820));
        final trackWithArtwork = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: '/tmp/player-expanded-cover.jpg',
          addedAt: DateTime(2026),
        );

        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('${style.name}-classic-artwork'),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('player-expanded-artwork')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('player-artwork-presentation-scale')),
          findsNothing,
        );
        final classicArtworkRect = tester.getRect(
          find.byKey(const ValueKey('player-large-artwork')),
        );
        final classicTitleRect = tester.getRect(
          find.byKey(const ValueKey('player-track-title')),
        );
        final classicPrimaryControlRect = tester.getRect(
          find.byKey(const ValueKey('player-primary-control')),
        );

        final controller = _TestPlayerController(snapshot);
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('${style.name}-expanded-artwork'),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            playerController: controller,
            style: style,
            artworkStyle: PlayerArtworkStyle.expanded,
            animatedArtworkEnabled: true,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final largeArtwork = find.byKey(const ValueKey('player-large-artwork'));
        final hero = find.byKey(const ValueKey('player-expanded-artwork-hero'));
        expect(hero, findsOneWidget);
        expect(
          find.descendant(
            of: hero,
            matching: find.byKey(const ValueKey('player-expanded-artwork')),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('player-expanded-artwork-blur')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('player-expanded-artwork-blurred-image')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('player-expanded-artwork-focused-image')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: hero,
            matching: find.byType(AnimatedArtworkMotion),
          ),
          findsOneWidget,
        );
        final expandedMotion = tester.widget<AnimatedArtworkMotion>(
          find.descendant(
            of: hero,
            matching: find.byType(AnimatedArtworkMotion),
          ),
        );
        expect(expandedMotion.depthEnabled, isFalse);
        expect(
          find.descendant(
            of: find.byType(AnimatedArtworkMotion),
            matching: find.byKey(
              const ValueKey('player-expanded-artwork-focused-image'),
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AnimatedArtworkMotion),
            matching: find.byKey(
              const ValueKey('player-expanded-artwork-focus-fade'),
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: hero,
            matching: find.byKey(const ValueKey('animated-artwork-particles')),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: largeArtwork,
            matching: find.byType(AnimatedArtworkMotion),
          ),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('player-artwork-presentation-scale')),
          findsNothing,
        );
        final expandedArtworkRect = tester.getRect(largeArtwork);
        final expandedTitleRect = tester.getRect(
          find.byKey(const ValueKey('player-track-title')),
        );
        final expandedPrimaryControlRect = tester.getRect(
          find.byKey(const ValueKey('player-primary-control')),
        );
        if (style == PlayerStyle.bstreamMusic) {
          final artworkOffset = Offset(
            0,
            expandedArtworkRect.top - classicArtworkRect.top,
          );
          final controlsOffset = Offset(
            0,
            expandedTitleRect.top - classicTitleRect.top,
          );
          expect(artworkOffset.dy, greaterThan(8));
          expect(artworkOffset.dy, greaterThan(controlsOffset.dy));
          expect(
            expandedArtworkRect,
            rectMoreOrLessEquals(classicArtworkRect.shift(artworkOffset)),
          );
          expect(
            expandedTitleRect,
            rectMoreOrLessEquals(classicTitleRect.shift(controlsOffset)),
          );
          expect(
            expandedPrimaryControlRect,
            rectMoreOrLessEquals(
              classicPrimaryControlRect.shift(controlsOffset),
            ),
          );
          expect(
            classicTitleRect.top - classicArtworkRect.bottom,
            greaterThan(expandedTitleRect.top - expandedArtworkRect.bottom),
          );
        } else {
          expect(expandedArtworkRect, classicArtworkRect);
          expect(expandedTitleRect, classicTitleRect);
          expect(expandedPrimaryControlRect, classicPrimaryControlRect);
        }
        final heroRect = tester.getRect(hero);
        expect(heroRect.left, closeTo(0, 0.1));
        expect(heroRect.right, closeTo(390, 0.1));
        expect(heroRect.top, closeTo(0, 0.1));
        expect(heroRect.bottom, closeTo(514.8, 0.1));
        expect(heroRect.bottom, greaterThan(classicArtworkRect.bottom));
        expect(
          find.byKey(const ValueKey('player-artwork-track-transition')),
          findsOneWidget,
        );

        controller.emit(
          snapshot.copyWith(
            title: 'Segunda portada expandida',
            trackId: '${style.name}-expanded-next',
            thumbnailUrl: '/tmp/player-expanded-next-cover.jpg',
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('player-expanded-artwork')),
          findsNWidgets(2),
        );
        expect(
          find.byKey(const ValueKey('player-artwork-surface')),
          findsNWidgets(2),
        );

        await tester.pump(const Duration(milliseconds: 430));

        expect(
          find.byKey(const ValueKey('player-expanded-artwork')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: hero,
            matching: find.byType(AnimatedArtworkMotion),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${style.name} expanded artwork fits a compact mobile viewport',
      (tester) async {
        _configureView(tester, const Size(320, 568), bottomPadding: 24);
        final trackWithArtwork = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: '/tmp/player-expanded-compact-cover.jpg',
          addedAt: DateTime(2026),
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
            artworkStyle: PlayerArtworkStyle.expanded,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('player-expanded-artwork')),
          findsOneWidget,
        );
        final largeArtwork = find.byKey(const ValueKey('player-large-artwork'));
        final artworkSize = tester.getSize(largeArtwork);
        final hero = find.byKey(const ValueKey('player-expanded-artwork-hero'));
        final heroRect = tester.getRect(hero);
        expect(artworkSize.shortestSide, greaterThan(0));
        expect(heroRect.left, closeTo(0, 0.1));
        expect(heroRect.right, closeTo(320, 0.1));
        expect(heroRect.top, closeTo(0, 0.1));
        expect(heroRect.bottom, closeTo(426, 0.1));
        final focusedImageRect = tester.getRect(
          find.byKey(const ValueKey('player-expanded-artwork-focused-image')),
        );
        expect(focusedImageRect.width, closeTo(focusedImageRect.height, 0.1));
        expect(
          heroRect.bottom,
          greaterThan(tester.getRect(largeArtwork).bottom),
        );
        expect(
          find.byKey(const ValueKey('player-artwork-presentation-scale')),
          findsNothing,
        );
        if (style == PlayerStyle.bstreamMusic) {
          expect(
            tester
                .widget<SingleChildScrollView>(
                  find.byKey(const ValueKey('player-content-scroll')),
                )
                .clipBehavior,
            Clip.hardEdge,
          );
          expect(
            find.byKey(const ValueKey('player-expanded-artwork-viewport')),
            findsNothing,
          );
        }
        final primaryControl = tester.getRect(
          find.byKey(const ValueKey('player-primary-control')),
        );
        expect(primaryControl.center.dy, inInclusiveRange(0, 568));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${style.name} expanded cover renders smooth edges without a dark header band',
      (tester) async {
        _configureView(tester, const Size(390, 820), topPadding: 44);
        final fixtures = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('bstream-artwork-edge-'),
        ))!;
        addTearDown(() => fixtures.delete(recursive: true));
        final coverFile = File('${fixtures.path}/white-cover.png');
        await tester.runAsync(() => _writeSolidWhiteArtwork(coverFile));
        final trackWithArtwork = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: coverFile.path,
          addedAt: DateTime(2026),
        );
        // Both mounts measure the hero mask, so avoid unrelated palette IO on
        // the temporary image, including when the keyed animation mount starts.
        final menuColorService = _CountingMenuColorService();

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            menuColorService: menuColorService,
            style: style,
            artworkStyle: PlayerArtworkStyle.expanded,
            disableAnimations: true,
          ),
        );
        await tester.runAsync(
          () => precacheImage(
            ResizeImage(FileImage(coverFile), width: 1280),
            tester.element(find.byType(PlayerPanel)),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        final hero = find.byKey(const ValueKey('player-expanded-artwork'));
        final heroRect = tester.getRect(hero);
        final focusedRect = tester.getRect(
          find.byKey(const ValueKey('player-expanded-artwork-focused-image')),
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(hero);
        final rendered = (await tester.runAsync(
          () => boundary.toImage(pixelRatio: 1),
        ))!;
        try {
          final pixels = (await tester.runAsync(
            () => rendered.toByteData(format: ui.ImageByteFormat.rawRgba),
          ))!;
          final x = rendered.width ~/ 2;
          int pixelOffset(int y) => ((y * rendered.width) + x) * 4;
          int alphaAt(int y) => pixels.getUint8(pixelOffset(y) + 3);
          final imageTop = focusedRect.top - heroRect.top;
          final topY = imageTop.ceil();
          final upperOpaqueY = (imageTop + focusedRect.height * 0.16).ceil();
          final opaqueY = (imageTop + focusedRect.height * 0.55).round();
          final edgeY = (imageTop + focusedRect.height).floor();

          // White artwork over a dark backdrop is the worst-case visible seam.
          // Check rendered pixels, not just the gradient's declared stops.
          expect(alphaAt(topY), lessThanOrEqualTo(1));
          for (var y = topY + 1; y <= upperOpaqueY; y += 1) {
            final alphaStep = alphaAt(y) - alphaAt(y - 1);
            expect(alphaStep, greaterThanOrEqualTo(-1));
            expect(alphaStep, lessThanOrEqualTo(16));
          }
          for (final position in [0.16, 0.20, 0.24, 0.28, 0.30]) {
            final y = (imageTop + focusedRect.height * position).round();
            for (var channel = 0; channel < 4; channel += 1) {
              expect(
                pixels.getUint8(pixelOffset(y) + channel),
                greaterThanOrEqualTo(250),
                reason: 'The opaque upper cover must retain its white color.',
              );
            }
          }
          for (var channel = 0; channel < 4; channel += 1) {
            expect(
              pixels.getUint8(pixelOffset(opaqueY) + channel),
              greaterThanOrEqualTo(250),
            );
          }
          expect(alphaAt(edgeY - 1), lessThanOrEqualTo(1));
          expect(alphaAt(edgeY + 1), lessThanOrEqualTo(1));

          var largestStep = 0;
          final fadeStart = (imageTop + focusedRect.height * 0.60).ceil();
          for (var y = fadeStart; y <= edgeY + 1; y += 1) {
            final step = (alphaAt(y) - alphaAt(y - 1)).abs();
            if (step > largestStep) largestStep = step;
          }
          expect(largestStep, lessThanOrEqualTo(8));
        } finally {
          rendered.dispose();
        }

        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('${style.name}-expanded-edge-motion'),
            platform: TargetPlatform.android,
            snapshot: snapshot.copyWith(status: PlayerStatus.playing),
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            menuColorService: menuColorService,
            style: style,
            artworkStyle: PlayerArtworkStyle.expanded,
            animatedArtworkEnabled: true,
          ),
        );
        await tester.pump();
        expect(hero, findsOneWidget);
        final motion = find.descendant(
          of: hero,
          matching: find.byType(AnimatedArtworkMotion),
        );
        expect(tester.widget<AnimatedArtworkMotion>(motion).enabled, isTrue);
        expect(tester.widget<AnimatedArtworkMotion>(motion).isPlaying, isTrue);
        expect(MediaQuery.disableAnimationsOf(tester.element(motion)), isFalse);

        for (final phase in const [
          (advance: Duration(seconds: 14), elapsed: 14),
          (advance: Duration(seconds: 6), elapsed: 20),
        ]) {
          await tester.pump(phase.advance);
          final transform = tester.widget<Transform>(
            find.descendant(
              of: hero,
              matching: find.byKey(
                const ValueKey('animated-artwork-flat-transform'),
              ),
            ),
          );
          expect(transform.transform.getMaxScaleOnAxis(), greaterThan(1));
          final movingBoundary = tester.renderObject<RenderRepaintBoundary>(
            hero,
          );
          final movingFrame = (await tester.runAsync(
            () => movingBoundary.toImage(pixelRatio: 1),
          ))!;
          try {
            final pixels = (await tester.runAsync(
              () => movingFrame.toByteData(format: ui.ImageByteFormat.rawRgba),
            ))!;
            for (final x in [
              0,
              movingFrame.width ~/ 2,
              movingFrame.width - 1,
            ]) {
              expect(
                pixels.getUint8(x * 4 + 3),
                lessThanOrEqualTo(1),
                reason:
                    'The top edge must remain transparent at ${phase.elapsed}s of zoom and pan.',
              );
            }
          } finally {
            movingFrame.dispose();
          }
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${style.name} keeps expanded artwork bounded in mobile landscape',
      (tester) async {
        _configureView(tester, const Size(820, 390));
        final trackWithArtwork = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: '/tmp/player-expanded-landscape-cover.jpg',
          addedAt: DateTime(2026),
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
            artworkStyle: PlayerArtworkStyle.expanded,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final scale = tester
            .widget<Transform>(
              find.byKey(const ValueKey('player-artwork-presentation-scale')),
            )
            .transform
            .getMaxScaleOnAxis();
        expect(scale, lessThanOrEqualTo(1.181));
        if (style == PlayerStyle.bstreamMusic) {
          expect(
            find.byKey(const ValueKey('bstream-player-adaptive-landscape')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('bstream-player-landscape-artwork-pane')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('player-content-scroll')),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${style.name} uses a bounded two-pane player on compact and large mobile landscape',
      (tester) async {
        const viewports = [
          Size(568, 320),
          Size(640, 360),
          Size(740, 360),
          Size(844, 390),
          Size(915, 412),
        ];
        final landscapeTrack = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: '/tmp/player-landscape-cover.jpg',
          addedAt: DateTime(2026),
        );
        _configureView(tester, viewports.first);

        for (final artworkStyle in PlayerArtworkStyle.values) {
          for (final viewport in viewports) {
            tester.view.physicalSize = viewport;
            await tester.pumpWidget(
              _playerHarness(
                key: ValueKey(
                  '${style.name}-${artworkStyle.name}-landscape-${viewport.width}x${viewport.height}',
                ),
                platform: TargetPlatform.android,
                snapshot: snapshot.copyWith(
                  position: const Duration(minutes: 1),
                ),
                localTrack: landscapeTrack,
                playlists: _TestPlaylistsController(),
                style: style,
                artworkStyle: artworkStyle,
              ),
            );
            await tester.pump(const Duration(milliseconds: 500));
            await tester.pump();

            final landscapeLayout = find.byKey(
              ValueKey(
                style == PlayerStyle.bstreamMusic
                    ? 'bstream-player-adaptive-landscape'
                    : 'apple-player-adaptive-two-column',
              ),
            );
            expect(
              landscapeLayout,
              findsOneWidget,
              reason: '$style $artworkStyle $viewport',
            );

            final artwork = find.byKey(const ValueKey('player-large-artwork'));
            final rightPaneBlocks = style == PlayerStyle.bstreamMusic
                ? <Finder>[
                    find.byKey(const ValueKey('player-track-title')),
                    find.byKey(const ValueKey('player-timeline')),
                    find.byKey(const ValueKey('player-playback-controls')),
                  ]
                : <Finder>[
                    find.byKey(const ValueKey('apple-player-metadata')),
                    find.byKey(const ValueKey('apple-player-timeline')),
                    find.byKey(const ValueKey('apple-player-transport')),
                    find.byKey(const ValueKey('apple-player-volume-row')),
                    find.byKey(const ValueKey('apple-player-utility-row')),
                  ];

            expect(
              artwork,
              findsOneWidget,
              reason: '$style $artworkStyle $viewport artwork',
            );
            for (final block in rightPaneBlocks) {
              expect(
                block,
                findsOneWidget,
                reason: '$style $artworkStyle $viewport $block',
              );
            }

            final artworkRect = tester.getRect(artwork);
            expect(
              artworkRect.shortestSide,
              greaterThanOrEqualTo(190),
              reason: '$style $artworkStyle $viewport artwork prominence',
            );
            final visibleElements = <({String name, Finder finder})>[
              (name: 'landscape layout', finder: landscapeLayout),
              (name: 'artwork', finder: artwork),
              for (var index = 0; index < rightPaneBlocks.length; index += 1)
                (
                  name: 'right pane block $index',
                  finder: rightPaneBlocks[index],
                ),
            ];

            for (final element in visibleElements) {
              final rect = tester.getRect(element.finder);
              expect(
                rect.left,
                greaterThanOrEqualTo(-0.1),
                reason: '$style $artworkStyle $viewport ${element.name} left',
              );
              expect(
                rect.top,
                greaterThanOrEqualTo(-0.1),
                reason: '$style $artworkStyle $viewport ${element.name} top',
              );
              expect(
                rect.right,
                lessThanOrEqualTo(viewport.width + 0.1),
                reason: '$style $artworkStyle $viewport ${element.name} right',
              );
              expect(
                rect.bottom,
                lessThanOrEqualTo(viewport.height + 0.1),
                reason: '$style $artworkStyle $viewport ${element.name} bottom',
              );
            }

            for (var index = 0; index < rightPaneBlocks.length; index += 1) {
              final blockRect = tester.getRect(rightPaneBlocks[index]);
              expect(
                artworkRect.right,
                lessThanOrEqualTo(blockRect.left + 0.1),
                reason:
                    '$style $artworkStyle $viewport artwork must be left of right pane block $index',
              );
            }

            expect(
              tester.takeException(),
              isNull,
              reason: '$style $artworkStyle $viewport',
            );
          }
        }
      },
    );

    testWidgets(
      '${style.name} keeps landscape artwork fixed when controls need accessibility scrolling',
      (tester) async {
        const viewport = Size(568, 320);
        _configureView(
          tester,
          viewport,
          textScaleFactor: 1.5,
          bottomPadding: 24,
        );
        final trackWithArtwork = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: '/tmp/player-landscape-accessibility-cover.jpg',
          addedAt: DateTime(2026),
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final artwork = find.byKey(const ValueKey('player-large-artwork'));
        final controlsScroll = find.byKey(
          ValueKey(
            style == PlayerStyle.bstreamMusic
                ? 'bstream-player-controls-scroll'
                : 'apple-player-controls-scroll',
          ),
        );
        final lastControl = style == PlayerStyle.bstreamMusic
            ? find.byKey(const ValueKey('player-volume-control'))
            : find.byKey(const ValueKey('apple-player-utility-row'));
        final artworkBeforeScroll = tester.getRect(artwork);

        expect(controlsScroll, findsOneWidget);
        expect(
          find.byKey(
            ValueKey(
              style == PlayerStyle.bstreamMusic
                  ? 'player-content-scroll'
                  : 'apple-player-scroll',
            ),
          ),
          findsNothing,
        );

        await tester.ensureVisible(lastControl);
        await tester.pump();

        expect(tester.getRect(artwork), artworkBeforeScroll);
        final controlRect = tester.getRect(lastControl);
        expect(controlRect.top, greaterThanOrEqualTo(0));
        expect(controlRect.bottom, lessThanOrEqualTo(viewport.height - 24));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${style.name} fits a compact landscape frame after system insets',
      (tester) async {
        // 537 dp mirrors the usable width left by a compact landscape phone
        // after its camera cutout/side safe area has been consumed.
        const viewport = Size(537, 268);
        const bottomInset = 24.0;
        _configureView(tester, viewport, bottomPadding: bottomInset);
        final trackWithArtwork = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: '/tmp/player-inset-landscape-cover.jpg',
          addedAt: DateTime(2026),
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final landscapeLayout = find.byKey(
          ValueKey(
            style == PlayerStyle.bstreamMusic
                ? 'bstream-player-adaptive-landscape'
                : 'apple-player-adaptive-two-column',
          ),
        );
        final artwork = find.byKey(const ValueKey('player-large-artwork'));
        final lastBlock = style == PlayerStyle.bstreamMusic
            ? find.byKey(const ValueKey('player-volume-control'))
            : find.byKey(const ValueKey('apple-player-utility-row'));

        expect(landscapeLayout, findsOneWidget);
        expect(artwork, findsOneWidget);
        expect(lastBlock, findsOneWidget);
        expect(tester.getSize(artwork).shortestSide, greaterThanOrEqualTo(190));
        expect(tester.getRect(lastBlock).top, greaterThanOrEqualTo(0));
        expect(
          tester.getRect(lastBlock).bottom,
          lessThanOrEqualTo(viewport.height - bottomInset + 0.1),
        );
        if (style == PlayerStyle.bstreamMusic) {
          expect(
            tester.getSize(find.byType(WavyPlaybackSeekBar)).height,
            greaterThanOrEqualTo(48),
          );
          for (final key in const [
            'player-shuffle-control',
            'player-previous-control',
            'player-primary-control',
            'player-next-control',
            'player-repeat-control',
            'player-lyrics-control',
            'player-queue-toggle',
            'player-audio-output-control',
            'player-volume-control',
          ]) {
            expect(
              tester.getSize(find.byKey(ValueKey(key))).shortestSide,
              greaterThanOrEqualTo(48),
              reason: '$key touch target',
            );
          }
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${style.name} switches cleanly between portrait and landscape',
      (tester) async {
        _configureView(tester, const Size(390, 820));
        final controller = _TestPlayerController(
          snapshot.copyWith(position: const Duration(seconds: 42)),
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: controller.snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            playerController: controller,
            style: style,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));

        final portraitLayoutKey = ValueKey(
          style == PlayerStyle.bstreamMusic
              ? 'player-content-scroll'
              : 'apple-player-adaptive-stack',
        );
        final landscapeLayoutKey = ValueKey(
          style == PlayerStyle.bstreamMusic
              ? 'bstream-player-adaptive-landscape'
              : 'apple-player-adaptive-two-column',
        );
        expect(find.byKey(portraitLayoutKey), findsOneWidget);
        expect(find.byKey(landscapeLayoutKey), findsNothing);

        tester.view.physicalSize = const Size(844, 390);
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.byKey(portraitLayoutKey), findsNothing);
        expect(find.byKey(landscapeLayoutKey), findsOneWidget);
        for (final key in const [
          'player-large-artwork',
          'player-track-title',
          'player-primary-control',
        ]) {
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        }
        expect(controller.snapshot.position, const Duration(seconds: 42));
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(390, 820);
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.byKey(portraitLayoutKey), findsOneWidget);
        expect(find.byKey(landscapeLayoutKey), findsNothing);
        expect(
          find.byKey(const ValueKey('player-primary-control')),
          findsOneWidget,
        );
        expect(controller.snapshot.position, const Duration(seconds: 42));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('${style.name} bounds expanded artwork on a portrait tablet', (
      tester,
    ) async {
      _configureView(tester, const Size(768, 1024));
      final trackWithArtwork = LocalTrack(
        id: trackId,
        title: 'Cancion de prueba',
        artist: 'BStream Music',
        filePath: '/tmp/player-controls-track.m4a',
        thumbnailPath: '/tmp/player-expanded-tablet-cover.jpg',
        addedAt: DateTime(2026),
      );

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: trackWithArtwork,
          playlists: _TestPlaylistsController(),
          style: style,
          artworkStyle: PlayerArtworkStyle.expanded,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final scale = tester
          .widget<Transform>(
            find.byKey(const ValueKey('player-artwork-presentation-scale')),
          )
          .transform
          .getMaxScaleOnAxis();
      expect(scale, lessThanOrEqualTo(1.181));
      expect(
        find.byKey(const ValueKey('player-expanded-artwork-viewport')),
        findsNothing,
      );
      if (style == PlayerStyle.bstreamMusic) {
        expect(
          tester
              .widget<SingleChildScrollView>(
                find.byKey(const ValueKey('player-content-scroll')),
              )
              .clipBehavior,
          Clip.hardEdge,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Classic Vinyl renders its turntable and fills the portrait controls area',
    (tester) async {
      const viewport = Size(390, 820);
      const systemBottomInset = 24.0;
      const layoutBottomPadding = 12.0;
      _configureView(tester, viewport, bottomPadding: systemBottomInset);
      final controller = _TestPlayerController(
        snapshot.copyWith(
          status: PlayerStatus.playing,
          position: const Duration(minutes: 1),
        ),
      );
      final trackWithArtwork = LocalTrack(
        id: trackId,
        title: 'Cancion de prueba',
        artist: 'BStream Music',
        filePath: '/tmp/player-controls-track.m4a',
        thumbnailPath: '/tmp/classic-vinyl-cover.jpg',
        addedAt: DateTime(2026),
      );

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: controller.snapshot,
          playerController: controller,
          localTrack: trackWithArtwork,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.classicVinyl,
          artworkStyle: PlayerArtworkStyle.expanded,
          animatedArtworkEnabled: true,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('classic-vinyl-player-layout')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('classic-vinyl-player-stack')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('classic-vinyl-deck')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('classic-vinyl-deck-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('classic-vinyl-record')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('classic-vinyl-tonearm')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('classic-vinyl-player-timeline')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('classic-vinyl-player-utility-row')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-large-artwork')), findsNothing);
      expect(
        find.byKey(const ValueKey('animated-artwork-particles')),
        findsNothing,
      );

      final deck = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-deck-slot')),
      );
      final controls = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-controls')),
      );
      final usableBottom =
          viewport.height - systemBottomInset - layoutBottomPadding;
      final deckControlsGap = controls.top - deck.bottom;
      final remainingControlsHeight = usableBottom - controls.top;
      // Compact portrait phones reserve space for the transport and utility
      // icon rows below the turntable.
      expect(deck.width / viewport.width, inInclusiveRange(0.88, 0.92));
      expect(deckControlsGap, inInclusiveRange(75.0, 90.0));
      expect(controls.height, closeTo(remainingControlsHeight, 1));
      expect(controls.bottom, closeTo(usableBottom, 1));

      final metadata = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-metadata')),
      );
      final timeline = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-timeline')),
      );
      final vinylSeek = find.byKey(
        const ValueKey('classic-vinyl-player-linear-seek'),
      );
      expect(vinylSeek, findsOneWidget);
      expect(tester.getSize(vinylSeek).height, 18);
      final vinylSeekRect = tester.getRect(vinylSeek);
      final positionLabel = tester.getRect(
        find.byKey(const ValueKey('apple-player-position')),
      );
      final durationLabel = tester.getRect(
        find.byKey(const ValueKey('apple-player-duration')),
      );
      expect(positionLabel.bottom, lessThanOrEqualTo(vinylSeekRect.top + 0.1));
      expect(durationLabel.bottom, lessThanOrEqualTo(vinylSeekRect.top + 0.1));
      final vinylSeekThemeFinder = find.ancestor(
        of: vinylSeek,
        matching: find.byType(SliderTheme),
      );
      expect(vinylSeekThemeFinder, findsOneWidget);
      final vinylSeekTheme = tester
          .widget<SliderTheme>(vinylSeekThemeFinder)
          .data;
      expect(vinylSeekTheme.trackHeight, 6);
      expect(
        vinylSeekTheme.activeTrackColor,
        AppColors.downloadAccentFor(tester.element(vinylSeek)),
      );
      expect(vinylSeekTheme.thumbShape, same(SliderComponentShape.noThumb));
      expect(vinylSeekTheme.overlayShape, same(SliderComponentShape.noOverlay));
      final roomyTransport = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-transport')),
      );
      final utilityRow = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-utility-row')),
      );
      final sectionGaps = <double>[
        timeline.top - metadata.bottom,
        roomyTransport.top - timeline.bottom,
        utilityRow.top - roomyTransport.bottom,
      ];
      for (final gap in sectionGaps) {
        expect(gap, greaterThanOrEqualTo(18));
      }
      expect(
        roomyTransport.center.dy,
        closeTo((vinylSeekRect.center.dy + utilityRow.top) / 2, 1),
      );
      expect(metadata.top, closeTo(controls.top, 1));
      expect(utilityRow.bottom, closeTo(controls.bottom, 1));

      expect(roomyTransport.left, closeTo(controls.left, 1));
      expect(roomyTransport.right, closeTo(controls.right, 1));
      expect(roomyTransport.width / controls.width, greaterThanOrEqualTo(0.98));
      expect(utilityRow.left, closeTo(controls.left, 1));
      expect(utilityRow.right, closeTo(controls.right, 1));
      expect(utilityRow.width / controls.width, greaterThanOrEqualTo(0.98));

      final utilityButtonRects = [
        for (final key in const [
          'player-lyrics-control',
          'player-volume-control',
          'player-audio-output-control',
          'player-queue-toggle',
        ])
          tester.getRect(find.byKey(ValueKey(key))),
      ];
      final utilityCapsule = tester.getRect(
        find.byKey(const ValueKey('player-utility-capsule')),
      );
      expect(utilityCapsule, utilityRow);
      expect(utilityButtonRects.first.left, greaterThan(utilityCapsule.left));
      expect(utilityButtonRects.last.right, lessThan(utilityCapsule.right));
      for (var index = 1; index < utilityButtonRects.length; index += 1) {
        expect(
          utilityButtonRects[index].center.dy,
          closeTo(utilityButtonRects.first.center.dy, 0.1),
        );
        expect(
          utilityButtonRects[index].left,
          greaterThanOrEqualTo(utilityButtonRects[index - 1].right),
        );
      }

      final transport = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-transport')),
      );
      final previous = tester.getRect(
        find.byKey(const ValueKey('player-previous-control')),
      );
      final shuffle = tester.getRect(
        find.byKey(const ValueKey('player-shuffle-control')),
      );
      final primary = tester.getRect(
        find.byKey(const ValueKey('player-primary-control')),
      );
      final next = tester.getRect(
        find.byKey(const ValueKey('player-next-control')),
      );
      final repeat = tester.getRect(
        find.byKey(const ValueKey('player-repeat-control')),
      );
      final transportButtons = [shuffle, previous, primary, next, repeat];
      for (final button in transportButtons) {
        expect(button.center.dy, closeTo(primary.center.dy, 0.1));
        expect(button.left, greaterThanOrEqualTo(transport.left - 0.1));
        expect(button.right, lessThanOrEqualTo(transport.right + 0.1));
        expect(button.size.aspectRatio, closeTo(1, 0.001));
      }
      for (var index = 1; index < transportButtons.length; index += 1) {
        expect(
          transportButtons[index].center.dx,
          greaterThan(transportButtons[index - 1].center.dx),
        );
      }
      expect(primary.center.dx, closeTo(transport.center.dx, 0.1));
      expect(previous.width, closeTo(next.width, 0.001));
      expect(shuffle.width, closeTo(repeat.width, 0.001));
      expect(previous.width, closeTo(67.18, 0.1));
      expect(primary.width, closeTo(79.39, 0.1));
      expect(primary.width / previous.width, inInclusiveRange(1.15, 1.25));
      expect(
        shuffle.left - transport.left,
        closeTo(transport.right - repeat.right, 0.1),
      );
      final transportFinder = find.byKey(
        const ValueKey('classic-vinyl-player-transport'),
      );
      final utilityFinder = find.byKey(
        const ValueKey('classic-vinyl-player-utility-row'),
      );
      for (final key in const [
        'player-shuffle-control',
        'player-repeat-control',
      ]) {
        expect(
          find.descendant(
            of: transportFinder,
            matching: find.byKey(ValueKey(key)),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: utilityFinder,
            matching: find.byKey(ValueKey(key)),
          ),
          findsNothing,
        );
      }
      _expectTransparentPrimaryControl(tester, mobile: true);
      for (final finder in [
        find.descendant(
          of: find.byKey(const ValueKey('player-previous-control')),
          matching: find.byType(IconButton),
        ),
        find.descendant(
          of: find.byKey(const ValueKey('player-next-control')),
          matching: find.byType(IconButton),
        ),
      ]) {
        expect(tester.widget<IconButton>(finder).style, isNull);
      }
      expect(tester.takeException(), isNull);

      final rotation = find.byKey(
        const ValueKey('classic-vinyl-record-rotation'),
      );
      final initialTurns = tester
          .widget<RotationTransition>(rotation)
          .turns
          .value;
      await tester.pump(const Duration(milliseconds: 540));
      final playingTurns = tester
          .widget<RotationTransition>(rotation)
          .turns
          .value;
      expect(playingTurns, greaterThan(initialTurns));

      controller.emit(
        controller.snapshot.copyWith(status: PlayerStatus.paused),
      );
      await tester.pump();
      final pausedTurns = tester
          .widget<RotationTransition>(rotation)
          .turns
          .value;
      await tester.pump(const Duration(milliseconds: 540));
      expect(
        tester.widget<RotationTransition>(rotation).turns.value,
        closeTo(pausedTurns, 0.000001),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Classic Vinyl adapts to compact mobile landscape', (
    tester,
  ) async {
    const viewport = Size(568, 320);
    _configureView(tester, viewport, bottomPadding: 24);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot.copyWith(position: const Duration(seconds: 45)),
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        style: PlayerStyle.classicVinyl,
      ),
    );
    await tester.pump();

    final layout = find.byKey(
      const ValueKey('classic-vinyl-player-two-column'),
    );
    expect(layout, findsOneWidget);
    expect(
      find.byKey(const ValueKey('classic-vinyl-player-controls-scroll')),
      findsOneWidget,
    );
    for (final key in const [
      'classic-vinyl-player-deck-slot',
      'classic-vinyl-player-metadata',
      'classic-vinyl-player-timeline',
      'classic-vinyl-player-transport',
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(rect.left, greaterThanOrEqualTo(-0.1), reason: key);
      expect(rect.top, greaterThanOrEqualTo(-0.1), reason: key);
      expect(rect.right, lessThanOrEqualTo(viewport.width + 0.1), reason: key);
      expect(
        rect.bottom,
        lessThanOrEqualTo(viewport.height - 24 + 0.1),
        reason: key,
      );
    }
    final controls = tester.getRect(
      find.byKey(const ValueKey('classic-vinyl-player-controls')),
    );
    final transport = tester.getRect(
      find.byKey(const ValueKey('classic-vinyl-player-transport')),
    );
    final utilities = tester.getRect(
      find.byKey(const ValueKey('classic-vinyl-player-utility-row')),
    );
    expect(transport.left, closeTo(controls.left, 1));
    expect(transport.right, closeTo(controls.right, 1));
    expect(utilities.left, closeTo(controls.left, 1));
    expect(utilities.right, closeTo(controls.right, 1));
    for (final key in const [
      'player-shuffle-control',
      'player-previous-control',
      'player-primary-control',
      'player-next-control',
      'player-repeat-control',
    ]) {
      final button = tester.getRect(find.byKey(ValueKey(key)));
      expect(button.left, greaterThanOrEqualTo(transport.left - 0.1));
      expect(button.right, lessThanOrEqualTo(transport.right + 0.1));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Classic Vinyl avoids scrolling at the shortest landscape size', (
    tester,
  ) async {
    const viewport = Size(480, 240);
    _configureView(tester, viewport, bottomPadding: 24);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot.copyWith(position: const Duration(seconds: 45)),
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        style: PlayerStyle.classicVinyl,
      ),
    );
    await tester.pump();

    final controls = tester.getRect(
      find.byKey(const ValueKey('classic-vinyl-player-controls')),
    );
    final transport = tester.getRect(
      find.byKey(const ValueKey('classic-vinyl-player-transport')),
    );
    final controlsInset = tester.getRect(
      find.byKey(const ValueKey('classic-vinyl-player-controls-inset')),
    );
    expect(controlsInset.width, closeTo(240, 0.1));
    expect(controls.left - controlsInset.left, closeTo(6, 0.1));
    expect(controlsInset.right - controls.right, closeTo(6, 0.1));
    expect(controls.width, closeTo(228, 0.1));
    expect(controls.bottom, lessThanOrEqualTo(viewport.height - 24 + 0.1));
    for (final key in const [
      'player-shuffle-control',
      'player-previous-control',
      'player-primary-control',
      'player-next-control',
      'player-repeat-control',
    ]) {
      final button = tester.getRect(find.byKey(ValueKey(key)));
      expect(button.left, greaterThanOrEqualTo(transport.left - 0.1));
      expect(button.right, lessThanOrEqualTo(transport.right + 0.1));
      expect(button.bottom, lessThanOrEqualTo(viewport.height - 24 + 0.1));
    }
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('classic-vinyl-player-controls-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Classic Vinyl fits compact and large portrait phones', (
    tester,
  ) async {
    const viewports = [
      Size(320, 568),
      Size(430, 688),
      Size(360, 800),
      Size(430, 932),
    ];
    _configureView(tester, viewports.first, bottomPadding: 24);

    for (final viewport in viewports) {
      tester.view.physicalSize = viewport;
      await tester.pumpWidget(
        _playerHarness(
          key: ValueKey('classic-vinyl-${viewport.width}x${viewport.height}'),
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.classicVinyl,
          artworkStyle: PlayerArtworkStyle.expanded,
        ),
      );
      await tester.pump();

      final deck = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-deck-slot')),
      );
      final controls = tester.getRect(
        find.byKey(const ValueKey('classic-vinyl-player-controls')),
      );
      expect(deck.width, greaterThanOrEqualTo(210), reason: '$viewport deck');
      if (viewport.height >= 700) {
        final expectedDeckWidthRatio = viewport.width < 400 ? 0.88 : 0.98;
        expect(
          deck.width,
          greaterThanOrEqualTo(viewport.width * expectedDeckWidthRatio),
          reason: '$viewport expanded deck',
        );
        expect(
          viewport.height - 24 - controls.bottom,
          lessThanOrEqualTo(16),
          reason: '$viewport bottom usage',
        );
      }
      expect(deck.height, greaterThanOrEqualTo(210), reason: '$viewport deck');
      expect(deck.left, greaterThanOrEqualTo(-0.1), reason: '$viewport deck');
      expect(deck.right, lessThanOrEqualTo(viewport.width + 0.1));
      expect(controls.left, greaterThanOrEqualTo(-0.1));
      expect(controls.right, lessThanOrEqualTo(viewport.width + 0.1));
      expect(controls.top, greaterThanOrEqualTo(0));
      expect(
        controls.bottom,
        lessThanOrEqualTo(viewport.height - 24 + 0.1),
        reason: '$viewport controls',
      );
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('classic-vinyl-player-stack')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        scrollable.position.maxScrollExtent,
        0,
        reason: '$viewport should not require player scrolling',
      );
      expect(tester.takeException(), isNull, reason: '$viewport');
    }
  });

  testWidgets(
    'Classic Vinyl compacts instead of scrolling when the roomy controls do not fit',
    (tester) async {
      const viewport = Size(600, 700);
      _configureView(tester, viewport, bottomPadding: 24);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.classicVinyl,
          artworkStyle: PlayerArtworkStyle.expanded,
        ),
      );
      await tester.pump();

      final controls = tester.widget<Column>(
        find.byKey(const ValueKey('classic-vinyl-player-controls')),
      );
      expect(controls.mainAxisSize, MainAxisSize.min);

      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('classic-vinyl-player-stack')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollable.position.maxScrollExtent, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Classic Vinyl disables roomy controls for enlarged system text',
    (tester) async {
      const viewport = Size(390, 820);
      const textScales = [1.3, 1.5];
      _configureView(
        tester,
        viewport,
        bottomPadding: 24,
        textScaleFactor: textScales.first,
      );

      for (final textScale in textScales) {
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('classic-vinyl-text-scale-$textScale'),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: PlayerStyle.classicVinyl,
            artworkStyle: PlayerArtworkStyle.expanded,
          ),
        );
        await tester.pump();

        final controls = tester.widget<Column>(
          find.byKey(const ValueKey('classic-vinyl-player-controls')),
        );
        expect(
          controls.mainAxisSize,
          MainAxisSize.min,
          reason: 'text scale $textScale',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'text scale $textScale before scrolling',
        );

        final utility = find.byKey(
          const ValueKey('classic-vinyl-player-utility-row'),
        );
        await tester.ensureVisible(utility);
        await tester.pump();
        final utilityRect = tester.getRect(utility);
        expect(
          utilityRect.top,
          greaterThanOrEqualTo(-0.1),
          reason: 'text scale $textScale utility top',
        );
        expect(
          utilityRect.bottom,
          lessThanOrEqualTo(viewport.height - 24 + 0.1),
          reason: 'text scale $textScale utility bottom',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'text scale $textScale after scrolling',
        );
      }
    },
  );

  testWidgets('BStream landscape keeps dark controls over a light app theme', (
    tester,
  ) async {
    _configureView(tester, const Size(568, 320));
    final trackWithArtwork = LocalTrack(
      id: trackId,
      title: 'Cancion de prueba',
      artist: 'BStream Music',
      filePath: '/tmp/player-controls-track.m4a',
      thumbnailPath: '/tmp/player-light-landscape-cover.jpg',
      addedAt: DateTime(2026),
    );

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: trackWithArtwork,
        playlists: _TestPlaylistsController(),
        brightness: Brightness.light,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final queueButton = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('player-queue-toggle')),
        matching: find.byType(IconButton),
        matchRoot: true,
      ),
    );
    final menuButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('player-menu-control')),
    );

    expect(find.byKey(const ValueKey('player-header')), findsNothing);
    expect(find.byKey(const ValueKey('player-tab-title')), findsNothing);
    final controlContext = tester.element(
      find.byKey(const ValueKey('player-queue-toggle')),
    );
    expect(Theme.of(controlContext).brightness, Brightness.dark);
    final foreground = AppColors.playbackControlForegroundFor(controlContext);
    expect(queueButton.color, foreground);
    expect(menuButton.color, foreground);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile player stays dark for every app theme and style', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      for (final brightness in Brightness.values) {
        for (final style in PlayerStyle.values) {
          await tester.pumpWidget(
            _playerHarness(
              key: ValueKey(
                'mobile-player-theme-$platform-$brightness-${style.name}',
              ),
              platform: platform,
              snapshot: snapshot,
              localTrack: localTrack,
              playlists: _TestPlaylistsController(),
              style: style,
              brightness: brightness,
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();

          final playerContent = switch (style) {
            PlayerStyle.bstreamMusic => find.byKey(
              const ValueKey('player-content-layout'),
            ),
            PlayerStyle.appleMusic => find.byKey(
              const ValueKey('apple-player-layout'),
            ),
            PlayerStyle.classicVinyl => find.byKey(
              const ValueKey('classic-vinyl-player-layout'),
            ),
            PlayerStyle.spotifyMusic => find.byKey(
              const ValueKey('spotify-player-layout'),
            ),
          };
          expect(
            playerContent,
            findsOneWidget,
            reason: '$style player content',
          );

          final playerTheme = Theme.of(tester.element(playerContent));
          expect(
            playerTheme.brightness,
            Brightness.dark,
            reason: '$platform $style keeps the isolated dark player palette',
          );
          expect(playerTheme.colorScheme.brightness, Brightness.dark);

          final appTheme = Theme.of(
            tester.element(find.byType(Scaffold).first),
          );
          expect(
            appTheme.brightness,
            brightness,
            reason: 'the surrounding app keeps its brightness',
          );
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final frame in const [
      (size: Size(390, 820), topPadding: 44.0),
      (size: Size(320, 568), topPadding: 56.0),
    ]) {
      for (final style in PlayerStyle.values) {
        testWidgets(
          '$platform ${style.name} paints behind the status bar and keeps controls safe at ${frame.size.width.toInt()}px',
          (tester) async {
            const bottomPadding = 24.0;
            _configureView(
              tester,
              frame.size,
              topPadding: frame.topPadding,
              bottomPadding: bottomPadding,
            );
            final trackWithArtwork = LocalTrack(
              id: trackId,
              title: 'Cancion de prueba',
              artist: 'BStream Music',
              filePath: '/tmp/player-controls-track.m4a',
              thumbnailPath: '/tmp/player-status-bar-cover.jpg',
              addedAt: DateTime(2026),
            );
            await tester.pumpWidget(
              _playerHarness(
                platform: platform,
                snapshot: snapshot,
                localTrack: trackWithArtwork,
                playlists: _TestPlaylistsController(),
                style: style,
                artworkStyle: PlayerArtworkStyle.expanded,
                drawBackground: true,
                disableAnimations: true,
                brightness: Brightness.light,
                onCollapse: () {},
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));

            final backdrop = find.byType(PlaybackArtworkBackdrop);
            expect(backdrop, findsOneWidget);
            final backdropRect = tester.getRect(backdrop);
            expect(backdropRect.top, closeTo(0, 0.001));
            expect(backdropRect.bottom, closeTo(frame.size.height, 0.001));

            final grabber = find.byKey(
              ValueKey(switch (style) {
                PlayerStyle.bstreamMusic => 'bstream-player-grabber',
                PlayerStyle.appleMusic => 'apple-player-grabber',
                PlayerStyle.classicVinyl => 'classic-vinyl-player-grabber',
                PlayerStyle.spotifyMusic => 'spotify-player-grabber',
              }),
            );
            expect(grabber, findsOneWidget);
            expect(
              tester.getRect(grabber).top,
              greaterThanOrEqualTo(frame.topPadding),
            );
            if (style != PlayerStyle.classicVinyl) {
              final hero = find.byKey(
                const ValueKey('player-expanded-artwork-hero'),
              );
              expect(hero, findsOneWidget);
              final heroRect = tester.getRect(hero);
              expect(heroRect.left, closeTo(0, 0.001));
              expect(heroRect.right, closeTo(frame.size.width, 0.001));
              expect(heroRect.top, closeTo(frame.topPadding - 24, 0.001));
              expect(heroRect.bottom, lessThanOrEqualTo(frame.size.height));
              final sharpCoverRect = tester.getRect(
                find.byKey(
                  const ValueKey('player-expanded-artwork-focused-image'),
                ),
              );
              expect(sharpCoverRect.top, closeTo(heroRect.top, 0.001));
              expect(sharpCoverRect.width, greaterThan(frame.size.width));
              expect(
                sharpCoverRect.height,
                closeTo(sharpCoverRect.width, 0.001),
              );
              final reflectionRect = tester
                  .widget<PlaybackArtworkBackdrop>(backdrop)
                  .reflectionArtworkRect;
              expect(reflectionRect, isNotNull);
              expect(
                reflectionRect!.shift(backdropRect.topLeft),
                rectMoreOrLessEquals(sharpCoverRect),
              );
            }
            final primary = find.byKey(
              const ValueKey('player-primary-control'),
            );
            await tester.ensureVisible(primary);
            await tester.pump();
            final primaryRect = tester.getRect(primary);
            expect(primaryRect.top, greaterThanOrEqualTo(frame.topPadding));
            expect(
              primaryRect.bottom,
              lessThanOrEqualTo(frame.size.height - bottomPadding + 0.1),
            );

            final utility = find.byKey(
              ValueKey(switch (style) {
                PlayerStyle.appleMusic => 'apple-player-utility-row',
                PlayerStyle.classicVinyl => 'classic-vinyl-player-utility-row',
                PlayerStyle.bstreamMusic ||
                PlayerStyle.spotifyMusic => 'player-utility-controls',
              }),
            );
            expect(utility, findsOneWidget);
            await tester.ensureVisible(utility);
            await tester.pump();
            final utilityRect = tester.getRect(utility);
            expect(utilityRect.top, greaterThanOrEqualTo(frame.topPadding));
            expect(
              utilityRect.bottom,
              lessThanOrEqualTo(frame.size.height - bottomPadding + 0.1),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('desktop player menu exposes app audio output without Cast', (
    tester,
  ) async {
    _configureView(tester, const Size(1200, 820));
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      await tester.pumpWidget(
        _playerHarness(
          key: ValueKey('desktop-audio-menu-$platform'),
          platform: platform,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('player-menu-control')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(const ValueKey('player-menu-audio-output')),
        findsOneWidget,
      );
      expect(find.text('Salida de audio'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-menu-cast')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('desktop player follows the app theme for every style', (
    tester,
  ) async {
    _configureView(tester, const Size(1200, 820));
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      for (final style in PlayerStyle.values) {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(
            _playerHarness(
              key: ValueKey('desktop-theme-$platform-$style-$brightness'),
              platform: platform,
              snapshot: snapshot,
              localTrack: localTrack,
              playlists: _TestPlaylistsController(),
              style: style,
              brightness: brightness,
              playerFont: PlayerFont.lora,
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
          final title = find.byKey(const ValueKey('player-track-title'));
          final context = tester.element(title);
          expect(Theme.of(context).brightness, brightness);
          expect(Theme.of(context).colorScheme.brightness, brightness);
          expect(tester.widget<MarqueeText>(title).style?.fontFamily, 'Lora');
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('the chosen font reaches all full player styles', (tester) async {
    _configureView(tester, const Size(390, 820));

    for (final style in PlayerStyle.values) {
      Future<(String?, String?)> render(PlayerFont font) async {
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('player-font-${style.name}-${font.code}'),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: style,
            playerFont: font,
            brightness: Brightness.light,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final title = find.byKey(const ValueKey('player-track-title'));
        final artist = find.byKey(const ValueKey('player-track-artist'));
        expect(title, findsOneWidget, reason: '$style title');
        expect(artist, findsOneWidget, reason: '$style artist');
        expect(
          Theme.of(tester.element(title)).brightness,
          Brightness.dark,
          reason: '$style player theme',
        );
        expect(
          Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
          Brightness.light,
          reason: '$style surrounding app theme',
        );
        return (
          tester.widget<MarqueeText>(title).style?.fontFamily,
          tester.widget<Text>(artist).style?.fontFamily,
        );
      }

      final platformFonts = await render(PlayerFont.current);
      expect(platformFonts.$1, isNot('Lora'));
      expect(platformFonts.$2, isNot('Lora'));
      expect(await render(PlayerFont.lora), ('Lora', 'Lora'));
      expect(await render(PlayerFont.current), platformFonts);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('player overflow menus retain the light app theme', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));

    for (final style in PlayerStyle.values) {
      await tester.pumpWidget(
        _playerHarness(
          key: ValueKey('light-player-menu-${style.name}'),
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: style,
          brightness: Brightness.light,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('player-menu-control')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final menuAction = find.byKey(const ValueKey('player-menu-share'));
      expect(menuAction, findsOneWidget, reason: '$style overflow menu');
      expect(
        Theme.of(tester.element(menuAction)).brightness,
        Brightness.light,
        reason: '$style popup route must use the surrounding app theme',
      );
      expect(
        Theme.of(
          tester.element(find.byKey(const ValueKey('player-track-title'))),
        ).brightness,
        Brightness.dark,
        reason: '$style player keeps its dark palette behind the light menu',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  for (final style in PlayerStyle.values) {
    for (final mode in SurfaceBackgroundMode.values) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '${style.name} options use the cover despite ${mode.name} in $brightness',
          (tester) async {
            _configureView(tester, const Size(390, 820));
            await tester.pumpWidget(
              _playerHarness(
                platform: TargetPlatform.android,
                snapshot: snapshot,
                localTrack: localTrack,
                playlists: _TestPlaylistsController(),
                style: style,
                backgroundMode: mode,
                brightness: brightness,
              ),
            );
            await tester.pump(const Duration(milliseconds: 500));
            await tester.tap(find.byKey(const ValueKey('player-menu-control')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            final sheet = find.byKey(const ValueKey('player-options-menu'));
            expect(sheet, findsOneWidget);
            expect(Theme.of(tester.element(sheet)).brightness, brightness);
            expect(
              AppColors.surfaceBackgroundModeFor(tester.element(sheet)),
              SurfaceBackgroundMode.accent,
            );
            expect(
              find.byKey(const ValueKey('app-menu-sheet-liquid-glass')),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('app-menu-sheet-transparent-backdrop')),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('player-menu-playlist')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('player-menu-favorite')),
              findsOneWidget,
            );
            await tester.tap(
              find.byKey(const ValueKey('player-options-close')),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(sheet, findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'capsules do not sample artwork and menu sampling ignores position ticks',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      final service = _CountingMenuColorService();
      final controller = _TestPlayerController(
        snapshot.copyWith(thumbnailUrl: '/fixture/menu-cover-orange.png'),
      );
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
          menuColorService: service,
          backgroundMode: SurfaceBackgroundMode.liquidGlass,
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(service.sources, isEmpty);
      final capsule =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byKey(
                            const ValueKey('player-utility-capsule'),
                          ),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      for (final key in [
        'apple-player-favorite-surface',
        'apple-player-menu-surface',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(LiquidGlassSurface),
          ),
          findsOneWidget,
        );
      }
      expect(capsule.color!.a, lessThan(.2));
      expect(capsule.gradient, isNull);
      expect(capsule.border, isNull);
      await tester.tap(find.byKey(const ValueKey('player-menu-control')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(service.sources, ['/fixture/menu-cover-orange.png']);
      final firstBackground = tester.widget<PlaybackArtworkBackdrop>(
        find.byKey(const ValueKey('playback-menu-artwork-background')),
      );
      expect(firstBackground.source, '/fixture/menu-cover-orange.png');
      expect(firstBackground.cacheWidth, 256);
      controller.emit(
        snapshot.copyWith(
          position: const Duration(seconds: 10),
          thumbnailUrl: '/fixture/menu-cover-orange.png',
        ),
      );
      await tester.pump();
      expect(service.sources, hasLength(1));
      controller.emit(
        snapshot.copyWith(
          trackId: 'other-track',
          thumbnailUrl: '/fixture/menu-cover-blue.png',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(service.sources, hasLength(2));
      expect(service.releases, 1);
      final secondBackground = tester.widget<PlaybackArtworkBackdrop>(
        find.byKey(const ValueKey('playback-menu-artwork-background')),
      );
      expect(secondBackground.source, '/fixture/menu-cover-blue.png');
      expect(secondBackground.source, isNot(firstBackground.source));
      final surface = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('app-menu-sheet-surface')),
      );
      expect(
        (surface.decoration! as BoxDecoration).gradient,
        isNull,
        reason:
            'The artwork must not be covered by the old solid-color gradient.',
      );
      await tester.tap(find.byKey(const ValueKey('player-options-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(service.releases, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(service.releases, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('player volume popover retains the light app theme', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        brightness: Brightness.light,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('player-volume-control')));
    await tester.pump(const Duration(milliseconds: 300));

    final popover = find.byKey(const ValueKey('volume-popover'));
    expect(popover, findsOneWidget);
    expect(
      Theme.of(tester.element(popover)).brightness,
      Brightness.light,
      reason: 'the popover follows the app brightness',
    );
    expect(
      Theme.of(
        tester.element(find.byKey(const ValueKey('player-track-title'))),
      ).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('position-only updates do not rebuild the open volume popover', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final controller = _TestPlayerController(snapshot);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: controller,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('player-volume-control')));
    await tester.pump(const Duration(milliseconds: 300));

    final popover = find.byKey(const ValueKey('volume-popover'));
    final initialSurface = tester.widget<Container>(popover);

    controller.emit(
      snapshot.copyWith(position: const Duration(minutes: 1, seconds: 12)),
    );
    await tester.pump();

    expect(
      identical(tester.widget<Container>(popover), initialSurface),
      isTrue,
      reason: 'playback position must not invalidate volume-only UI',
    );

    controller.emit(
      snapshot.copyWith(
        position: const Duration(minutes: 1, seconds: 13),
        volume: 0.41,
      ),
    );
    await tester.pump();

    expect(
      identical(tester.widget<Container>(popover), initialSurface),
      isFalse,
      reason: 'an actual volume change must still refresh the popover',
    );
    expect(find.text('41%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile playback queue retains the light app theme', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        style: PlayerStyle.classicVinyl,
        brightness: Brightness.light,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(
      Theme.of(
        tester.element(
          find.byKey(const ValueKey('classic-vinyl-player-layout')),
        ),
      ).brightness,
      Brightness.dark,
    );

    await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final queueTitle = find.textContaining('Cola de Reproducción');
    expect(queueTitle, findsOneWidget);
    expect(
      find.byKey(const ValueKey('queue-header-artwork-background')),
      findsOneWidget,
    );
    expect(
      Theme.of(tester.element(queueTitle)).brightness,
      Brightness.light,
      reason: 'the queue follows the surrounding app brightness',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop playback queue rail retains the light app theme', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 720));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        style: PlayerStyle.appleMusic,
        brightness: Brightness.light,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(
      Theme.of(
        tester.element(find.byKey(const ValueKey('apple-player-layout'))),
      ).brightness,
      Brightness.light,
    );

    final queueRail = find.byKey(const ValueKey('desktop-playback-queue-rail'));
    expect(queueRail, findsOneWidget);
    expect(
      Theme.of(tester.element(queueRail)).brightness,
      Brightness.light,
      reason: 'the desktop rail and player follow the surrounding light theme',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('downloaded playback replaces a soft file with catalog artwork', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final sharpLocalTrack = LocalTrack(
      id: trackId,
      title: 'Cancion de prueba',
      artist: 'BStream Music',
      filePath: '/tmp/player-controls-track.m4a',
      thumbnailPath: '/tmp/soft-player-cover.jpg',
      catalogThumbnailUrl:
          'https://lh3.googleusercontent.com/player-cover=w120-h120-l90-rj',
      addedAt: DateTime(2026),
    );

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: sharpLocalTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump();

    final artwork = find.byKey(const ValueKey('player-large-artwork'));
    final image = tester.widget<ProportionalArtwork>(
      find.descendant(of: artwork, matching: find.byType(ProportionalArtwork)),
    );
    expect(
      image.source,
      'https://lh3.googleusercontent.com/player-cover=w1280-h1280-l90-rj',
    );
    expect(image.fallbackSource, sharpLocalTrack.thumbnailPath);
  });

  for (final size in const [Size(320, 720), Size(360, 800)]) {
    testWidgets(
      'Android ${size.width.toInt()} px puts four utility icons below transport',
      (tester) async {
        _configureView(tester, size);
        final playlists = _TestPlaylistsController();

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: playlists,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final lyrics = find.byKey(const ValueKey('player-lyrics-control'));
        final shuffle = find.byKey(const ValueKey('player-shuffle-control'));
        final volume = find.byKey(const ValueKey('player-volume-control'));
        final repeat = find.byKey(const ValueKey('player-repeat-control'));
        final primary = find.byKey(const ValueKey('player-primary-control'));
        final previous = find.byKey(const ValueKey('player-previous-control'));
        final next = find.byKey(const ValueKey('player-next-control'));
        final artwork = find.byKey(const ValueKey('player-large-artwork'));
        final utility = find.byKey(const ValueKey('player-utility-controls'));

        expect(
          find.descendant(of: lyrics, matching: find.text('Letras')),
          findsNothing,
        );
        expect(
          find.descendant(of: volume, matching: find.text('Volumen')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: lyrics,
            matching: find.byKey(const ValueKey('player-lyrics-icon')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: volume,
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsOneWidget,
        );
        expect(
          tester.getCenter(lyrics).dy,
          greaterThan(tester.getCenter(shuffle).dy),
        );
        expect(
          tester.getCenter(volume).dy,
          greaterThan(tester.getCenter(repeat).dy),
        );
        expect(
          tester.getCenter(lyrics).dx,
          lessThan(tester.getCenter(primary).dx),
        );
        expect(
          tester.getCenter(shuffle).dx,
          lessThan(tester.getCenter(primary).dx),
        );
        expect(
          tester.getCenter(volume).dx,
          lessThan(tester.getCenter(primary).dx),
        );
        expect(
          tester.getCenter(repeat).dx,
          greaterThan(tester.getCenter(primary).dx),
        );
        final utilityRects = [
          for (final key in const [
            'player-lyrics-control',
            'player-volume-control',
            'player-audio-output-control',
            'player-queue-toggle',
          ])
            tester.getRect(find.byKey(ValueKey(key))),
        ];
        for (var index = 0; index < utilityRects.length; index++) {
          final rect = utilityRects[index];
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.center.dy, closeTo(utilityRects.first.center.dy, 0.1));
          expect(rect.left, greaterThanOrEqualTo(tester.getRect(utility).left));
          expect(rect.right, lessThanOrEqualTo(tester.getRect(utility).right));
          if (index > 0) {
            expect(
              rect.left,
              greaterThanOrEqualTo(utilityRects[index - 1].right),
            );
          }
        }
        final artworkSize = tester.getSize(artwork);
        expect(artworkSize.width, lessThanOrEqualTo(size.width - 48));
        expect(artworkSize.width, greaterThanOrEqualTo(180));
        expect(artworkSize.height, closeTo(artworkSize.width, 0.1));
        expect(find.byKey(const ValueKey('player-header')), findsNothing);
        expect(
          find.byKey(const ValueKey('player-share-control')),
          findsNothing,
        );
        final lyricsButton = tester.widget<IconButton>(
          find.descendant(of: lyrics, matching: find.byType(IconButton)),
        );
        final volumeButton = tester.widget<IconButton>(
          find.descendant(of: volume, matching: find.byType(IconButton)),
        );
        expect(lyricsButton.iconSize, greaterThanOrEqualTo(22));
        expect(lyricsButton.tooltip, 'Letras');
        expect(volumeButton.tooltip, 'Volumen');
        expect(
          lyricsButton.style?.backgroundColor?.resolve(<WidgetState>{}),
          anyOf(isNull, Colors.transparent),
        );
        expect(
          volumeButton.style?.backgroundColor?.resolve(<WidgetState>{}),
          anyOf(isNull, Colors.transparent),
        );
        expect(
          lyricsButton.style?.backgroundColor?.resolve(<WidgetState>{
            WidgetState.disabled,
          }),
          anyOf(isNull, Colors.transparent),
        );
        expect(
          volumeButton.style?.backgroundColor?.resolve(<WidgetState>{
            WidgetState.disabled,
          }),
          anyOf(isNull, Colors.transparent),
        );

        final expectedPlaySize = size.width == 320 ? 64.0 : 76.0;
        expect(tester.getSize(primary), Size.square(expectedPlaySize));
        _expectTransparentPrimaryControl(tester, mobile: true);
        final minimumSideSize = size.width == 320 ? 48.0 : 52.0;
        expect(
          tester.getSize(previous).shortestSide,
          greaterThanOrEqualTo(minimumSideSize),
        );
        expect(
          tester.getSize(next).shortestSide,
          greaterThanOrEqualTo(minimumSideSize),
        );

        if (size.width == 360) {
          final shuffleRect = tester.getRect(shuffle);
          final previousRect = tester.getRect(previous);
          final primaryRect = tester.getRect(primary);
          final nextRect = tester.getRect(next);
          final repeatRect = tester.getRect(repeat);
          expect(
            previousRect.left - shuffleRect.right,
            greaterThanOrEqualTo(6),
          );
          expect(
            primaryRect.left - previousRect.right,
            greaterThanOrEqualTo(6),
          );
          expect(nextRect.left - primaryRect.right, greaterThanOrEqualTo(6));
          expect(repeatRect.left - nextRect.right, greaterThanOrEqualTo(6));
        }
        await tester.ensureVisible(volume);
        final classicArtworkRect = tester.getRect(artwork);
        final classicPrimaryRect = tester.getRect(primary);
        final classicUtilityRect = tester.getRect(utility);
        final classicVolumeRect = tester.getRect(volume);
        expect(
          size.height - classicVolumeRect.bottom,
          greaterThanOrEqualTo(16),
        );

        // Classic uses spare room above the cover for a larger title gap;
        // metadata and playback controls retain their spacing as a group.
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('bstream-bottom-anchor-${size.width}'),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            artworkStyle: PlayerArtworkStyle.expanded,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        final artworkOffset =
            tester.getTopLeft(artwork) - classicArtworkRect.topLeft;
        final controlsOffset =
            tester.getTopLeft(primary) - classicPrimaryRect.topLeft;
        expect(artworkOffset.dx, closeTo(0, 0.001));
        expect(artworkOffset.dy, greaterThan(0));
        expect(controlsOffset.dx, closeTo(0, 0.001));
        expect(
          artworkOffset.dy,
          greaterThanOrEqualTo(controlsOffset.dy - 0.001),
        );
        expect(
          tester.getRect(artwork),
          rectMoreOrLessEquals(classicArtworkRect.shift(artworkOffset)),
        );
        expect(
          tester.getRect(primary),
          rectMoreOrLessEquals(classicPrimaryRect.shift(controlsOffset)),
        );
        expect(
          tester.getRect(utility),
          rectMoreOrLessEquals(classicUtilityRect.shift(controlsOffset)),
        );
        expect(
          tester.getRect(volume),
          rectMoreOrLessEquals(classicVolumeRect.shift(controlsOffset)),
        );
        expect(size.height - tester.getRect(volume).bottom, closeTo(16, 0.1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final variant in const [
    (
      name: 'Android 390 playing',
      size: Size(390, 820),
      status: PlayerStatus.playing,
    ),
    (
      name: 'Android 430 paused',
      size: Size(430, 900),
      status: PlayerStatus.paused,
    ),
  ]) {
    testWidgets('${variant.name} keeps a visually dominant primary glyph', (
      tester,
    ) async {
      _configureView(tester, variant.size);
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot.copyWith(status: variant.status),
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      _expectTransparentPrimaryControl(tester, mobile: true);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-primary-control')),
          matching: find.byIcon(
            variant.status == PlayerStatus.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final variant in const [
    (name: 'Android', size: Size(360, 800), platform: TargetPlatform.android),
    (name: 'Windows', size: Size(1280, 720), platform: TargetPlatform.windows),
  ]) {
    testWidgets('${variant.name} progress drag commits only its final seek', (
      tester,
    ) async {
      _configureView(tester, variant.size);
      final controller = _TestPlayerController(snapshot);
      await tester.pumpWidget(
        _playerHarness(
          platform: variant.platform,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final progress = find.byKey(
        const ValueKey('player-progress-color-animation'),
      );
      final rect = tester.getRect(progress);
      final gesture = await tester.startGesture(
        Offset(rect.right - 12, rect.center.dy),
      );
      await gesture.moveTo(Offset(rect.center.dx, rect.center.dy));
      await gesture.moveTo(Offset(rect.left + 12, rect.center.dy));
      await gesture.moveTo(Offset(rect.left - 20, rect.center.dy));
      await tester.pump();
      expect(controller.seekCalls, 0);

      await gesture.up();
      await tester.pump();
      expect(controller.seekCalls, 1);
      expect(controller.lastSeek, Duration.zero);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'BStream player keeps its wave progress and compact volume thumb',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.byType(WavyPlaybackSeekBar), findsOneWidget);
      expect(find.byKey(const ValueKey('player-linear-seek')), findsNothing);
      final timeline = tester.getRect(
        find.byKey(const ValueKey('player-timeline')),
      );
      final controlsInset = tester.getRect(
        find.byKey(const ValueKey('bstream-player-controls-inset')),
      );
      expect(controlsInset.left, closeTo(14, 0.1));
      expect(controlsInset.right, closeTo(376, 0.1));
      expect(timeline.left - controlsInset.left, closeTo(8, 0.1));
      expect(controlsInset.right - timeline.right, closeTo(8, 0.1));

      final shuffle = tester.getRect(
        find.byKey(const ValueKey('player-shuffle-control')),
      );
      final repeat = tester.getRect(
        find.byKey(const ValueKey('player-repeat-control')),
      );
      expect(shuffle.left - timeline.left, lessThan(9));
      expect(timeline.right - repeat.right, lessThan(9));
      final progressAnimation = find.byKey(
        const ValueKey('player-progress-color-animation'),
      );
      expect(
        tester
            .widget<TweenAnimationBuilder<Color?>>(progressAnimation)
            .tween
            .end,
        AppColors.downloadAccentFor(tester.element(progressAnimation)),
      );

      await tester.tap(find.byKey(const ValueKey('player-volume-control')));
      await tester.pump(const Duration(milliseconds: 300));

      final popover = find.byKey(const ValueKey('volume-popover'));
      final volumeTheme = tester
          .widget<SliderTheme>(
            find.descendant(of: popover, matching: find.byType(SliderTheme)),
          )
          .data;
      expect(volumeTheme.trackHeight, 2.5);
      expect(
        volumeTheme.trackShape,
        isNot(isA<UniformPlaybackSliderTrackShape>()),
      );
      expect(
        volumeTheme.thumbShape,
        isA<RoundSliderThumbShape>().having(
          (shape) => shape.enabledThumbRadius,
          'enabledThumbRadius',
          7,
        ),
      );
      expect(
        volumeTheme.overlayShape,
        isA<RoundSliderOverlayShape>().having(
          (shape) => shape.overlayRadius,
          'overlayRadius',
          13,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in const [
    (platform: TargetPlatform.android, brightness: Brightness.dark),
    (platform: TargetPlatform.windows, brightness: Brightness.light),
  ]) {
    testWidgets(
      '${scenario.platform} wave follows the cover and shares its lookup with the menu',
      (tester) async {
        _configureView(
          tester,
          scenario.platform == TargetPlatform.android
              ? const Size(390, 820)
              : const Size(700, 820),
        );
        const blueCover = '/fixture/blue-wave-cover.png';
        const orangeCover = '/fixture/orange-wave-cover.png';
        final service = _CountingMenuColorService();
        final initial = snapshot.copyWith(thumbnailUrl: blueCover);
        final controller = _TestPlayerController(initial);
        await tester.pumpWidget(
          _playerHarness(
            platform: scenario.platform,
            brightness: scenario.brightness,
            accent: AppAccent.red,
            snapshot: initial,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            playerController: controller,
            menuColorService: service,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        Color waveColor() => tester
            .widget<WavyPlaybackSeekBar>(find.byType(WavyPlaybackSeekBar))
            .waveColor;

        final firstColor = waveColor();
        final firstTone = HSLColor.fromColor(firstColor);
        expect(firstTone.hue, closeTo(HSLColor.fromColor(Colors.blue).hue, 1));
        expect(
          firstColor,
          isNot(
            AppColors.downloadAccentFor(
              tester.element(find.byType(WavyPlaybackSeekBar)),
            ),
          ),
        );
        expect(
          firstTone.lightness,
          scenario.brightness == Brightness.dark
              ? greaterThan(0.5)
              : lessThan(0.5),
        );
        expect(service.sources, [blueCover]);

        controller.emit(
          initial.copyWith(position: const Duration(seconds: 10)),
        );
        await tester.pump();
        expect(waveColor(), firstColor);
        expect(service.sources, [blueCover]);

        await tester.tap(find.byKey(const ValueKey('player-menu-control')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(service.sources, [blueCover]);
        expect(
          tester
              .widget<PlaybackArtworkBackdrop>(
                find.byKey(const ValueKey('playback-menu-artwork-background')),
              )
              .source,
          blueCover,
        );

        controller.emit(
          initial.copyWith(
            trackId: 'next-wave-track',
            thumbnailUrl: orangeCover,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(service.sources, [blueCover, orangeCover]);

        await tester.tap(find.byKey(const ValueKey('player-options-close')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          HSLColor.fromColor(waveColor()).hue,
          closeTo(HSLColor.fromColor(Colors.orange).hue, 1),
        );
        expect(service.sources, [blueCover, orangeCover]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('liquid volume popover delegates its complete material paint', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        backgroundMode: SurfaceBackgroundMode.liquidGlass,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('player-volume-control')));
    await tester.pump(const Duration(milliseconds: 300));

    final popover = tester.widget<Container>(
      find.byKey(const ValueKey('volume-popover')),
    );
    final decoration = popover.decoration! as BoxDecoration;
    expect(decoration.color, isNull);
    expect(decoration.gradient, isNull);
    expect(decoration.border, isNull);

    final glass = find.byKey(const ValueKey('volume-popover-liquid-glass'));
    expect(glass, findsOneWidget);
    expect(
      find.descendant(
        of: glass,
        matching: find.byKey(LiquidGlassSurface.opticsKey),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Apple Music Style orders artwork, metadata, timeline and controls',
    (tester) async {
      _configureView(tester, const Size(390, 820));

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot.copyWith(position: const Duration(minutes: 1)),
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      for (final key in const [
        'apple-player-layout',
        'apple-player-grabber',
        'apple-player-adaptive-stack',
        'player-large-artwork',
        'apple-player-metadata',
        'player-track-title',
        'player-track-artist',
        'player-favorite-control',
        'player-menu-control',
        'apple-player-menu-surface',
        'apple-player-timeline',
        'apple-player-linear-seek',
        'apple-player-position',
        'apple-player-duration',
        'apple-player-transport',
        'player-previous-control',
        'player-primary-control',
        'player-next-control',
        'player-volume-control',
        'apple-player-volume-row',
        'apple-player-volume-slider',
        'apple-player-utility-row',
        'player-lyrics-control',
        'player-shuffle-control',
        'player-repeat-control',
        'player-queue-toggle',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }

      final orderedBlocks = [
        find.byKey(const ValueKey('player-large-artwork')),
        find.byKey(const ValueKey('apple-player-metadata')),
        find.byKey(const ValueKey('apple-player-timeline')),
        find.byKey(const ValueKey('apple-player-transport')),
        find.byKey(const ValueKey('apple-player-volume-row')),
        find.byKey(const ValueKey('apple-player-utility-row')),
      ];
      for (var index = 1; index < orderedBlocks.length; index += 1) {
        expect(
          tester.getRect(orderedBlocks[index]).top,
          greaterThanOrEqualTo(tester.getRect(orderedBlocks[index - 1]).bottom),
          reason: 'block $index must follow block ${index - 1}',
        );
      }
      expect(find.byKey(const ValueKey('player-header')), findsNothing);
      expect(find.byKey(const ValueKey('player-content-scroll')), findsNothing);
      expect(find.byKey(const ValueKey('apple-player-scroll')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Apple Music Style fits standard phones without a scrolling player',
    (tester) async {
      const viewports = [
        Size(320, 568),
        Size(360, 640),
        Size(390, 820),
        Size(384, 832),
        Size(820, 390),
      ];
      _configureView(tester, viewports.first);

      for (final viewport in viewports) {
        tester.view.physicalSize = viewport;
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('apple-${viewport.width}x${viewport.height}'),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: PlayerStyle.appleMusic,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('apple-player-scroll')),
          findsNothing,
          reason: '$viewport',
        );
        expect(
          find.byKey(
            ValueKey(
              viewport.width > viewport.height
                  ? 'apple-player-adaptive-two-column'
                  : 'apple-player-adaptive-stack',
            ),
          ),
          findsOneWidget,
          reason: '$viewport',
        );
        for (final key in const [
          'player-large-artwork',
          'apple-player-metadata',
          'apple-player-timeline',
          'apple-player-transport',
          'apple-player-volume-row',
          'apple-player-utility-row',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.top, greaterThanOrEqualTo(0), reason: '$viewport $key');
          expect(
            rect.bottom,
            lessThanOrEqualTo(viewport.height),
            reason: '$viewport $key',
          );
        }
        final artworkSize = tester.getSize(
          find.byKey(const ValueKey('player-large-artwork')),
        );
        expect(artworkSize.width, closeTo(artworkSize.height, 0.1));
        expect(artworkSize.shortestSide, greaterThanOrEqualTo(120));
        if (viewport == const Size(320, 568)) {
          expect(
            artworkSize.shortestSide,
            greaterThanOrEqualTo(205),
            reason:
                'compact Apple layout should give the cover reclaimed height',
          );
        }
        if (viewport == const Size(384, 832)) {
          expect(
            artworkSize.shortestSide,
            closeTo(352, 0.1),
            reason:
                'S22/S25 should keep subtle margins without shrinking the cover excessively',
          );
          final artworkRect = tester.getRect(
            find.byKey(const ValueKey('player-large-artwork')),
          );
          expect(artworkRect.left, closeTo(16, 0.1));
          expect(artworkRect.right, closeTo(368, 0.1));
        }
        if (viewport == const Size(390, 820)) {
          final title = tester.widget<MarqueeText>(
            find.byKey(const ValueKey('player-track-title')),
          );
          expect(title.style?.fontSize, closeTo(22.25, 0.1));
        }
        if (viewport == const Size(820, 390)) {
          final title = tester.widget<MarqueeText>(
            find.byKey(const ValueKey('player-track-title')),
          );
          expect(title.style?.fontSize, closeTo(19.74, 0.1));
        }
        expect(tester.takeException(), isNull, reason: '$viewport');
      }
    },
  );

  testWidgets(
    'Apple Music Style uses the safe area and stays continuous near 760 px',
    (tester) async {
      const cases = <({Size size, double bottomInset})>[
        (size: Size(390, 770), bottomInset: 0),
        (size: Size(360, 720), bottomInset: 24),
        (size: Size(360, 770), bottomInset: 34),
        (size: Size(360, 759), bottomInset: 0),
        (size: Size(360, 760), bottomInset: 0),
        (size: Size(360, 761), bottomInset: 0),
      ];
      _configureView(
        tester,
        cases.first.size,
        bottomPadding: cases.first.bottomInset,
      );
      final extents = <double>[];

      for (final testCase in cases) {
        tester.view
          ..physicalSize = testCase.size
          ..padding = FakeViewPadding(bottom: testCase.bottomInset);
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey(
              'apple-safe-${testCase.size.height}-${testCase.bottomInset}',
            ),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: PlayerStyle.appleMusic,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('apple-player-scroll')),
          findsNothing,
          reason: '$testCase',
        );
        final grabber = tester.getRect(
          find.byKey(const ValueKey('apple-player-grabber')),
        );
        final artwork = tester.getRect(
          find.byKey(const ValueKey('player-large-artwork')),
        );
        final utility = tester.getRect(
          find.byKey(const ValueKey('apple-player-utility-row')),
        );
        expect(
          artwork.top - grabber.bottom,
          lessThanOrEqualTo(35),
          reason: '$testCase',
        );
        expect(
          utility.bottom,
          lessThanOrEqualTo(testCase.size.height - testCase.bottomInset),
          reason: '$testCase',
        );
        expect(tester.takeException(), isNull, reason: '$testCase');
        if (testCase.bottomInset == 0 &&
            testCase.size.width == 360 &&
            testCase.size.height >= 759) {
          extents.add(artwork.width);
        }
      }

      expect(extents, hasLength(3));
      expect((extents[1] - extents[0]).abs(), lessThanOrEqualTo(1));
      expect((extents[2] - extents[1]).abs(), lessThanOrEqualTo(1));
    },
  );

  testWidgets(
    'Apple Music Style aligns compact artist actions and enlarges transport',
    (tester) async {
      _configureView(tester, const Size(390, 820));

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final metadata = tester.getRect(
        find.byKey(const ValueKey('apple-player-metadata')),
      );
      final artist = tester.getRect(
        find.byKey(const ValueKey('player-track-artist')),
      );
      final favoriteSurface = tester.getRect(
        find.byKey(const ValueKey('apple-player-favorite-surface')),
      );
      final menuSurface = tester.getRect(
        find.byKey(const ValueKey('apple-player-menu-surface')),
      );

      expect(favoriteSurface.size, const Size.square(40));
      expect(menuSurface.size, const Size.square(40));
      expect(favoriteSurface.center.dy, closeTo(artist.center.dy, 1));
      expect(menuSurface.center.dy, closeTo(artist.center.dy, 1));

      for (final key in const [
        'player-favorite-control',
        'player-menu-control',
      ]) {
        final target = tester.getSize(find.byKey(ValueKey(key)));
        expect(target.width, greaterThanOrEqualTo(48), reason: '$key width');
        expect(target.height, greaterThanOrEqualTo(48), reason: '$key height');
      }

      final favoriteButton = tester.widget<IconButton>(
        find.byKey(const ValueKey('player-favorite-control')),
      );
      final menuIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('apple-player-menu-surface')),
          matching: find.byType(Icon),
        ),
      );
      final favoriteIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('apple-player-favorite-surface')),
          matching: find.byType(Icon),
        ),
      );
      expect(favoriteButton.iconSize, inInclusiveRange(20, 24));
      expect(menuIcon.size, inInclusiveRange(20, 24));
      expect(favoriteIcon.icon, Icons.favorite_border_rounded);

      final previous = find.byKey(const ValueKey('player-previous-control'));
      final primary = find.byKey(const ValueKey('player-primary-control'));
      final next = find.byKey(const ValueKey('player-next-control'));
      expect(tester.getSize(previous).shortestSide, inInclusiveRange(74, 76));
      expect(tester.getSize(primary).shortestSide, inInclusiveRange(89, 91));
      expect(tester.getSize(next).shortestSide, inInclusiveRange(74, 76));
      final previousRect = tester.getRect(previous);
      final primaryRect = tester.getRect(primary);
      final nextRect = tester.getRect(next);
      expect(primaryRect.left - previousRect.right, inInclusiveRange(6, 16));
      expect(
        nextRect.left - primaryRect.right,
        closeTo(primaryRect.left - previousRect.right, 0.1),
      );
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: previous, matching: find.byType(IconButton)),
            )
            .iconSize,
        inInclusiveRange(60, 62),
      );
      expect(
        tester.widget<IconButton>(primary).iconSize,
        inInclusiveRange(82, 84),
      );
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: next, matching: find.byType(IconButton)),
            )
            .iconSize,
        inInclusiveRange(60, 62),
      );

      final position = tester.getRect(
        find.byKey(const ValueKey('apple-player-position')),
      );
      final duration = tester.getRect(
        find.byKey(const ValueKey('apple-player-duration')),
      );
      expect(position.left, closeTo(metadata.left, 0.1));
      expect(duration.right, closeTo(metadata.right, 0.1));
      final artwork = tester.getRect(
        find.byKey(const ValueKey('player-large-artwork')),
      );
      final timelineSlider = tester.getRect(
        find.byKey(const ValueKey('apple-player-linear-seek')),
      );
      expect(timelineSlider.left - artwork.left, closeTo(8, 0.1));
      expect(artwork.right - timelineSlider.right, closeTo(8, 0.1));
      expect(metadata.left, closeTo(timelineSlider.left, 0.1));
      expect(metadata.right, closeTo(timelineSlider.right, 0.1));

      SliderThemeData localSliderTheme(String sliderKey) {
        final themes = find.ancestor(
          of: find.byKey(ValueKey(sliderKey)),
          matching: find.byType(SliderTheme),
        );
        expect(themes, findsWidgets, reason: sliderKey);
        return tester.widget<SliderTheme>(themes.first).data;
      }

      final seekTheme = localSliderTheme('apple-player-linear-seek');
      final volumeTheme = localSliderTheme('apple-player-volume-slider');
      expect(seekTheme.trackHeight, 8);
      expect(volumeTheme.trackHeight, 8);
      expect(
        seekTheme.trackShape.runtimeType,
        volumeTheme.trackShape.runtimeType,
      );
      expect(
        seekTheme.trackShape.runtimeType,
        isNot(RoundedRectSliderTrackShape),
      );
      expect(seekTheme.trackShape.runtimeType, isNot(GappedSliderTrackShape));
      expect(seekTheme.thumbShape, same(SliderComponentShape.noThumb));
      expect(volumeTheme.thumbShape, same(SliderComponentShape.noThumb));
      expect(seekTheme.overlayShape, same(SliderComponentShape.noOverlay));
      expect(volumeTheme.overlayShape, same(SliderComponentShape.noOverlay));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Apple Music Style keeps text scale 3 utility controls reachable',
    (tester) async {
      _configureView(tester, const Size(320, 568), textScaleFactor: 3);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.byKey(const ValueKey('apple-player-scroll')), findsOneWidget);

      for (final key in const [
        'player-lyrics-control',
        'player-queue-toggle',
      ]) {
        final control = find.byKey(ValueKey(key));
        await tester.ensureVisible(control);
        await tester.pump();
        expect(control, findsOneWidget, reason: key);
        expect(
          tester.getRect(control).top,
          greaterThanOrEqualTo(0),
          reason: key,
        );
        expect(
          tester.getRect(control).bottom,
          lessThanOrEqualTo(568),
          reason: key,
        );
      }

      for (final key in const [
        'player-favorite-control',
        'player-menu-control',
        'player-previous-control',
        'player-primary-control',
        'player-next-control',
        'player-volume-control',
        'player-lyrics-control',
        'player-shuffle-control',
        'player-repeat-control',
        'player-queue-toggle',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
      }
      expect(
        tester.getSize(
          find.byKey(const ValueKey('apple-player-favorite-surface')),
        ),
        const Size.square(40),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('apple-player-menu-surface'))),
        const Size.square(40),
      );

      final previous = find.byKey(const ValueKey('player-previous-control'));
      final primary = find.byKey(const ValueKey('player-primary-control'));
      final next = find.byKey(const ValueKey('player-next-control'));
      expect(tester.getSize(previous).shortestSide, greaterThanOrEqualTo(68));
      expect(tester.getSize(primary).shortestSide, greaterThanOrEqualTo(82));
      expect(tester.getSize(next).shortestSide, greaterThanOrEqualTo(68));
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: previous, matching: find.byType(IconButton)),
            )
            .iconSize,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.widget<IconButton>(primary).iconSize,
        greaterThanOrEqualTo(66),
      );
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: next, matching: find.byType(IconButton)),
            )
            .iconSize,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Apple Music Style timeline commits one final seek and shows total duration',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      final controller = _TestPlayerController(
        snapshot.copyWith(position: const Duration(minutes: 1, seconds: 41)),
      );

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: controller.snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('apple-player-duration')))
            .data,
        '3:00',
      );

      final seek = find.byKey(const ValueKey('apple-player-linear-seek'));
      final rect = tester.getRect(seek);
      final gesture = await tester.startGesture(
        Offset(rect.right - 20, rect.center.dy),
      );
      await gesture.moveTo(Offset(rect.center.dx, rect.center.dy));
      await gesture.moveTo(Offset(rect.left + 20, rect.center.dy));
      await tester.pump();
      expect(controller.seekCalls, 0);

      await gesture.up();
      await tester.pump();
      expect(controller.seekCalls, 1);
      expect(controller.lastSeek, isNotNull);
      expect(controller.lastSeek!, lessThan(const Duration(minutes: 1)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Apple Music Style volume slider invokes setVolume', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final controller = _TestPlayerController(snapshot);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: controller,
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final volume = find.byKey(const ValueKey('apple-player-volume-slider'));
    await tester.ensureVisible(volume);
    await tester.pump();
    final rect = tester.getRect(volume);
    await tester.tapAt(Offset(rect.left + (rect.width * 0.25), rect.center.dy));
    await tester.pump();

    expect(controller.volumeCalls, greaterThan(0));
    expect(controller.lastVolume, isNotNull);
    expect(controller.lastVolume!, inInclusiveRange(0.0, 1.0));
    expect(controller.lastVolume!, isNot(closeTo(snapshot.volume, 0.01)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Apple Music Style opens and closes the mobile playback queue', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.textContaining('Cola de Reproducción'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final queueTitle = find.textContaining('Cola de Reproducción');
    expect(queueTitle, findsOneWidget);
    expect(find.byTooltip('Cerrar'), findsOneWidget);
    expect(ModalRoute.of(tester.element(queueTitle))?.isCurrent, isTrue);
    expect(
      find.byKey(const ValueKey('apple-player-layout'), skipOffstage: false),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.textContaining('Cola de Reproducción'), findsNothing);
    final appleLayout = find.byKey(const ValueKey('apple-player-layout'));
    expect(appleLayout, findsOneWidget);
    expect(ModalRoute.of(tester.element(appleLayout))?.isCurrent, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback queue header toggles pause and advances the queue', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final controller = _TestPlayerController(
      snapshot.copyWith(status: PlayerStatus.playing),
    );

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: controller,
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Cancion de prueba'), findsWidgets);
    expect(find.text('BStream Music'), findsWidgets);
    final queueTitle = find.byKey(const ValueKey('queue-title'));
    final queueDivider = find.byKey(const ValueKey('queue-list-divider'));
    expect(tester.widget<Text>(queueTitle).textAlign, TextAlign.center);
    expect(
      tester.getTopLeft(queueTitle).dy,
      greaterThan(tester.getBottomRight(queueDivider).dy),
      reason:
          'the queue summary belongs below the divider, apart from the current track card',
    );
    expect(find.text('Pausar'), findsOneWidget);
    expect(find.text('Ver en la lista'), findsOneWidget);
    expect(find.text('Siguiente'), findsOneWidget);
    expect(find.text('Cola de Reproducción - 0 Canciones'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('queue-playback-toggle')));
    await tester.pump();
    expect(controller.togglePlayPauseCalls, 1);
    expect(find.text('Pausado'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('queue-play-next')));
    await tester.pump();
    expect(controller.playNextCalls, 1);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      '$platform queue metadata scrolls long titles and artists on one line',
      (tester) async {
        _configureView(
          tester,
          platform == TargetPlatform.windows
              ? const Size(1000, 700)
              : const Size(320, 568),
        );
        const title =
            'A long song title with several versions and additional featured performers';
        const artist =
            'First artist, Second artist, Third artist and Fourth featured artist';
        await tester.pumpWidget(
          _playerHarness(
            platform: platform,
            snapshot: snapshot.copyWith(title: title, artist: artist),
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: PlayerStyle.appleMusic,
            playbackQueue: const PlaybackQueueState(
              entries: [
                PlaybackQueueEntry(
                  id: trackId,
                  title: title,
                  artist: artist,
                  isRemote: false,
                ),
              ],
              currentIndex: 0,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        if (platform != TargetPlatform.windows) {
          await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final titleFinder = find.byKey(const ValueKey('queue-current-title'));
        final artistFinder = find.byKey(const ValueKey('queue-current-artist'));
        final heart = find.byKey(const ValueKey('queue-favorite-toggle'));
        for (final label in [titleFinder, artistFinder]) {
          final marquee = tester.widget<MarqueeText>(label);
          expect(
            find.descendant(of: label, matching: find.byType(Flow)),
            findsOneWidget,
          );
          expect(
            tester
                .widget<Text>(
                  find.descendant(of: label, matching: find.byType(Text)),
                )
                .maxLines,
            1,
          );
          expect(
            tester.getSize(label).height,
            lessThan(marquee.style!.fontSize! * 1.8),
            reason: 'long metadata must not increase the header to two lines',
          );
          expect(
            tester.getRect(label).right,
            lessThanOrEqualTo(tester.getRect(heart).left),
          );
        }
        final titleText = find.descendant(
          of: titleFinder,
          matching: find.byType(Text),
        );
        final artistText = find.descendant(
          of: artistFinder,
          matching: find.byType(Text),
        );
        final titleStart = tester.getTopLeft(titleText).dx;
        final artistStart = tester.getTopLeft(artistText).dx;
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.getTopLeft(titleText).dx, lessThan(titleStart));
        expect(tester.getTopLeft(artistText).dx, lessThan(artistStart));
        expect(tester.getSize(heart), const Size(48, 48));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$platform queue heart toggles the current track and metadata is larger',
      (tester) async {
        _configureView(
          tester,
          platform == TargetPlatform.windows
              ? const Size(1280, 720)
              : const Size(320, 568),
        );
        final playlists = _TestPlaylistsController();
        await tester.pumpWidget(
          _playerHarness(
            platform: platform,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: playlists,
            style: PlayerStyle.appleMusic,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        if (platform != TargetPlatform.windows) {
          await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final heart = find.byKey(const ValueKey('queue-favorite-toggle'));
        final close = find.byKey(const ValueKey('queue-close'));
        expect(tester.getSize(heart), const Size(48, 48));
        expect(
          tester.getCenter(heart).dx,
          lessThan(tester.getCenter(close).dx),
        );
        expect(
          tester.getCenter(heart).dy,
          closeTo(tester.getCenter(close).dy, .1),
        );
        expect(
          tester
              .widget<MarqueeText>(
                find.byKey(const ValueKey('queue-current-title')),
              )
              .style
              ?.fontSize,
          16,
        );
        expect(
          tester
              .widget<MarqueeText>(
                find.byKey(const ValueKey('queue-current-artist')),
              )
              .style
              ?.fontSize,
          14,
        );
        expect(
          find.descendant(
            of: heart,
            matching: find.byIcon(Icons.favorite_border_rounded),
          ),
          findsOneWidget,
        );
        await tester.tap(heart);
        await tester.pump();
        expect(playlists.favoriteIds, contains(trackId));
        expect(
          find.descendant(
            of: heart,
            matching: find.byIcon(Icons.favorite_rounded),
          ),
          findsOneWidget,
        );
        await tester.tap(heart);
        await tester.pump();
        expect(playlists.favoriteIds, isNot(contains(trackId)));
        expect(
          find.descendant(
            of: heart,
            matching: find.byIcon(Icons.favorite_border_rounded),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'queue heart reuses the canonical streamed-track favorite action',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      const remote = TrackInfo(
        id: 'dQw4w9WgXcQ',
        title: 'Cancion remota',
        artist: 'Artista remoto',
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        album: 'Album canonico',
      );
      final playlists = _TestPlaylistsController();
      final remoteSnapshot = snapshot.copyWith(
        trackId: remote.id,
        title: remote.title,
        artist: remote.artist,
        sourceUrl: remote.url,
        isRemote: true,
      );
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: remoteSnapshot,
          localTrack: localTrack,
          playlists: playlists,
          canonicalRemoteTrack: remote,
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('queue-favorite-toggle')));
      await tester.pump();
      expect(playlists.remoteFavoriteCalls, 1);
      expect(playlists.remoteFavoriteTrack, same(remote));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'queue metadata and heart fit compact landscape with enlarged text',
    (tester) async {
      _configureView(tester, const Size(568, 320), textScaleFactor: 2);
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot.copyWith(
            title: 'Un titulo largo para comprobar los margenes de la cola',
            artist: 'Un artista con nombre largo',
          ),
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.appleMusic,
          playbackQueue: const PlaybackQueueState(
            entries: [
              PlaybackQueueEntry(
                id: trackId,
                title: 'Un titulo largo para comprobar los margenes de la cola',
                artist: 'Un artista con nombre largo',
                isRemote: false,
              ),
            ],
            currentIndex: 0,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.ensureVisible(
        find.byKey(const ValueKey('player-queue-toggle')),
      );
      await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (final key in [
        'queue-favorite-toggle',
        'queue-close',
        'queue-current-title',
        'queue-current-artist',
      ]) {
        expect(
          tester.getRect(find.byKey(ValueKey(key))).right,
          lessThanOrEqualTo(568),
        );
      }
      expect(
        tester.getSize(find.byType(ReorderableListView)).height,
        greaterThan(0),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playback queue actions fit a compact mobile width', (
    tester,
  ) async {
    _configureView(tester, const Size(320, 568));
    final controller = _TestPlayerController(
      snapshot.copyWith(status: PlayerStatus.playing),
    );

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: controller,
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Pausar'), findsOneWidget);
    expect(find.text('Ver en la lista'), findsOneWidget);
    expect(find.text('Siguiente'), findsOneWidget);
    for (final key in const [
      ValueKey('queue-playback-toggle'),
      ValueKey('queue-view-in-list'),
      ValueKey('queue-play-next'),
    ]) {
      final buttonRect = tester.getRect(find.byKey(key));
      final label = switch (key.value) {
        'queue-playback-toggle' => find.text('Pausar'),
        'queue-view-in-list' => find.text('Ver en la lista'),
        _ => find.text('Siguiente'),
      };
      final labelRect = tester.getRect(label);
      expect(labelRect.left, greaterThanOrEqualTo(buttonRect.left));
      expect(labelRect.right, lessThanOrEqualTo(buttonRect.right));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback queue header scrolls to the current song', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final entries = List<PlaybackQueueEntry>.generate(
      20,
      (index) => PlaybackQueueEntry(
        id: 'queue-$index',
        title: 'Canción $index',
        artist: 'Artista $index',
        isRemote: false,
      ),
    );

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot.copyWith(status: PlayerStatus.playing),
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playbackQueue: PlaybackQueueState(entries: entries, currentIndex: 16),
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Cola de Reproducción - 20 Canciones'), findsOneWidget);
    final viewButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('queue-view-in-list')),
    );
    expect(viewButton.onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('queue-view-in-list')));
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final currentSong = find.byKey(
      const ValueKey('playback-queue-16-queue-16'),
    );
    expect(currentSong, findsOneWidget);
    final listRect = tester.getRect(find.byType(ReorderableListView));
    final songRect = tester.getRect(currentSong);
    expect(songRect.top, greaterThanOrEqualTo(listRect.top));
    expect(songRect.bottom, lessThanOrEqualTo(listRect.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'BStream raises its classic cover and adds title spacing when phone portrait has spare room',
    (tester) async {
      _configureView(
        tester,
        const Size(390, 820),
        topPadding: 44,
        bottomPadding: 24,
      );
      final trackWithArtwork = LocalTrack(
        id: trackId,
        title: 'Cancion de prueba',
        artist: 'BStream Music',
        filePath: '/tmp/player-controls-track.m4a',
        thumbnailPath: '/tmp/bstream-balanced-classic-cover.jpg',
        addedAt: DateTime(2026),
      );

      for (final viewport in const [Size(390, 820), Size(390, 900)]) {
        tester.view.physicalSize = viewport;
        final measurements =
            <
              PlayerArtworkStyle,
              ({
                Rect artwork,
                Rect title,
                Rect primary,
                Rect utility,
                Rect scroll,
              })
            >{};
        for (final artworkStyle in PlayerArtworkStyle.values) {
          await tester.pumpWidget(
            _playerHarness(
              key: ValueKey('bstream-balanced-$viewport-$artworkStyle'),
              platform: TargetPlatform.android,
              snapshot: snapshot,
              localTrack: trackWithArtwork,
              playlists: _TestPlaylistsController(),
              artworkStyle: artworkStyle,
              disableAnimations: true,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          final artworkRect = tester.getRect(
            find.byKey(const ValueKey('player-large-artwork')),
          );
          final utilityRect = tester.getRect(
            find.byKey(const ValueKey('player-utility-capsule')),
          );
          measurements[artworkStyle] = (
            artwork: artworkRect,
            title: tester.getRect(
              find.byKey(const ValueKey('player-track-title')),
            ),
            primary: tester.getRect(
              find.byKey(const ValueKey('player-primary-control')),
            ),
            utility: utilityRect,
            scroll: tester.getRect(
              find.byKey(const ValueKey('player-content-scroll')),
            ),
          );
          final handleRect = tester.getRect(
            find.byKey(const ValueKey('bstream-player-grabber')),
          );
          expect(handleRect.top, greaterThanOrEqualTo(44));
          expect(artworkRect.top - handleRect.bottom, greaterThanOrEqualTo(12));
          expect(utilityRect.bottom, lessThanOrEqualTo(viewport.height - 24));
          expect(tester.takeException(), isNull);
        }

        final classic = measurements[PlayerArtworkStyle.classic]!;
        final expanded = measurements[PlayerArtworkStyle.expanded]!;
        final upwardShift = expanded.artwork.top - classic.artwork.top;
        expect(upwardShift, greaterThan(8), reason: '$viewport');
        final artworkOffset = Offset(0, upwardShift);
        final controlsOffset = Offset(
          0,
          expanded.title.top - classic.title.top,
        );
        expect(artworkOffset.dy, greaterThan(controlsOffset.dy));
        expect(
          expanded.artwork,
          rectMoreOrLessEquals(classic.artwork.shift(artworkOffset)),
        );
        expect(
          expanded.title,
          rectMoreOrLessEquals(classic.title.shift(controlsOffset)),
        );
        expect(
          expanded.primary,
          rectMoreOrLessEquals(classic.primary.shift(controlsOffset)),
        );
        expect(
          expanded.utility,
          rectMoreOrLessEquals(classic.utility.shift(controlsOffset)),
        );
        expect(
          classic.title.top - classic.artwork.bottom,
          greaterThan(expanded.title.top - expanded.artwork.bottom),
        );
        expect(classic.scroll, expanded.scroll);
        expect(
          classic.artwork.top - classic.scroll.top,
          lessThan(expanded.artwork.top - expanded.scroll.top),
        );
        expect(
          classic.scroll.bottom - classic.utility.bottom,
          greaterThan(expanded.scroll.bottom - expanded.utility.bottom),
        );
        expect(
          classic.artwork.top - classic.scroll.top,
          lessThanOrEqualTo(
            (classic.scroll.bottom - classic.utility.bottom) * 1.6,
          ),
          reason: 'The classic group balances the spare room above and below.',
        );
      }
    },
  );

  testWidgets(
    'BStream keeps its classic cover and controls safe on small frames',
    (tester) async {
      _configureView(
        tester,
        const Size(320, 568),
        topPadding: 44,
        bottomPadding: 24,
      );
      for (final viewport in const [Size(320, 568), Size(820, 390)]) {
        tester.view.physicalSize = viewport;
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('bstream-classic-small-$viewport'),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            disableAnimations: true,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          find.byKey(const ValueKey('player-expanded-artwork-hero')),
          findsNothing,
        );
        final handleRect = tester.getRect(
          find.byKey(const ValueKey('bstream-player-grabber')),
        );
        final artworkRect = tester.getRect(
          find.byKey(const ValueKey('player-large-artwork')),
        );
        expect(handleRect.top, greaterThanOrEqualTo(44));
        expect(artworkRect.top, greaterThanOrEqualTo(44));
        expect(artworkRect.left, greaterThanOrEqualTo(0));
        expect(artworkRect.right, lessThanOrEqualTo(viewport.width));
        if (viewport.height > viewport.width) {
          expect(artworkRect.top - handleRect.bottom, greaterThanOrEqualTo(12));
          expect(
            tester
                    .getRect(find.byKey(const ValueKey('player-track-title')))
                    .top -
                artworkRect.bottom,
            closeTo(8, 0.1),
          );
        } else {
          expect(
            find.byKey(const ValueKey('bstream-player-adaptive-landscape')),
            findsOneWidget,
          );
        }
        for (final key in [
          'player-primary-control',
          'player-utility-capsule',
        ]) {
          final control = find.byKey(ValueKey(key));
          await tester.ensureVisible(control);
          await tester.pump();
          final rect = tester.getRect(control);
          expect(rect.top, greaterThanOrEqualTo(44));
          expect(rect.bottom, lessThanOrEqualTo(viewport.height - 24 + 0.1));
        }
        expect(tester.takeException(), isNull, reason: '$viewport');
      }
    },
  );

  testWidgets('BStream keeps a gap between its collapse handle and cover', (
    tester,
  ) async {
    _configureView(tester, const Size(936, 680));
    for (final testCase in [
      (platform: TargetPlatform.windows, size: const Size(936, 680)),
      (platform: TargetPlatform.windows, size: const Size(1280, 900)),
      (platform: TargetPlatform.android, size: const Size(390, 820)),
      (platform: TargetPlatform.android, size: const Size(320, 720)),
    ]) {
      tester.view.physicalSize = testCase.size;
      await tester.pumpWidget(
        _playerHarness(
          key: ValueKey(
            'bstream-handle-gap-${testCase.platform}-${testCase.size}',
          ),
          platform: testCase.platform,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final handle = tester.getRect(
        find.byKey(const ValueKey('bstream-player-grabber')),
      );
      final artwork = tester.getRect(
        find.byKey(const ValueKey('player-large-artwork')),
      );
      expect(artwork.top - handle.bottom, greaterThanOrEqualTo(12));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Apple Music Style toggles the desktop playback queue rail', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 720));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final toggle = find.byKey(const ValueKey('player-queue-toggle'));
    final rail = find.byKey(const ValueKey('desktop-playback-queue-rail'));
    final switcher = find.byKey(
      const ValueKey('desktop-playback-queue-switcher'),
    );
    expect(rail, findsOneWidget);
    expect(
      find.byKey(const ValueKey('queue-header-artwork-background')),
      findsOneWidget,
    );
    expect(tester.getSize(switcher).width, closeTo(400, 0.1));

    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(rail, findsNothing);
    expect(tester.getSize(switcher).width, closeTo(0, 0.1));
    expect(tester.takeException(), isNull);

    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(rail, findsOneWidget);
    expect(tester.getSize(rail).width, closeTo(400, 0.1));
    expect(tester.getRect(rail).right, lessThanOrEqualTo(1280));
    expect(tester.getRect(rail).bottom, lessThanOrEqualTo(720));
    expect(find.byKey(const ValueKey('apple-player-layout')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'BStream adapts between wide and tall desktop windows without stretched controls',
    (tester) async {
      _configureView(tester, const Size(1280, 820));
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.windows,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('queue-close')));
      await tester.pumpAndSettle();

      for (final viewport in const [
        Size(1600, 900),
        Size(720, 1100),
        Size(1280, 720),
        Size(640, 480),
      ]) {
        tester.view.physicalSize = viewport;
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('player-utility-capsule')),
        );
        await tester.pumpAndSettle();
        final artwork = tester.getRect(
          find.byKey(const ValueKey('player-large-artwork')),
        );
        final title = tester.getRect(
          find.byKey(const ValueKey('player-track-title')),
        );
        final utility = tester.getRect(
          find.byKey(const ValueKey('player-utility-capsule')),
        );
        if (viewport.width >= 1200) {
          expect(
            artwork.right,
            lessThan(title.left),
            reason: '$viewport places artwork beside controls',
          );
          expect(title.width, lessThanOrEqualTo(520));
        } else if (viewport.height > 900) {
          expect(artwork.bottom, lessThan(title.top));
          expect(
            title.top - artwork.bottom,
            lessThan(70),
            reason: 'Tall windows keep metadata close to the cover',
          );
          expect(artwork.width, greaterThan(340));
        }
        expect(utility.left, greaterThanOrEqualTo(0));
        expect(utility.right, lessThanOrEqualTo(viewport.width));
        expect(utility.bottom, lessThanOrEqualTo(viewport.height));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('player-lyrics-control')),
            matching: find.text('Letras'),
          ),
          findsNothing,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$viewport resizes without overflow',
        );
      }
    },
  );

  testWidgets('BStream and Apple use the same capsule icon and button sizes', (
    tester,
  ) async {
    for (final scenario in [
      (TargetPlatform.android, const Size(360, 740)),
      (TargetPlatform.android, const Size(390, 820)),
      (TargetPlatform.windows, const Size(936, 680)),
      (TargetPlatform.windows, const Size(1280, 900)),
    ]) {
      _configureView(tester, scenario.$2);
      final measurements = <PlayerStyle, ({double icon, double button})>{};
      for (final style in [PlayerStyle.bstreamMusic, PlayerStyle.appleMusic]) {
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('utility-sizes-$scenario-$style'),
            platform: scenario.$1,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: style,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final control = find.byKey(const ValueKey('player-lyrics-control'));
        final button = tester.widget<IconButton>(
          find.descendant(of: control, matching: find.byType(IconButton)),
        );
        measurements[style] = (
          icon: button.iconSize!,
          button: tester.getSize(control).height,
        );
        expect(tester.takeException(), isNull);
      }
      expect(
        measurements[PlayerStyle.bstreamMusic],
        measurements[PlayerStyle.appleMusic],
        reason: '$scenario',
      );
    }
  });

  testWidgets('Windows puts four utility icons below transport', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 720));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final lyrics = find.byKey(const ValueKey('player-lyrics-control'));
    final shuffle = find.byKey(const ValueKey('player-shuffle-control'));
    final volume = find.byKey(const ValueKey('player-volume-control'));
    final repeat = find.byKey(const ValueKey('player-repeat-control'));

    expect(
      tester.getCenter(lyrics).dy,
      greaterThan(tester.getCenter(shuffle).dy),
    );
    expect(
      tester.getCenter(volume).dy,
      greaterThan(tester.getCenter(repeat).dy),
    );
    final utilityRects = [
      for (final key in const [
        'player-lyrics-control',
        'player-volume-control',
        'player-audio-output-control',
        'player-queue-toggle',
      ])
        tester.getRect(find.byKey(ValueKey(key))),
    ];
    for (var index = 1; index < utilityRects.length; index++) {
      expect(
        utilityRects[index].center.dy,
        closeTo(utilityRects.first.center.dy, 0.1),
      );
      expect(
        utilityRects[index].left,
        greaterThanOrEqualTo(utilityRects[index - 1].right),
      );
    }
    expect(
      find.descendant(of: lyrics, matching: find.text('Letras')),
      findsNothing,
    );
    expect(
      find.descendant(of: volume, matching: find.text('Volumen')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-favorite-control')),
      findsOneWidget,
    );
    _expectTransparentPrimaryControl(tester, mobile: false);
    expect(tester.takeException(), isNull);
  });

  for (final style in PlayerStyle.values) {
    testWidgets(
      '$style gently reduces compact metadata and preserves accessibility scaling',
      (tester) async {
        _configureView(tester, const Size(480, 900));
        Widget harness() => _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: style,
        );
        double titleSize() => tester
            .widget<MarqueeText>(
              find.byKey(const ValueKey('player-track-title')),
            )
            .style!
            .fontSize!;
        double artistSize() => tester
            .widget<Text>(find.byKey(const ValueKey('player-track-artist')))
            .style!
            .fontSize!;
        await tester.pumpWidget(harness());
        await tester.pump(const Duration(milliseconds: 500));
        final roomyTitle = titleSize();
        final roomyArtist = artistSize();
        tester.view.physicalSize = const Size(320, 568);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final compactTitle = titleSize();
        final compactArtist = artistSize();
        expect(compactTitle, lessThan(roomyTitle));
        expect(compactArtist, lessThan(roomyArtist));
        expect(compactTitle, greaterThanOrEqualTo(18));
        expect(compactArtist, greaterThanOrEqualTo(13));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final title = find.byKey(const ValueKey('player-track-title'));
        expect(MediaQuery.textScalerOf(tester.element(title)).scale(16), 32);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('320x568 player keeps text scale 3 controls reachable', (
    tester,
  ) async {
    _configureView(tester, const Size(320, 568), textScaleFactor: 3);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    for (final key in const [
      'player-favorite-control',
      'player-lyrics-control',
      'player-shuffle-control',
      'player-primary-control',
      'player-repeat-control',
      'player-queue-toggle',
      'player-audio-output-control',
      'player-volume-control',
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(rect.width, greaterThanOrEqualTo(48), reason: key);
      expect(rect.height, greaterThanOrEqualTo(48), reason: key);
    }
    expect(
      tester.getSize(find.byKey(const ValueKey('player-primary-control'))),
      const Size.square(64),
    );
    _expectTransparentPrimaryControl(tester, mobile: true);
    final volume = find.byKey(const ValueKey('player-volume-control'));
    await tester.ensureVisible(volume);
    await tester.pump();
    expect(tester.getRect(volume).bottom, lessThanOrEqualTo(568));
    expect(tester.takeException(), isNull);
  });

  for (final variant in const [
    (size: Size(320, 720), textScale: 1.0),
    (size: Size(390, 820), textScale: 1.6),
  ]) {
    testWidgets(
      '${variant.size.width.toInt()} px Android contains multiline CJK metadata',
      (tester) async {
        _configureView(
          tester,
          variant.size,
          textScaleFactor: variant.textScale,
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot.copyWith(
              title: '夜空に輝く星を見上げながら一緒に歌う長い日本語の曲名',
              artist: 'とても長い日本語のアーティスト名',
            ),
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final metadata = tester.getRect(
          find.byKey(const ValueKey('player-stable-metadata')),
        );
        final title = find.byKey(const ValueKey('player-track-title'));
        final artist = find.byKey(const ValueKey('player-track-artist'));
        final titleText = tester.widget<MarqueeText>(title);
        expect(titleText.text, contains('夜空'));
        expect(
          find.ancestor(of: title, matching: find.byType(Positioned)),
          findsNothing,
        );
        expect(tester.getRect(title).top, greaterThanOrEqualTo(metadata.top));
        expect(
          tester.getRect(artist).bottom,
          lessThanOrEqualTo(metadata.bottom + 0.1),
        );

        final volume = find.byKey(const ValueKey('player-volume-control'));
        await tester.ensureVisible(volume);
        await tester.pump();
        expect(tester.getSize(volume).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'short Android viewports preserve artwork and compact only spacing',
    (tester) async {
      _configureView(tester, const Size(360, 720), bottomPadding: 24);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          key: const ValueKey('error-artwork-baseline'),
          snapshot: snapshot.copyWith(
            status: PlayerStatus.failed,
            errorMessage: 'No se pudo abrir la pista.',
          ),
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final errorArtworkWidth = tester
          .getSize(find.byKey(const ValueKey('player-large-artwork')))
          .width;

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          key: const ValueKey('normal-artwork-short-viewport'),
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final artwork = find.byKey(const ValueKey('player-large-artwork'));
      final volume = find.byKey(const ValueKey('player-volume-control'));
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('player-content-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      final artworkWidth = tester.getSize(artwork).width;
      expect(errorArtworkWidth, closeTo(artworkWidth, 0.1));
      expect(tester.getSize(volume).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(volume).height, greaterThanOrEqualTo(48));
      expect(scroll.position.pixels, closeTo(0, 0.1));
      expect(scroll.position.maxScrollExtent, closeTo(0, 0.1));
      expect(
        tester.getRect(volume).bottom,
        lessThanOrEqualTo(720 - 24.0 + 0.1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short Android frames compact the artwork shadow and preserve metadata gaps',
    (tester) async {
      _configureView(tester, const Size(430, 900));

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      BoxShadow artworkShadow() {
        final surface = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('player-artwork-surface')),
        );
        return (surface.decoration as BoxDecoration).boxShadow!.single;
      }

      final artwork = find.byKey(const ValueKey('player-large-artwork'));
      final contentScroll = find.byKey(const ValueKey('player-content-scroll'));
      final metadata = find.byKey(const ValueKey('player-stable-metadata'));
      final timeline = find.byKey(const ValueKey('player-timeline'));
      final playbackControls = find.byKey(
        const ValueKey('player-playback-controls'),
      );
      final longShadow = artworkShadow();
      expect(find.byKey(const ValueKey('player-header')), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('player-track-title'))).top -
            tester.getRect(artwork).bottom,
        closeTo(46, 0.1),
      );
      expect(
        tester.getRect(timeline).top - tester.getRect(metadata).bottom,
        closeTo(22, 0.1),
      );
      expect(
        tester.getRect(playbackControls).top - tester.getRect(timeline).bottom,
        lessThan(18),
      );
      expect(longShadow.blurRadius, 42);
      expect(longShadow.spreadRadius, 6);
      expect(longShadow.offset.dy, 18);
      expect(longShadow.color.a, closeTo(0.67, 0.001));
      expect(
        tester.widget<SingleChildScrollView>(contentScroll).clipBehavior,
        Clip.hardEdge,
      );
      expect(
        find.byKey(const ValueKey('player-content-shadow-clip')),
        findsNothing,
      );
      final roomyScroll = tester.state<ScrollableState>(
        find.descendant(of: contentScroll, matching: find.byType(Scrollable)),
      );
      expect(roomyScroll.position.maxScrollExtent, closeTo(0, 0.1));

      tester.view
        ..physicalSize = const Size(360, 720)
        ..padding = const FakeViewPadding(bottom: 24);
      await tester.pump();

      final shortArtworkWidth = tester.getSize(artwork).width;
      final shortShadow = artworkShadow();
      expect(find.byKey(const ValueKey('player-tab-title')), findsNothing);
      expect(
        shortShadow.blurRadius / shortArtworkWidth,
        lessThanOrEqualTo(0.035),
      );
      expect(shortShadow.blurRadius, greaterThan(0));
      expect(shortShadow.spreadRadius, closeTo(0, 0.001));
      expect(shortShadow.offset.dy / shortArtworkWidth, closeTo(0.018, 0.001));
      expect(shortShadow.color.a, closeTo(0.3, 0.001));
      expect(shortShadow.color.a, lessThan(longShadow.color.a));
      expect(
        tester.widget<SingleChildScrollView>(contentScroll).clipBehavior,
        Clip.hardEdge,
      );
      final compactScroll = tester.state<ScrollableState>(
        find.descendant(of: contentScroll, matching: find.byType(Scrollable)),
      );
      expect(compactScroll.position.maxScrollExtent, closeTo(0, 0.1));
      final scrollRect = tester.getRect(contentScroll);
      final artworkRect = tester.getRect(artwork);
      final horizontalShadowExtent = _visibleGaussianShadowExtent(shortShadow);
      expect(
        horizontalShadowExtent,
        lessThanOrEqualTo(artworkRect.left - scrollRect.left + 0.1),
      );
      expect(
        horizontalShadowExtent,
        lessThanOrEqualTo(scrollRect.right - artworkRect.right + 0.1),
      );
      expect(
        shortShadow.blurRadius +
            shortShadow.spreadRadius +
            shortShadow.offset.dy,
        lessThan(
          longShadow.blurRadius +
              longShadow.spreadRadius +
              longShadow.offset.dy,
        ),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-volume-control')))
            .bottom,
        lessThanOrEqualTo(720 - 24.0 + 0.1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('S22 display zoom keeps the compact shadow inside its viewport', (
    tester,
  ) async {
    // The connected SM-S908U exposes a 1440x2808 app area at 600 dpi.
    _configureView(tester, const Size(384, 748.8));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final artwork = find.byKey(const ValueKey('player-large-artwork'));
    final contentScroll = find.byKey(const ValueKey('player-content-scroll'));
    final metadata = find.byKey(const ValueKey('player-stable-metadata'));
    final timeline = find.byKey(const ValueKey('player-timeline'));
    final playbackControls = find.byKey(
      const ValueKey('player-playback-controls'),
    );
    final surface = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('player-artwork-surface')),
    );
    final shadow = (surface.decoration as BoxDecoration).boxShadow!.single;
    final artworkRect = tester.getRect(artwork);
    final visibleShadowExtent = _visibleGaussianShadowExtent(shadow);
    final compactness = ((820 - 748.8) / 100).clamp(0.0, 1.0);
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: contentScroll, matching: find.byType(Scrollable)),
    );

    expect(tester.getSize(artwork).width, greaterThan(320));
    expect(scroll.position.pixels, closeTo(0, 0.1));
    expect(scroll.position.maxScrollExtent, closeTo(0, 0.1));
    final artworkTitleGap =
        tester.getRect(find.byKey(const ValueKey('player-track-title'))).top -
        artworkRect.bottom;
    final baseArtworkTitleGap = 22 - (14 * compactness);
    expect(
      artworkTitleGap,
      inInclusiveRange(baseArtworkTitleGap - 0.2, baseArtworkTitleGap + 24.2),
    );
    expect(
      artworkTitleGap,
      closeTo(
        tester
            .getSize(find.byKey(const ValueKey('player-artwork-title-gap')))
            .height,
        0.2,
      ),
    );
    expect(
      tester.getRect(timeline).top - tester.getRect(metadata).bottom,
      closeTo(22 - (15 * compactness), 0.2),
    );
    expect(
      tester.getRect(playbackControls).top - tester.getRect(timeline).bottom,
      inInclusiveRange(0, 18 - (16 * compactness)),
    );
    expect(shadow.color.a, lessThanOrEqualTo(0.32));
    expect(shadow.spreadRadius, lessThan(0.3));
    // With no vertical overflow RenderSingleChildViewport does not install a
    // clip, so the compact halo may use the widened control canvas too.
    expect(visibleShadowExtent, lessThanOrEqualTo(artworkRect.left + 0.1));
    expect(
      visibleShadowExtent,
      lessThanOrEqualTo(384 - artworkRect.right + 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'width-compacted artwork also compacts its shadow on a short phone',
    (tester) async {
      _configureView(tester, const Size(360, 800), bottomPadding: 24);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final artworkWidth = tester
          .getSize(find.byKey(const ValueKey('player-large-artwork')))
          .width;
      final surface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('player-artwork-surface')),
      );
      final shadow = (surface.decoration as BoxDecoration).boxShadow!.single;

      expect(artworkWidth, lessThan(400));
      expect(shadow.blurRadius / artworkWidth, lessThanOrEqualTo(0.095));
      expect(shadow.spreadRadius / artworkWidth, lessThanOrEqualTo(0.007));
      expect(shadow.offset.dy / artworkWidth, lessThanOrEqualTo(0.035));
      expect(shadow.color.a, lessThan(0.67));
      expect(
        tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('player-content-scroll')),
            )
            .clipBehavior,
        Clip.hardEdge,
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-volume-control')))
            .bottom,
        lessThanOrEqualTo(800 - 24.0 + 0.1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short desktop frames compact the shadow with the artwork', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 900));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    BoxShadow artworkShadow() {
      final surface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('player-artwork-surface')),
      );
      return (surface.decoration as BoxDecoration).boxShadow!.single;
    }

    final artwork = find.byKey(const ValueKey('player-large-artwork'));
    final roomyArtworkWidth = tester.getSize(artwork).width;
    final roomyShadow = artworkShadow();
    expect(roomyShadow.blurRadius, 42);
    expect(roomyShadow.spreadRadius, 6);
    expect(roomyShadow.offset.dy, 18);

    tester.view.physicalSize = const Size(960, 600);
    await tester.pump();

    final compactArtworkWidth = tester.getSize(artwork).width;
    final compactShadow = artworkShadow();
    expect(compactArtworkWidth, lessThan(roomyArtworkWidth));
    expect(compactShadow.blurRadius, lessThan(roomyShadow.blurRadius));
    expect(compactShadow.spreadRadius, lessThan(roomyShadow.spreadRadius));
    expect(compactShadow.offset.dy, lessThan(roomyShadow.offset.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'full player transitions metadata and artwork without a luminance dip',
    (tester) async {
      _configureView(tester, const Size(960, 600));
      const first = PlayerSnapshot(
        status: PlayerStatus.playing,
        title: 'Primera transicion',
        artist: 'Primer artista',
        trackId: 'player-transition-first',
        duration: Duration(minutes: 3),
      );
      const second = PlayerSnapshot(
        status: PlayerStatus.playing,
        title: 'Segunda transicion',
        artist: 'Segundo artista',
        trackId: 'player-transition-second',
        duration: Duration(minutes: 4),
      );
      final controller = _TestPlayerController(first);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.windows,
          snapshot: first,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final artworkTransition = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('player-artwork-track-transition')),
      );
      final metadataTransition = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('player-metadata-track-transition')),
      );
      expect(artworkTransition.duration, const Duration(milliseconds: 420));
      expect(metadataTransition.duration, const Duration(milliseconds: 420));

      controller.emit(second);
      await tester.pump();

      final transitioningTitles = tester
          .widgetList<MarqueeText>(
            find.byKey(const ValueKey('player-track-title')),
          )
          .map((widget) => widget.text);
      expect(transitioningTitles, containsAll([first.title, second.title]));
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsNWidgets(2),
        reason: 'The track id must animate even when both covers are absent.',
      );
      expect(
        find.byKey(const ValueKey('player-track-artist-action')),
        findsNWidgets(2),
      );

      await tester.pump(const Duration(milliseconds: 210));
      final artworkOpacities = tester
          .widgetList<Opacity>(
            find.descendant(
              of: find.byKey(const ValueKey('player-artwork-track-transition')),
              matching: find.byType(Opacity),
            ),
          )
          .map((widget) => widget.opacity)
          .toList(growable: false);
      expect(artworkOpacities, contains(1));
      expect(
        artworkOpacities.any((opacity) => opacity > 0 && opacity < 1),
        isTrue,
      );

      await tester.pump(const Duration(milliseconds: 220));
      final settledTitle = tester.widget<MarqueeText>(
        find.byKey(const ValueKey('player-track-title')),
      );
      expect(settledTitle.text, second.title);
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('full player track transitions honor reduced motion', (
    tester,
  ) async {
    _configureView(tester, const Size(960, 600));
    const first = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Primera sin movimiento',
      trackId: 'player-reduced-first',
    );
    const second = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Segunda sin movimiento',
      trackId: 'player-reduced-second',
    );
    final controller = _TestPlayerController(first);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: first,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: controller,
        disableAnimations: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    for (final key in const [
      'player-artwork-track-transition',
      'player-metadata-track-transition',
    ]) {
      final switcher = tester.widget<AnimatedSwitcher>(
        find.byKey(ValueKey(key)),
      );
      expect(switcher.duration, Duration.zero);
      expect(switcher.reverseDuration, Duration.zero);
    }

    controller.emit(second);
    await tester.pump();
    await tester.pump();

    final title = tester.widget<MarqueeText>(
      find.byKey(const ValueKey('player-track-title')),
    );
    expect(title.text, second.title);
    expect(
      find.byKey(const ValueKey('player-artwork-surface')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hidden full player replaces track surfaces without retaining outgoing trees',
    (tester) async {
      _configureView(tester, const Size(960, 600));
      const first = PlayerSnapshot(
        status: PlayerStatus.playing,
        title: 'Cancion visible inicial',
        artist: 'Artista inicial',
        trackId: 'hidden-transition-0',
      );
      final controller = _TestPlayerController(first);
      final transitionsEnabled = ValueNotifier<bool>(true);
      addTearDown(transitionsEnabled.dispose);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.windows,
          snapshot: first,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
          trackTransitionsEnabledListenable: transitionsEnabled,
        ),
      );
      await tester.pump();
      await tester.pump();

      controller.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Cancion al comenzar a ocultar',
          artist: 'Artista al comenzar a ocultar',
          trackId: 'hidden-transition-1',
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsNWidgets(2),
      );

      transitionsEnabled.value = false;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsOneWidget,
      );

      for (var index = 2; index <= 12; index++) {
        controller.emit(
          PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion oculta $index',
            artist: 'Artista oculto $index',
            trackId: 'hidden-transition-$index',
          ),
        );
        await tester.pump();
      }

      for (final key in const [
        'player-artwork-track-transition',
        'player-metadata-track-transition',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing);
      }
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-track-artist-action')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<MarqueeText>(
              find.byKey(const ValueKey('player-track-title')),
            )
            .text,
        'Cancion oculta 12',
      );

      transitionsEnabled.value = true;
      await tester.pump();
      for (final key in const [
        'player-artwork-track-transition',
        'player-metadata-track-transition',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      final playerSurface = find.byKey(
        const ValueKey('desktop-player-surface'),
      );
      expect(
        find.descendant(
          of: playerSurface,
          matching: find.text('Cancion oculta 12'),
        ),
        findsOneWidget,
      );

      controller.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Cancion visible siguiente',
          artist: 'Artista visible siguiente',
          trackId: 'visible-transition-next',
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('player-track-artist-action')),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: playerSurface,
          matching: find.text('Cancion oculta 12'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: playerSurface,
          matching: find.text('Cancion visible siguiente'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('player errors keep normal artwork and use scroll as fallback', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 720), bottomPadding: 24);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot.copyWith(
          status: PlayerStatus.failed,
          errorMessage: 'No se pudo abrir la pista.',
        ),
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.byKey(const ValueKey('player-error-message')), findsOneWidget);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('player-content-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('960x600 desktop player fits text scale 2', (tester) async {
    _configureView(tester, const Size(960, 600), textScaleFactor: 2);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('player-primary-control')),
      findsOneWidget,
    );
    _expectTransparentPrimaryControl(tester, mobile: false);
    expect(
      find.byKey(const ValueKey('player-progress-color-animation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final variant in const [
    (
      name: 'Android 320',
      size: Size(320, 720),
      platform: TargetPlatform.android,
      textScale: 1.0,
    ),
    (
      name: 'Android 360',
      size: Size(360, 800),
      platform: TargetPlatform.android,
      textScale: 1.0,
    ),
    (
      name: 'Android 320 text scale 3',
      size: Size(320, 568),
      platform: TargetPlatform.android,
      textScale: 3.0,
    ),
    (
      name: 'Windows desktop text scale 2',
      size: Size(960, 600),
      platform: TargetPlatform.windows,
      textScale: 2.0,
    ),
  ]) {
    testWidgets(
      '${variant.name} keeps the title-to-artist gap independent of title lines',
      (tester) async {
        _configureView(
          tester,
          variant.size,
          textScaleFactor: variant.textScale,
        );

        Future<
          ({
            Rect artwork,
            double artworkTitleGap,
            double gap,
            double titleHeight,
          })
        >
        renderTitle(String title) async {
          await tester.pumpWidget(
            _playerHarness(
              platform: variant.platform,
              snapshot: snapshot.copyWith(
                title: title,
                artist:
                    'Un nombre de artista deliberadamente largo para validar '
                    'el espacio reservado a las acciones',
              ),
              localTrack: localTrack,
              playlists: _TestPlaylistsController(),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();

          final titleFinder = find.byKey(const ValueKey('player-track-title'));
          final artistFinder = find.byKey(
            const ValueKey('player-track-artist'),
          );
          final titleWidget = tester.widget<MarqueeText>(titleFinder);
          final titleRect = tester.getRect(titleFinder);
          final artistRect = tester.getRect(artistFinder);
          final favoriteRect = tester.getRect(
            find.byKey(const ValueKey('player-favorite-control')),
          );

          expect(titleWidget.text, title);
          expect(artistRect.right, lessThanOrEqualTo(favoriteRect.left));
          expect(
            tester
                .getRect(find.byKey(const ValueKey('player-favorite-control')))
                .center
                .dy,
            closeTo(artistRect.center.dy, 0.1),
          );
          expect(tester.takeException(), isNull);
          final artworkRect = tester.getRect(
            find.byKey(const ValueKey('player-large-artwork')),
          );
          return (
            artwork: artworkRect,
            artworkTitleGap: titleRect.top - artworkRect.bottom,
            gap: artistRect.top - titleRect.bottom,
            titleHeight: titleRect.height,
          );
        }

        final shortTitle = await renderTitle('A');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        final longTitle = await renderTitle(
          'Un titulo deliberadamente largo que necesita dos lineas en el '
          'reproductor sin separar de forma artificial el nombre del artista',
        );

        expect(longTitle.titleHeight, closeTo(shortTitle.titleHeight, 0.1));
        expect(longTitle.gap, closeTo(shortTitle.gap, 0.1));
        if (variant.platform == TargetPlatform.android) {
          expect(longTitle.artwork, shortTitle.artwork);
          final compactness = ((820 - variant.size.height) / 100).clamp(
            0.0,
            1.0,
          );
          final expectedArtworkTitleGap = 22 - (14 * compactness);
          for (final gap in [
            shortTitle.artworkTitleGap,
            longTitle.artworkTitleGap,
          ]) {
            if (variant.textScale > 1.35 || compactness == 1) {
              expect(gap, closeTo(expectedArtworkTitleGap, 0.1));
            } else {
              expect(
                gap,
                inInclusiveRange(
                  expectedArtworkTitleGap - 0.1,
                  expectedArtworkTitleGap + 24.1,
                ),
              );
            }
          }
          expect(
            longTitle.artworkTitleGap,
            closeTo(
              tester
                  .getSize(
                    find.byKey(const ValueKey('player-artwork-title-gap')),
                  )
                  .height,
              0.1,
            ),
          );
          expect(
            longTitle.artworkTitleGap,
            closeTo(shortTitle.artworkTitleGap, 0.1),
          );
        }
      },
    );
  }

  testWidgets('share stays in the overflow menu for every player style', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const shareSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Titulo resumido del reproductor',
      artist: 'Artista resumido',
      trackId: 'dQw4w9WgXcQ',
      sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      duration: Duration(minutes: 3),
    );
    const canonicalTrack = TrackInfo(
      id: 'dQw4w9WgXcQ',
      title: 'Cancion para compartir',
      artist: 'Artista de prueba',
      url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      album: 'Album canonico',
    );

    for (final style in PlayerStyle.values) {
      final shareService = _TestTrackShareService();
      await tester.pumpWidget(
        _playerHarness(
          key: ValueKey('share-menu-$style'),
          platform: TargetPlatform.android,
          snapshot: shareSnapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          shareService: shareService,
          canonicalRemoteTrack: canonicalTrack,
          style: style,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final directShare = find.byKey(const ValueKey('player-share-control'));
      expect(directShare, findsNothing);
      final menu = find.byKey(const ValueKey('player-menu-control'));
      expect(menu, findsOneWidget);

      await tester.tap(menu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        shareService.shareCalls,
        0,
        reason: 'opening the $style menu must not start sharing',
      );
      final popupSurface = find.byKey(const ValueKey('app-menu-sheet-surface'));
      expect(popupSurface, findsOneWidget);
      expect(tester.getSize(popupSurface).width, greaterThan(48));
      expect(tester.getSize(popupSurface).height, greaterThan(48));
      expect(
        find.byKey(const ValueKey('player-menu-go-to-artist')),
        findsOneWidget,
      );
      final shareAction = find.byKey(const ValueKey('player-menu-share'));
      expect(shareAction, findsOneWidget);

      await tester.tap(shareAction);
      await tester.pump();

      expect(shareService.shareCalls, 1);
      expect(shareService.sharedTrack, canonicalTrack);
      expect(shareService.sharedTrack!.album, 'Album canonico');
      expect(shareService.title, 'Compartir canción');
      expect(
        shareService.message,
        'Escucha "Cancion para compartir" de Artista de prueba.',
      );
      expect(shareService.sharePositionOrigin, isNotNull);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets(
    'downloaded track shares its YouTube origin, not its local path',
    (tester) async {
      _configureView(tester, const Size(360, 800));
      final shareService = _TestTrackShareService();
      final downloadedTrack = LocalTrack(
        id: 'local-download',
        title: 'Cancion descargada',
        artist: 'Artista local',
        filePath: r'C:\music\private-track.m4a',
        sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        sourceId: 'dQw4w9WgXcQ',
        addedAt: DateTime(2026),
      );
      const localSnapshot = PlayerSnapshot(
        status: PlayerStatus.paused,
        title: 'Cancion descargada',
        artist: 'Artista local',
        trackId: 'local-download',
        sourceUrl: r'C:\music\private-track.m4a',
      );

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: localSnapshot,
          localTrack: downloadedTrack,
          playlists: _TestPlaylistsController(),
          shareService: shareService,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const ValueKey('player-menu-control')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('player-menu-share')));
      await tester.pump();

      expect(shareService.shareCalls, 1);
      expect(shareService.sharedTrack?.id, 'dQw4w9WgXcQ');
      expect(
        shareService.sharedTrack?.url,
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      expect(shareService.sharedTrack?.url, isNot(contains('private-track')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('external playback exposes transport but no library actions', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final shareService = _TestTrackShareService();
    final artistService = _TestArtistService();

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot.copyWith(
          sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          isExternal: true,
        ),
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        shareService: shareService,
        youtubeMusicSearch: artistService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.byKey(const ValueKey('player-share-control')), findsNothing);
    expect(find.byKey(const ValueKey('player-menu-control')), findsNothing);
    expect(find.byKey(const ValueKey('player-favorite-control')), findsNothing);
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    expect(
      find.byKey(const ValueKey('player-menu-go-to-artist')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('player-menu-go-to-album')), findsNothing);

    final trackArtist = tester.widget<InkWell>(
      find.byKey(const ValueKey('player-track-artist-action')),
    );
    expect(trackArtist.onTap, isNull);
    expect(artistService.profileCalls, 0);

    expect(find.byKey(const ValueKey('player-lyrics-control')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-volume-control')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-primary-control')),
      findsOneWidget,
    );
    expect(shareService.shareCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unshareable playback keeps the menu share action disabled', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final shareService = _TestTrackShareService(canShareResult: false);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        shareService: shareService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('player-share-control')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-menu-control')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final share = find.byKey(const ValueKey('player-menu-share'));
    expect(tester.widget<ListTile>(share).enabled, isFalse);
    await tester.tap(share);
    await tester.pump();
    expect(shareService.shareCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('share failure is reported with the localized message', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final shareService = _TestTrackShareService(throwsOnShare: true);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        shareService: shareService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('player-menu-control')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('player-menu-share')));
    await tester.pump();

    expect(find.text('No se pudo compartir la canción.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download from player stays open and confirms the queue', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción remota',
      artist: 'Artista remoto',
      trackId: 'remote-download-1',
      sourceUrl: 'https://www.youtube.com/watch?v=remote-download-1',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'remote-download-1',
      title: 'Canción remota',
      artist: 'Artista remoto',
      url: 'https://www.youtube.com/watch?v=remote-download-1',
    );
    final downloads = _RecordingDownloadController();
    var searchOpenCalls = 0;

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        downloadController: downloads,
        onOpenSearch: () => searchOpenCalls += 1,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-menu-download')));
    await tester.pump(const Duration(milliseconds: 600));

    expect(downloads.downloadCalls, 1);
    expect(downloads.downloadedTrack?.id, 'remote-download-1');
    expect(searchOpenCalls, 0);
    expect(find.byType(PlayerPanel), findsOneWidget);
    expect(
      find.text('Canción añadida a la cola de descargas.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('download enqueue failure is reported without leaving player', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción remota',
      artist: 'Artista remoto',
      trackId: 'remote-download-error',
      sourceUrl: 'https://www.youtube.com/watch?v=remote-download-error',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    final downloads = _RecordingDownloadController(fail: true);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        downloadController: downloads,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-menu-download')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(downloads.downloadCalls, 1);
    expect(find.byType(PlayerPanel), findsOneWidget);
    expect(
      find.text('No se pudo añadir la canción a la cola de descargas.'),
      findsOneWidget,
    );
    expect(find.text('Canción añadida a la cola de descargas.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final entryPoint in <String>['artist-name', 'menu']) {
    testWidgets('$entryPoint opens the first artist profile', (tester) async {
      _configureView(tester, const Size(360, 800));
      const remoteSnapshot = PlayerSnapshot(
        status: PlayerStatus.paused,
        title: 'Colaboración',
        artist: 'Artista Primero, Artista Segundo',
        trackId: 'popular0001',
        sourceUrl: 'https://www.youtube.com/watch?v=popular0001',
        duration: Duration(minutes: 3),
        isRemote: true,
      );
      const canonicalTrack = TrackInfo(
        id: 'popular0001',
        title: 'Colaboración',
        artist: 'Artista Primero, Artista Segundo',
        artists: <String>['Artista Primero', 'Artista Segundo'],
        artistBrowseIds: <String?>['UCartistFirst', 'UCartistSecond'],
        url: 'https://www.youtube.com/watch?v=popular0001',
      );
      final artistService = _TestArtistService();

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: remoteSnapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          canonicalRemoteTrack: canonicalTrack,
          youtubeMusicSearch: artistService,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      if (entryPoint == 'artist-name') {
        final artistAction = tester.widget<InkWell>(
          find.byKey(const ValueKey('player-track-artist-action')),
        );
        artistAction.onTap!();
        artistAction.onTap!();
      } else {
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        expect(find.text('Ir al artista'), findsOneWidget);
        await tester.tap(find.text('Ir al artista'));
      }
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('artist-profile-page')), findsOneWidget);
      expect(find.text('Artista Primero'), findsOneWidget);
      expect(artistService.lastBrowseId, 'UCartistFirst');
      expect(artistService.profileCalls, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('player menu opens the resolved YouTube Music album', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      album: 'Álbum correcto',
      trackId: 'albumtrk001',
      sourceUrl: 'https://www.youtube.com/watch?v=albumtrk001',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'albumtrk001',
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      artists: <String>['Artista del álbum'],
      artistBrowseIds: <String?>['UCalbumArtist'],
      album: 'Álbum correcto',
      url: 'https://www.youtube.com/watch?v=albumtrk001',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    final albumService = _TestAlbumService();

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        youtubeMusicSearch: albumService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(albumService.searchCalls, 0);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('player-menu-go-to-album')),
      findsOneWidget,
    );
    expect(find.text('Ir al álbum'), findsOneWidget);
    await tester.tap(find.text('Ir al álbum'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
    expect(find.text('Álbum correcto'), findsWidgets);
    expect(albumService.lastAlbumBrowseId, 'MPREalbumCorrect');
    expect(albumService.searchCalls, 1);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ir al álbum'));
    await tester.pumpAndSettle();
    expect(albumService.searchCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player resolves a missing album name from the song catalog', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Cancion sin album',
      artist: 'Artista del album',
      trackId: 'songalbum01',
      sourceUrl: 'https://www.youtube.com/watch?v=songalbum01',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'songalbum01',
      title: 'Cancion sin album',
      artist: 'Artista del album',
      artists: <String>['Artista del album'],
      artistBrowseIds: <String?>['UCalbumArtist'],
      url: 'https://www.youtube.com/watch?v=songalbum01',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    final albumService = _TestRelatedAlbumService(
      nextSongs: <InnerTubeSong>[
        InnerTubeSong(
          videoId: 'different01',
          title: 'Otro resultado',
          artists: const <String>['Otro artista'],
          album: 'Álbum incorrecto',
          albumBrowseId: 'MPREalbumWrong',
        ),
        InnerTubeSong(
          videoId: 'songalbum01',
          title: 'Cancion sin album',
          artists: const <String>['Artista del album'],
          album: 'Álbum correcto',
          albumBrowseId: 'MPREalbumCorrect',
        ),
      ],
    );

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        youtubeMusicSearch: albumService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(albumService.nextCalls, 0);
    expect(albumService.searchCalls, 0);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('player-menu-go-to-album')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('player-menu-go-to-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
    expect(albumService.nextCalls, 1);
    expect(albumService.searchCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid album lookup reports unavailable without navigating', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      album: 'Álbum correcto',
      trackId: 'albumtrk001',
      sourceUrl: 'https://www.youtube.com/watch?v=albumtrk001',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'albumtrk001',
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      artists: <String>['Artista del álbum'],
      album: 'Álbum correcto',
      url: 'https://www.youtube.com/watch?v=albumtrk001',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    final albumService = _TestAlbumService(albumBrowseId: 'VLnot-an-album');

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        youtubeMusicSearch: albumService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump();

    expect(albumService.searchCalls, 0);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('player-menu-go-to-album')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('player-menu-go-to-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsNothing,
    );
    expect(
      find.text('No se pudo encontrar el álbum de esta canción.'),
      findsOneWidget,
    );
    expect(albumService.searchCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album lookup failure does not block the normal player menu', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      album: 'Álbum correcto',
      trackId: 'albumtrk001',
      sourceUrl: 'https://www.youtube.com/watch?v=albumtrk001',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'albumtrk001',
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      artists: <String>['Artista del álbum'],
      album: 'Álbum correcto',
      url: 'https://www.youtube.com/watch?v=albumtrk001',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    final albumService = _TestAlbumService(throwOnSearch: true);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        youtubeMusicSearch: albumService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Añadir a playlist'), findsOneWidget);
    expect(find.text('Añadir a favoritos'), findsOneWidget);
    expect(find.text('Ir al álbum'), findsOneWidget);
    expect(albumService.searchCalls, 0);
    await tester.tap(find.byKey(const ValueKey('player-menu-go-to-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('No se pudo encontrar el álbum de esta canción.'),
      findsOneWidget,
    );
    expect(albumService.searchCalls, 1);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-menu-go-to-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(albumService.searchCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('title heart toggles Favorites and uses the app accent', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final playlists = _TestPlaylistsController();

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: playlists,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final favorite = find.byKey(const ValueKey('player-favorite-control'));
    final title = find.byKey(const ValueKey('player-track-title'));
    expect(favorite, findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(
      tester.getCenter(favorite).dx,
      greaterThan(tester.getCenter(title).dx),
    );

    await tester.tap(favorite);
    await tester.pump();

    expect(playlists.favoriteIds, contains(trackId));
    final filledHeart = tester.widget<Icon>(
      find.descendant(
        of: favorite,
        matching: find.byIcon(Icons.favorite_rounded),
      ),
    );
    final favoriteButton = tester.widget<IconButton>(favorite);
    final context = tester.element(favorite);
    expect(favoriteButton.color, Theme.of(context).colorScheme.primary);
    expect(filledHeart.icon, Icons.favorite_rounded);

    await tester.tap(favorite);
    await tester.pump();

    expect(playlists.favoriteIds, isNot(contains(trackId)));
    expect(
      find.descendant(
        of: favorite,
        matching: find.byIcon(Icons.favorite_border_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

void _expectTransparentPrimaryControl(
  WidgetTester tester, {
  required bool mobile,
}) {
  final primaryFinder = find.byKey(const ValueKey('player-primary-control'));
  final primary = tester.widget<IconButton>(primaryFinder);
  final previous = tester.widget<IconButton>(
    find.descendant(
      of: find.byKey(const ValueKey('player-previous-control')),
      matching: find.byType(IconButton),
    ),
  );
  final next = tester.widget<IconButton>(
    find.descendant(
      of: find.byKey(const ValueKey('player-next-control')),
      matching: find.byType(IconButton),
    ),
  );

  expect(
    primary.style?.backgroundColor?.resolve(<WidgetState>{}),
    Colors.transparent,
  );
  expect(
    primary.style?.backgroundColor?.resolve(<WidgetState>{
      WidgetState.disabled,
    }),
    Colors.transparent,
  );
  expect(primary.color, previous.color);
  expect(primary.color, next.color);

  final buttonSize = tester.getSize(primaryFinder).shortestSide;
  final isShowingPause = find
      .descendant(of: primaryFinder, matching: find.byIcon(Icons.pause_rounded))
      .evaluate()
      .isNotEmpty;
  final expectedIconSize = mobile
      ? isShowingPause
            ? (buttonSize * 0.80).clamp(58.0, 76.0)
            : (buttonSize * 0.92).clamp(68.0, 88.0)
      : isShowingPause
      ? (buttonSize * 0.76).clamp(56.0, 88.0)
      : (buttonSize * 0.88).clamp(64.0, 104.0);
  expect(primary.iconSize, closeTo(expectedIconSize, 0.01));
  expect(
    primary.iconSize!,
    greaterThan(previous.iconSize! * (isShowingPause ? 1.20 : 1.40)),
  );
  expect(
    primary.iconSize!,
    greaterThan(next.iconSize! * (isShowingPause ? 1.20 : 1.40)),
  );
  final iconTranslation = tester.widget<Transform>(
    find.descendant(of: primaryFinder, matching: find.byType(Transform)),
  );
  expect(
    iconTranslation.transform.getTranslation().x,
    isShowingPause
        ? 0
        : mobile
        ? 1.25
        : 1.5,
  );
  expect(iconTranslation.transform.getTranslation().y, 0);
}

double _visibleGaussianShadowExtent(BoxShadow shadow) {
  const blurRadiusToSigma = 0.57735;
  return shadow.spreadRadius +
      (3 * ((shadow.blurRadius * blurRadiusToSigma) + 0.5));
}

Future<void> _writeSolidWhiteArtwork(File file) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = Colors.white,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 4);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await file.writeAsBytes(data.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void _configureView(
  WidgetTester tester,
  Size size, {
  double textScaleFactor = 1,
  double topPadding = 0,
  double bottomPadding = 0,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..padding = FakeViewPadding(top: topPadding, bottom: bottomPadding)
    ..viewPadding = FakeViewPadding(top: topPadding, bottom: bottomPadding);
  tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
  addTearDown(() {
    tester.view
      ..resetPhysicalSize()
      ..resetDevicePixelRatio()
      ..resetPadding()
      ..resetViewPadding();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

Widget _playerHarness({
  Key? key,
  required TargetPlatform platform,
  required PlayerSnapshot snapshot,
  required LocalTrack localTrack,
  required _TestPlaylistsController playlists,
  TrackShareService? shareService,
  ArtworkProgressColorService? menuColorService,
  TrackInfo? canonicalRemoteTrack,
  _TestPlayerController? playerController,
  YouTubeMusicSearch? youtubeMusicSearch,
  DownloadController? downloadController,
  VoidCallback? onOpenSearch,
  VoidCallback? onCollapse,
  bool drawBackground = false,
  bool disableAnimations = false,
  ValueListenable<bool>? trackTransitionsEnabledListenable,
  PlayerStyle style = defaultPlayerStyle,
  PlayerFont? playerFont,
  bool showAudioQuality = false,
  _PlayerFontSettingsController? settingsController,
  PlayerArtworkStyle artworkStyle = defaultPlayerArtworkStyle,
  bool animatedArtworkEnabled = false,
  SurfaceBackgroundMode backgroundMode = SurfaceBackgroundMode.accent,
  Brightness brightness = Brightness.dark,
  AppAccent accent = AppAccent.blue,
  LocalAudioQualityService? localAudioQualityService,
  PlaybackQueueState? playbackQueue,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent.seedColor,
    brightness: brightness,
  ).copyWith(primary: accent.seedColor);

  return ProviderScope(
    key: key,
    overrides: [
      if (localAudioQualityService != null)
        localPlaybackAudioQualityServiceProvider.overrideWithValue(
          localAudioQualityService,
        ),
      playerControllerProvider.overrideWith(
        () =>
            playerController ??
            _TestPlayerController(
              snapshot,
              canonicalRemoteTrack: canonicalRemoteTrack,
            ),
      ),
      playlistsControllerProvider.overrideWith(() => playlists),
      if (playerFont != null || showAudioQuality || settingsController != null)
        settingsControllerProvider.overrideWith(
          () =>
              settingsController ??
              _PlayerFontSettingsController(
                playerFont ?? defaultPlayerFont,
                showAudioQuality: showAudioQuality,
              ),
        ),
      if (playbackQueue != null)
        playbackQueueProvider.overrideWith(
          () => _TestPlaybackQueueNotifier(playbackQueue),
        ),
      libraryTracksProvider.overrideWith((ref) async => [localTrack]),
      trackShareServiceProvider.overrideWithValue(
        shareService ?? _TestTrackShareService(),
      ),
      if (menuColorService != null)
        artworkSurfaceColorServiceProvider.overrideWithValue(menuColorService),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
      if (youtubeMusicSearch != null)
        youtubeMusicSearchProvider.overrideWithValue(youtubeMusicSearch),
      if (downloadController != null)
        downloadControllerProvider.overrideWith(() => downloadController),
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: platform,
        colorScheme: scheme,
        extensions: <ThemeExtension<dynamic>>[
          AppAccentTheme(accent: accent),
          AppSurfaceTheme(backgroundMode: backgroundMode),
        ],
      ),
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: Scaffold(
        body: trackTransitionsEnabledListenable == null
            ? PlayerPanel(
                drawBackground: drawBackground,
                onOpenSearch: onOpenSearch,
                onCollapse: onCollapse,
                style: style,
                artworkStyle: artworkStyle,
                animatedArtworkEnabled: animatedArtworkEnabled,
              )
            : ValueListenableBuilder<bool>(
                valueListenable: trackTransitionsEnabledListenable,
                builder: (context, enabled, _) => PlayerPanel(
                  drawBackground: drawBackground,
                  onOpenSearch: onOpenSearch,
                  onCollapse: onCollapse,
                  trackTransitionsEnabled: enabled,
                  style: style,
                  artworkStyle: artworkStyle,
                  animatedArtworkEnabled: animatedArtworkEnabled,
                ),
              ),
      ),
    ),
  );
}

class _PlayerFontSettingsController extends SettingsController {
  _PlayerFontSettingsController(this.font, {this.showAudioQuality = false});

  final PlayerFont font;
  final bool showAudioQuality;

  @override
  Future<SettingsState> build() async => SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
    playerFont: font,
    showAudioQuality: showAudioQuality,
  );

  @override
  Future<void> setShowAudioQuality(bool enabled) async {
    final current = state.asData?.value ?? await future;
    state = AsyncData(current.copyWith(showAudioQuality: enabled));
  }
}

class _TestPlaybackQueueNotifier extends PlaybackQueueNotifier {
  _TestPlaybackQueueNotifier(this.initial);

  final PlaybackQueueState initial;

  @override
  PlaybackQueueState build() => initial;
}

class _RecordingDownloadController extends DownloadController {
  _RecordingDownloadController({this.fail = false});

  final bool fail;
  int downloadCalls = 0;
  TrackInfo? downloadedTrack;

  @override
  Map<String, DownloadTaskState> build() => const {};

  @override
  Future<void> downloadAudio(TrackInfo track) async {
    downloadCalls += 1;
    downloadedTrack = track;
    if (fail) {
      throw StateError('enqueue failed');
    }
  }
}

class _TestArtistService
    implements YouTubeMusicSearch, YouTubeMusicArtistProfileLookup {
  String? lastBrowseId;
  int profileCalls = 0;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async => const <InnerTubeSong>[];

  @override
  Future<InnerTubeArtistProfile> getArtistProfile(
    String artistBrowseId, {
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = 20,
    int releaseLimit = 20,
  }) async {
    profileCalls += 1;
    lastBrowseId = artistBrowseId;
    return InnerTubeArtistProfile(
      artist: InnerTubeArtist(
        browseId: artistBrowseId,
        name: fallbackName ?? 'Artista',
        thumbnailUrl: fallbackThumbnailUrl,
      ),
      popularSongs: const <InnerTubeSong>[],
      albums: const <InnerTubeAlbum>[],
      singles: const <InnerTubeAlbum>[],
    );
  }
}

class _TestAlbumService
    implements
        YouTubeMusicSearch,
        YouTubeMusicCatalogSearch,
        YouTubeMusicAlbumLookup {
  _TestAlbumService({
    this.albumBrowseId = 'MPREalbumCorrect',
    this.throwOnSearch = false,
  });

  final String albumBrowseId;
  final bool throwOnSearch;
  int searchCalls = 0;
  int songSearchCalls = 0;
  String? lastAlbumBrowseId;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    songSearchCalls += 1;
    return const <InnerTubeSong>[];
  }

  @override
  Future<List<InnerTubeSong>> searchVideos(
    String query, {
    int limit = 20,
  }) async => const <InnerTubeSong>[];

  @override
  Future<List<InnerTubeAlbum>> searchAlbums(
    String query, {
    int limit = 20,
  }) async {
    searchCalls += 1;
    if (throwOnSearch) {
      throw StateError('album search failed');
    }
    return <InnerTubeAlbum>[
      InnerTubeAlbum(
        browseId: albumBrowseId,
        title: 'Álbum correcto',
        artists: const <String>['Artista del álbum'],
        year: '2026',
        type: 'Álbum',
        thumbnailUrl: 'https://example.invalid/album.jpg',
      ),
    ];
  }

  @override
  Future<List<InnerTubeSong>> getAlbumSongs(
    String browseId, {
    int limit = innerTubeDetailResultLimit,
  }) async {
    lastAlbumBrowseId = browseId;
    return <InnerTubeSong>[
      InnerTubeSong(
        videoId: 'albumtrk001',
        title: 'Canción del álbum',
        artists: const <String>['Artista del álbum'],
        album: 'Álbum correcto',
      ),
    ];
  }
}

class _TestRelatedAlbumService extends _TestAlbumService
    implements YouTubeMusicRelated {
  _TestRelatedAlbumService({required this.nextSongs});

  final List<InnerTubeSong> nextSongs;
  int nextCalls = 0;

  @override
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = innerTubeDetailResultLimit,
  }) async {
    nextCalls += 1;
    return InnerTubeNextPage(songs: nextSongs.take(limit).toList());
  }

  @override
  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = innerTubeDetailResultLimit,
  }) async => InnerTubeNextPage(songs: const <InnerTubeSong>[]);

  @override
  Future<InnerTubeRelatedPage> getRelated(
    String browseId, {
    int limit = 20,
  }) async => InnerTubeRelatedPage(
    songs: const <InnerTubeSong>[],
    albums: const <InnerTubeAlbum>[],
    artists: const <InnerTubeArtist>[],
    collections: const <InnerTubeHomeCollection>[],
  );

  @override
  Future<InnerTubeRelatedPage> getRelatedContinuation(
    String continuation, {
    int limit = 20,
  }) => getRelated(continuation, limit: limit);
}

class _TestTrackShareService implements TrackShareService {
  _TestTrackShareService({
    this.canShareResult = true,
    this.throwsOnShare = false,
  });

  final bool canShareResult;
  final bool throwsOnShare;
  int shareCalls = 0;
  TrackInfo? sharedTrack;
  String? message;
  String? title;
  String? subject;
  Rect? sharePositionOrigin;

  @override
  bool canShare(TrackInfo track) => canShareResult;

  @override
  Future<void> shareTrack(
    TrackInfo track, {
    required String message,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    shareCalls += 1;
    sharedTrack = track;
    this.message = message;
    this.title = title;
    this.subject = subject;
    this.sharePositionOrigin = sharePositionOrigin;
    if (throwsOnShare) {
      throw StateError('share failed');
    }
  }
}

class _TestPlayerController extends PlayerController {
  _TestPlayerController(
    this.snapshot, {
    this.canonicalRemoteTrack,
    this.preparedAudioSource,
    this.localTrack,
  });

  final PlayerSnapshot snapshot;
  TrackInfo? canonicalRemoteTrack;
  final RemotePlaybackSource? preparedAudioSource;
  LocalTrack? localTrack;
  int seekCalls = 0;
  Duration? lastSeek;
  int volumeCalls = 0;
  double? lastVolume;
  int togglePlayPauseCalls = 0;
  int playNextCalls = 0;

  @override
  Future<PlayerSnapshot> build() async => snapshot;

  void emit(PlayerSnapshot nextSnapshot) {
    state = AsyncData(nextSnapshot);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    lastSeek = position;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeCalls++;
    lastVolume = volume;
  }

  @override
  Future<void> togglePlayPause() async {
    togglePlayPauseCalls++;
    final current = state.value ?? snapshot;
    emit(
      current.copyWith(
        status: current.status == PlayerStatus.playing
            ? PlayerStatus.paused
            : PlayerStatus.playing,
      ),
    );
  }

  @override
  Future<void> playNext({bool automatic = false}) async {
    playNextCalls++;
  }

  @override
  TrackInfo? currentRemoteTrackFor(String sourceUrl) {
    final track = canonicalRemoteTrack;
    return track?.url == sourceUrl ? track : null;
  }

  @override
  LocalTrack? currentLocalTrackFor(String? trackId) {
    final track = localTrack;
    return track?.id == trackId ? track : null;
  }

  @override
  RemotePlaybackSource? preparedAudioSourceFor(String sourceUrl) {
    final source = preparedAudioSource;
    return source?.track.url == sourceUrl ? source : null;
  }
}

class _CountingMenuColorService extends ArtworkProgressColorService {
  final sources = <String?>[];
  int releases = 0;

  @override
  ArtworkProgressColorLease acquire(String? rawSource) {
    sources.add(rawSource);
    return _CountingMenuColorLease(
      Future.value(
        rawSource?.contains('blue') == true ? Colors.blue : Colors.orange,
      ),
      () => releases++,
    );
  }
}

class _CountingMenuColorLease extends ArtworkProgressColorLease {
  _CountingMenuColorLease(Future<Color> future, this.onRelease)
    : super(future: future);
  final VoidCallback onRelease;
  bool _released = false;
  @override
  void release() {
    if (_released) return;
    _released = true;
    onRelease();
  }
}

class _TestPlaylistsController extends PlaylistsController {
  final now = DateTime(2026);
  int remoteFavoriteCalls = 0;
  TrackInfo? remoteFavoriteTrack;

  @override
  Future<bool> toggleFavoriteRemote(
    TrackInfo track, {
    bool download = true,
  }) async {
    remoteFavoriteCalls++;
    remoteFavoriteTrack = track;
    return true;
  }

  Set<String> get favoriteIds {
    final playlists = state.value ?? const <Playlist>[];
    return playlists
        .where((playlist) => playlist.isFavorites)
        .expand((playlist) => playlist.trackIds)
        .toSet();
  }

  @override
  Future<List<Playlist>> build() async => const <Playlist>[];

  @override
  Future<bool> toggleFavorite(String trackId) async {
    final normalized = trackId.trim();
    final playlists = state.value ?? await future;
    final index = playlists.indexWhere((playlist) => playlist.isFavorites);
    final current = index < 0
        ? Playlist(
            id: Playlist.favoritesId,
            name: 'Favoritos',
            trackIds: const [],
            createdAt: now,
            updatedAt: now,
          )
        : playlists[index];
    final wasFavorite = current.trackIds.contains(normalized);
    final updated = current.copyWith(
      trackIds: wasFavorite
          ? current.trackIds.where((id) => id != normalized).toList()
          : [...current.trackIds, normalized],
      updatedAt: now,
    );
    final next = [...playlists];
    if (index < 0) {
      next.add(updated);
    } else {
      next[index] = updated;
    }
    state = AsyncData(next);
    return !wasFavorite;
  }
}
