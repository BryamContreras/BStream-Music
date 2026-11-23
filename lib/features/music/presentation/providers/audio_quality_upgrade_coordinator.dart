part of 'music_providers.dart';

extension _PlayerAudioQualityUpgrade on PlayerController {
  void _maybeStartAudioQualityUpgrade(
    PlayerSnapshot snapshot,
    PlayerSnapshot playbackSnapshot,
  ) {
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
        _audioSourceRef.read(playerServiceProvider)
            is! AudioSourceUpgradePlayer) {
      return;
    }
    final policy = _audioSourceRef.read(audioSourcePolicyProvider);
    if (_audioUpgradeUnnecessary(track, policy.canUseAnyExtension) ||
        (!policy.allowsUpgrade(AudioNetworkKind.wifi) &&
            (policy.useSingleProfile ||
                !policy.allowsUpgrade(AudioNetworkKind.mobile)))) {
      return;
    }
    var recordingDuration = track.duration;
    if (recordingDuration == null || recordingDuration <= Duration.zero) {
      // The catalog can omit runtime. Use the loaded source's duration after
      // checking its identity before UI decoration substitutes catalog fields.
      if ((playbackSnapshot.queueEntryId != null &&
              playbackSnapshot.queueEntryId != entryId) ||
          !(_snapshotBelongsToTrack(playbackSnapshot, track) ||
              _isCachedRemoteSnapshot(playbackSnapshot, track))) {
        return;
      }
      recordingDuration = playbackSnapshot.duration;
      if (recordingDuration == null || recordingDuration <= Duration.zero) {
        return;
      }
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
    unawaited(
      _improveAudioQuality(track, entryId, requestId, token, recordingDuration),
    );
  }

  Future<void> _improveAudioQuality(
    TrackInfo original,
    String entryId,
    int requestId,
    Object token,
    Duration recordingDuration,
  ) async {
    final initialPolicy = _audioSourceRef.read(audioSourcePolicyProvider);
    final monitor = initialPolicy.useSingleProfile
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
    var announced = false;
    try {
      final network = await monitor?.current() ?? AudioNetworkKind.unknown;
      if (!selected()) return;
      final policy = _audioSourceRef.read(audioSourcePolicyProvider);
      if (policy.cacheKey != initialPolicy.cacheKey) return;
      _lastAudioQualityUpgradeKey =
          '$entryId:$requestId:${policy.cacheKey}:${network.name}:$recordingKey';
      if (!policy.allowsUpgrade(network)) return;
      final canUseExtension = policy.canUseExtensions(network);
      if (_audioUpgradeUnnecessary(original, canUseExtension)) return;
      bool allowed() =>
          selected() &&
          (monitor?.lastKnownKind ?? AudioNetworkKind.unknown) == network &&
          _audioSourceRef.read(audioSourcePolicyProvider).cacheKey ==
              policy.cacheKey;

      final localUri = Uri.tryParse(original.streamUrl ?? '');
      final savedFormat = localUri?.scheme == 'file'
          ? (await _libraryDownloadFor(original))?.audioFormat
          : null;
      if (!allowed()) return;
      if (localUri?.scheme == 'file' &&
          savedFormat == null &&
          (original.streamBitrate == null ||
              (canUseExtension && original.streamCodec == null))) {
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
            streamBitDepth: format.bitDepth,
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
          if (_audioUpgradeUnnecessary(original, canUseExtension)) {
            return;
          }
        }
      }
      _audioSourceRef
          .read(audioQualityUpgradeStateProvider.notifier)
          .begin(entryId);
      announced = true;
      final candidate =
          await _audioSourceRef.read(audioSourceUpgradeLookupProvider)(
            original.duration == recordingDuration
                ? original
                : original.copyWith(duration: recordingDuration),
            currentBitrate: original.streamBitrate,
            sourcePreference: policy.sourcePreferenceFor(network),
            shouldContinue: allowed,
          );
      if (!allowed() ||
          candidate == null ||
          !candidate.isUsable ||
          !candidate.improvesOn(original.streamBitrate)) {
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
          streamBitDepth: candidate.bitDepth,
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

bool _audioUpgradeUnnecessary(TrackInfo track, bool canUseLosslessExtension) =>
    (!canUseLosslessExtension &&
        ((track.streamBitrate ?? 0) >= 256000 ||
            track.streamSource == AudioStreamSource.jioSaavn.name)) ||
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
