part of 'music_providers.dart';

enum AppLanguage { spanish, english }

extension AppLanguageLabel on AppLanguage {
  String get label => switch (this) {
    AppLanguage.spanish => 'Espanol',
    AppLanguage.english => 'English',
  };

  String get code => switch (this) {
    AppLanguage.spanish => 'es',
    AppLanguage.english => 'en',
  };

  static AppLanguage fromCode(String? code) {
    return switch (code) {
      'en' => AppLanguage.english,
      _ => AppLanguage.spanish,
    };
  }
}

final appStringsProvider = Provider<AppStrings>((ref) {
  final language =
      ref.watch(settingsControllerProvider).value?.language ??
      AppLanguage.spanish;
  return AppStrings(language);
});

class AppStrings {
  const AppStrings(this.appLanguage);

  final AppLanguage appLanguage;

  bool get isEnglish => appLanguage == AppLanguage.english;

  String choose(String es, String en) => isEnglish ? en : es;

  String get home => choose('Inicio', 'Home');
  String get recentlyPlayed =>
      choose('Escuchado recientemente', 'Recently played');
  String get myPlaylists => choose('Mis playlists', 'My playlists');
  String get noRecentSongs => choose(
    'Aun no has escuchado canciones.',
    'No recently played songs yet.',
  );
  String get search => choose('Buscar', 'Search');
  String get searchTitle => choose('Búsqueda', 'Search');
  String get player => choose('Reproductor', 'Player');
  String get library => choose('Biblioteca', 'Library');
  String get settings => choose('Ajustes', 'Settings');
  String get searchHint =>
      choose('Cancion, artista o URL', 'Song, artist, or URL');
  String get searchEmptyTitle => choose(
    'Busca canciones, artistas o enlaces',
    'Search songs, artists, or links',
  );
  String get searchEmptySubtitle =>
      choose('Los resultados apareceran aqui.', 'Results will appear here.');
  String get searchErrorTitle => choose('No se pudo buscar', 'Search failed');
  String get play => choose('Reproducir', 'Play');
  String get pause => choose('Pausar', 'Pause');
  String get previous => choose('Anterior', 'Previous');
  String get next => choose('Siguiente', 'Next');
  String get download => choose('Descargar', 'Download');
  String get downloadAudio => choose('Descargar audio', 'Download audio');
  String get noPlayback => choose('Sin reproduccion', 'Nothing playing');
  String get nowPlaying => choose('En reproduccion', 'Now playing');
  String get noTitle => choose('Sin titulo', 'Untitled');
  String get unknownArtist => choose('Desconocido', 'Unknown');
  String get playbackError => choose('Error de reproduccion', 'Playback error');
  String get volume => choose('Volumen', 'Volume');
  String get volumeControl => choose('Control de Volumen', 'Volume control');
  String get close => choose('Cerrar', 'Close');
  String get moreOptions => choose('Mas opciones', 'More options');
  String get addToPlaylist => choose('Anadir a playlist', 'Add to playlist');
  String get favorites => choose('Favoritos', 'Favorites');
  String get addToFavorites => choose('Anadir a favoritos', 'Add to favorites');
  String get removeFromFavorites =>
      choose('Quitar de favoritos', 'Remove from favorites');
  String get addedToFavorites =>
      choose('Cancion agregada a favoritos.', 'Song added to favorites.');
  String get removedFromFavorites =>
      choose('Cancion quitada de favoritos.', 'Song removed from favorites.');
  String get choosePlaylist => choose('Elegir playlist', 'Choose playlist');
  String get createPlaylistFirst =>
      choose('Crea una playlist primero.', 'Create a playlist first.');
  String get songAddedToPlaylist =>
      choose('Cancion agregada a la playlist.', 'Song added to playlist.');
  String get downloadQueued =>
      choose('Descarga agregada a la cola.', 'Download added to queue.');
  String get back => choose('Volver', 'Back');
  String get error => choose('Error', 'Error');
  String get downloads => choose('Descargas', 'Downloads');
  String get downloadedSongs =>
      choose('Canciones descargadas', 'Downloaded songs');
  String get liveQueue => choose('LIVE', 'LIVE');
  String get liveQueueTitle => choose('Cola LIVE', 'LIVE queue');
  String get playbackQueue => choose('Cola de reproduccion', 'Playback queue');
  String get playbackQueueEmpty => choose(
    'No hay canciones en la cola actual.',
    'There are no songs in the current queue.',
  );
  String get liveQueueEmpty => choose(
    'Los pedidos !play apareceran aqui.',
    'Live !play requests will appear here.',
  );
  String get clearLiveQueue => choose('Limpiar cola LIVE', 'Clear LIVE queue');
  String get requestedBy => choose('Pedido por', 'Requested by');
  String get moderator => choose('Moderador', 'Moderator');
  String get commandPermissions =>
      choose('Quien puede usar los comandos', 'Who can use commands');
  String get everyone => choose('Todos', 'Everyone');
  String get moderators => choose('Moderadores', 'Moderators');
  String get reusedDownload => choose('Ya descargada', 'Already downloaded');
  String get playlist => choose('Playlist', 'Playlist');
  String get newPlaylist => choose('Nueva playlist', 'New playlist');
  String get createPlaylist => choose('Crear playlist', 'Create playlist');
  String get create => choose('Crear', 'Create');
  String get cancel => choose('Cancelar', 'Cancel');
  String get name => choose('Nombre', 'Name');
  String get filterSongs => choose('Filtrar canciones', 'Filter songs');
  String get noSongsToShow =>
      choose('No hay canciones para mostrar.', 'No songs to show.');
  String get noLocalPlaylists => choose(
    'Todavia no hay playlists locales.',
    'There are no local playlists yet.',
  );
  String get playlistMissing =>
      choose('La playlist ya no existe.', 'This playlist no longer exists.');
  String get deleteSong => choose('Eliminar cancion', 'Delete song');
  String get delete => choose('Eliminar', 'Delete');
  String get rename => choose('Renombrar', 'Rename');
  String get renameSong => choose('Renombrar cancion', 'Rename song');
  String get renamePlaylist => choose('Renombrar playlist', 'Rename playlist');
  String get deletePlaylist => choose('Eliminar playlist', 'Delete playlist');
  String get songRenamed => choose('Cancion renombrada.', 'Song renamed.');
  String get playlistRenamed =>
      choose('Playlist renombrada.', 'Playlist renamed.');
  String get playlistDeleted =>
      choose('Playlist eliminada.', 'Playlist deleted.');
  String get confirmDeletePlaylist => choose(
    'Esta accion no elimina las canciones guardadas.',
    'This does not delete downloaded songs.',
  );
  String get songDeleted => choose('Cancion eliminada.', 'Song deleted.');
  String get removeFromPlaylist =>
      choose('Quitar de playlist', 'Remove from playlist');
  String get folder => choose('Carpeta', 'Folder');
  String get backup => choose('Respaldo', 'Backup');
  String get exportBackup => choose('Exportar', 'Export');
  String get importBackup => choose('Importar', 'Import');
  String get exportBackupTitle => choose('Exportar respaldo', 'Export backup');
  String get importBackupTitle => choose('Importar respaldo', 'Import backup');
  String get backupExported =>
      choose('Respaldo exportado.', 'Backup exported.');
  String get backupImported =>
      choose('Respaldo importado.', 'Backup imported.');
  String get backupCancelled =>
      choose('Operacion cancelada.', 'Operation cancelled.');
  String get backupFailed =>
      choose('No se pudo completar el respaldo.', 'Backup failed.');
  String get language => choose('Idioma', 'Language');
  String get spanish => choose('Espanol', 'Spanish');
  String get english => 'English';
  String get sleepTimer => choose('Temporizador', 'Sleep timer');
  String get automaticShutdown =>
      choose('Apagado automatico', 'Automatic shutdown');
  String get sleepTimerOff => choose('Desactivado', 'Off');
  String get customDuration => choose('Personalizar', 'Custom');
  String get timerDuration =>
      choose('Duracion del temporizador', 'Timer duration');
  String get startTimer => choose('Iniciar', 'Start');
  String get invalidTimerDuration => choose(
    'Ingresa una duracion entre 1 y 720 minutos.',
    'Enter a duration between 1 and 720 minutes.',
  );
  String get desktopTools => choose('Herramientas desktop', 'Desktop tools');
  String get liveConnection => choose('Conexion LIVE', 'LIVE connection');
  String get tiktokLive => choose('TikTok LIVE', 'TikTok LIVE');
  String get tiktokLiveUser =>
      choose('@usuario o link del live', '@user or live link');
  String get connect => choose('Conectar', 'Connect');
  String get disconnect => choose('Desconectar', 'Disconnect');
  String get connected => choose('conectado', 'connected');
  String get disconnected => choose('desconectado', 'disconnected');
  String get lastCommand => choose('Ultimo comando', 'Last command');
  String get pendingRequests =>
      choose('Pedidos pendientes', 'Pending requests');
  String get roomId => 'room_id';
  String get browseFolder => choose('Explorar carpeta', 'Browse folder');
  String get save => choose('Guardar', 'Save');
  String get verify => choose('Verificar', 'Check');
  String get available => choose('disponible', 'available');
  String get notFound => choose('no encontrado', 'not found');
  String get selectDownloadFolder =>
      choose('Selecciona carpeta de descargas', 'Select downloads folder');
  String get queued => choose('En cola', 'Queued');
  String get downloading => choose('Descargando', 'Downloading');
  String get completed => choose('Completado', 'Completed');
  String get activateShuffle => choose('Activar aleatorio', 'Enable shuffle');
  String get deactivateShuffle =>
      choose('Desactivar aleatorio', 'Disable shuffle');
  String get repeatQueue => choose('Repetir cola', 'Repeat queue');
  String get repeatOne => choose('Repetir una', 'Repeat one');
  String get disableRepeat => choose('Desactivar repetir', 'Disable repeat');

  String sleepTimerRemaining(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 24 * 60 * 60);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final formatted = hours > 0
        ? '${hours.toString().padLeft(2, '0')}:'
              '${minutes.toString().padLeft(2, '0')}:'
              '${seconds.toString().padLeft(2, '0')}'
        : '${minutes.toString().padLeft(2, '0')}:'
              '${seconds.toString().padLeft(2, '0')}';
    return choose(
      'El reproductor se detendra en $formatted',
      'The player will stop in $formatted',
    );
  }

  String timerMinutes(int minutes) => choose('$minutes min', '$minutes min');

  String appVersion(String version) =>
      choose('Versión $version', 'Version $version');

  String songCount(int count) {
    if (isEnglish) {
      return '$count ${count == 1 ? 'song' : 'songs'}';
    }
    return '$count ${count == 1 ? 'cancion' : 'canciones'}';
  }

  String playbackQueueSummary(int count) {
    if (isEnglish) {
      return 'Playback Queue - $count ${count == 1 ? 'Song' : 'Songs'}';
    }
    return 'Cola de Reproducción - $count '
        '${count == 1 ? 'Canción' : 'Canciones'}';
  }

  String liveQueueSummary(int total, int ready, int pending) {
    if (isEnglish) {
      return '$total requests - $ready ready - $pending pending';
    }
    return '$total pedidos - $ready listos - $pending pendientes';
  }

  String exitPressesRemaining(int remaining) {
    if (isEnglish) {
      return 'Press ${remaining == 1 ? 'once' : '$remaining more times'} to exit.';
    }
    return 'Presiona $remaining ${remaining == 1 ? 'vez' : 'veces'} mas para salir.';
  }

  String downloadLabel(String label, String title, int queuedCount) {
    if (queuedCount <= 0) {
      return '$label: $title';
    }
    final queuedText = isEnglish
        ? '$queuedCount queued'
        : '$queuedCount en cola';
    return '$label: $title - $queuedText';
  }
}
