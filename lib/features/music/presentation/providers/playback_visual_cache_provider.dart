import 'package:flutter_riverpod/legacy.dart';

import '../../../../services/player/playback_visual_cache.dart';

final playbackVisualCacheProvider = ChangeNotifierProvider<PlaybackVisualCache>(
  (ref) {
    return PlaybackVisualCache();
  },
);
