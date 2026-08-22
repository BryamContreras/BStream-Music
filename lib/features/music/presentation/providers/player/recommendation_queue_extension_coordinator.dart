import 'recommendation_playback_item.dart';

/// Owns continuation lifetime and coalescing for a recommendation queue.
///
/// Queue reconciliation remains a controller concern; this component only
/// admits a continuation result while the same source/generation is active.
class RecommendationQueueExtensionCoordinator {
  RecommendationQueueExtender? _extender;
  String? _sourceId;
  Future<bool>? _inFlight;
  bool _exhausted = false;
  int _generation = 0;

  String? get sourceId => _sourceId;

  void configure({
    required String sourceId,
    required RecommendationQueueExtender extender,
  }) {
    _generation++;
    _sourceId = sourceId;
    _extender = extender;
    _inFlight = null;
    _exhausted = false;
  }

  void clear() {
    _generation++;
    _sourceId = null;
    _extender = null;
    _inFlight = null;
    _exhausted = false;
  }

  void invalidate() {
    _generation++;
  }

  Future<bool> maybeExtend({
    required bool sourceIsActive,
    required bool atQueueEnd,
    required int remaining,
    required int threshold,
    required int Function() currentLength,
    required bool Function() isDisposed,
    required Future<bool> Function(
      String sourceId,
      List<RecommendationPlaybackItem> items,
    )
    synchronize,
    required void Function(Object error) onError,
  }) {
    final active = _inFlight;
    if (active != null) {
      return active;
    }
    final extender = _extender;
    final sourceId = _sourceId;
    if (extender == null ||
        sourceId == null ||
        _exhausted ||
        !sourceIsActive ||
        (!atQueueEnd && remaining > threshold)) {
      return Future<bool>.value(false);
    }

    final generation = _generation;
    final previousLength = currentLength();
    late final Future<bool> operation;
    operation = () async {
      try {
        final expanded = await extender();
        if (isDisposed() ||
            generation != _generation ||
            _sourceId != sourceId) {
          return false;
        }
        final lengthBeforeSync = currentLength();
        if (expanded.length <= lengthBeforeSync) {
          if (lengthBeforeSync == previousLength) {
            _exhausted = true;
          }
          return false;
        }
        final didSync = await synchronize(sourceId, expanded);
        if (!didSync || currentLength() <= previousLength) {
          _exhausted = true;
          return false;
        }
        return true;
      } catch (error) {
        onError(error);
        return false;
      }
    }();
    _inFlight = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight, operation)) {
        _inFlight = null;
      }
    });
  }
}
