import 'package:media_kit/media_kit.dart';

import 'player_equalizer.dart';

/// One native filter owns the complete curve. Labelled
/// replacement leaves filters installed by other playback features untouched.
class MediaKitEqualizerFilter {
  static const label = 'bstream-eq';

  static String? graph(EqualizerSettings settings) {
    final curve = settings.normalized;
    if (!curve.enabled || curve.isFlat) return null;
    return [
      for (var index = 0; index < equalizerBandFrequencies.length; index++)
        if (curve.gainsDb[index].abs() >= .01)
          'equalizer=f=${equalizerBandFrequencies[index].toInt()}'
              ':t=q:w=1:g=${curve.gainsDb[index].toStringAsFixed(3)}:r=f64',
    ].join(',');
  }

  static bool containsFilter(String filters) =>
      RegExp(r'(^|,)\s*@bstream-eq:').hasMatch(filters);

  static Future<void> apply(
    NativePlayer player,
    EqualizerSettings settings,
  ) async {
    final filterGraph = graph(settings);
    final before = await player.getProperty('af');
    if (filterGraph == null) {
      if (!containsFilter(before)) return;
      await player.command(['af', 'remove', '@$label']);
      if (containsFilter(await player.getProperty('af'))) {
        throw StateError('The player did not bypass the equalizer.');
      }
      return;
    }

    // mpv's af add replaces an existing filter with the same label atomically.
    // Brackets quote the commas of the FFmpeg graph for mpv's list parser.
    await player.command(['af', 'add', '@$label:lavfi=[$filterGraph]']);
    final after = await player.getProperty('af');
    // media_kit's native commands log certain mpv failures without throwing.
    // Read back the graph as well as the label to detect a rejected update.
    if (!containsFilter(after) || !after.contains(filterGraph)) {
      // A missing optional filter must never interrupt the song. Remove only
      // our previous curve, leaving other filters and the source intact.
      if (containsFilter(after)) {
        await player.command(['af', 'remove', '@$label']);
      }
      throw StateError('The player did not accept the equalizer curve.');
    }
  }
}
