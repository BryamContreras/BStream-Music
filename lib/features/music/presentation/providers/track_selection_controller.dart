import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../domain/entities/track_info.dart';

const searchTrackSelectionScope = 'music-search';

final trackSelectionProvider = ChangeNotifierProvider.autoDispose
    .family<TrackSelectionController, Object>(
      (ref, scope) => TrackSelectionController(),
    );

String trackSelectionKey(TrackInfo track) =>
    track.id.trim().isEmpty ? track.url : track.id.trim();

/// Each screen owns its selection; tracks keep their original display order.
class TrackSelectionController extends ChangeNotifier {
  final _ids = <String>{};
  bool _busy = false;
  bool _disposed = false;

  bool get active => _ids.isNotEmpty;
  int get count => _ids.length;
  bool get busy => _busy;
  bool contains(TrackInfo track) => _ids.contains(trackSelectionKey(track));

  void select(TrackInfo track) {
    if (_busy || _disposed) return;
    if (_ids.add(trackSelectionKey(track))) notifyListeners();
  }

  void toggle(TrackInfo track) {
    if (_busy || _disposed) return;
    final id = trackSelectionKey(track);
    if (!_ids.remove(id)) _ids.add(id);
    notifyListeners();
  }

  bool clear() {
    if (_disposed || _ids.isEmpty) return false;
    _ids.clear();
    notifyListeners();
    return true;
  }

  void setBusy(bool busy) {
    if (_disposed || _busy == busy) return;
    _busy = busy;
    notifyListeners();
  }

  void retainTracks(Iterable<TrackInfo> tracks) {
    if (_disposed || !active) return;
    final available = tracks.map(trackSelectionKey).toSet();
    final countBefore = _ids.length;
    _ids.removeWhere((id) => !available.contains(id));
    if (_ids.length != countBefore) notifyListeners();
  }

  List<TrackInfo> selectedTracks(Iterable<TrackInfo> tracks) {
    final seen = <String>{};
    return [
      for (final track in tracks)
        if (contains(track) && seen.add(trackSelectionKey(track))) track,
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
