import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'core/constants/app_constants.dart';
import 'core/platform/app_platform.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'features/music/presentation/pages/home_page.dart';
import 'features/music/presentation/providers/music_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep artwork memory bounded across long sessions with many searches and
  // queue transitions. The default Flutter image cache allows 100 MiB and
  // 1,000 entries, which is excessive for music thumbnails.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 100;
  imageCache.maximumSizeBytes = 48 * 1024 * 1024;
  if (AppPlatform.isAndroid) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.bstream.bstream_music.audio',
      androidNotificationChannelName: 'BStream Music',
      notificationColor: AppColors.brandGreen,
      // Android/Samsung media surfaces expect a monochrome notification mask.
      androidNotificationIcon: 'drawable/ic_stat_bstream_music',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: true,
      // Notification artwork is decoded by Android and kept in a native LRU
      // cache. Bounding it prevents high-resolution thumbnails from creating
      // avoidable memory pressure during long background sessions.
      artDownscaleWidth: 320,
      artDownscaleHeight: 320,
    );
  }
  runApp(const ProviderScope(child: BStreamMusicApp()));
}

class BStreamMusicApp extends ConsumerWidget {
  const BStreamMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the per-track lyrics offset synchronized even while its route is
    // closed, without rebuilding the app when the offset itself changes.
    ref.watch(lyricsOffsetControllerProvider.select((_) => null));
    final settings = ref.watch(settingsControllerProvider).value;
    final language = settings?.language ?? AppLanguage.spanish;
    final accent = settings?.accent ?? AppAccent.white;
    final themeMode = settings?.themeMode.materialMode ?? ThemeMode.system;
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
      themeMode: themeMode,
      theme: _buildLightTheme(
        accent: accent,
        isDesktop: isDesktop,
        iconButtonSize: iconButtonSize,
        textButtonHeight: textButtonHeight,
      ),
      darkTheme: _buildDarkTheme(
        accent: accent,
        isDesktop: isDesktop,
        iconButtonSize: iconButtonSize,
        textButtonHeight: textButtonHeight,
      ),
      home: const HomePage(),
    );
  }
}

ThemeData _buildDarkTheme({
  required AppAccent accent,
  required bool isDesktop,
  required double iconButtonSize,
  required double textButtonHeight,
}) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent.seedColor,
        brightness: Brightness.dark,
      ).copyWith(
        surface: const Color(0xFF060806),
        surfaceContainerHighest: const Color(0xFF121612),
        primary: accent.seedColor,
        primaryContainer: accent.darkColor,
        secondary: accent.darkColor,
        tertiary: accent.seedColor,
      );

  return ThemeData(
    useMaterial3: true,
    fontFamily: AppPlatform.isLinux ? 'Roboto' : null,
    fontFamilyFallback: AppPlatform.isLinux ? const [] : null,
    brightness: Brightness.dark,
    colorScheme: scheme,
    extensions: [AppAccentTheme.fromAccent(accent)],
    scaffoldBackgroundColor: const Color(0xFF030504),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: const Color(0xFF050705),
      indicatorColor: accent.darkColor.withValues(alpha: 0.28),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF050705),
      indicatorColor: accent.darkColor.withValues(alpha: 0.28),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface.withValues(alpha: 0.64),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.menuBackground,
      surfaceTintColor: Colors.transparent,
      shadowColor: const Color(0xB3000000),
      elevation: 14,
      textStyle: const TextStyle(
        color: AppColors.menuForeground,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.menuBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.64),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    ),
    iconButtonTheme: _iconButtonTheme(iconButtonSize),
    filledButtonTheme: _filledButtonTheme(isDesktop, textButtonHeight),
    textButtonTheme: _textButtonTheme(isDesktop, textButtonHeight),
  );
}

ThemeData _buildLightTheme({
  required AppAccent accent,
  required bool isDesktop,
  required double iconButtonSize,
  required double textButtonHeight,
}) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent.seedColor,
        brightness: Brightness.light,
      ).copyWith(
        primary: accent.darkColor,
        primaryContainer: accent.seedColor.withValues(alpha: 0.18),
        secondary: accent.darkColor,
        tertiary: accent.seedColor,
      );

  return ThemeData(
    useMaterial3: true,
    fontFamily: AppPlatform.isLinux ? 'Roboto' : null,
    fontFamilyFallback: AppPlatform.isLinux ? const [] : null,
    brightness: Brightness.light,
    colorScheme: scheme,
    extensions: [AppAccentTheme.fromAccent(accent)],
    scaffoldBackgroundColor: const Color(0xFFF5F8F6),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.white,
      indicatorColor: accent.seedColor.withValues(alpha: 0.16),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: accent.seedColor.withValues(alpha: 0.16),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface.withValues(alpha: 0.64),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.97),
      surfaceTintColor: Colors.transparent,
      shadowColor: const Color(0x40000000),
      elevation: 8,
      textStyle: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.9)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.64),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    ),
    iconButtonTheme: _iconButtonTheme(iconButtonSize),
    filledButtonTheme: _filledButtonTheme(isDesktop, textButtonHeight),
    textButtonTheme: _textButtonTheme(isDesktop, textButtonHeight),
  );
}

IconButtonThemeData _iconButtonTheme(double size) {
  return IconButtonThemeData(
    style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size.square(size)),
      tapTargetSize: MaterialTapTargetSize.padded,
      padding: const WidgetStatePropertyAll(EdgeInsets.all(12)),
    ),
  );
}

FilledButtonThemeData _filledButtonTheme(bool isDesktop, double height) {
  return FilledButtonThemeData(
    style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, height)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: isDesktop ? 20 : 16),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
  );
}

TextButtonThemeData _textButtonTheme(bool isDesktop, double height) {
  return TextButtonThemeData(
    style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, height)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: isDesktop ? 18 : 14),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
  );
}
