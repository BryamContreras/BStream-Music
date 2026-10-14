import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_settings_account_card.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows generic account and sign-in action when signed out', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_anonymousState));

    expect(
      find.byKey(const ValueKey('settings-youtube-music-account-card')),
      findsOneWidget,
    );
    expect(find.text('Cuenta de YouTube Music'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-youtube-music-sign-in')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-youtube-music-sign-out')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the authenticated name and sign-out action', (
    tester,
  ) async {
    const profile = YouTubeMusicAccountProfile(
      channelId: 'channel-1',
      displayName: 'BStream User',
      handle: '@bstream',
    );
    await tester.pumpWidget(
      _harness(
        const YouTubeMusicAuthState(
          phase: YouTubeMusicAuthPhase.authenticated,
          generation: 1,
          profile: profile,
        ),
      ),
    );

    expect(find.text('BStream User'), findsOneWidget);
    expect(find.text('@bstream'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-youtube-music-sign-out')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-youtube-music-sign-in')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

const _anonymousState = YouTubeMusicAuthState(
  phase: YouTubeMusicAuthPhase.anonymous,
  generation: 0,
);

Widget _harness(YouTubeMusicAuthState initialState) {
  return ProviderScope(
    overrides: <Override>[
      youtubeMusicAuthControllerProvider.overrideWith(
        () => _TestYouTubeMusicAuthController(initialState),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: Center(
          child: YouTubeMusicSettingsAccountCard(
            strings: AppStrings(AppLanguage.spanish),
          ),
        ),
      ),
    ),
  );
}

class _TestYouTubeMusicAuthController extends YouTubeMusicAuthController {
  _TestYouTubeMusicAuthController(this.initialState);

  final YouTubeMusicAuthState initialState;

  @override
  YouTubeMusicAuthState build() => initialState;
}
