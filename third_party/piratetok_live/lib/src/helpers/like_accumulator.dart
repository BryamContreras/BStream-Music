/// Like accumulator — monotonizes TikTok's inconsistent total_like_count.
///
/// TikTok's `total` field on like events arrives from different server shards
/// with stale values, causing backwards jumps. The `count` field (per-event
/// delta) is reliable.
class LikeStats {
  final int eventLikeCount;
  final int totalLikeCount;
  final int accumulatedCount;
  final bool wentBackwards;

  const LikeStats({
    required this.eventLikeCount,
    required this.totalLikeCount,
    required this.accumulatedCount,
    required this.wentBackwards,
  });
}

class LikeAccumulator {
  int _maxTotal = 0;
  int _accumulated = 0;

  /// Process a raw like event map and return monotonized stats.
  LikeStats process(Map<String, dynamic> data) {
    final count = _intVal(data, 'count');
    final total = _intVal(data, 'total');

    _accumulated += count;
    final wentBackwards = total < _maxTotal;
    if (total > _maxTotal) _maxTotal = total;

    return LikeStats(
      eventLikeCount: count,
      totalLikeCount: _maxTotal,
      accumulatedCount: _accumulated,
      wentBackwards: wentBackwards,
    );
  }

  /// Clear state. For reconnect.
  void reset() {
    _maxTotal = 0;
    _accumulated = 0;
  }

  static int _intVal(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is int) return v;
    return 0;
  }
}
