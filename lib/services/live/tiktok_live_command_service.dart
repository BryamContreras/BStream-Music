import 'tiktok_live_dart_adapter.dart';
import 'tiktok_live_models.dart';

export 'tiktok_live_models.dart';

/// Receives TikTok LIVE chat directly through a Dart WebSocket client.
///
/// This keeps the public contract used by the controller stable while removing
/// the Python subprocess, virtual environment, and newline-delimited JSON IPC.
class TikTokLiveCommandService {
  TikTokLiveCommandService({TikTokLiveDartAdapter? adapter})
    : _adapter = adapter ?? TikTokLiveDartAdapter();

  final TikTokLiveDartAdapter _adapter;

  Stream<TikTokLiveEvent> get events => _adapter.events;

  bool get isRunning => _adapter.isRunning;

  Future<void> connect(String rawUser) => _adapter.connect(rawUser);

  Future<void> disconnect() => _adapter.disconnect();

  Future<void> dispose() => _adapter.dispose();
}
