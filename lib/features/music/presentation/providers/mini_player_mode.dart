enum MiniPlayerMode {
  standard,
  capsule;

  String get code => switch (this) {
    MiniPlayerMode.standard => 'default',
    MiniPlayerMode.capsule => 'capsule',
  };

  static MiniPlayerMode fromCode(String? code) {
    return switch (code) {
      'default' => MiniPlayerMode.standard,
      'capsule' => MiniPlayerMode.capsule,
      _ => defaultMiniPlayerMode,
    };
  }
}

const defaultMiniPlayerMode = MiniPlayerMode.capsule;
