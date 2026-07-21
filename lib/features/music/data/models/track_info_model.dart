import '../../domain/entities/track_info.dart';

class TrackInfoModel extends TrackInfo {
  const TrackInfoModel({
    required super.id,
    required super.title,
    required super.artist,
    required super.url,
    super.thumbnailUrl,
    super.duration,
    super.streamUrl,
    super.extractor,
    super.album,
    super.viewCount,
    super.httpHeaders,
  });

  factory TrackInfoModel.fromJson(Map<String, dynamic> json) {
    return TrackInfoModel(
      id: _stringValue(json['id']) ?? _stringValue(json['display_id']) ?? '',
      title: _stringValue(json['title']) ?? 'Sin titulo',
      artist:
          _stringValue(json['artist']) ??
          _stringValue(json['uploader']) ??
          _stringValue(json['channel']) ??
          'Desconocido',
      url: _sourceUrl(json),
      thumbnailUrl: _thumbnailUrl(json),
      duration: _durationValue(json['duration']),
      streamUrl: _stringValue(json['streamUrl']) ?? _streamUrl(json),
      extractor:
          _stringValue(json['extractor']) ??
          _stringValue(json['extractor_key']) ??
          _stringValue(json['ie_key']),
      album: _stringValue(json['album']),
      viewCount: _intValue(json['view_count']),
      httpHeaders: _httpHeaders(json),
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
      'duration': duration?.inSeconds,
      'streamUrl': streamUrl,
      'extractor': extractor,
      'album': album,
      'view_count': viewCount,
      'http_headers': httpHeaders,
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
    if (requested is List && requested.isNotEmpty && requested.first is Map) {
      return _mapToStringMap((requested.first as Map)['http_headers']);
    }

    final requestedFormats = json['requested_formats'];
    final fromRequestedFormats = _headersFromFormats(requestedFormats);
    if (fromRequestedFormats != null) {
      return fromRequestedFormats;
    }

    return _headersFromFormats(json['formats']);
  }

  static Map<String, String>? _headersFromFormats(Object? formats) {
    if (formats is! List) {
      return null;
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

    final audioOnly = formats.whereType<Map>().where((format) {
      final acodec = _stringValue(format['acodec']);
      final vcodec = _stringValue(format['vcodec']);
      return acodec != null && acodec != 'none' && vcodec == 'none';
    }).toList();

    if (audioOnly.isNotEmpty) {
      audioOnly.sort((left, right) {
        final leftScore = _streamCompatibilityScore(left);
        final rightScore = _streamCompatibilityScore(right);
        if (leftScore != rightScore) {
          return rightScore.compareTo(leftScore);
        }
        final leftBitrate =
            _intValue(left['abr']) ?? _intValue(left['tbr']) ?? 0;
        final rightBitrate =
            _intValue(right['abr']) ?? _intValue(right['tbr']) ?? 0;
        if (leftBitrate == 0 || rightBitrate == 0) {
          return rightBitrate.compareTo(leftBitrate);
        }
        return leftBitrate.compareTo(rightBitrate);
      });
      return _stringValue(audioOnly.first['url']);
    }

    for (final format in formats.whereType<Map>()) {
      final url = _stringValue(format['url']);
      if (url != null && url.startsWith('http')) {
        return url;
      }
    }
    return null;
  }

  static int _streamCompatibilityScore(Map<dynamic, dynamic> format) {
    final ext = _stringValue(format['ext'])?.toLowerCase();
    final audioExt = _stringValue(format['audio_ext'])?.toLowerCase();
    final acodec = _stringValue(format['acodec'])?.toLowerCase() ?? '';
    final container = _stringValue(format['container'])?.toLowerCase() ?? '';
    final mime = _stringValue(format['mime_type'])?.toLowerCase() ?? '';

    if (ext == 'm4a' ||
        audioExt == 'm4a' ||
        acodec.startsWith('mp4a') ||
        container.contains('m4a') ||
        mime.contains('audio/mp4')) {
      return 3;
    }
    if (ext == 'mp3' || acodec.contains('mp3') || mime.contains('mpeg')) {
      return 2;
    }
    if (ext == 'webm' || acodec.contains('opus')) {
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
