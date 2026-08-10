import 'package:flutter/material.dart';

/// The appearance modes exposed by the settings screen.
enum AppThemeMode {
  system,
  light,
  dark;

  String get code => name;

  ThemeMode get materialMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  static AppThemeMode fromCode(String? code) => switch (code) {
    'light' => AppThemeMode.light,
    'dark' => AppThemeMode.dark,
    _ => AppThemeMode.system,
  };
}

/// Accent palettes are intentionally small and curated so every choice keeps
/// enough contrast for buttons, tabs, and progress indicators.
enum AppAccent {
  white,
  green,
  blue,
  purple,
  orange,
  red,
  yellow,
  pink,
  teal,
  cyan,
  indigo,
  lime;

  String get code => name;

  Color get seedColor => switch (this) {
    AppAccent.white => const Color(0xFFF5F7F5),
    AppAccent.green => const Color(0xFF18C75A),
    AppAccent.blue => const Color(0xFF3D8BFF),
    AppAccent.purple => const Color(0xFFA66CFF),
    AppAccent.orange => const Color(0xFFFFA047),
    AppAccent.red => const Color(0xFFFF5A5F),
    AppAccent.yellow => const Color(0xFFFFD54F),
    AppAccent.pink => const Color(0xFFFF5C93),
    AppAccent.teal => const Color(0xFF2DD4BF),
    AppAccent.cyan => const Color(0xFF22D3EE),
    AppAccent.indigo => const Color(0xFF818CF8),
    AppAccent.lime => const Color(0xFFA3E635),
  };

  Color get darkColor => switch (this) {
    AppAccent.white => const Color(0xFF8E9891),
    AppAccent.green => const Color(0xFF0B8F43),
    AppAccent.blue => const Color(0xFF1F58B5),
    AppAccent.purple => const Color(0xFF6C2FC7),
    AppAccent.orange => const Color(0xFFC86A16),
    AppAccent.red => const Color(0xFFC62828),
    AppAccent.yellow => const Color(0xFFC49A00),
    AppAccent.pink => const Color(0xFFC52D65),
    AppAccent.teal => const Color(0xFF0F8F80),
    AppAccent.cyan => const Color(0xFF0E7490),
    AppAccent.indigo => const Color(0xFF4338CA),
    AppAccent.lime => const Color(0xFF4D7C0F),
  };

  static AppAccent fromCode(String? code) => switch (code) {
    'white' => AppAccent.white,
    'green' => AppAccent.green,
    'blue' => AppAccent.blue,
    'purple' => AppAccent.purple,
    'orange' => AppAccent.orange,
    'red' => AppAccent.red,
    'yellow' => AppAccent.yellow,
    'pink' => AppAccent.pink,
    'teal' => AppAccent.teal,
    'cyan' => AppAccent.cyan,
    'indigo' => AppAccent.indigo,
    'lime' => AppAccent.lime,
    _ => AppAccent.white,
  };
}

/// Theme data used by widgets that need the accent gradient rather than a
/// single Material color (for example download progress bars).
@immutable
class AppAccentTheme extends ThemeExtension<AppAccentTheme> {
  const AppAccentTheme({required this.accent});

  final AppAccent accent;

  Color get seed => accent.seedColor;
  Color get dark => accent.darkColor;
  List<Color> get downloadGradient => [seed, dark];

  static AppAccentTheme fromAccent(AppAccent accent) {
    return AppAccentTheme(accent: accent);
  }

  @override
  AppAccentTheme copyWith({AppAccent? accent}) {
    return AppAccentTheme(accent: accent ?? this.accent);
  }

  @override
  AppAccentTheme lerp(ThemeExtension<AppAccentTheme>? other, double t) {
    if (other is! AppAccentTheme) {
      return this;
    }
    return t < 0.5 ? this : other;
  }
}
