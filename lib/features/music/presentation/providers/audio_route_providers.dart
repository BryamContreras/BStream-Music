import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/audio_output/audio_output_service.dart';
import '../../../../services/casting/cast_coordinator.dart';

final audioOutputServiceProvider = Provider<AudioOutputService>((ref) {
  final service = AudioOutputService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final audioOutputStateProvider = StreamProvider.autoDispose<AudioOutputState>((
  ref,
) {
  final service = ref.watch(audioOutputServiceProvider);
  final controller = StreamController<AudioOutputState>();
  final subscription = service.changes.listen(controller.add);
  ref.onDispose(() {
    unawaited(subscription.cancel());
    unawaited(service.stopWatching());
    unawaited(controller.close());
  });
  unawaited(() async {
    try {
      final initial = await service.startWatching();
      if (!controller.isClosed) controller.add(initial);
    } catch (error, stackTrace) {
      if (!controller.isClosed) controller.addError(error, stackTrace);
    }
  }());
  return controller.stream;
});

final castCoordinatorProvider = Provider<CastCoordinator>((ref) {
  final service = CastCoordinator();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final castStateProvider = StreamProvider<CastState>((ref) async* {
  final service = ref.watch(castCoordinatorProvider);
  yield service.state;
  yield* service.changes;
});
