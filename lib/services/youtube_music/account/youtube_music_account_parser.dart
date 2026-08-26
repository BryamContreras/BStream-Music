import 'youtube_music_account_models.dart';

/// Defensive parser for the small authenticated surface used by BStream.
///
/// YouTube frequently wraps the same renderer in different containers. The
/// parser therefore keys off renderer names and semantic endpoint fields, not
/// fixed array indexes. It never deduplicates playlist entries.
class YouTubeMusicAccountParser {
  const YouTubeMusicAccountParser();

  RemoteAccountProfile? parseProfile(Object? root) {
    final renderer =
        _firstRenderer(root, 'activeAccountHeaderRenderer') ??
        _firstRenderer(root, 'accountHeaderRenderer');
    if (renderer == null) {
      return null;
    }

    final displayName = _firstText(renderer, const <String>[
      'accountName',
      'title',
    ]);
    if (displayName == null) {
      return null;
    }
    return RemoteAccountProfile(
      displayName: displayName,
      email: _firstText(renderer, const <String>['email']),
      handle: _firstText(renderer, const <String>[
        'channelHandle',
        'accountByline',
        'subtitle',
      ]),
      avatarUrl: _thumbnailUrl(
        renderer['accountPhoto'] ?? renderer['thumbnail'],
      ),
      channelId: _firstChannelId(renderer),
    );
  }

  RemoteAccountDirectory parseAccountDirectory(Object? root) {
    final accounts = <RemoteGoogleAccount>[];
    final channels = <RemoteAccountChannel>[];
    final seenAccounts = <String>{};
    final seenChannels = <String>{};

    for (final renderer in _renderers(root, 'googleAccountHeaderRenderer')) {
      final displayName = _firstText(renderer, const <String>['name', 'title']);
      final email = _firstText(renderer, const <String>['email']);
      if (displayName == null || email == null) {
        continue;
      }
      final key = '${email.toLowerCase()}|$displayName';
      if (seenAccounts.add(key)) {
        accounts.add(
          RemoteGoogleAccount(displayName: displayName, email: email),
        );
      }
    }

    for (final rendererName in const <String>[
      'accountItem',
      'accountItemRenderer',
      'channelSwitcherItemRenderer',
    ]) {
      for (final renderer in _renderers(root, rendererName)) {
        final displayName = _firstText(renderer, const <String>[
          'accountName',
          'title',
        ]);
        if (displayName == null) {
          continue;
        }
        final email = _firstText(renderer, const <String>['email']);
        final handle = _firstText(renderer, const <String>[
          'channelHandle',
          'accountByline',
          'subtitle',
        ]);
        final avatar = _thumbnailUrl(
          renderer['accountPhoto'] ?? renderer['thumbnail'],
        );
        final selected = _boolForKeys(renderer, const <String>[
          'isSelected',
          'selected',
        ]);
        final pageId = _firstStringForKeys(renderer, const <String>[
          'pageId',
          'obfuscatedGaiaId',
        ]);
        final dataSyncId = _firstStringForKeys(renderer, const <String>[
          'datasyncIdToken',
          'dataSyncId',
        ]);
        final signInUrl = _firstStringForKeys(renderer, const <String>[
          'signinUrl',
          'signInUrl',
        ]);
        final channelId = _firstChannelId(renderer);

        if (email != null) {
          final key = '${email.toLowerCase()}|$displayName';
          if (seenAccounts.add(key)) {
            accounts.add(
              RemoteGoogleAccount(
                displayName: displayName,
                email: email,
                avatarUrl: avatar,
                isSelected: selected,
              ),
            );
          }
        } else {
          final key = pageId ?? channelId ?? '$displayName|${handle ?? ''}';
          if (seenChannels.add(key)) {
            channels.add(
              RemoteAccountChannel(
                displayName: displayName,
                handle: handle,
                channelId: channelId,
                pageId: pageId,
                dataSyncId: dataSyncId,
                signInUrl: signInUrl,
                avatarUrl: avatar,
                isSelected: selected,
              ),
            );
          }
        }
      }
    }

    return RemoteAccountDirectory(accounts: accounts, channels: channels);
  }

  List<RemotePlaylistSummary> parsePlaylistSummaries(Object? root) {
    final summaries = <RemotePlaylistSummary>[];
    final containers = _savedPlaylistContainers(root);
    final collections = containers.isNotEmpty
        ? containers.expand(_savedPlaylistCollections).toList(growable: false)
        : _uniqueLegacyRendererCollection(
            root,
            _savedPlaylistRendererNames,
            _isVerifiablePlaylistSummary,
          );
    for (final renderer in _directRenderers(
      collections,
      _savedPlaylistRendererNames,
    )) {
      final playlistId = _playlistId(renderer);
      if (playlistId == null) {
        continue;
      }
      final title = _playlistTitle(renderer);
      if (title == null) {
        continue;
      }
      final metadata = _metadataTexts(renderer);
      summaries.add(
        RemotePlaylistSummary(
          playlistId: playlistId,
          title: title,
          owner: _owner(renderer, metadata),
          thumbnailUrl: _thumbnailUrl(renderer),
          itemCount: _itemCount(metadata),
          visibility: _visibility(metadata),
          isEditable: _containsAnyKey(renderer, const <String>{
            'editPlaylistEndpoint',
            'playlistEditEndpoint',
            'editable',
          }),
        ),
      );
    }
    return summaries;
  }

  RemotePlaylistSummary? parsePlaylistHeader(
    Object? root, {
    required String playlistId,
  }) {
    // Current YouTube Music responses can wrap the visible detail header in
    // musicEditablePlaylistDetailHeaderRenderer while keeping the edit
    // endpoint on the wrapper (or on a sibling menu). Looking only inside the
    // renderer that provides the title turns an owned playlist into a false
    // read-only snapshot and blocks the next synchronization.
    final isEditable =
        _firstRenderer(root, 'musicEditablePlaylistDetailHeaderRenderer') !=
            null ||
        _containsAnyKey(root, const <String>{
          'editPlaylistEndpoint',
          'playlistEditEndpoint',
        });
    for (final rendererName in const <String>[
      'musicEditablePlaylistDetailHeaderRenderer',
      'musicDetailHeaderRenderer',
      'musicResponsiveHeaderRenderer',
    ]) {
      final renderer = _firstRenderer(root, rendererName);
      if (renderer == null) {
        continue;
      }
      final title = _firstText(renderer, const <String>['title', 'headline']);
      if (title == null) {
        continue;
      }
      final metadata = _metadataTexts(renderer);
      return RemotePlaylistSummary(
        playlistId: playlistId,
        title: title,
        owner: _owner(renderer, metadata),
        thumbnailUrl: _thumbnailUrl(renderer),
        itemCount: _itemCount(metadata),
        visibility: _visibility(metadata),
        isEditable: isEditable,
      );
    }
    return null;
  }

  List<RemotePlaylistEntry> parsePlaylistEntries(
    Object? root, {
    required int startingPosition,
  }) {
    final entries = <RemotePlaylistEntry>[];
    final containers = _playlistEntryContainers(root);
    final collections = containers.isNotEmpty
        ? containers.expand(_playlistEntryCollections).toList(growable: false)
        : _uniqueLegacyRendererCollection(
            root,
            _playlistEntryRendererNames,
            _isVerifiablePlaylistEntry,
          );
    for (final renderer in _directRenderers(
      collections,
      _playlistEntryRendererNames,
    )) {
      final videoId = _entryVideoId(renderer);
      final setVideoId = _firstStringForKeys(renderer, const <String>[
        'playlistSetVideoId',
        'setVideoId',
      ]);
      if (videoId == null && setVideoId == null) {
        continue;
      }
      final title = _entryTitle(renderer) ?? 'Contenido no disponible';
      final metadata = _entryMetadata(renderer);
      entries.add(
        RemotePlaylistEntry(
          position: startingPosition + entries.length,
          videoId: videoId,
          setVideoId: setVideoId,
          title: title,
          artists: metadata.artists,
          artistBrowseIds: metadata.artistBrowseIds,
          album: metadata.album,
          duration: _duration(renderer),
          thumbnailUrl: _thumbnailUrl(renderer),
          isAvailable:
              videoId != null &&
              !_boolForKeys(renderer, const <String>['isDisabled']),
        ),
      );
    }
    return entries;
  }

  /// Continuations for `FEmusic_liked_playlists` are accepted only from the
  /// grid/music shelf that owns the parsed playlist cards.
  List<String> parseSavedPlaylistContinuationTokens(Object? root) {
    final containers = _savedPlaylistContainers(root);
    if (containers.isNotEmpty) {
      return _continuationTokensFromContainers(containers);
    }
    final legacy = _uniqueLegacyRendererCollection(
      root,
      _savedPlaylistRendererNames,
      _isVerifiablePlaylistSummary,
    );
    return _continuationTokensFromCollections(legacy);
  }

  /// Parses only cards owned by the authenticated subscriptions collection.
  /// Song bylines and unrelated carousel renderers are intentionally ignored.
  List<RemoteSubscribedArtist> parseSubscribedArtists(Object? root) {
    final artists = <RemoteSubscribedArtist>[];
    final seen = <String>{};
    final containers = _subscribedArtistContainers(root);
    final collections = containers.isNotEmpty
        ? containers
              .expand(_subscribedArtistCollections)
              .toList(growable: false)
        : _uniqueLegacyRendererCollection(
            root,
            _subscribedArtistRendererNames,
            _isVerifiableSubscribedArtist,
          );
    for (final renderer in _directRenderers(
      collections,
      _subscribedArtistRendererNames,
    )) {
      final browseId = _artistBrowseId(renderer);
      final name = _artistTitle(renderer);
      if (browseId == null || name == null) continue;
      final channelId = _firstChannelId(renderer);
      final artist = RemoteSubscribedArtist(
        browseId: browseId,
        name: name,
        channelId: channelId?.startsWith('UC') == true ? channelId : null,
        thumbnailUrl: _thumbnailUrl(renderer),
      );
      if (seen.add(artist.identity)) {
        artists.add(artist);
      }
    }
    return List<RemoteSubscribedArtist>.unmodifiable(artists);
  }

  List<String> parseSubscribedArtistContinuationTokens(Object? root) {
    final containers = _subscribedArtistContainers(root);
    if (containers.isNotEmpty) {
      return _continuationTokensFromContainers(containers);
    }
    final legacy = _uniqueLegacyRendererCollection(
      root,
      _subscribedArtistRendererNames,
      _isVerifiableSubscribedArtist,
    );
    return _continuationTokensFromCollections(legacy);
  }

  /// Playlist-detail continuations are scoped to the playlist shelf. Tokens
  /// from related shelves, menus or other response branches are ignored.
  List<String> parsePlaylistEntryContinuationTokens(Object? root) {
    final containers = _playlistEntryContainers(root);
    if (containers.isNotEmpty) {
      return _continuationTokensFromContainers(containers);
    }
    final legacy = _uniqueLegacyRendererCollection(
      root,
      _playlistEntryRendererNames,
      _isVerifiablePlaylistEntry,
    );
    return _continuationTokensFromCollections(legacy);
  }

  /// Compatibility entry point for callers that do not know the browse kind.
  /// It still uses collection-scoped parsing and never walks arbitrary maps.
  List<String> parseContinuationTokens(Object? root) {
    final playlistContainers = _playlistEntryContainers(root);
    if (playlistContainers.isNotEmpty) {
      return _continuationTokensFromContainers(playlistContainers);
    }
    final savedContainers = _savedPlaylistContainers(root);
    if (savedContainers.isNotEmpty) {
      return _continuationTokensFromContainers(savedContainers);
    }

    final legacy = <_RendererCollection>[
      ..._legacyRendererCollections(
        root,
        _playlistEntryRendererNames,
        _isVerifiablePlaylistEntry,
      ),
      ..._legacyRendererCollections(
        root,
        _savedPlaylistRendererNames,
        _isVerifiablePlaylistSummary,
      ),
    ];
    return legacy.length == 1
        ? _continuationTokensFromCollections(legacy)
        : const <String>[];
  }

  String? parseCreatedPlaylistId(Object? root) {
    final value = _firstStringForKeys(root, const <String>['playlistId']);
    return value == null ? null : canonicalPlaylistId(value);
  }
}

String canonicalPlaylistId(String value) {
  final normalized = value.trim();
  return normalized.startsWith('VL') ? normalized.substring(2) : normalized;
}

typedef _EntryMetadata = ({
  List<String> artists,
  List<String?> artistBrowseIds,
  String? album,
});

typedef _RendererCollection = List<dynamic>;
typedef _RendererVerifier = bool Function(Map<String, Object?> renderer);

const List<String> _savedPlaylistRendererNames = <String>[
  'musicTwoRowItemRenderer',
  'musicResponsiveListItemRenderer',
];

const List<String> _playlistEntryRendererNames = <String>[
  'musicResponsiveListItemRenderer',
  'playlistPanelVideoRenderer',
];

const List<String> _subscribedArtistRendererNames = <String>[
  'musicTwoRowItemRenderer',
  'musicResponsiveListItemRenderer',
];

List<Map<String, Object?>> _playlistEntryContainers(Object? root) {
  final rootMap = _asMap(root);
  final continuationContents = _asMap(rootMap?['continuationContents']);
  final continuation = _asMap(
    continuationContents?['musicPlaylistShelfContinuation'],
  );
  if (continuation != null) {
    return <Map<String, Object?>>[continuation];
  }
  return _renderers(root, 'musicPlaylistShelfRenderer').toList(growable: false);
}

List<Map<String, Object?>> _savedPlaylistContainers(Object? root) {
  final rootMap = _asMap(root);
  final continuationContents = _asMap(rootMap?['continuationContents']);
  if (continuationContents != null) {
    final continuations = <Map<String, Object?>>[];
    for (final key in const <String>[
      'gridContinuation',
      'musicShelfContinuation',
      'musicCarouselShelfContinuation',
    ]) {
      final container = _asMap(continuationContents[key]);
      if (container != null) {
        continuations.add(container);
      }
    }
    if (continuations.isNotEmpty) {
      // A browse response can carry continuation branches for several
      // shelves. Prefer branches that actually contain playlist cards; this
      // keeps unrelated shelves from stealing the pagination token while
      // still accepting the carousel used by the current YT Music library.
      final playlistBranches = continuations
          .where(_savedPlaylistContainerHasVerifiableCard)
          .toList(growable: false);
      return playlistBranches.isNotEmpty ? playlistBranches : continuations;
    }
  }

  final containers = <Map<String, Object?>>[
    ..._renderers(root, 'gridRenderer'),
    ..._renderers(root, 'musicShelfRenderer'),
  ];
  final carousels = _renderers(
    root,
    'musicCarouselShelfRenderer',
  ).where(_savedPlaylistContainerHasVerifiableCard).toList(growable: false);
  containers.addAll(carousels);
  return containers;
}

List<Map<String, Object?>> _subscribedArtistContainers(Object? root) {
  final rootMap = _asMap(root);
  final continuationContents = _asMap(rootMap?['continuationContents']);
  if (continuationContents != null) {
    final candidates = <Map<String, Object?>>[];
    for (final key in const <String>[
      'gridContinuation',
      'musicShelfContinuation',
      'musicCarouselShelfContinuation',
    ]) {
      final container = _asMap(continuationContents[key]);
      if (container != null) candidates.add(container);
    }
    final artistBranches = candidates
        .where(_subscribedArtistContainerHasVerifiableCard)
        .toList(growable: false);
    return artistBranches.isNotEmpty ? artistBranches : candidates;
  }

  return <Map<String, Object?>>[
    ..._renderers(root, 'gridRenderer'),
    ..._renderers(root, 'musicShelfRenderer'),
    ..._renderers(root, 'musicCarouselShelfRenderer'),
  ].where(_subscribedArtistContainerHasVerifiableCard).toList(growable: false);
}

bool _subscribedArtistContainerHasVerifiableCard(
  Map<String, Object?> container,
) {
  return _directRenderers(
    _subscribedArtistCollections(container),
    _subscribedArtistRendererNames,
  ).any(_isVerifiableSubscribedArtist);
}

bool _savedPlaylistContainerHasVerifiableCard(Map<String, Object?> container) {
  final collections = _savedPlaylistCollections(container);
  return _directRenderers(
    collections,
    _savedPlaylistRendererNames,
  ).any(_isVerifiablePlaylistSummary);
}

Iterable<_RendererCollection> _playlistEntryCollections(
  Map<String, Object?> container,
) sync* {
  final contents = container['contents'];
  if (contents is List) {
    yield contents;
  }
}

Iterable<_RendererCollection> _savedPlaylistCollections(
  Map<String, Object?> container,
) sync* {
  for (final key in const <String>['items', 'contents']) {
    final values = container[key];
    if (values is List) {
      yield values;
    }
  }
}

Iterable<_RendererCollection> _subscribedArtistCollections(
  Map<String, Object?> container,
) sync* {
  for (final key in const <String>['items', 'contents']) {
    final values = container[key];
    if (values is List) yield values;
  }
}

Iterable<Map<String, Object?>> _directRenderers(
  Iterable<_RendererCollection> collections,
  List<String> rendererNames,
) sync* {
  for (final collection in collections) {
    for (final value in collection) {
      final item = _asMap(value);
      if (item == null) {
        continue;
      }
      for (final rendererName in rendererNames) {
        final renderer = _asMap(item[rendererName]);
        if (renderer != null) {
          yield renderer;
          break;
        }
      }
    }
  }
}

List<_RendererCollection> _uniqueLegacyRendererCollection(
  Object? root,
  List<String> rendererNames,
  _RendererVerifier verifier,
) {
  final candidates = _legacyRendererCollections(root, rendererNames, verifier);
  return candidates.length == 1 ? candidates : const <_RendererCollection>[];
}

List<_RendererCollection> _legacyRendererCollections(
  Object? root,
  List<String> rendererNames,
  _RendererVerifier verifier,
) {
  final candidates = <_RendererCollection>[];
  final seen = <Object>{};
  for (final map in _walkMaps(root)) {
    for (final key in const <String>['items', 'contents']) {
      final values = map[key];
      if (values is! List || !seen.add(values)) {
        continue;
      }
      final hasVerifiableRenderer = _directRenderers(<_RendererCollection>[
        values,
      ], rendererNames).any(verifier);
      if (hasVerifiableRenderer) {
        candidates.add(values);
      }
    }
  }
  return candidates;
}

bool _isVerifiablePlaylistSummary(Map<String, Object?> renderer) {
  return _playlistId(renderer) != null && _playlistTitle(renderer) != null;
}

bool _isVerifiablePlaylistEntry(Map<String, Object?> renderer) {
  return _entryVideoId(renderer) != null ||
      _firstStringForKeys(renderer, const <String>[
            'playlistSetVideoId',
            'setVideoId',
          ]) !=
          null;
}

bool _isVerifiableSubscribedArtist(Map<String, Object?> renderer) {
  return _artistBrowseId(renderer) != null && _artistTitle(renderer) != null;
}

List<String> _continuationTokensFromContainers(
  Iterable<Map<String, Object?>> containers,
) {
  final tokens = <String>{};
  for (final container in containers) {
    _addContinuationTokens(tokens, container['continuations']);
    for (final collection in <_RendererCollection>[
      ..._playlistEntryCollections(container),
      ..._savedPlaylistCollections(container),
      ..._subscribedArtistCollections(container),
    ]) {
      for (final value in collection) {
        final item = _asMap(value);
        final continuationItem = _asMap(item?['continuationItemRenderer']);
        if (continuationItem != null) {
          _addContinuationTokens(tokens, continuationItem);
        }
      }
    }
  }
  return List<String>.unmodifiable(tokens);
}

List<String> _continuationTokensFromCollections(
  Iterable<_RendererCollection> collections,
) {
  final tokens = <String>{};
  for (final collection in collections) {
    for (final value in collection) {
      final item = _asMap(value);
      final continuationItem = _asMap(item?['continuationItemRenderer']);
      if (continuationItem != null) {
        _addContinuationTokens(tokens, continuationItem);
      }
    }
  }
  return List<String>.unmodifiable(tokens);
}

void _addContinuationTokens(Set<String> tokens, Object? metadata) {
  // Walking is intentionally limited to a known continuation metadata node,
  // never the whole response or a song/playlist renderer.
  for (final map in _walkMaps(metadata)) {
    final continuationCommand = _asMap(map['continuationCommand']);
    final commandToken = _nonEmptyString(continuationCommand?['token']);
    if (commandToken != null) {
      tokens.add(commandToken);
    }
    for (final key in const <String>[
      'nextContinuationData',
      'reloadContinuationData',
    ]) {
      final data = _asMap(map[key]);
      final token = _nonEmptyString(data?['continuation']);
      if (token != null) {
        tokens.add(token);
      }
    }
  }
}

Map<String, Object?>? _asMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

Iterable<Map<String, Object?>> _walkMaps(Object? value) sync* {
  final map = _asMap(value);
  if (map != null) {
    yield map;
    for (final child in map.values) {
      yield* _walkMaps(child);
    }
    return;
  }
  if (value is List) {
    for (final child in value) {
      yield* _walkMaps(child);
    }
  }
}

Iterable<Map<String, Object?>> _renderers(
  Object? root,
  String rendererName,
) sync* {
  for (final map in _walkMaps(root)) {
    final renderer = _asMap(map[rendererName]);
    if (renderer != null) {
      yield renderer;
    }
  }
}

Map<String, Object?>? _firstRenderer(Object? root, String rendererName) {
  for (final renderer in _renderers(root, rendererName)) {
    return renderer;
  }
  return null;
}

String? _nonEmptyString(Object? value) {
  if (value is! String) {
    return null;
  }
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String? _text(Object? value) {
  final direct = _nonEmptyString(value);
  if (direct != null) {
    return direct;
  }
  final map = _asMap(value);
  if (map == null) {
    return null;
  }
  final simple = _nonEmptyString(map['simpleText']);
  if (simple != null) {
    return simple;
  }
  final runs = map['runs'];
  if (runs is List) {
    final buffer = StringBuffer();
    for (final runValue in runs) {
      final run = _asMap(runValue);
      final part = _nonEmptyString(run?['text']);
      if (part != null) {
        buffer.write(part);
      }
    }
    final combined = buffer.toString().trim();
    if (combined.isNotEmpty) {
      return combined;
    }
  }
  final directText = _nonEmptyString(map['text']);
  if (directText != null) {
    return directText;
  }
  for (final child in map.values) {
    final nested = _text(child);
    if (nested != null) {
      return nested;
    }
  }
  return null;
}

String? _firstText(Map<String, Object?> renderer, List<String> keys) {
  for (final key in keys) {
    final result = _text(renderer[key]);
    if (result != null) {
      return result;
    }
  }
  return null;
}

String? _firstStringForKeys(Object? root, List<String> keys) {
  for (final map in _walkMaps(root)) {
    for (final key in keys) {
      final value = _nonEmptyString(map[key]);
      if (value != null) {
        return value;
      }
    }
  }
  return null;
}

bool _boolForKeys(Object? root, List<String> keys) {
  for (final map in _walkMaps(root)) {
    for (final key in keys) {
      final value = map[key];
      if (value is bool) {
        return value;
      }
    }
  }
  return false;
}

bool _containsAnyKey(Object? root, Set<String> keys) {
  for (final map in _walkMaps(root)) {
    if (map.keys.any(keys.contains)) {
      return true;
    }
  }
  return false;
}

String? _thumbnailUrl(Object? root) {
  String? best;
  var bestArea = -1;
  for (final map in _walkMaps(root)) {
    final thumbnails = map['thumbnails'];
    if (thumbnails is! List) {
      continue;
    }
    for (final value in thumbnails) {
      final thumbnail = _asMap(value);
      final url = _nonEmptyString(thumbnail?['url']);
      if (url == null) {
        continue;
      }
      final width = thumbnail?['width'];
      final height = thumbnail?['height'];
      final area =
          (width is num ? width.toInt() : 0) *
          (height is num ? height.toInt() : 0);
      if (best == null || area >= bestArea) {
        best = url;
        bestArea = area;
      }
    }
  }
  return best;
}

String? _firstChannelId(Object? root) {
  for (final map in _walkMaps(root)) {
    final browseId = _nonEmptyString(map['browseId']);
    if (browseId != null && browseId.startsWith('UC')) {
      return browseId;
    }
    final channelId = _nonEmptyString(map['channelId']);
    if (channelId != null) {
      return channelId;
    }
  }
  return null;
}

String? _playlistId(Object? root) {
  for (final map in _walkMaps(root)) {
    final browseId = _nonEmptyString(map['browseId']);
    if (browseId != null && browseId.startsWith('VL')) {
      return canonicalPlaylistId(browseId);
    }
  }
  for (final map in _walkMaps(root)) {
    final playlistId = _nonEmptyString(map['playlistId']);
    if (playlistId != null &&
        !playlistId.startsWith('RD') &&
        !playlistId.startsWith('FE')) {
      return canonicalPlaylistId(playlistId);
    }
  }
  return null;
}

String? _playlistTitle(Map<String, Object?> renderer) {
  final direct = _firstText(renderer, const <String>['title', 'headline']);
  if (direct != null) {
    return direct;
  }
  final flexColumns = renderer['flexColumns'];
  if (flexColumns is List && flexColumns.isNotEmpty) {
    return _text(flexColumns.first);
  }
  return null;
}

String? _artistBrowseId(Map<String, Object?> renderer) {
  final directNavigation = _asMap(renderer['navigationEndpoint']);
  final directBrowse = _asMap(directNavigation?['browseEndpoint']);
  final directId = _nonEmptyString(directBrowse?['browseId']);
  final directPageType = _firstStringForKeys(directBrowse, const <String>[
    'pageType',
  ])?.toUpperCase();
  if (directId != null &&
      (directPageType?.contains('ARTIST') == true ||
          directId.startsWith('UC') ||
          directId.startsWith('MPLA'))) {
    return directId;
  }
  for (final map in _walkMaps(renderer)) {
    final browse = _asMap(map['browseEndpoint']);
    final browseId = _nonEmptyString(browse?['browseId']);
    if (browseId == null) continue;
    final pageType = _firstStringForKeys(browse, const <String>[
      'pageType',
    ])?.toUpperCase();
    if (pageType?.contains('ARTIST') == true ||
        browseId.startsWith('UC') ||
        browseId.startsWith('MPLA')) {
      return browseId;
    }
  }
  return null;
}

String? _artistTitle(Map<String, Object?> renderer) {
  final direct = _firstText(renderer, const <String>['title', 'headline']);
  if (direct != null) return direct;
  final flexColumns = renderer['flexColumns'];
  if (flexColumns is List && flexColumns.isNotEmpty) {
    return _text(flexColumns.first);
  }
  return null;
}

List<String> _metadataTexts(Object? renderer) {
  final values = <String>[];
  for (final map in _walkMaps(renderer)) {
    final runs = map['runs'];
    if (runs is! List) {
      continue;
    }
    for (final runValue in runs) {
      final run = _asMap(runValue);
      final value = _nonEmptyString(run?['text']);
      if (value != null && !values.contains(value)) {
        values.add(value);
      }
    }
  }
  return values;
}

int? _itemCount(List<String> metadata) {
  final pattern = RegExp(
    r'([0-9][0-9., ]*)\s*(?:songs?|canciones?|videos?)',
    caseSensitive: false,
  );
  for (final value in metadata) {
    final match = pattern.firstMatch(value);
    if (match == null) {
      continue;
    }
    final digits = match.group(1)!.replaceAll(RegExp(r'[^0-9]'), '');
    final count = int.tryParse(digits);
    if (count != null) {
      return count;
    }
  }
  return null;
}

RemotePlaylistVisibility _visibility(List<String> metadata) {
  final text = metadata.join(' ').toLowerCase();
  if (text.contains('private') || text.contains('privada')) {
    return RemotePlaylistVisibility.private;
  }
  if (text.contains('unlisted') || text.contains('no listada')) {
    return RemotePlaylistVisibility.unlisted;
  }
  if (text.contains('public') || text.contains('pública')) {
    return RemotePlaylistVisibility.public;
  }
  return RemotePlaylistVisibility.unknown;
}

String? _owner(Map<String, Object?> renderer, List<String> metadata) {
  final owner = _firstText(renderer, const <String>[
    'owner',
    'straplineTextOne',
  ]);
  if (owner != null) {
    return owner;
  }
  for (final map in _walkMaps(renderer)) {
    final browseId = _nonEmptyString(map['browseId']);
    if (browseId == null || !browseId.startsWith('UC')) {
      continue;
    }
    final text = _text(map);
    if (text != null) {
      return text;
    }
  }
  for (final value in metadata.skip(1)) {
    if (!RegExp(r'^\d').hasMatch(value) && value != ' • ') {
      return value;
    }
  }
  return null;
}

String? _entryVideoId(Object? renderer) {
  for (final map in _walkMaps(renderer)) {
    final playlistItemData = _asMap(map['playlistItemData']);
    final direct = _nonEmptyString(playlistItemData?['videoId']);
    if (direct != null) {
      return direct;
    }
  }
  return _firstStringForKeys(renderer, const <String>['videoId']);
}

String? _entryTitle(Map<String, Object?> renderer) {
  final direct = _firstText(renderer, const <String>['title']);
  if (direct != null) {
    return direct;
  }
  final flexColumns = renderer['flexColumns'];
  if (flexColumns is List && flexColumns.isNotEmpty) {
    return _text(flexColumns.first);
  }
  return null;
}

_EntryMetadata _entryMetadata(Map<String, Object?> renderer) {
  final artists = <String>[];
  final artistBrowseIds = <String?>[];
  String? album;
  for (final map in _walkMaps(renderer)) {
    final text = _nonEmptyString(map['text']);
    if (text == null) {
      continue;
    }
    final endpoint = _asMap(map['navigationEndpoint']);
    final browseEndpoint = _asMap(endpoint?['browseEndpoint']);
    final browseId = _nonEmptyString(browseEndpoint?['browseId']);
    final pageType = _firstStringForKeys(browseEndpoint, const <String>[
      'pageType',
    ])?.toUpperCase();
    if (browseId?.startsWith('UC') == true ||
        pageType?.contains('ARTIST') == true) {
      artists.add(text);
      artistBrowseIds.add(browseId);
    } else if (pageType?.contains('ALBUM') == true) {
      album ??= text;
    }
  }
  if (artists.isEmpty) {
    final flexColumns = renderer['flexColumns'];
    if (flexColumns is List && flexColumns.length > 1) {
      final fallback = _text(flexColumns[1]);
      if (fallback != null) {
        artists.addAll(
          fallback
              .split(RegExp(r'\s*[•·]\s*'))
              .where((part) => part.isNotEmpty && _parseDuration(part) == null)
              .take(1),
        );
        artistBrowseIds.addAll(List<String?>.filled(artists.length, null));
      }
    }
  }
  return (
    artists: List<String>.unmodifiable(artists),
    artistBrowseIds: List<String?>.unmodifiable(artistBrowseIds),
    album: album,
  );
}

Duration? _duration(Object? renderer) {
  for (final map in _walkMaps(renderer)) {
    final text = _text(map);
    final duration = _parseDuration(text);
    if (duration != null) {
      return duration;
    }
  }
  return null;
}

Duration? _parseDuration(String? value) {
  if (value == null || !RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$').hasMatch(value)) {
    return null;
  }
  final parts = value.split(':').map(int.parse).toList(growable: false);
  if (parts.any((part) => part < 0 || part > 59) ||
      (parts.length == 2 && parts.first > 59)) {
    return null;
  }
  final seconds = parts.length == 3
      ? parts[0] * 3600 + parts[1] * 60 + parts[2]
      : parts[0] * 60 + parts[1];
  return Duration(seconds: seconds);
}
