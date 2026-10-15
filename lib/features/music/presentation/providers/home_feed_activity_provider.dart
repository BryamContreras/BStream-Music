import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Visibility, not playback position, controls optional feed refresh work.
final homeFeedActivityProvider = NotifierProvider<HomeFeedActivity, bool>(
  HomeFeedActivity.new,
);

class HomeFeedActivity extends Notifier<bool> {
  @override
  bool build() => true;

  void setVisible(bool visible) {
    if (state != visible) state = visible;
  }
}
