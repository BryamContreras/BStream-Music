import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/track_selection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const first = TrackInfo(id: 'one', title: 'One', artist: '', url: 'url-one');
  const second = TrackInfo(id: 'two', title: 'Two', artist: '', url: 'url-two');

  test(
    'selection keeps display order, removes duplicates and can be cleared',
    () {
      final selection = TrackSelectionController();
      addTearDown(selection.dispose);
      selection.select(second);
      selection.select(first);
      selection.select(second);
      expect(selection.count, 2);
      expect(selection.selectedTracks([first, second, first]), [first, second]);
      selection.toggle(first);
      expect(selection.selectedTracks([first, second]), [second]);
      expect(selection.clear(), isTrue);
      expect(selection.clear(), isFalse);
    },
  );

  test(
    'busy blocks selection edits and is safe to finish after screen disposal',
    () {
      final selection = TrackSelectionController()..select(first);
      selection.setBusy(true);
      selection.select(second);
      selection.toggle(first);
      expect(selection.selectedTracks([first, second]), [first]);
      selection.dispose();
      expect(() => selection.setBusy(false), returnsNormally);
      expect(() => selection.clear(), returnsNormally);
    },
  );

  test('new result pages retain only tracks that still exist', () {
    final selection = TrackSelectionController()
      ..select(first)
      ..select(second);
    addTearDown(selection.dispose);
    selection.retainTracks([second]);
    expect(selection.count, 1);
    expect(selection.selectedTracks([first, second]), [second]);
  });
}
