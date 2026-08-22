import 'package:flutter/material.dart';

import '../providers/app_strings.dart';

/// Resolves auth copy without coupling standalone widgets to the large
/// `music_providers.dart` composition root.
AppStrings resolveYouTubeMusicAppStrings(
  BuildContext context,
  AppStrings? explicit,
) {
  if (explicit != null) return explicit;
  final languageCode = Localizations.maybeLocaleOf(context)?.languageCode;
  return AppStrings(
    languageCode == 'en' ? AppLanguage.english : AppLanguage.spanish,
  );
}
