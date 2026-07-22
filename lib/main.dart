import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'core/constants/app_constants.dart';
import 'core/platform/app_platform.dart';
import 'features/music/presentation/pages/home_page.dart';
import 'features/music/presentation/providers/music_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppPlatform.isAndroid) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.bstream.bstream_music.audio',
      androidNotificationChannelName: 'BStream Music',
      notificationColor: const Color(0xFF18C75A),
      androidNotificationIcon: 'drawable/ic_stat_bstream_music',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: true,
    );
  }
  runApp(const ProviderScope(child: BStreamMusicApp()));
}

class BStreamMusicApp extends ConsumerWidget {
  const BStreamMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const seed = Color(0xFF18C75A);
    final language =
        ref.watch(settingsControllerProvider).value?.language ??
        AppLanguage.spanish;
    final isDesktop = AppPlatform.isDesktop;
    final iconButtonSize = isDesktop ? 52.0 : 48.0;
    final textButtonHeight = isDesktop ? 52.0 : 48.0;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: AppConstants.appName,
      locale: Locale(language.code),
      supportedLocales: const [Locale('es'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.dark,
            ).copyWith(
              surface: const Color(0xFF060806),
              surfaceContainerHighest: const Color(0xFF121612),
              primary: seed,
              primaryContainer: const Color(0xFF0B8F43),
              secondary: const Color(0xFF5FA833),
              tertiary: const Color(0xFF159071),
            ),
        scaffoldBackgroundColor: const Color(0xFF030504),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFF050705),
          indicatorColor: Color(0xFF121A13),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF050705),
          indicatorColor: Color(0xFF121A13),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xA0080A08),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0x70243026)),
          ),
        ),
        dialogTheme: DialogThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xA0101410),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size.square(iconButtonSize)),
            tapTargetSize: MaterialTapTargetSize.padded,
            padding: const WidgetStatePropertyAll(EdgeInsets.all(12)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(0, textButtonHeight)),
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: isDesktop ? 20 : 16),
            ),
            textStyle: WidgetStatePropertyAll(
              TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(0, textButtonHeight)),
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: isDesktop ? 18 : 14),
            ),
            textStyle: WidgetStatePropertyAll(
              TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}
