import 'dart:async';

import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('secure store round-trips one versioned atomic value', () async {
    final keyValueStore = _MemorySecureStore();
    final store = SecureYouTubeMusicSessionStore(
      secureStore: keyValueStore,
      revocationStore: _MemoryRevocationStore(),
    );
    final credential = _credential();

    await store.write(credential);
    final restored = await store.read();

    expect(keyValueStore.values.keys, <String>[
      'bstream.youtube_music.session.v1',
    ]);
    expect(restored?.profile.channelId, credential.profile.channelId);
    expect(restored?.cookieHeader, credential.cookieHeader);
  });

  test('corrupt and future values are deleted instead of being used', () async {
    for (final value in <String>['{not-json', '{"version":999}']) {
      final keyValueStore = _MemorySecureStore(
        values: <String, String>{'bstream.youtube_music.session.v1': value},
      );
      final store = SecureYouTubeMusicSessionStore(
        secureStore: keyValueStore,
        revocationStore: _MemoryRevocationStore(),
      );

      expect(await store.read(), isNull);
      expect(keyValueStore.values, isEmpty);
      expect(keyValueStore.operations, <String>['read', 'delete']);
    }
  });

  test(
    'operations are serialized so logout follows an in-flight write',
    () async {
      final writeGate = Completer<void>();
      final keyValueStore = _MemorySecureStore(writeGate: writeGate);
      final store = SecureYouTubeMusicSessionStore(
        secureStore: keyValueStore,
        revocationStore: _MemoryRevocationStore(),
      );

      final write = store.write(_credential());
      await Future<void>.delayed(Duration.zero);
      final delete = store.delete();
      await Future<void>.delayed(Duration.zero);
      expect(keyValueStore.operations, <String>['write-start']);

      writeGate.complete();
      await Future.wait<void>(<Future<void>>[write, delete]);
      expect(keyValueStore.operations, <String>[
        'write-start',
        'write-end',
        'delete',
      ]);
      expect(keyValueStore.values, isEmpty);
    },
  );

  test(
    'a platform error propagates without poisoning later operations',
    () async {
      final keyValueStore = _MemorySecureStore(
        writeError: StateError('locked'),
      );
      final store = SecureYouTubeMusicSessionStore(
        secureStore: keyValueStore,
        revocationStore: _MemoryRevocationStore(),
      );

      await expectLater(store.write(_credential()), throwsStateError);
      await store.delete();

      expect(keyValueStore.operations, <String>['write-start', 'delete']);
    },
  );

  test(
    'a failed secure deletion stays revoked across restarts and retries cleanup',
    () async {
      final credential = _credential();
      final keyValueStore = _MemorySecureStore(
        values: <String, String>{
          'bstream.youtube_music.session.v1': credential.encode(),
        },
        deleteFailuresRemaining: 2,
      );
      final revocationStore = _MemoryRevocationStore();
      final firstProcess = SecureYouTubeMusicSessionStore(
        secureStore: keyValueStore,
        revocationStore: revocationStore,
      );

      await expectLater(firstProcess.delete(), throwsStateError);
      expect(revocationStore.revoked, isTrue);
      expect(keyValueStore.values, isNotEmpty);

      final secondProcess = SecureYouTubeMusicSessionStore(
        secureStore: keyValueStore,
        revocationStore: revocationStore,
      );
      expect(await secondProcess.read(), isNull);
      expect(revocationStore.revoked, isTrue);
      expect(keyValueStore.values, isNotEmpty);

      final thirdProcess = SecureYouTubeMusicSessionStore(
        secureStore: keyValueStore,
        revocationStore: revocationStore,
      );
      expect(await thirdProcess.read(), isNull);
      expect(revocationStore.revoked, isFalse);
      expect(keyValueStore.values, isEmpty);
    },
  );

  test('a revocation marker read failure never reads the credential', () async {
    final keyValueStore = _MemorySecureStore(
      values: <String, String>{
        'bstream.youtube_music.session.v1': _credential().encode(),
      },
    );
    final store = SecureYouTubeMusicSessionStore(
      secureStore: keyValueStore,
      revocationStore: _MemoryRevocationStore(
        readError: StateError('auxiliary storage unavailable'),
      ),
    );

    await expectLater(store.read(), throwsStateError);
    expect(keyValueStore.operations, isEmpty);
  });

  test(
    'a replacement login remains quarantined if its marker cannot be cleared',
    () async {
      final keyValueStore = _MemorySecureStore();
      final revocationStore = _MemoryRevocationStore(
        revoked: true,
        clearError: StateError('marker locked'),
      );
      final store = SecureYouTubeMusicSessionStore(
        secureStore: keyValueStore,
        revocationStore: revocationStore,
      );

      await expectLater(store.write(_credential()), throwsStateError);

      expect(revocationStore.revoked, isTrue);
      expect(keyValueStore.values, isEmpty);
    },
  );

  test(
    'SharedPreferences revocation value is only a non-secret boolean',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const store = SharedPreferencesYouTubeMusicSessionRevocationStore();

      await store.markRevoked();

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), <String>{store.storageKey});
      expect(preferences.getBool(store.storageKey), isTrue);
      expect(preferences.get(store.storageKey), isA<bool>());

      await store.clearRevoked();
      expect(await store.isRevoked(), isFalse);
    },
  );
}

class _MemorySecureStore implements YouTubeMusicSecureKeyValueStore {
  _MemorySecureStore({
    Map<String, String>? values,
    this.writeGate,
    this.writeError,
    this.deleteFailuresRemaining = 0,
  }) : values = values ?? <String, String>{};

  final Map<String, String> values;
  final Completer<void>? writeGate;
  final Object? writeError;
  int deleteFailuresRemaining;
  final List<String> operations = <String>[];

  @override
  Future<String?> read(String key) async {
    operations.add('read');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    operations.add('write-start');
    final error = writeError;
    if (error != null) throw error;
    await writeGate?.future;
    values[key] = value;
    operations.add('write-end');
  }

  @override
  Future<void> delete(String key) async {
    operations.add('delete');
    if (deleteFailuresRemaining > 0) {
      deleteFailuresRemaining -= 1;
      throw StateError('secure deletion failed');
    }
    values.remove(key);
  }
}

class _MemoryRevocationStore implements YouTubeMusicSessionRevocationStore {
  _MemoryRevocationStore({
    this.revoked = false,
    this.readError,
    this.clearError,
  });

  bool revoked;
  final Object? readError;
  final Object? clearError;

  @override
  Future<bool> isRevoked() async {
    final error = readError;
    if (error != null) throw error;
    return revoked;
  }

  @override
  Future<void> markRevoked() async {
    revoked = true;
  }

  @override
  Future<void> clearRevoked() async {
    final error = clearError;
    if (error != null) throw error;
    revoked = false;
  }
}

YouTubeMusicSessionCredential _credential() => YouTubeMusicSessionCredential(
  cookieHeader: 'SAPISID=test-session-value',
  identity: const YouTubeMusicAuthIdentity(
    visitorData: 'test-visitor-data',
    authUser: '0',
  ),
  profile: const YouTubeMusicAccountProfile(
    channelId: 'test-channel-id',
    displayName: 'Test account',
  ),
  validatedAt: DateTime.utc(2026, 8, 22),
  apiKey: 'test_api_key',
  clientVersion: '1.20260822.00.00',
  clientName: 'WEB_REMIX',
);
