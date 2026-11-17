import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/music/data/models/local_track_model.dart';
import '../../features/music/data/models/track_info_model.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import 'player_service.dart';

/// Durable catalog/local identity, without a resolved or authenticated stream.
class PlaybackSessionEntry {
  PlaybackSessionEntry({
    LocalTrack? local,
    TrackInfo? remote,
    this.logicalEntryId,
  }) : local = local?.copyWith(
         artists: List<String>.unmodifiable(local.artists),
         artistBrowseIds: List<String?>.unmodifiable(local.artistBrowseIds),
       ),
       remote = remote?.withoutAudioTransport().copyWith(
         artists: List<String>.unmodifiable(remote.artists),
         artistBrowseIds: List<String?>.unmodifiable(remote.artistBrowseIds),
       ) {
    if (this.local == null && this.remote == null) {
      throw ArgumentError('A playback entry needs a source.');
    }
  }

  final LocalTrack? local;
  final TrackInfo? remote;
  final String? logicalEntryId;

  Duration? get duration => local?.duration ?? remote?.duration;

  Map<String, Object?> toJson() {
    final localTrack = local;
    final remoteTrack = remote;
    return <String, Object?>{
      if (logicalEntryId != null) 'logicalEntryId': logicalEntryId,
      if (localTrack != null)
        'local': <String, Object?>{
          ...LocalTrackModel.fromEntity(localTrack).toMap(),
          'is_external': localTrack.isExternal,
          'duration_us': localTrack.duration?.inMicroseconds,
        },
      if (remoteTrack != null)
        'remote': <String, Object?>{
          'id': remoteTrack.id,
          'title': remoteTrack.title,
          'artist': remoteTrack.artist,
          'url': remoteTrack.url,
          'thumbnail': remoteTrack.thumbnailUrl,
          'catalog_thumbnail': remoteTrack.catalogThumbnailUrl,
          'duration': remoteTrack.duration?.inSeconds,
          'duration_us': remoteTrack.duration?.inMicroseconds,
          'extractor': remoteTrack.extractor,
          'album': remoteTrack.album,
          'album_browse_id': remoteTrack.albumBrowseId,
          'view_count': remoteTrack.viewCount,
          'artists': remoteTrack.artists,
          'artist_browse_ids': remoteTrack.artistBrowseIds,
          'metadata_source': remoteTrack.metadataSource.name,
        },
    };
  }

  static PlaybackSessionEntry fromJson(Object? value) {
    final map = _objectMap(value);
    final localValue = map['local'];
    final remoteValue = map['remote'];
    LocalTrack? local;
    TrackInfo? remote;
    if (localValue != null) {
      final fields = _objectMap(localValue);
      _requiredString(fields, 'id');
      _requiredString(fields, 'file_path');
      _string(fields, 'title');
      _string(fields, 'artist');
      local = LocalTrackModel.fromMap(fields).copyWith(
        isExternal: _boolean(fields, 'is_external', fallback: false),
        duration: _optionalDuration(fields['duration_us']),
      );
    }
    if (remoteValue != null) {
      final fields = _objectMap(remoteValue);
      _requiredString(fields, 'url');
      _string(fields, 'id');
      _string(fields, 'title');
      _string(fields, 'artist');
      remote = TrackInfoModel.fromJson(fields)
          .copyWith(duration: _optionalDuration(fields['duration_us']))
          .withoutAudioTransport();
    }
    if (local == null && remote == null) {
      throw const FormatException('A playback entry needs a source.');
    }
    return PlaybackSessionEntry(
      local: local,
      remote: remote,
      logicalEntryId: _optionalString(map, 'logicalEntryId'),
    );
  }
}

/// The logical queue and cursor to restore in a paused state after a cold start.
///
/// Reuse [entries] when checkpointing position, or use [copyWith], so the store
/// does not re-encode the potentially large queue on every cursor write.
class PlaybackSession {
  PlaybackSession({
    required List<PlaybackSessionEntry> entries,
    required this.currentIndex,
    required Duration position,
    this.shuffleEnabled = false,
    this.repeatMode = PlaybackRepeatMode.off,
    Iterable<int> playedIndices = const <int>[],
    Iterable<int> shufflePlan = const <int>[],
    this.localSourceId,
    this.remoteSourceId,
    this.activePlaybackIsRemote = false,
    this.useNativeLocalQueue = true,
  }) : entries = entries is _SessionEntries
           ? entries
           : _SessionEntries(entries),
       position = position < Duration.zero ? Duration.zero : position,
       playedIndices = Set<int>.unmodifiable(playedIndices),
       shufflePlan = List<int>.unmodifiable(shufflePlan);

  final List<PlaybackSessionEntry> entries;
  final int currentIndex;
  final Duration position;
  final bool shuffleEnabled;
  final PlaybackRepeatMode repeatMode;
  final Set<int> playedIndices;
  final List<int> shufflePlan;
  final String? localSourceId;
  final String? remoteSourceId;
  final bool activePlaybackIsRemote;
  final bool useNativeLocalQueue;

  PlaybackSession copyWith({
    List<PlaybackSessionEntry>? entries,
    int? currentIndex,
    Duration? position,
    bool? shuffleEnabled,
    PlaybackRepeatMode? repeatMode,
    Iterable<int>? playedIndices,
    Iterable<int>? shufflePlan,
    String? localSourceId,
    String? remoteSourceId,
    bool? activePlaybackIsRemote,
    bool? useNativeLocalQueue,
  }) => PlaybackSession(
    entries: entries ?? this.entries,
    currentIndex: currentIndex ?? this.currentIndex,
    position: position ?? this.position,
    shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
    repeatMode: repeatMode ?? this.repeatMode,
    playedIndices: playedIndices ?? this.playedIndices,
    shufflePlan: shufflePlan ?? this.shufflePlan,
    localSourceId: localSourceId ?? this.localSourceId,
    remoteSourceId: remoteSourceId ?? this.remoteSourceId,
    activePlaybackIsRemote:
        activePlaybackIsRemote ?? this.activePlaybackIsRemote,
    useNativeLocalQueue: useNativeLocalQueue ?? this.useNativeLocalQueue,
  );
}

class _SessionEntries extends ListBase<PlaybackSessionEntry> {
  _SessionEntries(List<PlaybackSessionEntry> entries)
    : _entries = List<PlaybackSessionEntry>.unmodifiable(entries);

  final List<PlaybackSessionEntry> _entries;

  @override
  int get length => _entries.length;
  @override
  set length(int value) =>
      throw UnsupportedError('Session entries are immutable.');
  @override
  PlaybackSessionEntry operator [](int index) => _entries[index];
  @override
  void operator []=(int index, PlaybackSessionEntry value) =>
      throw UnsupportedError('Session entries are immutable.');
}

abstract interface class PlaybackSessionStore {
  Future<PlaybackSession?> read();
  Future<void> write(PlaybackSession session);
  Future<void> clear();
}

/// Queue metadata is written only when it changes. Frequent checkpoints update
/// a separate, small cursor. A matching revision prevents torn writes from
/// applying the previous queue's cursor to a replacement queue.
class SharedPreferencesPlaybackSessionStore implements PlaybackSessionStore {
  SharedPreferencesPlaybackSessionStore({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const queuePreferenceKey = 'bstream.playback_session.queue.v1';
  static const cursorPreferenceKey = 'bstream.playback_session.cursor.v1';
  static const _version = 1;

  final Future<SharedPreferences> Function() _loadPreferences;
  Future<SharedPreferences>? _preferences;
  Future<void> _tail = Future<void>.value();
  List<PlaybackSessionEntry>? _encodedEntries;
  String? _entriesJson;
  String? _revision;
  String? _cursorJson;

  Future<SharedPreferences> get _prefs {
    final cached = _preferences;
    if (cached != null) return cached;
    late final Future<SharedPreferences> request;
    request = Future<SharedPreferences>.sync(_loadPreferences)
        .then<SharedPreferences>(
          (value) => value,
          onError: (Object error, StackTrace stack) {
            if (identical(_preferences, request)) _preferences = null;
            Error.throwWithStackTrace(error, stack);
          },
        );
    _preferences = request;
    return request;
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<PlaybackSession?> read() => _serialized(() async {
    _encodedEntries = null;
    _entriesJson = null;
    _revision = null;
    _cursorJson = null;
    final prefs = await _prefs;
    try {
      final raw = prefs.getString(queuePreferenceKey);
      if (raw == null) return null;
      final queue = _objectMap(jsonDecode(raw));
      if (queue['version'] != _version || queue['entries'] is! List) {
        return null;
      }
      final encoded = jsonEncode(queue['entries']);
      final revision = _requiredString(queue, 'revision');
      if (_queueRevision(encoded) != revision) return null;
      final entries = (queue['entries']! as List)
          .map(PlaybackSessionEntry.fromJson)
          .toList(growable: false);
      if (entries.isEmpty) return null;
      final storedCursor = prefs.get(cursorPreferenceKey);
      final rawCursor = storedCursor is String ? storedCursor : null;
      Map<String, Object?>? cursor;
      PlaybackSession? cursorSession;
      if (rawCursor != null) {
        try {
          final candidate = _objectMap(jsonDecode(rawCursor));
          if (candidate['version'] == _version &&
              candidate['revision'] == revision) {
            cursorSession = _decodeSession(entries, candidate);
            cursor = candidate;
          }
        } on FormatException {
          // A partially written cursor can use the queue's original cursor.
        }
      }
      final session =
          cursorSession ??
          _decodeSession(entries, _objectMap(queue['initialCursor']));
      _encodedEntries = session.entries;
      _entriesJson = encoded;
      _revision = revision;
      _cursorJson = cursor == null ? null : rawCursor;
      return session;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  });

  @override
  Future<void> write(PlaybackSession session) => _serialized(() async {
    if (session.entries.isEmpty ||
        session.currentIndex < 0 ||
        session.currentIndex >= session.entries.length) {
      throw ArgumentError('A persisted session needs a selected queue entry.');
    }
    final prefs = await _prefs;
    final sameEntries = identical(session.entries, _encodedEntries);
    final encoded = sameEntries
        ? _entriesJson!
        : jsonEncode(session.entries.map((entry) => entry.toJson()).toList());
    final revision = sameEntries ? _revision! : _queueRevision(encoded);
    final cursor = _encodeCursor(session, revision);
    final cursorJson = jsonEncode(cursor);
    if (encoded != _entriesJson) {
      // Components are encoded already. Keep large queues out of a second
      // decode/encode cycle when writing their durable envelope.
      final queueJson =
          '{"version":$_version,"revision":${jsonEncode(revision)},'
          '"entries":$encoded,"initialCursor":$cursorJson}';
      if (!await prefs.setString(queuePreferenceKey, queueJson)) {
        throw StateError('The playback queue could not be saved.');
      }
      _entriesJson = encoded;
      _revision = revision;
    }
    _encodedEntries = session.entries;
    if (cursorJson != _cursorJson) {
      if (!await prefs.setString(cursorPreferenceKey, cursorJson)) {
        throw StateError('The playback cursor could not be saved.');
      }
      _cursorJson = cursorJson;
    }
  });

  @override
  Future<void> clear() => _serialized(() async {
    final prefs = await _prefs;
    // Remove the queue first: an interrupted clear cannot revive old metadata.
    if (!await prefs.remove(queuePreferenceKey)) {
      throw StateError('The playback queue could not be removed.');
    }
    _encodedEntries = null;
    _entriesJson = null;
    _revision = null;
    _cursorJson = null;
    if (!await prefs.remove(cursorPreferenceKey)) {
      throw StateError('The playback cursor could not be removed.');
    }
  });

  static String _queueRevision(String entries) =>
      sha256.convert(utf8.encode(entries)).toString();

  static Map<String, Object?> _encodeCursor(
    PlaybackSession session,
    String revision,
  ) => <String, Object?>{
    'version': _version,
    'revision': revision,
    'currentIndex': session.currentIndex,
    'positionUs': session.position.inMicroseconds,
    'shuffleEnabled': session.shuffleEnabled,
    'repeatMode': session.repeatMode.name,
    'playedIndices': session.playedIndices.toList(),
    'shufflePlan': session.shufflePlan,
    'localSourceId': session.localSourceId,
    'remoteSourceId': session.remoteSourceId,
    'activePlaybackIsRemote': session.activePlaybackIsRemote,
    'useNativeLocalQueue': session.useNativeLocalQueue,
  };

  static PlaybackSession _decodeSession(
    List<PlaybackSessionEntry> entries,
    Map<String, Object?> cursor,
  ) {
    final index = _integer(cursor['currentIndex']);
    if (index < 0 || index >= entries.length) {
      throw const FormatException('The selected queue index is invalid.');
    }
    var position = _integer(cursor['positionUs']);
    if (position < 0) position = 0;
    final activePlaybackIsRemote = _boolean(
      cursor,
      'activePlaybackIsRemote',
      fallback: false,
    );
    final selected = entries[index];
    final duration = activePlaybackIsRemote
        ? selected.remote?.duration ?? selected.local?.duration
        : selected.duration;
    if (duration != null &&
        duration > Duration.zero &&
        position > duration.inMicroseconds) {
      position = duration.inMicroseconds;
    }
    final played = _indices(cursor['playedIndices'], entries.length).toSet();
    final plan = _indices(cursor['shufflePlan'], entries.length)
        .where((value) => value != index && !played.contains(value))
        .toList(growable: false);
    final repeatName = _optionalString(cursor, 'repeatMode');
    return PlaybackSession(
      entries: entries,
      currentIndex: index,
      position: Duration(microseconds: position),
      shuffleEnabled: _boolean(cursor, 'shuffleEnabled', fallback: false),
      repeatMode: PlaybackRepeatMode.values.firstWhere(
        (mode) => mode.name == repeatName,
        orElse: () => PlaybackRepeatMode.off,
      ),
      playedIndices: played,
      shufflePlan: plan,
      localSourceId: _optionalString(cursor, 'localSourceId'),
      remoteSourceId: _optionalString(cursor, 'remoteSourceId'),
      activePlaybackIsRemote: activePlaybackIsRemote,
      useNativeLocalQueue: _boolean(
        cursor,
        'useNativeLocalQueue',
        fallback: true,
      ),
    );
  }
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Expected an object.');
  }
  return Map<String, Object?>.from(value);
}

String _string(Map<String, Object?> value, String key) {
  final text = value[key];
  if (text is! String) throw FormatException('Invalid $key.');
  return text;
}

String _requiredString(Map<String, Object?> value, String key) {
  final text = _string(value, key);
  if (text.trim().isEmpty) throw FormatException('Empty $key.');
  return text;
}

String? _optionalString(Map<String, Object?> value, String key) {
  final text = value[key];
  if (text == null) return null;
  if (text is! String) throw FormatException('Invalid $key.');
  return text.trim().isEmpty ? null : text;
}

bool _boolean(
  Map<String, Object?> value,
  String key, {
  required bool fallback,
}) {
  final flag = value[key];
  if (flag == null) return fallback;
  if (flag is! bool) throw FormatException('Invalid $key.');
  return flag;
}

int _integer(Object? value) {
  if (value is! int) throw const FormatException('Expected an integer.');
  return value;
}

Duration? _optionalDuration(Object? value) {
  if (value == null) return null;
  final micros = _integer(value);
  return micros < 0 ? null : Duration(microseconds: micros);
}

Iterable<int> _indices(Object? value, int count) {
  if (value == null) return const <int>[];
  if (value is! List) throw const FormatException('Invalid shuffle indices.');
  return value
      .whereType<int>()
      .where((index) => index >= 0 && index < count)
      .toSet();
}
