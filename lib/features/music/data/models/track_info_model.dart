import '../../domain/entities/track_info.dart';

class TrackInfoModel extends TrackInfo {
  const TrackInfoModel({
    required super.id,
    required super.title,
    required super.artist,
    required super.url,
    super.thumbnailUrl,
    super.catalogThumbnailUrl,
    super.duration,
    super.streamUrl,
    super.streamExtension,
    super.streamMimeType,
    super.streamSource,
    super.streamFormatId,
    super.streamCodec,
    super.extractor,
    super.album,
    super.viewCount,
    super.httpHeaders,
    super.artists,
    super.metadataSource,
  });

  factory TrackInfoModel.fromJson(Map<String, dynamic> json) {
    final artistNames = _stringListValues(json['artists']);
    final metadataSource = _metadataSource(json['metadata_source']);
    final artist =
        (metadataSource == TrackMetadataSource.youtubeMusic &&
                artistNames.isNotEmpty
            ? artistNames.join(', ')
            : _stringValue(json['artist'])) ??
        (artistNames.isEmpty ? null : artistNames.join(', ')) ??
        _stringValue(json['creator']) ??
        _stringValue(json['uploader']) ??
        _stringValue(json['channel']) ??
        'Desconocido';
    return TrackInfoModel(
      id: _stringValue(json['id']) ?? _stringValue(json['display_id']) ?? '',
      title:
          _stringValue(json['track']) ??
          _stringValue(json['title']) ??
          'Sin titulo',
      artist: artist,
      url: _sourceUrl(json),
      thumbnailUrl: _thumbnailUrl(json),
      catalogThumbnailUrl: _stringValue(json['catalog_thumbnail']),
      duration: _durationValue(json['duration']),
      streamUrl: _stringValue(json['streamUrl']) ?? _streamUrl(json),
      streamExtension: _streamExtension(json),
      streamMimeType: _streamMimeType(json),
      streamSource: _stringValue(json['stream_source']),
      streamFormatId:
          _stringValue(json['stream_format_id']) ??
          _stringValue(_selectedStreamFormat(json)?['format_id']) ??
          _stringValue(json['format_id']),
      streamCodec:
          _stringValue(json['stream_codec']) ??
          _stringValue(_selectedStreamFormat(json)?['acodec']) ??
          _stringValue(json['acodec']),
      extractor:
          _stringValue(json['extractor']) ??
          _stringValue(json['extractor_key']) ??
          _stringValue(json['ie_key']),
      album: _stringValue(json['album']),
      viewCount: _intValue(json['view_count']),
      httpHeaders: _httpHeaders(json),
      artists: artistNames.isNotEmpty
          ? List.unmodifiable(artistNames)
          : artist == 'Desconocido'
          ? const []
          : [artist],
      metadataSource: metadataSource,
    );
  }

  factory TrackInfoModel.fromMethodChannel(Map<Object?, Object?> value) {
    return TrackInfoModel.fromJson(
      value.map((key, data) => MapEntry(key.toString(), data)),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'url': url,
      'thumbnail': thumbnailUrl,
      'catalog_thumbnail': catalogThumbnailUrl,
      'duration': duration?.inSeconds,
      'streamUrl': streamUrl,
      'stream_extension': streamExtension,
      'stream_mime_type': streamMimeType,
      'stream_source': streamSource,
      'stream_format_id': streamFormatId,
      'stream_codec': streamCodec,
      'extractor': extractor,
      'album': album,
      'view_count': viewCount,
      'http_headers': httpHeaders,
      'artists': artists,
      'metadata_source': metadataSource.name,
    };
  }

  static String _sourceUrl(Map<String, dynamic> json) {
    final webpageUrl = _stringValue(json['webpage_url']);
    if (webpageUrl != null && webpageUrl.startsWith('http')) {
      return webpageUrl;
    }

    final originalUrl = _stringValue(json['original_url']);
    if (originalUrl != null && originalUrl.startsWith('http')) {
      return originalUrl;
    }

    final url = _stringValue(json['url']);
    if (url != null && url.startsWith('http')) {
      return url;
    }

    final id = _stringValue(json['id']) ?? url;
    final extractor =
        (_stringValue(json['extractor_key']) ??
                _stringValue(json['ie_key']) ??
                _stringValue(json['extractor']) ??
                '')
            .toLowerCase();

    if (id != null && extractor.contains('youtube')) {
      return 'https://www.youtube.com/watch?v=$id';
    }

    return id ?? '';
  }

  static bool _looksLikeWebpage(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    return host == 'youtube.com' ||
        host == 'www.youtube.com' ||
        host == 'music.youtube.com' ||
        host == 'youtu.be' ||
        host.endsWith('.youtube.com');
  }

  static String? _streamUrl(Map<String, dynamic> json) {
    final requested = json['requested_downloads'];
    if (requested is List && requested.isNotEmpty && requested.first is Map) {
      return _audioFormatUrl(requested) ??
          _stringValue((requested.first as Map)['url']);
    }

    final requestedFormats = json['requested_formats'];
    final requestedFormatUrl = _audioFormatUrl(requestedFormats);
    if (requestedFormatUrl != null) {
      return requestedFormatUrl;
    }

    final url = _stringValue(json['url']);
    if (url != null && url.startsWith('http') && !_looksLikeWebpage(url)) {
      return url;
    }

    final formatUrl = _audioFormatUrl(json['formats']);
    if (formatUrl != null) {
      return formatUrl;
    }

    return null;
  }

  static Map<String, String>? _httpHeaders(Map<String, dynamic> json) {
    final direct = _mapToStringMap(json['http_headers']);
    if (direct != null) {
      return direct;
    }

    final requested = json['requested_downloads'];
    final fromRequested = _headersFromFormats(requested);
    if (fromRequested != null) {
      return fromRequested;
    }

    final requestedFormats = json['requested_formats'];
    final fromRequestedFormats = _headersFromFormats(requestedFormats);
    if (fromRequestedFormats != null) {
      return fromRequestedFormats;
    }

    return _headersFromFormats(json['formats']);
  }

  static String? _streamExtension(Map<String, dynamic> json) {
    final direct = _normalizeExtension(
      _stringValue(json['stream_extension']) ??
          _stringValue(json['audio_ext']) ??
          _stringValue(json['ext']),
    );
    if (direct != null) {
      return direct;
    }

    final format = _selectedStreamFormat(json);
    return _normalizeExtension(
      _stringValue(format?['audio_ext']) ?? _stringValue(format?['ext']),
    );
  }

  static String? _streamMimeType(Map<String, dynamic> json) {
    final direct =
        _stringValue(json['stream_mime_type']) ??
        _stringValue(json['mime_type']);
    if (direct != null) {
      return direct.toLowerCase();
    }

    final formatMime = _stringValue(_selectedStreamFormat(json)?['mime_type']);
    if (formatMime != null) {
      return formatMime.toLowerCase();
    }

    return _mimeTypeForExtension(_streamExtension(json));
  }

  static Map<dynamic, dynamic>? _selectedStreamFormat(
    Map<String, dynamic> json,
  ) {
    for (final key in const ['requested_downloads', 'requested_formats']) {
      final formats = json[key];
      if (formats is! List) {
        continue;
      }
      final preferred = _preferredAudioFormat(formats);
      if (preferred != null) {
        return preferred;
      }
      for (final format in formats.whereType<Map>()) {
        if (_stringValue(format['url'])?.startsWith('http') == true) {
          return format;
        }
      }
    }

    final formats = json['formats'];
    if (formats is List) {
      return _preferredAudioFormat(formats);
    }
    return null;
  }

  static String? _normalizeExtension(String? extension) {
    final value = extension?.trim().toLowerCase().replaceFirst('.', '');
    return value == null || value.isEmpty ? null : value;
  }

  static String? _mimeTypeForExtension(String? extension) {
    return switch (extension) {
      'm4a' || 'mp4' => 'audio/mp4',
      'aac' => 'audio/aac',
      'mp3' => 'audio/mpeg',
      'webm' || 'weba' => 'audio/webm',
      'ogg' || 'oga' => 'audio/ogg',
      'opus' => 'audio/opus',
      'flac' => 'audio/flac',
      '3gp' || '3gpp' => 'audio/3gpp',
      'm3u8' => 'application/vnd.apple.mpegurl',
      'wav' => 'audio/wav',
      _ => null,
    };
  }

  static Map<String, String>? _headersFromFormats(Object? formats) {
    if (formats is! List) {
      return null;
    }
    final preferredHeaders = _mapToStringMap(
      _preferredAudioFormat(formats)?['http_headers'],
    );
    if (preferredHeaders != null) {
      return preferredHeaders;
    }
    for (final format in formats.whereType<Map>()) {
      final headers = _mapToStringMap(format['http_headers']);
      if (headers != null) {
        return headers;
      }
    }
    return null;
  }

  static Map<String, String>? _mapToStringMap(Object? value) {
    if (value is! Map) {
      return null;
    }
    final entries = value.entries
        .where((entry) => entry.key != null && entry.value != null)
        .map((entry) => MapEntry(entry.key.toString(), entry.value.toString()));
    final map = Map<String, String>.fromEntries(entries);
    return map.isEmpty ? null : map;
  }

  static String? _audioFormatUrl(Object? formats) {
    if (formats is! List) {
      return null;
    }

    final preferredUrl = _stringValue(_preferredAudioFormat(formats)?['url']);
    if (preferredUrl != null) {
      return preferredUrl;
    }

    for (final format in formats.whereType<Map>()) {
      final url = _stringValue(format['url']);
      if (url != null && url.startsWith('http')) {
        return url;
      }
    }
    return null;
  }

  static Map<dynamic, dynamic>? _preferredAudioFormat(List<dynamic> formats) {
    final audioOnly = formats.whereType<Map>().where((format) {
      final acodec = _stringValue(format['acodec']);
      final vcodec = _stringValue(format['vcodec']);
      return acodec != null && acodec != 'none' && vcodec == 'none';
    }).toList();

    if (audioOnly.isNotEmpty) {
      audioOnly.sort((left, right) {
        final leftScore = _nativeAudioPreferenceScore(left);
        final rightScore = _nativeAudioPreferenceScore(right);
        if (leftScore != rightScore) {
          return rightScore.compareTo(leftScore);
        }
        final leftBitrate =
            _intValue(left['abr']) ?? _intValue(left['tbr']) ?? 0;
        final rightBitrate =
            _intValue(right['abr']) ?? _intValue(right['tbr']) ?? 0;
        return rightBitrate.compareTo(leftBitrate);
      });
      return audioOnly.first;
    }
    return null;
  }

  static int _nativeAudioPreferenceScore(Map<dynamic, dynamic> format) {
    final ext = _stringValue(format['ext'])?.toLowerCase();
    final audioExt = _stringValue(format['audio_ext'])?.toLowerCase();
    final acodec = _stringValue(format['acodec'])?.toLowerCase() ?? '';
    final container = _stringValue(format['container'])?.toLowerCase() ?? '';
    final mime = _stringValue(format['mime_type'])?.toLowerCase() ?? '';

    if (ext == 'm4a' ||
        audioExt == 'm4a' ||
        acodec.startsWith('mp4a') ||
        acodec.startsWith('aac') ||
        ext == 'aac' ||
        audioExt == 'aac' ||
        container.contains('m4a') ||
        mime.contains('audio/mp4') ||
        mime.contains('audio/aac')) {
      return 1;
    }
    return 0;
  }

  static String? _thumbnailUrl(Map<String, dynamic> json) {
    final direct = _stringValue(json['thumbnail']);
    if (direct != null) {
      return direct;
    }

    final thumbnails = json['thumbnails'];
    if (thumbnails is! List || thumbnails.isEmpty) {
      return null;
    }

    final candidates = thumbnails
        .whereType<Map>()
        .map((thumbnail) {
          final url = _stringValue(thumbnail['url']);
          final width = _intValue(thumbnail['width']) ?? 0;
          final height = _intValue(thumbnail['height']) ?? 0;
          return (url: url, area: width * height);
        })
        .where((thumbnail) => thumbnail.url != null)
        .toList();

    if (candidates.isEmpty) {
      return null;
    }

    candidates.sort((left, right) => right.area.compareTo(left.area));
    return candidates.first.url;
  }

  static String? _stringValue(Object? value) {
    if (value == null) {
      return null;
    }
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static List<String> _stringListValues(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value.map(_stringValue).whereType<String>().toList(growable: false);
  }

  static TrackMetadataSource _metadataSource(Object? value) {
    return switch (_stringValue(value)) {
      'youtubeMusic' || 'youtube_music' => TrackMetadataSource.youtubeMusic,
      _ => TrackMetadataSource.youtube,
    };
  }

  static Duration? _durationValue(Object? value) {
    if (value == null) {
      return null;
    }
    final seconds = value is num
        ? value.round()
        : int.tryParse(value.toString());
    if (seconds == null || seconds <= 0) {
      return null;
    }
    return Duration(seconds: seconds);
  }

  static int? _intValue(Object? value) {
    if (value == null) {
      return null;
    }
    return value is num ? value.toInt() : int.tryParse(value.toString());
  }
}
