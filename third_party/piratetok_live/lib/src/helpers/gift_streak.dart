/// Gift streak tracker — computes per-event deltas from TikTok's running totals.
///
/// TikTok combo gifts fire multiple events during a streak, each carrying a
/// running total in `repeatCount` (2, 4, 7, 7). This helper tracks active
/// streaks by `groupId` and computes the delta per event.
class GiftStreakEvent {
  final int streakId;
  final bool isActive;
  final bool isFinal;
  final int eventGiftCount;
  final int totalGiftCount;
  final int eventDiamondCount;
  final int totalDiamondCount;

  const GiftStreakEvent({
    required this.streakId,
    required this.isActive,
    required this.isFinal,
    required this.eventGiftCount,
    required this.totalGiftCount,
    required this.eventDiamondCount,
    required this.totalDiamondCount,
  });
}

class _StreakEntry {
  final int lastRepeatCount;
  final int lastSeenMs;
  _StreakEntry(this.lastRepeatCount, this.lastSeenMs);
}

class GiftStreakTracker {
  static const _staleMs = 60000;

  final Map<int, _StreakEntry> _streaks = {};

  /// Process a raw gift event map and return enriched streak data with deltas.
  GiftStreakEvent process(Map<String, dynamic> data) {
    final groupId = _intVal(data, 'groupId');
    final repeatCount = _intVal(data, 'repeatCount');
    final repeatEnd = _intVal(data, 'repeatEnd');

    final gift = (data['gift'] as Map<String, dynamic>?) ?? {};
    final giftType = _intVal(gift, 'type');
    final diamondPer = _intVal(gift, 'diamondCount');

    final isCombo = giftType == 1;
    final isFinal = repeatEnd == 1;

    if (!isCombo) {
      return GiftStreakEvent(
        streakId: groupId,
        isActive: false,
        isFinal: true,
        eventGiftCount: 1,
        totalGiftCount: 1,
        eventDiamondCount: diamondPer,
        totalDiamondCount: diamondPer,
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    _evictStale(now);

    var prevCount = 0;
    final prev = _streaks[groupId];
    if (prev != null) prevCount = prev.lastRepeatCount;

    var delta = repeatCount - prevCount;
    if (delta < 0) delta = 0;

    if (isFinal) {
      _streaks.remove(groupId);
    } else {
      _streaks[groupId] = _StreakEntry(repeatCount, now);
    }

    final rc = repeatCount > 0 ? repeatCount : 1;

    return GiftStreakEvent(
      streakId: groupId,
      isActive: !isFinal,
      isFinal: isFinal,
      eventGiftCount: delta,
      totalGiftCount: repeatCount,
      eventDiamondCount: diamondPer * delta,
      totalDiamondCount: diamondPer * rc,
    );
  }

  /// Number of currently active (non-finalized) streaks.
  int get activeStreaks => _streaks.length;

  /// Clear all tracked state. For reconnect scenarios.
  void reset() => _streaks.clear();

  void _evictStale(int nowMs) {
    _streaks.removeWhere((_, e) => nowMs - e.lastSeenMs >= _staleMs);
  }

  static int _intVal(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is int) return v;
    return 0;
  }
}
