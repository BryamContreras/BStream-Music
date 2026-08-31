import 'dart:io';

import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('artist mix labels stay coherent in Spanish and English', () {
    const spanish = AppStrings(AppLanguage.spanish);
    const english = AppStrings(AppLanguage.english);

    expect(spanish.artistMix, 'Mix');
    expect(english.artistMix, 'Mix');
    expect(
      spanish.artistMixLoadError,
      'No se pudo iniciar el mix del artista.',
    );
    expect(english.artistMixLoadError, 'The artist mix could not be started.');
  });

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
    expect(strings.everyone, 'Todos');
    expect(strings.moderators, 'Moderadores');
    expect(strings.subscribers, 'Suscriptores');
    expect(
      strings.everyoneCommandPermissionsHint,
      'Comandos disponibles para cualquier espectador.',
    );
    expect(
      strings.moderatorCommandPermissionsHint,
      'Permisos adicionales para moderadores.',
    );
    expect(
      strings.subscriberCommandPermissionsHint,
      'Permisos adicionales para suscriptores.',
    );
    expect(strings.commandAllowedForEveryone, 'Ya está disponible para todos.');
    expect(strings.livePlayCommand, '!play <canción>');
    expect(
      strings.livePlayCommandDescription,
      'Añade una canción a la cola LIVE.',
    );
    expect(strings.liveSkipCommand, '!skip / !next');
    expect(
      strings.liveSkipCommandDescription,
      'Salta a la siguiente canción de la cola LIVE.',
    );
    expect(strings.liveRevokeCommand, '!revoke / revoke!');
    expect(
      strings.liveRevokeCommandDescription,
      'Retira el último pedido de la cola LIVE.',
    );
    expect(strings.liveStopCommand, '!stop');
    expect(strings.liveStopCommandDescription, 'Pausa la canción LIVE actual.');
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

  test('local music filter labels are localized', () {
    const spanish = AppStrings(AppLanguage.spanish);
    const english = AppStrings(AppLanguage.english);

    expect(spanish.localMusic, 'Música local');
    expect(spanish.localTab, 'Local');
    expect(spanish.allLocalSongs, 'Todas las canciones');
    expect(spanish.localMusicFolders, 'Carpetas');
    expect(spanish.allowMusicAccess, 'Permitir acceso');
    expect(spanish.playAll, 'Reproducir todo');
    expect(spanish.backupAndRestore, 'Respaldo y Restauración');
    expect(spanish.localMusicFilters, 'Filtros de música local');
    expect(spanish.localMusicFiltersSummary(0), 'Sin filtros activos');
    expect(spanish.localMusicFiltersSummary(1), '1 filtro activo');
    expect(spanish.localMusicFiltersSummary(2), '2 filtros activos');
    expect(spanish.hideWhatsAppAudio, 'Ocultar audios de WhatsApp');
    expect(spanish.hideTelegramAudio, 'Ocultar audios de Telegram');
    expect(spanish.hideAudioRecordings, 'Ocultar grabaciones de audio');
    expect(
      spanish.hideTracksUnder30Seconds,
      'Ocultar canciones de menos de 30 segundos',
    );
    expect(english.localMusic, 'Local music');
    expect(english.localTab, 'Local');
    expect(english.allLocalSongs, 'All songs');
    expect(english.localMusicFolders, 'Folders');
    expect(english.allowMusicAccess, 'Allow access');
    expect(english.playAll, 'Play all');
    expect(english.backupAndRestore, 'Backup and restore');
    expect(english.localMusicFilters, 'Local music filters');
    expect(english.localMusicFiltersSummary(0), 'No active filters');
    expect(english.localMusicFiltersSummary(1), '1 active filter');
    expect(english.localMusicFiltersSummary(2), '2 active filters');
    expect(english.hideWhatsAppAudio, 'Hide WhatsApp audio');
    expect(english.hideTelegramAudio, 'Hide Telegram audio');
    expect(english.hideAudioRecordings, 'Hide audio recordings');
    expect(
      english.hideTracksUnder30Seconds,
      'Hide songs shorter than 30 seconds',
    );
  });

  test('surface and mini player appearance labels are localized', () {
    const spanish = AppStrings(AppLanguage.spanish);
    const english = AppStrings(AppLanguage.english);

    expect(spanish.surfaceEffects, 'Efectos de superficie');
    expect(spanish.surfaceBackground, 'Fondo de las superficies');
    expect(spanish.surfaceBackgroundAccent, 'Acento');
    expect(spanish.surfaceBackgroundTransparent, 'Transparente');
    expect(spanish.miniPlayer, 'Mini reproductor');
    expect(spanish.miniPlayerStyle, 'Estilo');
    expect(spanish.miniPlayerClassic, 'Clásico');
    expect(spanish.miniPlayerCapsule, 'Cápsula');
    expect(spanish.miniPlayerBackground, 'Fondo del Mini reproductor');
    expect(spanish.miniPlayerBackgroundAccent, 'Acento');
    expect(spanish.miniPlayerBackgroundArtwork, 'Portada');
    expect(spanish.miniPlayerBackgroundTransparent, 'Transparente');
    expect(english.surfaceEffects, 'Surface effects');
    expect(english.surfaceBackground, 'Surface background');
    expect(english.surfaceBackgroundAccent, 'Accent');
    expect(english.surfaceBackgroundTransparent, 'Transparent');
    expect(english.miniPlayer, 'Mini player');
    expect(english.miniPlayerStyle, 'Style');
    expect(english.miniPlayerClassic, 'Classic');
    expect(english.miniPlayerCapsule, 'Capsule');
    expect(english.miniPlayerBackground, 'Mini player background');
    expect(english.miniPlayerBackgroundAccent, 'Accent');
    expect(english.miniPlayerBackgroundArtwork, 'Artwork');
    expect(english.miniPlayerBackgroundTransparent, 'Transparent');
  });

  test('Home greeting labels omit account names', () {
    const spanish = AppStrings(AppLanguage.spanish);
    const english = AppStrings(AppLanguage.english);

    expect(spanish.homeGreeting(hour: 0), 'Buenos días');
    expect(spanish.homeGreeting(hour: 11), 'Buenos días');
    expect(spanish.homeGreeting(hour: 12), 'Buenas tardes');
    expect(spanish.homeGreeting(hour: 23), 'Buenas tardes');
    expect(spanish.recommendedArtists, 'Artistas recomendados');
    expect(english.homeGreeting(hour: 11), 'Good morning');
    expect(english.homeGreeting(hour: 12), 'Good afternoon');
    expect(english.recommendedArtists, 'Recommended artists');
  });

  test('artist subscription availability feedback is localized', () {
    const spanish = AppStrings(AppLanguage.spanish);
    const english = AppStrings(AppLanguage.english);

    expect(
      spanish.artistSubscriptionUnavailable,
      'Este artista no tiene una suscripción disponible.',
    );
    expect(
      english.artistSubscriptionUnavailable,
      'A subscription is not available for this artist.',
    );
    expect(spanish.goToAlbum, 'Ir al álbum');
    expect(english.goToAlbum, 'Go to album');
    expect(
      spanish.albumNavigationUnavailable,
      'No se pudo encontrar el álbum de esta canción.',
    );
    expect(
      english.albumNavigationUnavailable,
      'The album for this song could not be found.',
    );
  });

  test('YouTube Music disclosure stays brief and explains the access risk', () {
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
  });
}

const _mojibakeMarkers = <String, String>{
  '\uFFFD': 'replacement character U+FFFD',
  'Ã': 'Latin-1-decoded UTF-8 sequence beginning with Ã',
  'Â': 'Latin-1-decoded UTF-8 sequence beginning with Â',
  'â€': 'misdecoded typographic punctuation',
  'ðŸ': 'misdecoded emoji',
  'ï»¿': 'misdecoded UTF-8 byte-order mark',
};
