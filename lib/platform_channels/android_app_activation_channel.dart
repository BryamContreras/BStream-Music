import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';

enum AndroidAppActivation { home, player }

@immutable
class AndroidAppActivationEvent {
  const AndroidAppActivationEvent({
    required this.activation,
    this.entryGeneration = 0,
  });

  final AndroidAppActivation activation;
  final int entryGeneration;

  factory AndroidAppActivationEvent.fromPlatformEvent(Object? event) {
    final Object? rawActivation;
    final int entryGeneration;
    if (event is Map<Object?, Object?>) {
      rawActivation = event['activation'];
      final rawGeneration = event['entryGeneration'];
      entryGeneration = rawGeneration is num ? rawGeneration.toInt() : 0;
    } else {
      // Accept the original string payload while upgrading an already-running
      // audio-service engine from an older Activity instance.
      rawActivation = event;
      entryGeneration = 0;
    }

    final activation = switch (rawActivation) {
      'home' => AndroidAppActivation.home,
      'player' => AndroidAppActivation.player,
      _ => throw FormatException(
        'Invalid Android app activation: $rawActivation',
      ),
    };
    return AndroidAppActivationEvent(
      activation: activation,
      entryGeneration: entryGeneration,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AndroidAppActivationEvent &&
        other.activation == activation &&
        other.entryGeneration == entryGeneration;
  }

  @override
  int get hashCode => Object.hash(activation, entryGeneration);
}

/// Delivers Android entry-point changes without depending on a particular
/// Activity instance. This matters while audio_service keeps Flutter's engine
/// alive and Android recreates the visible Activity around it.
class AndroidAppActivationChannel {
  static const _maxPendingActivations = 8;

  AndroidAppActivationChannel({MethodChannel? methodChannel})
    : _methodChannel =
          methodChannel ??
          const MethodChannel(AppConstants.androidAppActivationChannel) {
    _controller = StreamController<AndroidAppActivationEvent>.broadcast(
      onListen: _flushPending,
    );
  }

  final MethodChannel _methodChannel;
  late final StreamController<AndroidAppActivationEvent> _controller;
  final List<AndroidAppActivationEvent> _pending =
      <AndroidAppActivationEvent>[];
  bool _initialized = false;

  Stream<AndroidAppActivationEvent> get activations {
    if (!_initialized) {
      _initialized = true;
      unawaited(_initialize());
    }
    return _controller.stream;
  }

  Future<void> _initialize() async {
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method != 'activate') {
        throw MissingPluginException('Unknown app activation method.');
      }
      _emit(AndroidAppActivationEvent.fromPlatformEvent(call.arguments));
      return true;
    });

    try {
      final pending = await _methodChannel.invokeMethod<Object?>(
        'consumePendingActivation',
      );
      if (pending != null) {
        _emit(AndroidAppActivationEvent.fromPlatformEvent(pending));
      }
    } on MissingPluginException {
      // The channel is Android-only. Keeping the stream quiet makes accidental
      // construction on another platform harmless.
    } catch (error, stackTrace) {
      debugPrint('Could not consume the pending Android activation: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _emit(AndroidAppActivationEvent activation) {
    if (_controller.hasListener) {
      _controller.add(activation);
      return;
    }
    if (_pending.isEmpty || _pending.last != activation) {
      while (_pending.length >= _maxPendingActivations) {
        _pending.removeAt(0);
      }
      _pending.add(activation);
    }
  }

  void _flushPending() {
    if (_pending.isEmpty) {
      return;
    }
    for (final activation in List<AndroidAppActivationEvent>.of(_pending)) {
      _controller.add(activation);
    }
    _pending.clear();
  }

  @visibleForTesting
  Future<void> dispose() async {
    _methodChannel.setMethodCallHandler(null);
    await _controller.close();
  }
}

final androidAppActivationChannel = AndroidAppActivationChannel();
