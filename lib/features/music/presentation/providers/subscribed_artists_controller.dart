import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/youtube_music/account/youtube_music_account.dart';
import 'youtube_music_auth_controller.dart';

final youtubeMusicSubscribedArtistsAccountProvider =
    Provider<YouTubeMusicSubscribedArtistsAccount?>((ref) {
      return ref.watch(youtubeMusicAuthenticatedAccountGatewayProvider);
    });

final subscribedArtistsProvider =
    AsyncNotifierProvider<
      SubscribedArtistsController,
      List<RemoteSubscribedArtist>
    >(SubscribedArtistsController.new);

/// Account-backed artists followed by the active YouTube Music identity.
///
/// The remote subscriptions shelf remains the durable source of truth. The
/// optimistic overlay only bridges YouTube's eventual-consistency window so a
/// successful subscribe/unsubscribe action is reflected in Library at once.
class SubscribedArtistsController
    extends AsyncNotifier<List<RemoteSubscribedArtist>> {
  final Map<String, RemoteSubscribedArtist> _optimisticSubscribed =
      <String, RemoteSubscribedArtist>{};
  final Set<String> _optimisticRemoved = <String>{};
  String? _sessionKey;

  @override
  Future<List<RemoteSubscribedArtist>> build() async {
    final auth = ref.watch(youtubeMusicAuthControllerProvider);
    final nextSessionKey = auth.isAuthenticated
        ? '${auth.generation}|${auth.profile?.channelId ?? ''}'
        : null;
    if (_sessionKey != nextSessionKey) {
      _sessionKey = nextSessionKey;
      _optimisticSubscribed.clear();
      _optimisticRemoved.clear();
    }
    if (nextSessionKey == null) {
      return const <RemoteSubscribedArtist>[];
    }

    final account = ref.watch(youtubeMusicSubscribedArtistsAccountProvider);
    if (account == null) {
      return const <RemoteSubscribedArtist>[];
    }
    final remote = await account.getSubscribedArtists();
    return _withOptimisticChanges(remote.artists);
  }

  /// Call only after YouTube confirms a subscribe mutation.
  void recordSubscribed(RemoteSubscribedArtist artist) {
    if (_sessionKey == null) return;
    final normalized = _normalizedArtist(artist);
    final keys = _artistKeys(normalized);
    if (keys.isEmpty) return;
    _optimisticRemoved.removeAll(keys);
    _optimisticSubscribed.removeWhere(
      (_, candidate) => _artistKeys(candidate).any(keys.contains),
    );
    _optimisticSubscribed[normalized.identity] = normalized;
    state = AsyncData(
      _withOptimisticChanges(state.value ?? const <RemoteSubscribedArtist>[]),
    );
  }

  /// Call only after YouTube confirms an unsubscribe mutation.
  void recordUnsubscribed({required String artistBrowseId, String? channelId}) {
    if (_sessionKey == null) return;
    final keys = <String?>[
      _normalizedId(artistBrowseId),
      _normalizedId(channelId),
    ].whereType<String>().toSet();
    if (keys.isEmpty) return;
    _optimisticRemoved.addAll(keys);
    _optimisticSubscribed.removeWhere(
      (_, artist) => _artistKeys(artist).any(keys.contains),
    );
    state = AsyncData(
      _withOptimisticChanges(state.value ?? const <RemoteSubscribedArtist>[]),
    );
  }

  /// Re-reads the account shelf while retaining unconfirmed optimistic state.
  void refresh() => ref.invalidateSelf();

  List<RemoteSubscribedArtist> _withOptimisticChanges(
    Iterable<RemoteSubscribedArtist> remote,
  ) {
    final merged = <RemoteSubscribedArtist>[];
    final seen = <String>{};

    void add(RemoteSubscribedArtist artist) {
      final keys = _artistKeys(artist);
      if (keys.isEmpty || keys.any(_optimisticRemoved.contains)) return;
      if (keys.any(seen.contains)) return;
      seen.addAll(keys);
      merged.add(artist);
    }

    for (final artist in _optimisticSubscribed.values) {
      add(artist);
    }
    for (final artist in remote) {
      add(_normalizedArtist(artist));
    }
    return List<RemoteSubscribedArtist>.unmodifiable(merged);
  }
}

RemoteSubscribedArtist _normalizedArtist(RemoteSubscribedArtist artist) {
  return RemoteSubscribedArtist(
    browseId: artist.browseId.trim(),
    name: artist.name.trim(),
    channelId: _normalizedId(artist.channelId),
    thumbnailUrl: _normalizedId(artist.thumbnailUrl),
  );
}

Set<String> _artistKeys(RemoteSubscribedArtist artist) => <String?>[
  _normalizedId(artist.browseId),
  _normalizedId(artist.channelId),
].whereType<String>().toSet();

String? _normalizedId(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
