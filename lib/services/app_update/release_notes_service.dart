import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lyrics/lyrics_translation_service.dart';
import 'github_release_checker.dart';

class LocalizedReleaseNotes {
  const LocalizedReleaseNotes({
    required this.items,
    this.translationFailed = false,
    this.translated = false,
  });

  final List<String> items;
  final bool translationFailed;
  final bool translated;
}

abstract interface class ReleaseNotesCache {
  Future<List<String>?> read(String key);

  Future<void> write(String key, List<String> items);
}

/// Only successful translations are persisted. Updating the release body or
/// switching languages creates a different cache key, even for the same tag.
class SharedPreferencesReleaseNotesCache implements ReleaseNotesCache {
  SharedPreferencesReleaseNotesCache({
    this.maximumEntries = 12,
    this.maximumCharacters = 180000,
  }) : assert(maximumEntries > 0),
       assert(maximumCharacters > 0);

  static const preferenceKey = 'app.update.releaseNotes.translations.v1';

  final int maximumEntries;
  final int maximumCharacters;
  Future<void> _writes = Future<void>.value();

  @override
  Future<List<String>?> read(String key) async {
    try {
      await _writes;
      final preferences = await SharedPreferences.getInstance();
      final entries = _decode(preferences.getString(preferenceKey));
      for (final entry in entries) {
        if (entry.key == key) return entry.value;
      }
    } catch (_) {
      // Persistent storage must never prevent an update notification.
    }
    return null;
  }

  @override
  Future<void> write(String key, List<String> items) {
    final completion = _writes.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        final entries = _decode(preferences.getString(preferenceKey))
          ..removeWhere((entry) => entry.key == key)
          ..add(MapEntry(key, List<String>.of(items)));
        while (entries.length > maximumEntries) {
          entries.removeAt(0);
        }
        String encode() => jsonEncode([
          for (final entry in entries) {'key': entry.key, 'items': entry.value},
        ]);
        var encoded = encode();
        while (encoded.length > maximumCharacters && entries.isNotEmpty) {
          entries.removeAt(0);
          encoded = encode();
        }
        await preferences.setString(preferenceKey, encoded);
      } catch (_) {
        // A full or unavailable preference store is just a cache miss.
      }
    });
    _writes = completion;
    return completion;
  }

  List<MapEntry<String, List<String>>> _decode(String? encoded) {
    if (encoded == null || encoded.length > maximumCharacters) return [];
    Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      return [];
    }
    if (decoded is! List) return [];
    return [
      for (final entry in decoded.take(maximumEntries))
        if (entry is Map &&
            entry['key'] is String &&
            (entry['key']! as String).length == 64 &&
            entry['items'] is List &&
            (entry['items']! as List).length <= 200 &&
            (entry['items']! as List).every(
              (item) => item is String && item.trim().isNotEmpty,
            ))
          MapEntry(
            entry['key']! as String,
            List<String>.unmodifiable(entry['items']! as List),
          ),
    ];
  }
}

/// Release notes are translated only when requested by the update dialog.
/// There is no polling or prefetch. The existing anonymous translation
/// transport is fallible, so every error returns the original GitHub notes.
class ReleaseNotesService {
  ReleaseNotesService({
    LyricsTranslationSession Function()? sessionFactory,
    ReleaseNotesCache? cache,
    this.maximumCacheEntries = 12,
    this.maximumSourceCharacters = 24000,
    this.maximumBatchBytes = 1600,
    this.maximumRequests = 40,
    this.requestTimeout = const Duration(seconds: 15),
    this.totalTimeout = const Duration(seconds: 60),
  }) : assert(maximumCacheEntries > 0),
       assert(maximumSourceCharacters > 0),
       assert(maximumBatchBytes >= 8),
       assert(maximumRequests > 0),
       _sessionFactory = sessionFactory ?? GoogleLyricsTranslationSession.new,
       _persistentCache = cache ?? SharedPreferencesReleaseNotesCache();

  final LyricsTranslationSession Function() _sessionFactory;
  final ReleaseNotesCache _persistentCache;
  final int maximumCacheEntries;
  final int maximumSourceCharacters;
  final int maximumBatchBytes;
  final int maximumRequests;
  final Duration requestTimeout;
  final Duration totalTimeout;

  final _cache = <String, LocalizedReleaseNotes>{};
  final _inFlight = <String, Future<LocalizedReleaseNotes>>{};
  final _sessions = <LyricsTranslationSession>{};
  bool _disposed = false;

  LocalizedReleaseNotes original(
    AppReleaseCheckResult release, {
    required String languageCode,
  }) => LocalizedReleaseNotes(
    items: _parseNotes(release.releaseNotes, _language(languageCode)).items,
  );

  Future<LocalizedReleaseNotes> load(
    AppReleaseCheckResult release, {
    required String languageCode,
  }) {
    final language = _language(languageCode);
    final notes = _parseNotes(release.releaseNotes, language);
    final original = LocalizedReleaseNotes(items: notes.items);
    if (notes.items.isEmpty || notes.language == language) {
      return Future.value(original);
    }
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([1, release.releaseTag, release.releaseNotes, language]),
          ),
        )
        .toString();
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return Future.value(cached);
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;
    late final Future<LocalizedReleaseNotes> request;
    request = _load(key, notes, language)
        .then((result) {
          if (!_disposed && !result.translationFailed) {
            _cache[key] = result;
            while (_cache.length > maximumCacheEntries) {
              _cache.remove(_cache.keys.first);
            }
          }
          return result;
        })
        .whenComplete(() {
          if (identical(_inFlight[key], request)) _inFlight.remove(key);
        });
    _inFlight[key] = request;
    return request;
  }

  Future<LocalizedReleaseNotes> _load(
    String key,
    _ParsedNotes notes,
    String language,
  ) async {
    final original = LocalizedReleaseNotes(items: notes.items);
    LyricsTranslationSession? session;
    var active = true;
    var requests = 0;
    try {
      if (_disposed || !_supportedLanguages.contains(language)) {
        throw const LyricsTranslationException();
      }
      List<String>? cached;
      try {
        cached = await _persistentCache
            .read(key)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // Persistence is optional; the network path remains available.
      }
      if (cached != null && cached.isNotEmpty && !_disposed) {
        return LocalizedReleaseNotes(
          items: List.unmodifiable(cached),
          translated: true,
        );
      }
      final source = notes.items.join('\n');
      if (source.length > maximumSourceCharacters || notes.items.length > 200) {
        throw const LyricsTranslationException();
      }
      session = _sessionFactory();
      _sessions.add(session);
      Future<Map<String, dynamic>> request(
        String text, {
        bool detectOnly = false,
      }) {
        if (!active || _disposed || requests >= maximumRequests) {
          throw const LyricsTranslationCancelled();
        }
        requests++;
        return session!
            .request(text, language, detectOnly: detectOnly)
            .timeout(requestTimeout);
      }

      final translated = await (() async {
        if (notes.language == null) {
          final detection = await request(
            String.fromCharCodes(
              _chunks(source, maximumBatchBytes).first.runes.take(800),
            ),
            detectOnly: true,
          );
          final sourceLanguage = detection['src'];
          if (sourceLanguage is! String || sourceLanguage.trim().isEmpty) {
            throw const LyricsTranslationException();
          }
          if (_language(sourceLanguage) == language) return original;
        }
        final chunks = <({int item, String text})>[];
        for (var index = 0; index < notes.items.length; index++) {
          for (final chunk in _chunks(notes.items[index], maximumBatchBytes)) {
            chunks.add((item: index, text: chunk));
          }
        }
        final translations = List.generate(
          notes.items.length,
          (_) => <String>[],
        );
        var batch = <({int item, String text})>[];
        var byteCount = 0;
        Future<void> flush() async {
          if (batch.isEmpty) return;
          final response = await request(
            batch.map((chunk) => chunk.text).join('\n'),
          );
          final output = _translatedText(response).split('\n');
          if (output.length == batch.length &&
              output.every((line) => line.trim().isNotEmpty)) {
            for (var index = 0; index < batch.length; index++) {
              translations[batch[index].item].add(output[index].trim());
            }
          } else {
            // A merged response must not shift text to a different bullet.
            // Fall back serially and keep the global request/time limits.
            for (final chunk in batch) {
              translations[chunk.item].add(
                _translatedText(
                  await request(chunk.text),
                ).replaceAll('\n', ' ').trim(),
              );
            }
          }
          batch = [];
          byteCount = 0;
        }

        for (final chunk in chunks) {
          final size = utf8.encode(chunk.text).length;
          if (batch.isNotEmpty && byteCount + size + 1 > maximumBatchBytes) {
            await flush();
          }
          batch.add(chunk);
          byteCount += size + 1;
        }
        await flush();
        if (!active || _disposed) throw const LyricsTranslationCancelled();
        return LocalizedReleaseNotes(
          items: List.unmodifiable(
            translations.map((parts) => parts.join(' ').trim()),
          ),
          translated: true,
        );
      })().timeout(totalTimeout);
      if (!active || _disposed) throw const LyricsTranslationCancelled();
      if (translated.translated) {
        try {
          await _persistentCache
              .write(key, translated.items)
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          // A cache failure cannot discard a successful translation.
        }
      }
      return translated;
    } catch (_) {
      return LocalizedReleaseNotes(items: notes.items, translationFailed: true);
    } finally {
      active = false;
      session?.close();
      _sessions.remove(session);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final session in _sessions) {
      session.close();
    }
    _sessions.clear();
    _cache.clear();
    _inFlight.clear();
  }
}

const _supportedLanguages = {'es', 'en', 'pt', 'fr', 'ko', 'zh', 'ja'};

String _language(String value) =>
    value.toLowerCase().split(RegExp('[-_]')).first;

String _translatedText(Map<String, dynamic> response) {
  final sentences = response['sentences'];
  if (sentences is! List || sentences.isEmpty) {
    throw const LyricsTranslationException();
  }
  final buffer = StringBuffer();
  for (final sentence in sentences) {
    if (sentence is! Map || sentence['trans'] is! String) {
      throw const LyricsTranslationException();
    }
    buffer.write(sentence['trans']);
  }
  final text = buffer.toString().replaceAll('\r\n', '\n').trim();
  if (text.isEmpty) throw const LyricsTranslationException();
  return text;
}

/// Keep UTF-8 request sizes bounded even for CJK text or a very long bullet.
/// Prefer a word boundary but do not require whitespace (e.g. Japanese).
Iterable<String> _chunks(String text, int maximumBytes) sync* {
  var remaining = text.trim();
  while (utf8.encode(remaining).length > maximumBytes) {
    final runes = remaining.runes;
    var bytes = 0;
    var codeUnits = 0;
    var lastSpace = -1;
    for (final rune in runes) {
      final character = String.fromCharCode(rune);
      final length = utf8.encode(character).length;
      if (bytes + length > maximumBytes) break;
      bytes += length;
      codeUnits += character.length;
      if (character == ' ') lastSpace = codeUnits - 1;
    }
    final cut = lastSpace > codeUnits ~/ 2 ? lastSpace : codeUnits;
    yield remaining.substring(0, cut).trim();
    remaining = remaining.substring(cut).trim();
  }
  if (remaining.isNotEmpty) yield remaining;
}

class _ParsedNotes {
  const _ParsedNotes(this.items, this.language);

  final List<String> items;
  final String? language;
}

_ParsedNotes _parseNotes(String body, String language) {
  // GitHub bodies can also contain arbitrary HTML and badge/download markup.
  // None of it is rendered as HTML; remove non-notes before plain text parsing.
  var markdown = body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(
        RegExp(
          r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^\n]*?\)'), '')
      .replaceAll(RegExp(r'!\[[^\]]*\]\[[^\]]*\]'), '')
      .replaceAll(RegExp(r'^\s*\[[^\]]+\]:.*$', multiLine: true), '')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  final localized = <String, List<String>>{};
  String? section;
  for (final line in markdown.split('\n')) {
    final heading = RegExp(r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(line);
    final headingLanguage = heading == null
        ? null
        : _headingLanguage(_plainText(heading.group(1)!));
    if (headingLanguage != null) {
      section = headingLanguage;
      localized.putIfAbsent(section, () => []);
    } else if (section != null) {
      localized[section]!.add(line);
    }
  }
  String? sourceLanguage;
  if (localized.isNotEmpty) {
    sourceLanguage = localized.containsKey(language)
        ? language
        : localized.containsKey('en')
        ? 'en'
        : localized.keys.first;
    markdown = localized[sourceLanguage]!.join('\n');
  }
  final items = <String>[];
  var paragraph = <String>[];
  var fenced = false;
  void flush() {
    final text = _plainText(paragraph.join(' '));
    if (text.isNotEmpty && !_isNotesHeading(text)) items.add(text);
    paragraph = [];
  }

  for (final line in markdown.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      flush();
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    if (trimmed.isEmpty ||
        RegExp(r'^#{1,6}\s').hasMatch(trimmed) ||
        RegExp(r'^[-*_]{3,}$').hasMatch(trimmed)) {
      flush();
      continue;
    }
    final bullet = RegExp(r'^\s*(?:[-*+•]|\d+[.)])\s+(.*)$').firstMatch(line);
    if (bullet != null) {
      flush();
      final content = bullet
          .group(1)!
          .replaceFirst(RegExp(r'^\[[ xX]\]\s*'), '');
      paragraph.add(content);
    } else {
      paragraph.add(trimmed);
    }
  }
  flush();
  return _ParsedNotes(List.unmodifiable(items), sourceLanguage);
}

String _plainText(String value) => value
    .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^\n]*?\)'), (match) => match[1]!)
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\[[^\]]*\]'), (match) => match[1]!)
    .replaceAll(RegExp(r'[*_~`]'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _isNotesHeading(String text) => RegExp(
  r'^(?:v?\d+(?:\.\d+){1,3}(?:[-+][\w.-]+)?|'
  r'(?:bstream(?: music)?\s*)?(?:release notes|what.?s (?:new|changed)|'
  r'changelog|novedades|notas de (?:la versi[oó]n|lanzamiento)|'
  r'novidades|nouveaut[eé]s)\s*[:\-–]?\s*v?\d*(?:\.\d+)*)$',
  caseSensitive: false,
).hasMatch(text);

String? _headingLanguage(String value) {
  final name = value
      .toLowerCase()
      .replaceAll(RegExp(r'[\u{1F1E6}-\u{1F1FF}]', unicode: true), '')
      .replaceAll(
        RegExp(r'^(?:release notes|novedades|notes)\s*[-:–(]*\s*'),
        '',
      )
      .replaceAll(RegExp(r'[():\[\]]'), '')
      .trim();
  return switch (name) {
    'en' || 'english' => 'en',
    'es' || 'español' || 'espanol' || 'spanish' => 'es',
    'pt' ||
    'português' ||
    'portugues' ||
    'portuguese' ||
    'português brasil' => 'pt',
    'fr' || 'français' || 'francais' || 'french' => 'fr',
    'ko' || '한국어' || 'korean' => 'ko',
    'zh' || '中文' || '简体中文' || '繁體中文' || 'chinese' => 'zh',
    'ja' || '日本語' || 'japanese' => 'ja',
    _ => null,
  };
}
