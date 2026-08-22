import 'dart:io';

import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first-party Dart sources do not contain UTF-8 mojibake', () {
    final libDirectory = Directory('lib');
    expect(libDirectory.existsSync(), isTrue);

    final findings = <String>[];
    for (final entity in libDirectory.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }

      final contents = entity.readAsStringSync();
      final lines = contents.split('\n');
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        final marker = _mojibakeMarkers.entries
            .where((entry) => line.contains(entry.key))
            .map((entry) => entry.value)
            .firstOrNull;
        if (marker != null) {
          findings.add('${entity.path}:${index + 1} ($marker)');
        }
      }
    }

    expect(
      findings,
      isEmpty,
      reason:
          'These markers normally mean valid UTF-8 text was decoded with the '
          'wrong character set:\n${findings.join('\n')}',
    );
  });

  test('the Spanish language name and add actions preserve the enye', () {
    const strings = AppStrings(AppLanguage.spanish);

    expect(AppLanguage.spanish.label, 'Español');
    expect(strings.spanish, 'Español');
    expect(strings.addToPlaylist, 'Añadir a playlist');
    expect(strings.addToFavorites, 'Añadir a favoritos');
  });

  test('Spanish LIVE labels preserve their diacritics', () {
    const strings = AppStrings(AppLanguage.spanish);

    expect(strings.liveQueueEmpty, 'Los pedidos !play aparecerán aquí.');
    expect(strings.commandPermissions, 'Quién puede usar los comandos');
    expect(strings.liveConnection, 'Conexión LIVE');
    expect(
      strings.liveConnectionSummary,
      'Conecta un LIVE y configura quién puede pedir canciones.',
    );
    expect(
      strings.liveUnavailable,
      'Conexión LIVE no disponible en este dispositivo.',
    );
    expect(strings.readyForRemotePlayback, 'Lista para reproducción remota');
    expect(strings.lastCommand, 'Último comando');
  });

  test('privacy and recommendation labels are localized', () {
    const spanish = AppStrings(AppLanguage.spanish);
    const english = AppStrings(AppLanguage.english);

    expect(spanish.privacyAndRecommendations, 'Privacidad y recomendaciones');
    expect(spanish.recommendationHistory, 'Historial de recomendaciones');
    expect(
      spanish.clearRecommendationHistory,
      'Borrar historial y recomendaciones',
    );
    expect(english.privacyAndRecommendations, 'Privacy and recommendations');
    expect(english.recommendationHistory, 'Recommendation history');
    expect(
      english.clearRecommendationHistory,
      'Clear history and recommendations',
    );
  });

  test(
    'YouTube Music disclosure stays brief and explains the access risk',
    () {
      const spanish = AppStrings(AppLanguage.spanish);
      const english = AppStrings(AppLanguage.english);

      expect(
        spanish.youtubeMusicUnofficialDisclosure,
        allOf(
          contains('no oficiales'),
          contains('no guarda tu contraseña'),
          contains('cambiar, bloquear o restringir'),
        ),
      );
      expect(
        english.youtubeMusicUnofficialDisclosure,
        allOf(
          contains('unofficial'),
          contains('never stores your password'),
          contains('may change, block, or restrict'),
        ),
      );
      expect(
        spanish.youtubeMusicUnofficialDisclosure,
        isNot(contains('Favoritos')),
      );
      expect(
        english.youtubeMusicUnofficialDisclosure,
        isNot(contains('Favorites')),
      );
    },
  );
}

const _mojibakeMarkers = <String, String>{
  '\uFFFD': 'replacement character U+FFFD',
  'Ã': 'Latin-1-decoded UTF-8 sequence beginning with Ã',
  'Â': 'Latin-1-decoded UTF-8 sequence beginning with Â',
  'â€': 'misdecoded typographic punctuation',
  'ðŸ': 'misdecoded emoji',
  'ï»¿': 'misdecoded UTF-8 byte-order mark',
};
