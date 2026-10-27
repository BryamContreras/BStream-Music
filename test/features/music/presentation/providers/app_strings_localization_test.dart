import 'package:flutter_test/flutter_test.dart';
import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';

void main() {
  group('AppLanguage', () {
    test('labels and persisted language codes cover all supported locales', () {
      const expected = <AppLanguage, (String, String)>{
        AppLanguage.spanish: ('es', 'Español'),
        AppLanguage.english: ('en', 'English'),
        AppLanguage.portuguese: ('pt', 'Português'),
        AppLanguage.french: ('fr', 'Français'),
        AppLanguage.korean: ('ko', '한국어'),
        AppLanguage.chinese: ('zh', '简体中文'),
        AppLanguage.japanese: ('ja', '日本語'),
      };

      for (final entry in expected.entries) {
        expect(entry.key.code, entry.value.$1);
        expect(entry.key.label, entry.value.$2);
        expect(AppLanguageLabel.fromCode(entry.value.$1), entry.key);
      }
      expect(AppLanguageLabel.fromCode('unknown'), AppLanguage.spanish);
    });
  });

  test('static and interpolated strings use each selected translation', () {
    for (final language in <AppLanguage>[
      AppLanguage.portuguese,
      AppLanguage.french,
      AppLanguage.korean,
      AppLanguage.chinese,
      AppLanguage.japanese,
    ]) {
      final strings = AppStrings(language);

      expect(strings.home, isNot('Home'), reason: language.code);
      expect(strings.search, isNot('Search'), reason: language.code);
      expect(strings.player, isNot('Player'), reason: language.code);
      expect(strings.settings, isNot('Settings'), reason: language.code);
      expect(strings.language, isNot('Language'), reason: language.code);
      expect(strings.songCount(7), contains('7'), reason: language.code);
      expect(strings.songCount(7), isNot('7 songs'), reason: language.code);
      expect(
        strings.playbackQueueSummary(2),
        isNot('Playback Queue - 2 Songs'),
        reason: language.code,
      );
    }
  });

  test('new release highlights are translated for every added language', () {
    const highlights = <(String, String)>[
      (
        'Se hicieron mejoras en la interfaz para ofrecer más rendimiento y fluidez.',
        'Interface performance and smoothness have been improved.',
      ),
      (
        'Los fondos de álbumes, mixes y artistas ahora heredan los tonos de sus portadas.',
        'Album, mix, and artist pages now inherit colors from their cover art.',
      ),
      (
        'La aplicación ahora es compatible con portugués, francés, coreano, chino y japonés.',
        'Portuguese, French, Korean, Chinese, and Japanese are now supported.',
      ),
    ];
    for (final language in <AppLanguage>[
      AppLanguage.portuguese,
      AppLanguage.french,
      AppLanguage.korean,
      AppLanguage.chinese,
      AppLanguage.japanese,
    ]) {
      final strings = AppStrings(language);
      for (final (spanish, english) in highlights) {
        final translated = strings.choose(spanish, english);
        expect(translated, isNot(english), reason: language.code);
        expect(translated, isNot(spanish), reason: language.code);
      }
    }
  });

  test('update dialog is localized without changing version identifiers', () {
    const latestVersion = 'v1.3.0-beta.2+147';
    const currentVersion = '1.2.9+129';
    const english = AppStrings(AppLanguage.english);
    const spanish = AppStrings(AppLanguage.spanish);
    final englishMessage = english.updateAvailableMessage(
      latestVersion: latestVersion,
      currentVersion: currentVersion,
    );

    expect(
      spanish.updateAvailableMessage(
        latestVersion: latestVersion,
        currentVersion: currentVersion,
      ),
      'BStream Music $latestVersion está disponible. '
      'Versión actual: $currentVersion.',
    );
    expect(
      spanish.updateReleaseNotesTitle(latestVersion),
      'Novedades $latestVersion',
    );

    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      final message = strings.updateAvailableMessage(
        latestVersion: latestVersion,
        currentVersion: currentVersion,
      );
      final heading = strings.updateReleaseNotesTitle(latestVersion);
      expect(message, contains('BStream Music'), reason: language.code);
      expect(message, contains(latestVersion), reason: language.code);
      expect(message, contains(currentVersion), reason: language.code);
      expect(heading, contains(latestVersion), reason: language.code);
      expect(message, isNot(contains('ZXQPH')), reason: language.code);
      expect(heading, isNot(contains('ZXQPH')), reason: language.code);
      if (language == AppLanguage.english) continue;
      expect(message, isNot(englishMessage), reason: language.code);
      expect(
        strings.updateAvailableTitle,
        isNot(english.updateAvailableTitle),
        reason: language.code,
      );
      expect(
        heading,
        isNot(english.updateReleaseNotesTitle(latestVersion)),
        reason: language.code,
      );
      expect(
        strings.updateReleaseNotesLoading,
        isNot(english.updateReleaseNotesLoading),
        reason: language.code,
      );
      expect(
        strings.updateReleaseNotesEmpty,
        isNot(english.updateReleaseNotesEmpty),
        reason: language.code,
      );
      expect(
        strings.updateReleaseNotesTranslationFailed,
        isNot(english.updateReleaseNotesTranslationFailed),
        reason: language.code,
      );
    }
  });

  test('the local navigation tab uses the selected language', () {
    expect(AppStrings(AppLanguage.spanish).localTab, 'Local');
    expect(AppStrings(AppLanguage.english).localTab, 'Local');
    expect(AppStrings(AppLanguage.portuguese).localTab, 'No dispositivo');
    expect(AppStrings(AppLanguage.french).localTab, 'Appareil');
    expect(AppStrings(AppLanguage.korean).localTab, '로컬');
    expect(AppStrings(AppLanguage.chinese).localTab, '本地');
    expect(AppStrings(AppLanguage.japanese).localTab, 'ローカル');
  });
}
