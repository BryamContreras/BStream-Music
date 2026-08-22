import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_consent_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('persists opaque consent and isolates it per account key', () async {
    const store = SharedPreferencesPlaylistSyncConsentStore();

    expect(await store.hasConsent('channel-a'), isFalse);
    expect(await store.hasConsent('channel-b'), isFalse);

    await store.grantConsent('channel-a');

    expect(await store.hasConsent('channel-a'), isTrue);
    expect(await store.hasConsent('channel-b'), isFalse);
    expect(
      await const SharedPreferencesPlaylistSyncConsentStore().hasConsent(
        'channel-a',
      ),
      isTrue,
    );

    final preferences = await SharedPreferences.getInstance();
    final keys = preferences.getKeys();
    expect(keys, hasLength(1));
    expect(keys.single, isNot(contains('channel-a')));
    expect(preferences.get(keys.single), isTrue);
  });

  test('rejects an empty account key without writing preferences', () async {
    const store = SharedPreferencesPlaylistSyncConsentStore();

    await expectLater(store.grantConsent('   '), throwsA(isA<ArgumentError>()));

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(), isEmpty);
  });
}
