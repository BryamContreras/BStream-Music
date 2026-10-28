import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/sharing/lyrics_image_share_service.dart';
import '../../../../services/sharing/lyrics_share_photo_service.dart';

final lyricsImageShareServiceProvider = Provider<LyricsImageShareService>(
  (ref) => const DefaultLyricsImageShareService(),
);

final lyricsSharePhotoServiceProvider = Provider<LyricsSharePhotoService>(
  (ref) => const DefaultLyricsSharePhotoService(),
);
