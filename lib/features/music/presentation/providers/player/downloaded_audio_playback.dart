part of '../music_providers.dart';

/// A library download is the first transport for its catalog recording. Keeping
/// its catalog identity lets the existing second deck improve it in place.
extension _DownloadedAudioPlayback on PlayerController {
  _QueueItem _downloadQueueItem(LocalTrack local) {
    final catalog = _catalogTrackForDownload(local);
    if (catalog == null ||
        _audioSourceRef.read(playerServiceProvider)
            is! AudioSourceUpgradePlayer) {
      return _QueueItem.local(local);
    }
    final assigned = _remoteQueueEntries.newRemoteItem(catalog);
    return _QueueItem.hybrid(
      local: local,
      remote: catalog,
      remoteQueueEntryId: assigned.remoteQueueEntryId,
    );
  }

  TrackInfo? _catalogTrackForDownload(LocalTrack local) {
    if (local.isExternal) return null;
    final url = local.sourceUrl?.trim();
    final uri = Uri.tryParse(url ?? '');
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      return null;
    }
    return TrackInfo(
      id: local.sourceId?.trim().isNotEmpty == true
          ? local.sourceId!.trim()
          : PlaybackIdentity.canonicalYoutubeVideoId(url: url) ?? local.id,
      title: local.title,
      artist: local.artist,
      url: url!,
      thumbnailUrl: local.thumbnailPath ?? local.thumbnailUrl,
      catalogThumbnailUrl: local.catalogThumbnailUrl,
      duration: local.duration,
      album: local.album,
      artists: local.artists,
      artistBrowseIds: local.artistBrowseIds,
      metadataSource: local.metadataSource,
    );
  }

  Future<LocalTrack?> _libraryDownloadFor(TrackInfo track) async {
    bool matches(LocalTrack local) =>
        !local.isExternal &&
        (local.sourceUrl == track.url ||
            (local.sourceId?.isNotEmpty == true && local.sourceId == track.id));
    final selected = _queueIndex >= 0 && _queueIndex < _queue.length
        ? _queue[_queueIndex].local
        : null;
    if (selected != null && matches(selected)) return selected;
    try {
      final library = await _audioSourceRef.read(libraryTracksProvider.future);
      for (final local in library) {
        if (matches(local)) return local;
      }
    } catch (_) {
      // A library read failure must not prevent regular streaming.
    }
    return null;
  }

  TrackInfo _downloadedAudioTrack(
    TrackInfo catalog,
    LocalTrack local, [
    AudioFormatDetails? format,
  ]) {
    format ??= local.audioFormat;
    return catalog.withoutAudioTransport().copyWith(
      streamUrl: File(local.filePath).uri.toString(),
      streamExtension: p.extension(local.filePath).replaceFirst('.', ''),
      streamCodec: format?.codec,
      streamMimeType: format?.mimeType,
      streamBitrate: format?.bitrate,
      streamSampleRate: format?.sampleRate,
      streamChannels: format?.channels,
      streamBitDepth: format?.bitDepth,
    );
  }

  Future<TrackInfo?> _usableDownloadedAudioTrack(TrackInfo catalog) async {
    final local = await _libraryDownloadFor(catalog);
    if (local == null || !await probeUsableLocalAudio(local.filePath)) {
      return null;
    }
    return _downloadedAudioTrack(catalog, local);
  }

  Future<bool> _tryPlayLibraryDownload(
    TrackInfo catalog,
    int requestId,
    PlayerSnapshot pending, {
    Duration initialPosition = Duration.zero,
  }) async {
    final service = _audioSourceRef.read(playerServiceProvider);
    if (service is! AudioSourceUpgradePlayer) return false;
    final local = await _libraryDownloadFor(catalog);
    if (!_isCurrentPlayRequest(requestId)) return true;
    if (local == null || !await probeUsableLocalAudio(local.filePath)) {
      return false;
    }
    if (!_isCurrentPlayRequest(requestId)) return true;
    final track = _downloadedAudioTrack(catalog, local);
    final entryId = pending.queueEntryId ?? _remoteQueueEntryId(_queueIndex);
    final original = _queue[_queueIndex];
    final next = List<_QueueItem>.of(_queue);
    next[_queueIndex] = _QueueItem.hybrid(
      local: local,
      remote: track,
      logicalEntryId: original.logicalEntryId,
      remoteQueueEntryId: entryId,
    );
    _queue = List.unmodifiable(next);
    _useNativeLocalQueue = false;
    _publishPlaybackQueue();
    final source = RemotePlaybackSource(
      track: track,
      uri: File(local.filePath).uri,
      queueEntryId: entryId,
      isOnlyLogicalQueueItem: _queue.length == 1,
    );
    _rememberPreparedAudioSource(source);
    final attempt = _beginRemoteLoadAttempt();
    try {
      if (service is NativeRemoteQueuePlayer) {
        await (service as NativeRemoteQueuePlayer).playRemoteSource(
          source,
          initialPosition: initialPosition,
        );
      } else {
        await service.playRemote(track, initialPosition: initialPosition);
      }
      if (_wasRemoteLoadFailureHandled(attempt) ||
          !_isCurrentPlayRequest(requestId)) {
        return true;
      }
      if (!_cachedPlaybackActivated(service.currentSnapshot, track, entryId)) {
        throw const PlayerException('Downloaded source did not activate.');
      }
      _clearPendingRemoteSnapshot(requestId);
      unawaited(_warmUpcomingRemoteTracks(requestId));
      return true;
    } catch (_) {
      if (_wasRemoteLoadFailureHandled(attempt) ||
          !_isCurrentPlayRequest(requestId)) {
        return true;
      }
      // Keep the library file. A decoder/open failure can fall back online.
      _replaceCurrentRemoteTrack(catalog);
      _preparedRemoteAudioSources.remove(entryId);
      return false;
    } finally {
      _finishRemoteLoadAttempt(attempt);
    }
  }
}
