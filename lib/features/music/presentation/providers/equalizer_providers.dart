import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/player/cast_aware_player_service.dart';
import 'audio_route_providers.dart';
import 'music_providers.dart';

class EqualizerRuntimeState {
  const EqualizerRuntimeState({
    this.supported = false,
    this.applying = false,
    this.error,
  });
  final bool supported;
  final bool applying;
  final Object? error;
}

final equalizerRuntimeProvider =
    NotifierProvider<EqualizerRuntimeController, EqualizerRuntimeState>(
      EqualizerRuntimeController.new,
    );

final equalizerAvailableProvider = Provider<bool>((ref) {
  final supported = ref.watch(equalizerRuntimeProvider).supported;
  final service = ref.watch(playerServiceProvider);
  if (service is CastAwarePlayerService) {
    ref.watch(castStateProvider);
    return supported && !service.isCasting;
  }
  return supported;
});

/// One binding for every entry point. Coalesce slider updates and serialize
/// native writes so a slow old curve can never overwrite a newer selection.
class EqualizerRuntimeController extends Notifier<EqualizerRuntimeState> {
  Timer? _timer;
  bool _disposed = false;
  bool _writing = false;
  EqualizerSettings? _pending;
  EqualizerSettings? _applied;
  int _epoch = 0;

  @override
  EqualizerRuntimeState build() {
    final epoch = ++_epoch;
    _timer?.cancel();
    _disposed = false;
    _writing = false;
    _pending = null;
    _applied = null;
    final service = ref.watch(playerServiceProvider);
    final capable =
        service is EqualizerCapablePlayer &&
        (service as EqualizerCapablePlayer).supportsEqualizer;
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
    });
    if (service case final EqualizerCapablePlayer equalizer) {
      final subscription = service.snapshotStream
          .map((_) => equalizer.supportsEqualizer)
          .distinct()
          .listen((supported) {
            if (_disposed || epoch != _epoch || state.supported == supported) {
              return;
            }
            state = EqualizerRuntimeState(
              supported: supported,
              applying: state.applying,
              error: state.error,
            );
          });
      ref.onDispose(subscription.cancel);
    }
    ref.listen<EqualizerSettings?>(
      settingsControllerProvider.select((s) => s.asData?.value.equalizer),
      (_, settings) {
        if (settings == null || !capable) return;
        _pending = settings;
        _schedule(service as EqualizerCapablePlayer, epoch);
      },
      fireImmediately: true,
    );
    return EqualizerRuntimeState(supported: capable);
  }

  void _schedule(EqualizerCapablePlayer player, int epoch) {
    if (_disposed || epoch != _epoch || _writing || _timer?.isActive == true) {
      return;
    }
    // Continuous dragging keeps changing the sound, with at most one write
    // per interval. Only the latest curve in that interval is sent to native.
    _timer = Timer(const Duration(milliseconds: 80), () {
      unawaited(_apply(player, epoch));
    });
  }

  Future<void> _apply(EqualizerCapablePlayer player, int epoch) async {
    if (_writing || _disposed || epoch != _epoch) return;
    _writing = true;
    state = EqualizerRuntimeState(
      supported: player.supportsEqualizer,
      applying: true,
    );
    Object? failure;
    try {
      if (!_disposed && epoch == _epoch && _pending != null) {
        final settings = _pending!;
        _pending = null;
        if (settings != _applied) {
          // A rejected update can remove a previously installed native curve.
          // Returning to that old preset must therefore send it again.
          _applied = null;
          await player.configureEqualizer(settings);
          if (_disposed || epoch != _epoch) return;
          _applied = settings;
        }
      }
    } catch (error) {
      failure = error;
    } finally {
      if (!_disposed && epoch == _epoch) {
        _writing = false;
        state = EqualizerRuntimeState(
          supported: player.supportsEqualizer,
          error: failure,
        );
        if (_pending != null) _schedule(player, epoch);
      }
    }
  }
}
