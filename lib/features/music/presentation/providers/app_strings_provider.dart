part of 'music_providers.dart';

final appStringsProvider = Provider<AppStrings>((ref) {
  final language =
      ref.watch(settingsControllerProvider).value?.language ??
      AppLanguage.spanish;
  return AppStrings(language);
});
