import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../services/live/local_overlay_hosts.dart';
import '../../../../services/live/local_overlay_server.dart';
import '../../../../services/player/player_service.dart';
import 'music_providers.dart';
import '../services/live_overlay_artwork_service.dart';
import '../services/live_overlay_document.dart';

const liveOverlayUrl = localLiveOverlayUrl;
const liveOverlayMaximumItems = 5;

enum LiveOverlayStatus {
  inactive,
  starting,
  active,
  stopping,
  error,
  unsupported,
}

@immutable
class LiveOverlaySnapshot {
  const LiveOverlaySnapshot({
    this.status = LiveOverlayStatus.inactive,
    this.url,
    this.error,
  });

  final LiveOverlayStatus status;
  final Uri? url;
  final String? error;

  bool get isActive => status == LiveOverlayStatus.active;
  bool get isBusy =>
      status == LiveOverlayStatus.starting ||
      status == LiveOverlayStatus.stopping;
}

@immutable
class LiveOverlayQueueEntry {
  const LiveOverlayQueueEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.status,
    this.artworkSource,
    this.artworkDataUri,
  });

  final String id;
  final String title;
  final String artist;
  final String status;

  /// Kept inside Flutter only, so private paths never reach the browser page.
  final String? artworkSource;

  /// A small, cached PNG prepared by [LiveOverlayArtworkService].
  final String? artworkDataUri;

  LiveOverlayQueueEntry withArtworkDataUri(String? value) =>
      LiveOverlayQueueEntry(
        id: id,
        title: title,
        artist: artist,
        status: status,
        artworkSource: artworkSource,
        artworkDataUri: value,
      );

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'title': title,
    'artist': artist,
    'status': status,
    'artwork': ?artworkDataUri,
  };

  @override
  bool operator ==(Object other) {
    return other is LiveOverlayQueueEntry &&
        id == other.id &&
        title == other.title &&
        artist == other.artist &&
        status == other.status &&
        artworkSource == other.artworkSource &&
        artworkDataUri == other.artworkDataUri;
  }

  @override
  int get hashCode =>
      Object.hash(id, title, artist, status, artworkSource, artworkDataUri);
}

@immutable
class LiveOverlayAppearance {
  const LiveOverlayAppearance({
    this.accentSeedArgb = 0xFFF5F7F5,
    this.accentDarkArgb = 0xFF8E9891,
    this.playbackProgressPermille = 0,
    this.playbackPositionMilliseconds = 0,
    this.playbackDurationMilliseconds = 0,
  }) : assert(
         playbackProgressPermille >= 0 && playbackProgressPermille <= 1000,
       ),
       assert(playbackPositionMilliseconds >= 0),
       assert(playbackDurationMilliseconds >= 0);

  final int accentSeedArgb;
  final int accentDarkArgb;
  final int playbackProgressPermille;
  final int playbackPositionMilliseconds;
  final int playbackDurationMilliseconds;

  Map<String, Object> toJson() => <String, Object>{
    'accent': <String, String>{
      'seed': _cssColor(accentSeedArgb),
      'dark': _cssColor(accentDarkArgb),
    },
    'progress': playbackProgressPermille / 1000,
    'positionMs': playbackPositionMilliseconds,
    'durationMs': playbackDurationMilliseconds,
  };

  @override
  bool operator ==(Object other) =>
      other is LiveOverlayAppearance &&
      accentSeedArgb == other.accentSeedArgb &&
      accentDarkArgb == other.accentDarkArgb &&
      playbackProgressPermille == other.playbackProgressPermille &&
      playbackPositionMilliseconds == other.playbackPositionMilliseconds &&
      playbackDurationMilliseconds == other.playbackDurationMilliseconds;

  @override
  int get hashCode => Object.hash(
    accentSeedArgb,
    accentDarkArgb,
    playbackProgressPermille,
    playbackPositionMilliseconds,
    playbackDurationMilliseconds,
  );
}

String _cssColor(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

abstract interface class LiveOverlayClient {
  Future<Uri> start();

  void publishJson(Object? value);

  Future<void> stop();

  Future<void> dispose();
}

class DartLiveOverlayClient implements LiveOverlayClient {
  LocalLiveOverlayServer? _server;
  Future<LocalLiveOverlayServer>? _creatingServer;
  bool _disposed = false;

  Future<LocalLiveOverlayServer> _getServer() {
    final current = _server;
    if (current != null) return Future<LocalLiveOverlayServer>.value(current);
    final pending = _creatingServer;
    if (pending != null) return pending;
    final operation = _createServer();
    _creatingServer = operation;
    return operation.whenComplete(() {
      if (identical(_creatingServer, operation)) _creatingServer = null;
    });
  }

  Future<LocalLiveOverlayServer> _createServer() async {
    if (_disposed) throw StateError('The LIVE overlay client is disposed.');
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'La overlay LIVE local solo está disponible en PC.',
      );
    }
    final iconData = await rootBundle.load('assets/icons/bstream_icon.png');
    final server = LocalLiveOverlayServer(
      hostProvisioner: WindowsLocalOverlayHostProvisioner(),
      htmlDocument: liveOverlayHtml,
      brandIconBytes: iconData.buffer.asUint8List(
        iconData.offsetInBytes,
        iconData.lengthInBytes,
      ),
    );
    if (_disposed) {
      await server.stop();
      throw StateError('The LIVE overlay client is disposed.');
    }
    return _server = server;
  }

  @override
  Future<Uri> start() async {
    _ensureUsable();
    final server = await _getServer();
    _ensureUsable();
    final uri = await server.start();
    if (_disposed) {
      await server.stop();
      _ensureUsable();
    }
    return uri;
  }

  @override
  void publishJson(Object? value) {
    final server = _server;
    if (server == null || !server.isRunning) {
      throw StateError('The LIVE overlay server is not running.');
    }
    server.publishJson(value);
  }

  @override
  Future<void> stop() async => _server?.stop();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final pending = _creatingServer;
    if (pending != null) {
      try {
        await pending;
      } on Object {
        // A concurrent start reports its own creation failure.
      }
    }
    final server = _server;
    _server = null;
    await server?.stop();
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('The LIVE overlay client is disposed.');
  }
}

final liveOverlayAvailableProvider = Provider<bool>(
  (_) => AppPlatform.isWindows,
);

final liveOverlayClientProvider = Provider<LiveOverlayClient>((ref) {
  final client = DartLiveOverlayClient();
  ref.onDispose(() => unawaited(client.dispose()));
  return client;
});

final liveOverlayArtworkLoaderProvider = Provider<LiveOverlayArtworkLoader>((
  _,
) {
  final service = LiveOverlayArtworkService();
  return service.load;
});

final liveOverlayAccentProvider = Provider<AppAccent>((ref) {
  return ref.watch(settingsControllerProvider).value?.accent ?? AppAccent.white;
});

final liveOverlayControllerProvider =
    NotifierProvider<LiveOverlayController, LiveOverlaySnapshot>(
      LiveOverlayController.new,
    );

class LiveOverlayController extends Notifier<LiveOverlaySnapshot> {
  late LiveOverlayClient _client;
  late LiveOverlayArtworkLoader _artworkLoader;
  var _latestQueue = const <LiveOverlayQueueEntry>[];
  var _latestAppearance = const LiveOverlayAppearance();
  var _liveQueue = const <LiveQueueItem>[];
  PlayerSnapshot? _playback;
  var _accent = AppAccent.white;
  var _strings = const AppStrings(AppLanguage.spanish);
  String? _currentLiveItemId;
  var _operationGeneration = 0;
  final Map<String, String?> _resolvedArtwork = <String, String?>{};
  final Set<String> _loadingArtwork = <String>{};
  var _disposed = false;

  @override
  LiveOverlaySnapshot build() {
    _client = ref.watch(liveOverlayClientProvider);
    _artworkLoader = ref.watch(liveOverlayArtworkLoaderProvider);
    _accent = ref.read(liveOverlayAccentProvider);
    _strings = ref.read(appStringsProvider);
    _liveQueue =
        ref.read(tiktokLiveControllerProvider).value?.liveQueue ?? const [];
    _playback = ref.read(playerControllerProvider).value;
    _rebuildQueue(publish: false);

    ref.listen<AsyncValue<TikTokLiveState>>(tiktokLiveControllerProvider, (
      _,
      next,
    ) {
      final liveState = next.value;
      if (liveState == null) return;
      _liveQueue = liveState.liveQueue;
      _rebuildQueue();
    });
    ref.listen<AsyncValue<PlayerSnapshot>>(playerControllerProvider, (_, next) {
      _playback = next.value;
      _rebuildQueue();
    });
    ref.listen<AppAccent>(liveOverlayAccentProvider, (_, next) {
      if (_accent == next) return;
      _accent = next;
      _rebuildQueue();
    });
    ref.listen<AppStrings>(appStringsProvider, (_, next) {
      if (_strings.appLanguage == next.appLanguage) return;
      _strings = next;
      if (state.isActive) _publishLatest();
    });
    ref.onDispose(() {
      _disposed = true;
      unawaited(_client.dispose());
    });
    return const LiveOverlaySnapshot();
  }

  Future<void> start() async {
    if (state.isActive || state.isBusy) return;
    final operation = ++_operationGeneration;
    state = const LiveOverlaySnapshot(status: LiveOverlayStatus.starting);
    _scheduleArtworkResolution();
    try {
      final url = await _client.start();
      if (_disposed || operation != _operationGeneration) return;
      state = LiveOverlaySnapshot(status: LiveOverlayStatus.active, url: url);
      _publishLatest();
    } catch (error, stackTrace) {
      if (_disposed || operation != _operationGeneration) return;
      state = LiveOverlaySnapshot(
        status: error is UnsupportedError
            ? LiveOverlayStatus.unsupported
            : LiveOverlayStatus.error,
        error: _messageFor(error, stackTrace),
      );
    }
  }

  Future<void> stop() async {
    if (state.status == LiveOverlayStatus.inactive ||
        state.status == LiveOverlayStatus.stopping) {
      return;
    }
    final operation = ++_operationGeneration;
    final previousUrl = state.url;
    state = LiveOverlaySnapshot(
      status: LiveOverlayStatus.stopping,
      url: previousUrl,
    );
    try {
      await _client.stop();
      if (_disposed || operation != _operationGeneration) return;
      state = const LiveOverlaySnapshot();
    } catch (error, stackTrace) {
      if (_disposed || operation != _operationGeneration) return;
      state = LiveOverlaySnapshot(
        status: LiveOverlayStatus.active,
        url: previousUrl ?? Uri.parse(liveOverlayUrl),
        error: _messageFor(error, stackTrace),
      );
    }
  }

  void _rebuildQueue({bool publish = true}) {
    if (_currentLiveItemId != null &&
        !_liveQueue.any((item) => item.id == _currentLiveItemId)) {
      _currentLiveItemId = null;
    }
    final selection = selectLiveOverlayQueue(
      _liveQueue,
      playback: _playback,
      isLiveQueueActive: ref
          .read(playerControllerProvider.notifier)
          .isLiveQueueActive,
      previousCurrentItemId: _currentLiveItemId,
    );
    _currentLiveItemId = selection.currentItemId;
    final next = List<LiveOverlayQueueEntry>.unmodifiable(
      selection.entries.map((entry) {
        final source = entry.artworkSource;
        if (source == null || !_resolvedArtwork.containsKey(source)) {
          return entry;
        }
        return entry.withArtworkDataUri(_resolvedArtwork[source]);
      }),
    );
    final nextAppearance = _currentAppearance();
    if (_sameQueue(_latestQueue, next) && _latestAppearance == nextAppearance) {
      return;
    }
    _latestQueue = next;
    _latestAppearance = nextAppearance;
    if (publish && state.isActive) _publishLatest();
    if (publish &&
        (state.isActive || state.status == LiveOverlayStatus.starting)) {
      _scheduleArtworkResolution();
    }
  }

  void _scheduleArtworkResolution() {
    for (final entry in _latestQueue) {
      final source = entry.artworkSource;
      if (source == null ||
          source.isEmpty ||
          _resolvedArtwork.containsKey(source) ||
          !_loadingArtwork.add(source)) {
        continue;
      }
      unawaited(_resolveArtwork(source));
    }
  }

  Future<void> _resolveArtwork(String source) async {
    String? dataUri;
    try {
      dataUri = await _artworkLoader(source);
    } catch (_) {
      // Metadata and the server remain usable when a cover is unavailable.
    }
    _loadingArtwork.remove(source);
    if (_disposed) return;
    _resolvedArtwork[source] = dataUri;
    _rebuildQueue();
  }

  void _publishLatest() {
    try {
      final appearance = _latestAppearance.toJson();
      _client.publishJson(<String, Object>{
        'type': 'state',
        'version': 1,
        'locale': _strings.appLanguage.code,
        'labels': <String, String>{
          'resolving': _strings.liveOverlayResolving,
          'downloading': _strings.liveOverlayLoading,
          'untitled': _strings.noTitle,
        },
        ...appearance,
        'items': <Map<String, Object>>[
          for (final item in _latestQueue) item.toJson(),
        ],
      });
    } catch (error, stackTrace) {
      if (!state.isActive) return;
      state = LiveOverlaySnapshot(
        status: LiveOverlayStatus.active,
        url: state.url,
        error: _messageFor(error, stackTrace),
      );
    }
  }

  LiveOverlayAppearance _currentAppearance() {
    var durationMilliseconds = _currentLiveItemId == null
        ? 0
        : _playback?.duration?.inMilliseconds ?? 0;
    var positionMilliseconds = _currentLiveItemId == null
        ? 0
        : _playback?.position.inMilliseconds ?? 0;
    if (durationMilliseconds < 0) durationMilliseconds = 0;
    if (positionMilliseconds < 0) positionMilliseconds = 0;
    if (durationMilliseconds > 0 &&
        positionMilliseconds > durationMilliseconds) {
      positionMilliseconds = durationMilliseconds;
    }
    final progress = durationMilliseconds <= 0 || _currentLiveItemId == null
        ? 0
        : ((positionMilliseconds.clamp(0, durationMilliseconds) * 1000) /
                  durationMilliseconds)
              .round()
              .clamp(0, 1000);
    return LiveOverlayAppearance(
      accentSeedArgb: _accent.seedColor.toARGB32(),
      accentDarkArgb: _accent.darkColor.toARGB32(),
      playbackProgressPermille: progress,
      playbackPositionMilliseconds: positionMilliseconds,
      playbackDurationMilliseconds: durationMilliseconds,
    );
  }

  String _messageFor(Object error, StackTrace stackTrace) {
    if (kDebugMode) {
      debugPrint('Local LIVE overlay operation failed: $error\n$stackTrace');
    }

    final causes = _liveOverlayErrorChain(error).toList(growable: false);
    if (causes.any((cause) => cause is UnsupportedError)) {
      return _strings.liveOverlayUnsupported;
    }
    if (causes.any(
      (cause) => cause is LocalOverlayHostsCommandTimeoutException,
    )) {
      return _strings.liveOverlayWindowsRequestTimeoutError;
    }
    if (causes.any(
      (cause) => cause is LocalOverlayHostsElevationCancelledException,
    )) {
      return _strings.liveOverlayPermissionCancelledError;
    }
    if (causes.any((cause) => cause is LocalOverlayHostsPolicyException)) {
      return _strings.liveOverlayPolicyBlockedError;
    }
    if (causes.any(
      (cause) => cause is LocalOverlayHostsPowerShellUnavailableException,
    )) {
      return _strings.liveOverlayPowerShellUnavailableError;
    }
    if (causes.any(
      (cause) =>
          cause is LocalOverlayHostsElevationException ||
          cause is ProcessException,
    )) {
      return _strings.liveOverlayPermissionError;
    }
    if (causes.any((cause) => cause is LocalOverlayHostsConflictException)) {
      return _strings.liveOverlayHostsConflictError(localLiveOverlayHost);
    }
    if (causes.any(
      (cause) => cause is LocalOverlayHostsVerificationException,
    )) {
      return _strings.liveOverlayHostsVerificationError;
    }
    if (causes.any((cause) => cause is LocalLiveOverlayVerificationException)) {
      return _strings.liveOverlayEndpointVerificationError;
    }
    if (causes.any((cause) => cause is LocalLiveOverlayPortInUseException)) {
      return _strings.liveOverlayPortInUseError;
    }
    if (causes.any((cause) => cause is LocalLiveOverlayPortAccessException)) {
      return _strings.liveOverlayPortAccessError;
    }
    if (causes.any(_isUnavailableLiveOverlayPort)) {
      return _strings.liveOverlayPortUnavailableError;
    }
    if (causes.any((cause) => cause is LocalOverlayHostsException) ||
        error is LocalLiveOverlayServerException) {
      return _strings.liveOverlayError;
    }

    final message = error.toString().replaceFirst(
      RegExp(r'^[A-Za-z]+(?:Exception|Error):\s*'),
      '',
    );
    return message.trim().isEmpty ? _strings.liveOverlayError : message.trim();
  }
}

Iterable<Object> _liveOverlayErrorChain(Object error) sync* {
  final visited = <Object>{};
  Object? current = error;
  while (current != null && visited.add(current)) {
    yield current;
    if (current is LocalLiveOverlayServerException) {
      current = current.cause;
    } else if (current is LocalOverlayHostsException) {
      current = current.cause;
    } else {
      current = null;
    }
  }
}

bool _isUnavailableLiveOverlayPort(Object error) {
  if (error is! SocketException) return false;
  return error.osError?.errorCode == 10048 || error.osError?.errorCode == 10013;
}

class LiveOverlayQueueSelection {
  const LiveOverlayQueueSelection({required this.entries, this.currentItemId});

  final List<LiveOverlayQueueEntry> entries;
  final String? currentItemId;
}

LiveOverlayQueueSelection selectLiveOverlayQueue(
  Iterable<LiveQueueItem> queue, {
  PlayerSnapshot? playback,
  bool isLiveQueueActive = false,
  String? previousCurrentItemId,
}) {
  final items = queue.toList(growable: false);
  var startIndex = 0;
  String? currentItemId;

  if (isLiveQueueActive && playback != null) {
    final playingIndex = items.indexWhere(
      (item) =>
          item.status != LiveQueueItemStatus.failed &&
          _snapshotMatchesLiveItem(playback, item),
    );
    if (playingIndex >= 0) {
      startIndex = playingIndex;
      currentItemId = items[playingIndex].id;
    }
  }

  if (currentItemId == null && previousCurrentItemId != null) {
    final previousIndex = items.indexWhere(
      (item) => item.id == previousCurrentItemId,
    );
    if (previousIndex >= 0) {
      startIndex = previousIndex;
      currentItemId = previousCurrentItemId;
    }
  }

  final entries = List<LiveOverlayQueueEntry>.unmodifiable(
    items
        .skip(startIndex)
        .where((item) => item.status != LiveQueueItemStatus.failed)
        .take(liveOverlayMaximumItems)
        .map((item) {
          final local = item.localTrack;
          final remote = item.remoteTrack;
          final artwork =
              local?.thumbnailPath ??
              local?.thumbnailUrl ??
              local?.catalogThumbnailUrl ??
              remote?.thumbnailUrl ??
              remote?.catalogThumbnailUrl;
          return LiveOverlayQueueEntry(
            id: item.id,
            title: item.displayTitle,
            artist: local?.artist ?? remote?.artist ?? '',
            status: isLiveQueueActive && item.id == currentItemId
                ? 'playing'
                : item.status.name,
            artworkSource: artwork?.trim().isEmpty ?? true
                ? null
                : artwork!.trim(),
          );
        }),
  );
  return LiveOverlayQueueSelection(
    entries: entries,
    currentItemId: currentItemId,
  );
}

bool _snapshotMatchesLiveItem(PlayerSnapshot snapshot, LiveQueueItem item) {
  final local = item.localTrack;
  if (item.saveToLibrary && local != null) {
    return snapshot.trackId == local.id ||
        (!snapshot.isRemote && snapshot.sourceUrl == local.filePath);
  }

  final remote = item.remoteTrack;
  if (remote == null) return false;
  final trackId = remote.id.trim();
  if (trackId.isNotEmpty && snapshot.trackId == trackId) return true;
  final sourceUrl = snapshot.sourceUrl?.trim();
  return sourceUrl != null &&
      sourceUrl.isNotEmpty &&
      (sourceUrl == remote.url || sourceUrl == remote.streamUrl);
}

bool _sameQueue(
  List<LiveOverlayQueueEntry> first,
  List<LiveOverlayQueueEntry> second,
) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
