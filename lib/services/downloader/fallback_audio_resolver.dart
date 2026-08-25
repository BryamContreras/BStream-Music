import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/music/domain/entities/track_info.dart';
import 'audio_stream_resolver.dart';

/// Chains one or more [AudioStreamResolver]s and surfaces the first usable
/// result.
class FallbackAudioResolver
    implements AudioStreamResolver, FallbackAwareAudioStreamResolver {
  FallbackAudioResolver(this._resolvers);

  final List<AudioStreamResolver> _resolvers;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) {
    return resolveWithMode(track);
  }

  @override
  Future<AudioStreamResolution> resolveWithMode(
    TrackInfo track, {
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    AudioResolverFailureCallback? onResolverFailure,
    AudioResolverContinuationCallback? shouldContinue,
  }) async {
    if (_resolvers.isEmpty) {
      throw const AudioStreamResolverException(
        'No audio stream resolver is registered.',
      );
    }
    final startIndex = mode == AudioResolutionMode.fallbackOnly ? 1 : 0;
    if (startIndex >= _resolvers.length) {
      throw const AudioStreamResolverException(
        'No fallback audio stream resolver is registered.',
      );
    }

    Object? lastError;
    for (var index = startIndex; index < _resolvers.length; index++) {
      _ensureActive(shouldContinue);
      final resolver = _resolvers[index];
      try {
        final result = resolver is ContinuationAwareAudioStreamResolver
            ? await (resolver as ContinuationAwareAudioStreamResolver)
                  .resolveWhileCurrent(track, shouldContinue: shouldContinue)
            : await resolver.resolve(track);
        _ensureActive(shouldContinue);
        if (result.isUsable) {
          return result;
        }
        lastError = AudioStreamResolverException(
          'Resolver ${resolver.runtimeType} returned an empty stream.',
        );
      } catch (error) {
        lastError = error;
      }
      if (index + 1 < _resolvers.length) {
        onResolverFailure?.call(_sourceForIndex(index), lastError);
      }
    }
    throw AudioStreamResolverException(
      'All audio stream resolvers failed.',
      cause: lastError,
    );
  }

  void _ensureActive(AudioResolverContinuationCallback? shouldContinue) {
    if (shouldContinue != null && !shouldContinue()) {
      throw const AudioStreamResolverException(
        'Audio stream resolution was superseded.',
      );
    }
  }

  AudioStreamSource _sourceForIndex(int index) {
    return index == 0
        ? AudioStreamSource.youtubeExplode
        : AudioStreamSource.ytDlp;
  }

  @override
  Future<void> dispose() async {
    for (final resolver in _resolvers) {
      try {
        await resolver.dispose();
      } catch (error, stackTrace) {
        debugPrint(
          'AudioStreamResolver ${resolver.runtimeType} failed to dispose: '
          '$error\n$stackTrace',
        );
      }
    }
  }
}

/// Helper that decides where to start the chain given the last known source.
///
/// Returning a list starting from the desired provider lets the caller keep
/// the rest of the chain intact.
List<AudioStreamResolver> startingFrom(
  AudioStreamSource source,
  List<AudioStreamResolver> resolvers,
) {
  if (source == AudioStreamSource.youtubeExplode) {
    return resolvers;
  }
  return resolvers.skip(1).toList(growable: false);
}

/// Wraps a primary resolver and its fallbacks behind one application contract.
AudioStreamResolver withFallbacks({
  required AudioStreamResolver primary,
  required List<AudioStreamResolver> others,
}) {
  return FallbackAudioResolver([primary, ...others]);
}
