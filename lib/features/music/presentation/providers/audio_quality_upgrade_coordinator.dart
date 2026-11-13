part of 'music_providers.dart';

extension _PlayerAudioQualityUpgrade on PlayerController {
  void _maybeStartAudioQualityUpgrade(PlayerSnapshot snapshot) {
    var track = _playingRemoteTrack;
    final entryId = _currentRemoteQueueEntryId;
    final prepared = _preparedRemoteAudioSources[entryId];
    if (track != null &&
        prepared?.uri.scheme == 'file' &&
        prepared!.track.url == track.url) {
      track = prepared.track;
    }
    if (_disposed ||
        _userPaused ||
        !_playWhenReady ||
        !snapshot.isRemote ||
        snapshot.status != PlayerStatus.playing ||
        track == null ||
        entryId == null ||
        !_snapshotBelongsToTrack(snapshot, track) ||
        _audioUpgradeUnnecessary(track) ||
        track.streamSource == AudioStreamSource.jioSaavn.name ||
        _audioSourceRef.read(playerServiceProvider)
            is! AudioSourceUpgradePlayer) {
      return;
    }
    final policy = _audioSourceRef.read(audioSourcePolicyProvider);
    if (!policy.jioSaavnEnabled ||
        (policy.wifiAudioQuality == AudioQualityProfile.standard &&
            (policy.useSingleProfile ||
                policy.mobileAudioQuality == AudioQualityProfile.standard))) {
      return;
    }
    final requestId = _playRequestId;
    final pending = _audioQualityUpgradeJob;
    if (pending?.entryId == entryId && pending?.requestId == requestId) return;
    final monitor = policy.useSingleProfile
        ? null
        : _audioSourceRef.read(audioNetworkMonitorProvider);
    final knownNetwork = monitor?.lastKnownKind ?? AudioNetworkKind.unknown;
    final recordingKey = _audioUpgradeRecordingKey(track);
    final selection = '$entryId:$requestId:${policy.cacheKey}:$recordingKey';
    if (_audioQualityNetworkRetrySelection != selection) {
      _audioQualityNetworkRetrySelection = selection;
      _audioQualityNetworkRetryCount = 0;
    }
    final retryableNetwork =
        !policy.useSingleProfile &&
        (knownNetwork == AudioNetworkKind.unknown ||
            knownNetwork == AudioNetworkKind.offline);
    if (!retryableNetwork) _audioQualityNetworkRetryCount = 0;
    final key =
        '$entryId:$requestId:${policy.cacheKey}:${knownNetwork.name}:'
        '$recordingKey';
    if (_lastAudioQualityUpgradeKey == key) {
      if (!retryableNetwork ||
          _audioQualityNetworkRetryCount >= 2 ||
          monitor?.canRefreshAfter(
                Duration(seconds: _audioQualityNetworkRetryCount == 0 ? 3 : 8),
              ) !=
              true) {
        return;
      }
      _audioQualityNetworkRetryCount++;
    }
    _lastAudioQualityUpgradeKey = key;
    final token = Object();
    _audioQualityUpgradeJob = (
      token: token,
      entryId: entryId,
      requestId: requestId,
    );
    unawaited(_improveAudioQuality(track, entryId, requestId, token));
  }

  Future<void> _improveAudioQuality(
    TrackInfo original,
    String entryId,
    int requestId,
    Object token,
  ) async {
    final monitor =
        _audioSourceRef.read(audioSourcePolicyProvider).useSingleProfile
        ? null
        : _audioSourceRef.read(audioNetworkMonitorProvider);
    final seekGeneration = _seekRequestId;
    final recordingKey = _audioUpgradeRecordingKey(original);
    bool selected() =>
        !_disposed &&
        identical(_audioQualityUpgradeJob?.token, token) &&
        !_userPaused &&
        !_explicitlyStopped &&
        _playWhenReady &&
        _seekRequestId == seekGeneration &&
        _isCurrentPlayRequest(requestId) &&
        _audioUpgradeRecordingKey(_playingRemoteTrack) == recordingKey &&
        _currentRemoteQueueEntryId == entryId;
    bool allowed() =>
        selected() &&
        _audioSourceRef
            .read(audioSourcePolicyProvider)
            .allowsUpgrade(monitor?.lastKnownKind ?? AudioNetworkKind.unknown);
    var announced = false;
    try {
      final network = await monitor?.current() ?? AudioNetworkKind.unknown;
      if (!selected()) return;
      final policy = _audioSourceRef.read(audioSourcePolicyProvider);
      _lastAudioQualityUpgradeKey =
          '$entryId:$requestId:${policy.cacheKey}:${network.name}:$recordingKey';
      if (!policy.allowsUpgrade(network)) return;
      final localUri = Uri.tryParse(original.streamUrl ?? '');
      final savedFormat = localUri?.scheme == 'file'
          ? (await _libraryDownloadFor(original))?.audioFormat
          : null;
      if (!allowed()) return;
      if (localUri?.scheme == 'file' &&
          savedFormat == null &&
          original.streamBitrate == null) {
        // Older downloads have no saved technical format. Share the bounded
        // header cache with the UI, after audio has already started playing.
        final format = await _audioSourceRef
            .read(localPlaybackAudioQualityServiceProvider)
            .read(localUri!.toFilePath());
        if (!allowed()) return;
        if (format != null) {
          original = original.copyWith(
            streamCodec: format.codec,
            streamMimeType: format.mimeType,
            streamBitrate: format.bitrate,
            streamSampleRate: format.sampleRate,
            streamChannels: format.channels,
          );
          _replaceCurrentRemoteTrack(original);
          _rememberPreparedAudioSource(
            RemotePlaybackSource(
              track: original,
              uri: localUri,
              queueEntryId: entryId,
              isOnlyLogicalQueueItem: _queue.length == 1,
            ),
          );
          _publishAudioSourceSnapshot(
            _audioSourceRef.read(playerServiceProvider).currentSnapshot,
          );
          if (_audioUpgradeUnnecessary(original)) return;
        }
      }
      _audioSourceRef
          .read(audioQualityUpgradeStateProvider.notifier)
          .begin(entryId);
      announced = true;
      final candidate =
          await _audioSourceRef.read(audioSourceUpgradeLookupProvider)(
            original,
            currentBitrate: original.streamBitrate,
            shouldContinue: allowed,
          );
      if (!allowed() ||
          candidate == null ||
          !candidate.isUsable ||
          (candidate.bitrate ?? 0) <= (original.streamBitrate ?? 0)) {
        return;
      }
      final improved = _mergeTrackInfo(
        original,
        TrackInfo(
          id: '',
          title: '',
          artist: '',
          url: '',
          streamUrl: candidate.streamUrl,
          streamExtension: candidate.streamExtension,
          streamMimeType: candidate.streamMimeType,
          streamSource: candidate.source.name,
          streamFormatId: candidate.formatId,
          streamCodec: candidate.codec,
          streamBitrate: candidate.bitrate,
          streamSampleRate: candidate.sampleRate,
          streamChannels: candidate.channels,
          streamClientProfileKey: '',
          httpHeaders: candidate.httpHeaders ?? const {},
        ),
      );
      _remotePrefetch.invalidate();
      await _scheduleCrossfadePreparation(null);
      await _remotePrefetch.waitForServiceMutations();
      if (!allowed()) return;
      final service = _audioSourceRef.read(playerServiceProvider);
      if (service is! AudioSourceUpgradePlayer) return;
      final source = _networkRemotePlaybackSource(improved);
      final promoted = await (service as AudioSourceUpgradePlayer)
          .upgradeRemoteSource(source, shouldContinue: allowed);
      if (!promoted || !selected()) return;
      _replaceCurrentRemoteTrack(improved);
      _rememberPreparedAudioSource(source);
      // Force the format-selective consumer to see the new transport even if
      // the native position has not ticked since deck promotion.
      _publishAudioSourceSnapshot(service.currentSnapshot);
    } catch (error) {
      // The original source remains audible on a missed/failed improvement.
      debugPrint(
        'Optional audio quality upgrade unavailable: ${error.runtimeType}',
      );
    } finally {
      if (!_disposed && announced) {
        _audioSourceRef
            .read(audioQualityUpgradeStateProvider.notifier)
            .finish(entryId);
      }
      if (identical(_audioQualityUpgradeJob?.token, token)) {
        if (!selected()) _lastAudioQualityUpgradeKey = null;
        _audioQualityUpgradeJob = null;
        if (announced &&
            !_disposed &&
            _isCurrentPlayRequest(requestId) &&
            _currentRemoteQueueEntryId == entryId &&
            _playWhenReady &&
            !_userPaused) {
          _remotePrefetch.invalidate();
          unawaited(_warmUpcomingRemoteTracks(requestId));
        }
      }
    }
  }
}

bool _audioUpgradeUnnecessary(TrackInfo track) =>
    (track.streamBitrate ?? 0) >= 256000 ||
    AudioFormatDetails(
      codec: track.streamCodec,
      mimeType: track.streamMimeType,
    ).isLossless;

String _audioUpgradeRecordingKey(TrackInfo? track) => track == null
    ? ''
    : jsonEncode([
        track.title,
        track.artist,
        track.album,
        track.duration?.inSeconds,
      ]);
