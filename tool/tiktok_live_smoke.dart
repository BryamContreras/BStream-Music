import 'dart:async';
import 'dart:io';

import 'package:bstream_music/services/live/tiktok_live_command_service.dart';

/// Manual end-to-end check for the direct Dart TikTok LIVE transport.
///
/// Usage: `dart run tool/tiktok_live_smoke.dart @creator [observe-seconds]`
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln(
      'Usage: dart run tool/tiktok_live_smoke.dart @creator '
      '[observe-seconds]',
    );
    exitCode = 64;
    return;
  }
  final observationSeconds = arguments.length == 2
      ? int.tryParse(arguments[1])
      : 5;
  if (observationSeconds == null ||
      observationSeconds < 0 ||
      observationSeconds > 300) {
    stderr.writeln('observe-seconds must be between 0 and 300.');
    exitCode = 64;
    return;
  }

  final service = TikTokLiveCommandService();
  final connected = Completer<bool>();
  late final StreamSubscription<TikTokLiveEvent> subscription;
  subscription = service.events.listen((event) {
    final status = event.status?.name ?? event.type;
    final room = event.roomId == null ? '' : ' room=${event.roomId}';
    stdout.writeln(
      '[$status]${event.message == null ? '' : ' ${event.message}'}$room',
    );
    final command = event.command;
    if (command != null) {
      stdout.writeln(
        '  command=${command.action} user=${command.user} '
        'moderator=${command.isModerator}',
      );
    }
    if (!connected.isCompleted) {
      if (event.status == TikTokLiveStatus.connected) {
        connected.complete(true);
      } else if (event.status == TikTokLiveStatus.error ||
          event.status == TikTokLiveStatus.liveEnded) {
        connected.complete(false);
      }
    }
  });

  try {
    await service.connect(arguments.first);
    final succeeded = await connected.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => false,
    );
    if (!succeeded) {
      stderr.writeln('TikTok LIVE smoke test did not establish a connection.');
      exitCode = 1;
      return;
    }
    // Keep reading briefly so protocol/traffic decode failures are visible.
    await Future<void>.delayed(Duration(seconds: observationSeconds));
  } finally {
    await service.dispose();
    await subscription.cancel();
  }
}
