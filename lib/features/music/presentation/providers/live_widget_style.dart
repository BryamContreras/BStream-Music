enum LiveWidgetStyle {
  classic,
  wave;

  String get code => name;

  static LiveWidgetStyle fromCode(String? code) => switch (code) {
    'wave' => LiveWidgetStyle.wave,
    _ => LiveWidgetStyle.classic,
  };
}
