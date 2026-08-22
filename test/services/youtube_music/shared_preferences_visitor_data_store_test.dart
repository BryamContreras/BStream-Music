import 'package:bstream_music/services/youtube_music/shared_preferences_visitor_data_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persists, normalizes, and clears anonymous visitor data', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const store = SharedPreferencesInnerTubeVisitorDataStore();

    expect(await store.read(), isNull);
    await store.write('  visitor-123  ');
    expect(await store.read(), 'visitor-123');

    await store.write('   ');
    expect(await store.read(), isNull);

    await store.write('visitor-456');
    await store.clear();
    expect(await store.read(), isNull);
  });
}
