import 'dart:async';

import 'package:youtube_explode_dart/js_challenge.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../platform_channels/android_ytdl_channel.dart';
import '../../desktop_tool_locator.dart';
import 'android_quickjs_ejs_solver.dart';
import 'android_web_po_token_provider.dart';
import 'youtube_audio_stream_selector.dart';

/// Owns the YouTube clients and the optional JavaScript challenge solver.
///
/// The no-solver client is created immediately on first use. The solver-backed
/// client is initialized only after a solver-dependent attempt is reached, so
/// normal playback does not pay the EJS download/runtime startup cost.
class YoutubeExplodeRuntime {
  YoutubeExplodeRuntime({
    required this.platform,
    this.androidChannel,
    this.denoExecutable,
  });

  final AppPlatformType platform;
  final AndroidYtdlChannel? androidChannel;
  final String? denoExecutable;
  Future<YoutubeExplode>? _fastClientFuture;
  Future<YoutubeExplode>? _solverClientFuture;
  Future<BaseJSChallengeSolver>? _solverFuture;
  AndroidWebPoTokenProvider? _androidPoTokenProvider;
  bool _disposed = false;

  bool get supportsSolver =>
      platform == AppPlatformType.android ||
      platform == AppPlatformType.windows ||
      platform == AppPlatformType.linux ||
      platform == AppPlatformType.macos;

  Future<YoutubeExplode> get fastClient {
    _checkNotDisposed();
    return _fastClientFuture ??= Future<YoutubeExplode>.value(
      YoutubeExplode(
        manifestClientsProvider: () => _manifestClients(useSolver: false),
      ),
    );
  }

  Future<YoutubeExplode> get solverClient {
    _checkNotDisposed();
    if (!supportsSolver) {
      return Future<YoutubeExplode>.error(
        UnsupportedError('No JavaScript solver is available on this platform.'),
      );
    }
    return _solverClientFuture ??= _createSolverClient();
  }

  Future<YoutubeExplode> clientFor(YoutubeManifestAttempt attempt) {
    return attempt.requiresJsSolver ? solverClient : fastClient;
  }

  Future<YoutubeExplode> _createSolverClient() async {
    final solver = await (_solverFuture ??= _createSolver());
    final poTokenProvider = platform == AppPlatformType.android
        ? (_androidPoTokenProvider ??= AndroidWebPoTokenProvider(
            channel: androidChannel,
          ))
        : null;
    return YoutubeExplode(
      jsSolver: solver,
      poTokenProvider: poTokenProvider,
      manifestClientsProvider: () => _manifestClients(useSolver: true),
    );
  }

  Future<void> prewarmPoTokens() async {
    if (_disposed || platform != AppPlatformType.android) {
      return;
    }
    final provider = _androidPoTokenProvider ??= AndroidWebPoTokenProvider(
      channel: androidChannel,
    );
    await provider.prewarm();
  }

  Future<BaseJSChallengeSolver> _createSolver() async {
    switch (platform) {
      case AppPlatformType.android:
        return AndroidQuickJsEjsSolver(channel: androidChannel);
      case AppPlatformType.windows:
      case AppPlatformType.linux:
      case AppPlatformType.macos:
        return DenoEJSSolver.init(
          denoExe: denoExecutable ?? findBundledDenoExecutable(),
        );
      case AppPlatformType.unsupported:
        throw UnsupportedError('No JavaScript solver is available.');
    }
  }

  List<YoutubeApiClient> _manifestClients({required bool useSolver}) {
    return defaultYoutubeManifestAttempts
        .where((attempt) => useSolver || !attempt.requiresJsSolver)
        .map((attempt) => attempt.client)
        .toList(growable: false);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final clients = <Future<YoutubeExplode>>[
      ?_fastClientFuture,
      ?_solverClientFuture,
    ];
    var solverClientClosed = false;
    for (final future in clients) {
      try {
        (await future).close();
        if (identical(future, _solverClientFuture)) {
          solverClientClosed = true;
        }
      } catch (_) {}
    }
    if (!solverClientClosed) {
      _androidPoTokenProvider?.dispose();
      final solverFuture = _solverFuture;
      if (solverFuture != null) {
        try {
          (await solverFuture).dispose();
        } catch (_) {}
      }
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('YoutubeExplodeRuntime was disposed.');
    }
  }
}
