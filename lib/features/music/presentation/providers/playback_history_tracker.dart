part of 'music_providers.dart';

typedef PlaybackHistoryTimerFactory =
    Timer Function(Duration duration, void Function() callback);

typedef PlaybackHistoryWriteCallback =
    Future<void> Function(PlaybackHistoryWrite write);

abstract interface class PlaybackHistorySink {
  Future<void> persist(PlaybackHistoryWrite write);
}

final playbackHistorySinkProvider = Provider<PlaybackHistorySink>((ref) {
  return _DatabasePlaybackHistorySink(
    database: ref.watch(databaseServiceProvider),
    repository: ref.watch(libraryRepositoryProvider),
  );
});

class _DatabasePlaybackHistorySink implements PlaybackHistorySink {
  const _DatabasePlaybackHistorySink({
    required this._database,
    required this._repository,
  });

  final LocalDatabaseService _database;
  final LibraryRepository _repository;

  @override
  Future<void> persist(PlaybackHistoryWrite write) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _database.recordPlaybackEvent(write.event);
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }

    final localTrackId = write.track.localTrackId;
    if (write.isInitialQualification && localTrackId != null) {
      try {
        await _repository.markPlayed(
          localTrackId,
          write.event.playedAt,
          playlistId: write.track.playlistId,
        );
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}

/// Canonical catalog metadata for one logical queue item.
///
/// The player backend is deliberately not used as the source of truth here:
/// a cached YouTube stream is reported as a local file by just_audio even
/// though it is still a remote catalog track from the user's perspective.
class PlaybackHistoryTrack {
  const PlaybackHistoryTrack({
    required this.logicalKey,
    required this.trackId,
    required this.title,
    required this.artists,
    required this.source,
    this.videoId,
    this.artistBrowseIds = const <String?>[],
    this.album,
    this.thumbnailUrl,
    this.duration,
    this.localTrackId,
    this.playlistId,
    this.isFavorite,
    this.isLiked,
  });

  final String logicalKey;
  final String trackId;
  final String? videoId;
  final String title;
  final List<String> artists;
  final List<String?> artistBrowseIds;
  final String? album;
  final String? thumbnailUrl;
  final Duration? duration;
  final PlaybackEventSource source;

  /// Present only when the qualifying play should update the legacy local
  /// "recently played" list as well as the recommendation event table.
  final String? localTrackId;
  final String? playlistId;
  final bool? isFavorite;
  final bool? isLiked;
}

/// One idempotent persistence operation for a playback session.
class PlaybackHistoryWrite {
  const PlaybackHistoryWrite({
    required this.event,
    required this.track,
    required this.isInitialQualification,
  });

  final PlaybackEvent event;
  final PlaybackHistoryTrack track;
  final bool isInitialQualification;
}

/// Counts actual time spent in `playing`, independently of media position.
///
/// Seeking therefore cannot qualify a play. Pauses, buffering and resolver
/// retries stop the monotonic clock. Writes for one session reuse the same
/// id, so a later completion snapshot enriches the row instead of adding a
/// second play.
class QualifiedPlaybackHistoryTracker {
  QualifiedPlaybackHistoryTracker({
    required PlaybackHistoryWriteCallback onWrite,
    DateTime Function()? wallClock,
    Duration Function()? monotonicClock,
    String Function()? sessionIdFactory,
    PlaybackHistoryTimerFactory? timerFactory,
  }) : _onWrite = ((write) => onWrite(write)),
       _wallClock = wallClock ?? DateTime.now,
       _sessionIdFactory = sessionIdFactory ?? const Uuid().v4,
       _timerFactory = timerFactory ?? _defaultTimerFactory {
    if (monotonicClock == null) {
      _stopwatch = Stopwatch()..start();
      _monotonicClock = () => _stopwatch!.elapsed;
    } else {
      _monotonicClock = monotonicClock;
    }
  }

  static const Duration maximumQualificationThreshold = Duration(seconds: 30);

  final PlaybackHistoryWriteCallback _onWrite;
  final DateTime Function() _wallClock;
  final String Function() _sessionIdFactory;
  final PlaybackHistoryTimerFactory _timerFactory;
  late final Duration Function() _monotonicClock;
  Stopwatch? _stopwatch;

  bool _enabled = false;
  bool _disposed = false;
  _QualifiedPlaybackSession? _active;
  Timer? _thresholdTimer;
  Future<void> _writeTail = Future<void>.value();

  bool get isEnabled => _enabled;

  /// Forty percent of known duration, capped at 30 seconds. Unknown or
  /// invalid durations conservatively use the full 30-second threshold.
  static Duration qualificationThreshold(Duration? duration) {
    if (duration == null || duration <= Duration.zero) {
      return maximumQualificationThreshold;
    }
    final fortyPercent = Duration(
      microseconds: (duration.inMicroseconds * 0.4).round(),
    );
    if (fortyPercent <= Duration.zero) {
      return maximumQualificationThreshold;
    }
    return fortyPercent < maximumQualificationThreshold
        ? fortyPercent
        : maximumQualificationThreshold;
  }

  /// Enabling begins with the next valid playback observation. Disabling is
  /// synchronous from the caller's perspective and discards partial listens.
  Future<void> setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) {
      return _writeTail;
    }
    _enabled = enabled;
    if (!enabled) {
      _discardActiveSession();
    }
    return _writeTail;
  }

  void update({
    required PlaybackHistoryTrack? track,
    required PlayerStatus status,
  }) {
    if (!_enabled || _disposed) {
      return;
    }

    final current = _active;
    if (track == null) {
      _finishActive(completed: false);
      return;
    }

    if (current == null || current.track.logicalKey != track.logicalKey) {
      _finishActive(completed: false);
      if (status != PlayerStatus.playing) {
        return;
      }
      _active = _QualifiedPlaybackSession(
        sessionId: _sessionIdFactory(),
        track: track,
        startedAt: _wallClock(),
      );
    } else {
      // Resolver refreshes may enrich duration or metadata without changing
      // the logical item. Keep the accumulated session and use the newest
      // canonical representation for persistence.
      current.track = track;
    }

    final session = _active;
    if (session == null) {
      return;
    }

    if (status == PlayerStatus.playing) {
      _resume(session);
      return;
    }

    _pause(session);
    if (status == PlayerStatus.completed) {
      _persistIfQualified(session, completed: true, terminal: true);
      _endSession(session);
    } else if (status == PlayerStatus.stopped || status == PlayerStatus.idle) {
      _persistIfQualified(session, completed: false, terminal: true);
      _endSession(session);
    }
  }

  /// Drops the in-memory listen and waits until every already-started write
  /// has settled. Calling this before deleting the database rows prevents a
  /// late threshold write from resurrecting cleared history.
  Future<void> reset() async {
    _discardActiveSession();
    await _writeTail;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return _writeTail;
    }
    _disposed = true;
    final session = _active;
    if (session != null) {
      _pause(session);
      _persistIfQualified(session, completed: false, terminal: true);
    }
    _discardActiveSession();
    await _writeTail;
    _stopwatch?.stop();
  }

  void _resume(_QualifiedPlaybackSession session) {
    if (!identical(_active, session)) {
      return;
    }
    _accumulate(session);
    session.playingSince ??= _monotonicClock();
    _persistIfQualified(session, completed: false);
    _scheduleThreshold(session);
  }

  void _pause(_QualifiedPlaybackSession session) {
    _accumulate(session);
    session.playingSince = null;
    _thresholdTimer?.cancel();
    _thresholdTimer = null;
    _persistIfQualified(session, completed: false);
  }

  void _accumulate(_QualifiedPlaybackSession session) {
    final startedAt = session.playingSince;
    if (startedAt == null) {
      return;
    }
    final now = _monotonicClock();
    final delta = now - startedAt;
    if (delta > Duration.zero) {
      session.listened += delta;
    }
    session.playingSince = now;
  }

  void _scheduleThreshold(_QualifiedPlaybackSession session) {
    _thresholdTimer?.cancel();
    _thresholdTimer = null;
    if (!identical(_active, session) ||
        session.playingSince == null ||
        session.initialQualificationWritten) {
      return;
    }
    final threshold = qualificationThreshold(session.track.duration);
    final remaining = threshold - session.listened;
    if (remaining <= Duration.zero) {
      _persistIfQualified(session, completed: false);
      return;
    }
    // A one-millisecond floor avoids a tight loop if an injected or coarse
    // monotonic clock advances slightly less than the Dart timer.
    final delay = remaining < const Duration(milliseconds: 1)
        ? const Duration(milliseconds: 1)
        : remaining;
    _thresholdTimer = _timerFactory(delay, () {
      if (!_enabled || _disposed || !identical(_active, session)) {
        return;
      }
      _accumulate(session);
      _persistIfQualified(session, completed: false);
      _scheduleThreshold(session);
    });
  }

  void _persistIfQualified(
    _QualifiedPlaybackSession session, {
    required bool completed,
    bool terminal = false,
  }) {
    final threshold = qualificationThreshold(session.track.duration);
    if (session.listened < threshold) {
      return;
    }
    final isInitial = !session.initialQualificationWritten;
    final listenedMs = session.listened.inMilliseconds;
    if (!isInitial) {
      if (completed) {
        if (session.completionWritten) {
          return;
        }
      } else if (!terminal || listenedMs <= session.lastPersistedListenedMs) {
        return;
      }
    }
    session.initialQualificationWritten = true;
    session.lastPersistedListenedMs = listenedMs;
    if (completed) {
      session.completionWritten = true;
    }
    _thresholdTimer?.cancel();
    _thresholdTimer = null;

    final track = session.track;
    final event = PlaybackEvent(
      sessionId: session.sessionId,
      trackId: track.trackId,
      videoId: track.videoId,
      title: track.title,
      artists: track.artists,
      artistBrowseIds: track.artistBrowseIds,
      album: track.album,
      thumbnailUrl: track.thumbnailUrl,
      durationMs: track.duration?.inMilliseconds,
      source: track.source,
      startedAt: session.startedAt,
      playedAt: _wallClock(),
      listenedMs: listenedMs,
      completed: completed,
      isFavorite: track.isFavorite,
      isLiked: track.isLiked,
    );
    final write = PlaybackHistoryWrite(
      event: event,
      track: track,
      isInitialQualification: isInitial,
    );
    _writeTail = _writeTail
        .catchError((Object _) {})
        .then((_) => _onWrite(write))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint(
            'Qualified playback history write failed: $error\n$stackTrace',
          );
        });
  }

  void _finishActive({required bool completed}) {
    final session = _active;
    if (session == null) {
      return;
    }
    _pause(session);
    _persistIfQualified(session, completed: completed, terminal: true);
    _endSession(session);
  }

  void _endSession(_QualifiedPlaybackSession session) {
    if (identical(_active, session)) {
      _active = null;
    }
    _thresholdTimer?.cancel();
    _thresholdTimer = null;
  }

  void _discardActiveSession() {
    _thresholdTimer?.cancel();
    _thresholdTimer = null;
    _active = null;
  }

  static Timer _defaultTimerFactory(
    Duration duration,
    void Function() callback,
  ) => Timer(duration, callback);
}

class _QualifiedPlaybackSession {
  _QualifiedPlaybackSession({
    required this.sessionId,
    required this.track,
    required this.startedAt,
  });

  final String sessionId;
  PlaybackHistoryTrack track;
  final DateTime startedAt;
  Duration listened = Duration.zero;
  Duration? playingSince;
  bool initialQualificationWritten = false;
  bool completionWritten = false;
  int lastPersistedListenedMs = 0;
}
