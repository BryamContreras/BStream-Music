import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/app_update/release_notes_service.dart';

/// Translates on demand while the update dialog is open. Closing the dialog
/// cancels unfinished requests; successful translations remain on disk.
final appReleaseNotesServiceProvider =
    Provider.autoDispose<ReleaseNotesService>((ref) {
      final service = ReleaseNotesService();
      ref.onDispose(service.dispose);
      return service;
    });
