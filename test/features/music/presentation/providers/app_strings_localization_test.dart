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

  test(
    'audio extension labels are translated for every supported language',
    () {
      List<String> labels(AppStrings strings) => [
        strings.addAudioSource,
        strings.audioExtensionUrl,
        strings.audioExtensionUrlHelp,
        strings.audioExtensionInvalidUrl,
        strings.audioExtensionUnavailable,
        strings.audioExtensionUnsupported,
        strings.audioExtensionRestricted,
        strings.audioExtensionOfficialClientOnly,
        strings.audioExtensionOutputRequired,
        strings.audioExtensionModuleIndex,
        strings.audioExtensionNoAvailableSources,
        strings.audioExtensionStreamingOnly,
        strings.audioExtensionsWithFallback,
        strings.removeAudioSource,
      ];
      final english = labels(const AppStrings(AppLanguage.english));
      for (final language in AppLanguage.values) {
        final translated = labels(AppStrings(language));
        expect(translated, everyElement(isNotEmpty), reason: language.code);
        if (language == AppLanguage.english) continue;
        for (var index = 0; index < english.length; index++) {
          expect(
            translated[index],
            isNot(english[index]),
            reason: language.code,
          );
        }
      }
    },
  );

  test(
    'playlist artwork controls are localized in every supported language',
    () {
      List<String> labels(AppStrings strings) => [
        strings.playlistArtworkTitle,
        strings.playlistArtworkRandom,
        strings.playlistArtworkCustom,
        strings.playlistArtworkEdit,
        strings.playlistArtworkSaveFailed,
      ];
      final english = labels(const AppStrings(AppLanguage.english));
      final spanish = labels(const AppStrings(AppLanguage.spanish));
      expect(spanish[1], 'Aleatorio');
      expect(spanish[2], 'Personalizada');
      for (final language in AppLanguage.values) {
        final localized = labels(AppStrings(language));
        expect(localized, hasLength(5));
        for (var index = 0; index < localized.length; index++) {
          expect(localized[index].trim(), isNotEmpty, reason: language.code);
          if (language != AppLanguage.english) {
            expect(
              localized[index],
              isNot(english[index]),
              reason: language.code,
            );
          }
          if (language != AppLanguage.spanish &&
              language != AppLanguage.english) {
            expect(
              localized[index],
              isNot(spanish[index]),
              reason: language.code,
            );
          }
        }
      }
    },
  );

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

  test('1.3.1 release notes cover every supported language offline', () {
    const english = AppStrings(AppLanguage.english);
    const spanish = AppStrings(AppLanguage.spanish);
    const expectedEnglish = <String>[
      'Added support for external audio source add-ons.',
      'A 10-band equalizer is now available.',
      'Support for higher quality audio whenever available.',
      'Improved and optimized player style layouts.',
      'Added the new Spotify Style player.',
      'Added filtering options to the Local music tab.',
      'Added word-by-word synchronized lyrics when timing is available.',
      'Improved the Settings tab layout.',
      'Customize playlist artwork with an image from your gallery.',
    ];
    expect(english.whatsNewHighlights, expectedEnglish);
    expect(
      english.whatsNewSummary,
      'Player styles, local music filters, lyrics, and settings',
    );
    expect(spanish.whatsNewHighlights, hasLength(expectedEnglish.length));
    expect(
      spanish.whatsNewHighlights.first,
      'Se agregó compatibilidad con complementos de fuentes de audio externas.',
    );
    expect(
      spanish.whatsNewHighlights[1],
      'Ahora está disponible un ecualizador de 10 bandas.',
    );
    expect(
      spanish.whatsNewHighlights[2],
      'Compatibilidad con audio de mayor calidad, siempre que esté disponible.',
    );
    expect(
      spanish.whatsNewHighlights.last,
      'Personaliza la portada de tus playlists con una imagen de tu galería.',
    );

    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      final highlights = strings.whatsNewHighlights;
      final title = strings.whatsNewTitle('1.3.1');
      expect(title, contains('1.3.1'), reason: language.code);
      expect(
        highlights,
        hasLength(expectedEnglish.length),
        reason: language.code,
      );
      expect(strings.whatsNewSummary.trim(), isNotEmpty, reason: language.code);
      expect(highlights[4], contains('Spotify Style'), reason: language.code);
      for (var index = 0; index < highlights.length; index++) {
        expect(highlights[index].trim(), isNotEmpty, reason: language.code);
        if (language != AppLanguage.english) {
          expect(
            highlights[index],
            isNot(expectedEnglish[index]),
            reason: '${language.code}: release item $index must be translated',
          );
        }
        if (language != AppLanguage.spanish &&
            language != AppLanguage.english) {
          expect(
            highlights[index],
            isNot(spanish.whatsNewHighlights[index]),
            reason: '${language.code}: do not fall back to Spanish',
          );
        }
      }
      if (language != AppLanguage.english) {
        expect(title, isNot(english.whatsNewTitle('1.3.1')));
        expect(
          strings.whatsNewSummary,
          isNot(english.whatsNewSummary),
          reason: language.code,
        );
      }
      if (language != AppLanguage.spanish && language != AppLanguage.english) {
        expect(title, isNot(spanish.whatsNewTitle('1.3.1')));
        expect(
          strings.whatsNewSummary,
          isNot(spanish.whatsNewSummary),
          reason: language.code,
        );
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

  test(
    'lyrics sharing labels and selection counts follow the app language',
    () {
      List<String> sharingLabels(AppStrings strings) => <String>[
        strings.lyricsShareTitle,
        strings.lyricsShareSelectHint,
        strings.lyricsShareLimit,
        strings.lyricsShareBackground,
        strings.lyricsShareBlur,
        strings.lyricsShareCover,
        strings.lyricsShareGradient,
        strings.lyricsShareTextColor,
        strings.lyricsShareTextAuto,
        strings.lyricsShareTextLight,
        strings.lyricsShareTextDark,
        strings.lyricsShareGallery,
        strings.lyricsShareChoosePhoto,
        strings.lyricsShareAdjustPhoto,
        strings.lyricsShareCropTitle,
        strings.lyricsShareCropHint,
        strings.lyricsShareUsePhoto,
        strings.lyricsShareResetCrop,
        strings.lyricsSharePhotoFailed,
        strings.lyricsSharePalette,
        strings.lyricsShareImage,
        strings.lyricsShareSaveImage,
        strings.lyricsShareSaved,
        strings.lyricsShareFailed,
        strings.lyricsSharePreparing,
        strings.lyricsSharePreview,
      ];

      final englishLabels = sharingLabels(
        const AppStrings(AppLanguage.english),
      );
      for (final language in AppLanguage.values) {
        final strings = AppStrings(language);
        final labels = sharingLabels(strings);
        for (var index = 0; index < labels.length; index++) {
          expect(labels[index], isNotEmpty, reason: '${language.code}: $index');
          if (language != AppLanguage.english) {
            expect(
              labels[index],
              isNot(englishLabels[index]),
              reason: '${language.code}: $index',
            );
          }
        }
        for (var count = 0; count <= 5; count++) {
          final label = strings.lyricsShareSelectedCount(count);
          expect(label, contains('$count'), reason: language.code);
          expect(label, contains('5'), reason: language.code);
          expect(label, isNot(contains('ZXQPH')), reason: language.code);
          if (language != AppLanguage.english) {
            expect(label, isNot('$count of 5 lines'), reason: language.code);
          }
        }
        for (var index = 1; index <= 2; index++) {
          final label = strings.lyricsShareColorLabel(index);
          expect(label, contains('$index'), reason: language.code);
          expect(label, isNot(contains('ZXQPH')), reason: language.code);
        }
      }
    },
  );
}
