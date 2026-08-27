import 'package:flutter/foundation.dart';

enum MiniPlayerMode {
  standard,
  capsule;

  String get code => switch (this) {
    MiniPlayerMode.standard => 'default',
    MiniPlayerMode.capsule => 'capsule',
  };

  static MiniPlayerMode fromCode(String? code, {TargetPlatform? platform}) {
    return switch (code) {
      'default' => MiniPlayerMode.standard,
      'capsule' => MiniPlayerMode.capsule,
      _ => defaultMiniPlayerModeForPlatform(platform ?? defaultTargetPlatform),
    };
  }
}

MiniPlayerMode defaultMiniPlayerModeForPlatform(TargetPlatform platform) =>
    platform == TargetPlatform.android
    ? MiniPlayerMode.capsule
    : MiniPlayerMode.standard;

// Const fallback retained for SettingsState fixtures and explicit const widget
// configurations. Production defaults must use
// [defaultMiniPlayerModeForPlatform] so desktop and Android can differ.
const defaultMiniPlayerMode = MiniPlayerMode.capsule;
