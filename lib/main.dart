import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/constants/app_constants.dart';
import 'core/platform/app_platform.dart';
import 'core/startup/app_startup_coordinator.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/liquid_glass_surface.dart';
import 'features/music/presentation/pages/home_page.dart';
import 'features/music/presentation/providers/music_providers.dart';
import 'services/player/notification_artwork_service.dart';
import 'services/media_session/audio_service_desktop_media_session.dart';

void main() {
  launchBStreamMusicApp();
}

typedef AppStartupScheduler = void Function(VoidCallback callback);

@visibleForTesting
Set<OptionalStartupService> startupServicesForPlatform({
  required AppPlatformType platform,
  bool? initializeAndroidServices,
}) {
  if (initializeAndroidServices != null) {
    return initializeAndroidServices
        ? const <OptionalStartupService>{
            OptionalStartupService.notificationArtwork,
            OptionalStartupService.audioService,
          }
        : const <OptionalStartupService>{};
  }
  return switch (platform) {
    AppPlatformType.android => const <OptionalStartupService>{
      OptionalStartupService.notificationArtwork,
      OptionalStartupService.audioService,
    },
    AppPlatformType.ios => const <OptionalStartupService>{
      OptionalStartupService.notificationArtwork,
      OptionalStartupService.audioService,
    },
    _ => const <OptionalStartupService>{},
  };
}

void _scheduleStartupAfterFirstFrame(VoidCallback callback) {
  WidgetsBinding.instance.addPostFrameCallback((_) => callback());
}

@visibleForTesting
AppStartupCoordinator launchBStreamMusicApp({
  bool? initializeAndroidServices,
  OptionalStartupOperation? initializeNotificationArtwork,
  OptionalStartupOperation? initializeAudioService,
  void Function(Widget application)? runApplication,
  AppStartupScheduler? scheduleStartup,
}) {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep artwork memory bounded across long sessions with many searches and
  // queue transitions. The default Flutter image cache allows 100 MiB and
  // 1,000 entries, which is excessive for music thumbnails.
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 100;
  imageCache.maximumSizeBytes = 48 * 1024 * 1024;
  // Begin compiling the optional Impeller lens before Liquid Glass surfaces
  // mount. Unsupported desktop renderers keep the portable fallback.
  unawaited(LiquidGlassSurface.warmUp());
  final startupServices = startupServicesForPlatform(
    platform: AppPlatform.current,
    initializeAndroidServices: initializeAndroidServices,
  );
  final startup = AppStartupCoordinator(
    operations: <OptionalStartupService, OptionalStartupOperation>{
      if (startupServices.contains(OptionalStartupService.notificationArtwork))
        OptionalStartupService.notificationArtwork:
            initializeNotificationArtwork ??
            NotificationArtworkService.instance.initialize,
      if (startupServices.contains(OptionalStartupService.audioService))
        OptionalStartupService.audioService:
            initializeAudioService ??
            AudioServiceDesktopMediaSession.ensureInitialized,
    },
  );

  // The UI is intentionally mounted before optional mobile integrations are
  // attempted. Transient failures retry in the background with a bounded
  // backoff, without trapping the user on a blank launch screen.
  (runApplication ?? runApp)(
    const ProviderScope(
      child: _LocalArtworkMaintenance(
        child: BStreamMusicApp(checkForUpdatesOnStartup: true),
      ),
    ),
  );
  (scheduleStartup ?? _scheduleStartupAfterFirstFrame)(() {
    unawaited(startup.initialize());
  });
  return startup;
}

/// Runs non-blocking library maintenance only for the production app shell.
/// Widget tests that mount [BStreamMusicApp] directly remain deterministic.
class _LocalArtworkMaintenance extends ConsumerStatefulWidget {
  const _LocalArtworkMaintenance({required this.child});

  final Widget child;

  @override
  ConsumerState<_LocalArtworkMaintenance> createState() =>
      _LocalArtworkMaintenanceState();
}

class _LocalArtworkMaintenanceState
    extends ConsumerState<_LocalArtworkMaintenance> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_repairStoredArtwork());
      }
    });
  }

  Future<void> _repairStoredArtwork() async {
    try {
      // Android may first rewrite managed-media paths during reconciliation.
      // Repair only after those paths are stable.
      await ref.read(localLibraryReconciliationProvider.future);
      final tracks = await ref.read(libraryRepositoryProvider).getLocalTracks();
      await ref
          .read(localTrackDownloadHelperProvider)
          .repairStoredArtwork(tracks);
    } catch (error, stackTrace) {
      debugPrint('Stored artwork repair failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class BStreamMusicApp extends ConsumerWidget {
  const BStreamMusicApp({this.checkForUpdatesOnStartup = false, super.key});

  final bool checkForUpdatesOnStartup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(desktopMediaSessionProvider);
    // Keep the per-track lyrics offset synchronized even while its route is
    // closed, without rebuilding the app when the offset itself changes.
    ref.watch(lyricsOffsetControllerProvider.select((_) => null));
    final appearance = ref.watch(
      settingsControllerProvider.select((settings) {
        final value = settings.value;
        return (
          language: value?.language ?? AppLanguage.spanish,
          accent: value?.accent ?? AppAccent.white,
          surfaceBackgroundMode:
              value?.surfaceBackgroundMode ?? SurfaceBackgroundMode.accent,
          themeMode: value?.themeMode.materialMode ?? ThemeMode.system,
        );
      }),
    );
    final language = appearance.language;
    final accent = appearance.accent;
    final surfaceBackgroundMode = appearance.surfaceBackgroundMode;
    final themeMode = appearance.themeMode;
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
        surfaceBackgroundMode: surfaceBackgroundMode,
        isDesktop: isDesktop,
        iconButtonSize: iconButtonSize,
        textButtonHeight: textButtonHeight,
      ),
      darkTheme: _buildDarkTheme(
        accent: accent,
        surfaceBackgroundMode: surfaceBackgroundMode,
        isDesktop: isDesktop,
        iconButtonSize: iconButtonSize,
        textButtonHeight: textButtonHeight,
      ),
      builder: (context, child) =>
          ScrollNotificationObserver(child: child ?? const SizedBox.shrink()),
      home: HomePage(checkForUpdatesOnStartup: checkForUpdatesOnStartup),
    );
  }
}

ThemeData _buildDarkTheme({
  required AppAccent accent,
  required SurfaceBackgroundMode surfaceBackgroundMode,
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
  final menuIcon = Color.alphaBlend(
    accent.seedColor.withValues(alpha: 0.62),
    AppColors.menuForeground,
  );
  final menuForeground = Color.alphaBlend(
    accent.seedColor.withValues(alpha: 0.04),
    Colors.white,
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: AppPlatform.isLinux ? 'Roboto' : null,
    fontFamilyFallback: AppPlatform.isLinux ? const [] : null,
    brightness: Brightness.dark,
    colorScheme: scheme,
    extensions: [
      AppAccentTheme.fromAccent(accent),
      AppSurfaceTheme(backgroundMode: surfaceBackgroundMode),
    ],
    scaffoldBackgroundColor: const Color(0xFF030504),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: const Color(0xFF050705),
      indicatorColor: accent.darkColor.withValues(alpha: 0.34),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF050705),
      indicatorColor: accent.darkColor.withValues(alpha: 0.34),
    ),
    cardTheme: CardThemeData(
      color: Color.alphaBlend(
        accent.seedColor.withValues(alpha: 0.055),
        scheme.surface,
      ).withValues(alpha: 0.72),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: Color.alphaBlend(
            accent.seedColor.withValues(alpha: 0.18),
            scheme.outlineVariant,
          ).withValues(alpha: 0.78),
        ),
      ),
    ),
    segmentedButtonTheme: _segmentedButtonTheme(accent, scheme),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.dialogSurfaceForTheme(
        accent,
        scheme,
        backgroundMode: surfaceBackgroundMode,
      ),
      surfaceTintColor: Colors.transparent,
      barrierColor: AppColors.dialogBarrierForTheme(
        scheme,
        backgroundMode: surfaceBackgroundMode,
      ),
      shadowColor: const Color(0xB8000000),
      elevation: 18,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.dialogBorderForTheme(
            accent,
            scheme,
            backgroundMode: surfaceBackgroundMode,
          ),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.menuBackgroundForTheme(
        accent,
        scheme,
        backgroundMode: surfaceBackgroundMode,
      ),
      surfaceTintColor: Colors.transparent,
      shadowColor: const Color(0xB3000000),
      elevation: 14,
      textStyle: TextStyle(color: menuForeground, fontWeight: FontWeight.w600),
      iconColor: menuIcon,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: AppColors.menuBorderForTheme(
            accent,
            scheme,
            backgroundMode: surfaceBackgroundMode,
          ),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.inputSurfaceForTheme(
        accent,
        scheme,
        backgroundMode: surfaceBackgroundMode,
      ),
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
  required SurfaceBackgroundMode surfaceBackgroundMode,
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
  final menuForeground = Color.alphaBlend(
    accent.darkColor.withValues(alpha: 0.12),
    scheme.onSurface,
  );
  final menuIcon = Color.alphaBlend(
    accent.darkColor.withValues(alpha: 0.72),
    scheme.onSurface,
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: AppPlatform.isLinux ? 'Roboto' : null,
    fontFamilyFallback: AppPlatform.isLinux ? const [] : null,
    brightness: Brightness.light,
    colorScheme: scheme,
    extensions: [
      AppAccentTheme.fromAccent(accent),
      AppSurfaceTheme(backgroundMode: surfaceBackgroundMode),
    ],
    scaffoldBackgroundColor: const Color(0xFFF5F8F6),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.white,
      indicatorColor: accent.seedColor.withValues(alpha: 0.21),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: accent.seedColor.withValues(alpha: 0.21),
    ),
    cardTheme: CardThemeData(
      color: Color.alphaBlend(
        accent.seedColor.withValues(alpha: 0.055),
        scheme.surface,
      ).withValues(alpha: 0.72),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: Color.alphaBlend(
            accent.seedColor.withValues(alpha: 0.18),
            scheme.outlineVariant,
          ).withValues(alpha: 0.78),
        ),
      ),
    ),
    segmentedButtonTheme: _segmentedButtonTheme(accent, scheme),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.dialogSurfaceForTheme(
        accent,
        scheme,
        backgroundMode: surfaceBackgroundMode,
      ),
      surfaceTintColor: Colors.transparent,
      barrierColor: AppColors.dialogBarrierForTheme(
        scheme,
        backgroundMode: surfaceBackgroundMode,
      ),
      shadowColor: const Color(0x40000000),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.dialogBorderForTheme(
            accent,
            scheme,
            backgroundMode: surfaceBackgroundMode,
          ),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.menuBackgroundForTheme(
        accent,
        scheme,
        backgroundMode: surfaceBackgroundMode,
      ),
      surfaceTintColor: Colors.transparent,
      shadowColor: const Color(0x40000000),
      elevation: 8,
      textStyle: TextStyle(color: menuForeground, fontWeight: FontWeight.w600),
      iconColor: menuIcon,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: AppColors.menuBorderForTheme(
            accent,
            scheme,
            backgroundMode: surfaceBackgroundMode,
          ),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.inputSurfaceForTheme(
        accent,
        scheme,
        backgroundMode: surfaceBackgroundMode,
      ),
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

SegmentedButtonThemeData _segmentedButtonTheme(
  AppAccent accent,
  ColorScheme scheme,
) {
  final selectedBorder = scheme.brightness == Brightness.dark
      ? accent.seedColor
      : accent.darkColor;
  return SegmentedButtonThemeData(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (!states.contains(WidgetState.selected)) {
          return null;
        }
        return accent.seedColor.withValues(alpha: 0.22);
      }),
      side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
        if (!states.contains(WidgetState.selected)) {
          return null;
        }
        return BorderSide(
          color: selectedBorder.withValues(alpha: 0.66),
          width: 1.2,
        );
      }),
    ),
  );
}
