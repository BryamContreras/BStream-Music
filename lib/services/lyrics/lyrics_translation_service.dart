import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/utils/bounded_byte_stream.dart';
import '../../features/music/domain/entities/lyrics_document.dart';

class TranslatedLyricsView {
  const TranslatedLyricsView({
    required this.syncedLines,
    required this.plainLyrics,
    required this.sourceLanguage,
    required this.alreadyInTargetLanguage,
  });

  final List<String> syncedLines;
  final String? plainLyrics;
  final String sourceLanguage;
  final bool alreadyInTargetLanguage;
}

class LyricsTranslationException implements Exception {
  const LyricsTranslationException();
}

class LyricsTranslationCancelled implements Exception {
  const LyricsTranslationCancelled();
}

abstract class LyricsTranslationSession {
  Future<Map<String, dynamic>> request(
    String text,
    String targetLanguage, {
    bool detectOnly = false,
  });

  void close();
}

/// Anonymous Google Translate web interface, not the paid Cloud Translation
/// API. Its response format and availability are not guaranteed. Callers must
/// retain the original lyrics on any network, quota, or parsing failure.
class GoogleLyricsTranslationSession implements LyricsTranslationSession {
  GoogleLyricsTranslationSession({HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 6);
  }

  final HttpClient _client;
  bool _closed = false;

  @override
  Future<Map<String, dynamic>> request(
    String text,
    String targetLanguage, {
    bool detectOnly = false,
  }) async {
    if (_closed) throw const LyricsTranslationCancelled();
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': targetLanguage,
      'dj': '1',
      'dt': detectOnly ? 'ld' : 't',
      'q': text,
    });
    HttpClientRequest? activeRequest;
    try {
      return await (() async {
        final request = await _client.getUrl(uri);
        activeRequest = request;
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw const LyricsTranslationException();
        }
        final bytes = await collectBoundedByteStream(
          response,
          maximumBytes: 256 * 1024,
          declaredLength: response.contentLength < 0
              ? null
              : response.contentLength,
          idleTimeout: const Duration(seconds: 10),
          totalTimeout: const Duration(seconds: 15),
        );
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, dynamic>) {
          throw const LyricsTranslationException();
        }
        return value;
      })().timeout(const Duration(seconds: 15));
    } on TimeoutException catch (error) {
      activeRequest?.abort(error);
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

class LyricsTranslationRequest {
  final _result = Completer<TranslatedLyricsView>();
  final _cancellation = Completer<void>();
  LyricsTranslationSession? _session;
  bool _cancelled = false;

  Future<TranslatedLyricsView> get result => _result.future;

  void cancel() {
    if (_result.isCompleted) return;
    _cancelled = true;
    _cancellation.complete();
    _session?.close();
    _result.completeError(const LyricsTranslationCancelled());
  }

  void _checkActive() {
    if (_cancelled) throw const LyricsTranslationCancelled();
  }
}

/// Fetches only on demand, serializes small batches, and keeps eight completed
/// documents in RAM. No polling, background prefetch, or persisted lyric text.
class LyricsTranslationService {
  LyricsTranslationService({
    LyricsTranslationSession Function()? sessionFactory,
    this.maximumCacheEntries = 8,
    this.maximumBatchBytes = 1600,
  }) : assert(maximumCacheEntries > 0),
       assert(maximumBatchBytes > 0),
       _sessionFactory = sessionFactory ?? GoogleLyricsTranslationSession.new;

  final LyricsTranslationSession Function() _sessionFactory;
  final int maximumCacheEntries;
  final int maximumBatchBytes;
  final _cache = <String, TranslatedLyricsView>{};
  final _active = <LyricsTranslationRequest>{};
  bool _disposed = false;

  LyricsTranslationRequest translateDocument(
    LyricsDocument document, {
    required String targetLanguage,
  }) {
    final request = LyricsTranslationRequest();
    final sourceLines = document.lines.isNotEmpty
        ? document.lines.map((line) => line.text).toList()
        : (document.plainLyrics ?? '').replaceAll('\r\n', '\n').split('\n');
    final key = sha256
        .convert(utf8.encode(jsonEncode([targetLanguage, sourceLines])))
        .toString();
    final cached = _cache.remove(key);
    if (cached != null && !_disposed) {
      _cache[key] = cached;
      request._result.complete(_viewFor(document, cached));
      return request;
    }
    _active.add(request);
    unawaited(() async {
      try {
        if (_disposed || !{'es', 'en'}.contains(targetLanguage)) {
          throw const LyricsTranslationException();
        }
        final view = await Future.any([
          _translate(request, sourceLines, targetLanguage),
          request._cancellation.future.then<TranslatedLyricsView>(
            (_) => throw const LyricsTranslationCancelled(),
          ),
        ]).timeout(const Duration(seconds: 90));
        request._checkActive();
        _cache[key] = view;
        while (_cache.length > maximumCacheEntries) {
          _cache.remove(_cache.keys.first);
        }
        if (!request._result.isCompleted) {
          request._result.complete(_viewFor(document, view));
        }
      } catch (error, stack) {
        if (!request._result.isCompleted) {
          request._result.completeError(error, stack);
        }
      } finally {
        request._cancelled = true;
        request._session?.close();
        _active.remove(request);
      }
    }());
    return request;
  }

  TranslatedLyricsView _viewFor(
    LyricsDocument document,
    TranslatedLyricsView cached,
  ) => TranslatedLyricsView(
    syncedLines: document.lines.isNotEmpty ? cached.syncedLines : const [],
    plainLyrics: document.lines.isEmpty ? cached.syncedLines.join('\n') : null,
    sourceLanguage: cached.sourceLanguage,
    alreadyInTargetLanguage: cached.alreadyInTargetLanguage,
  );

  Future<TranslatedLyricsView> _translate(
    LyricsTranslationRequest request,
    List<String> sourceLines,
    String targetLanguage,
  ) async {
    final texts = LinkedHashSet<String>.from(
      sourceLines.map((line) => line.trim()).where((line) => line.isNotEmpty),
    );
    final source = texts.join('\n');
    if (source.length > 30000 || sourceLines.length > 600) {
      throw const LyricsTranslationException();
    }
    if (texts.isEmpty) {
      return const TranslatedLyricsView(
        syncedLines: [],
        plainLyrics: null,
        sourceLanguage: '',
        alreadyInTargetLanguage: true,
      );
    }
    request._checkActive();
    final session = request._session = _sessionFactory();
    final detection = await session.request(
      String.fromCharCodes(source.runes.take(1000)),
      targetLanguage,
      detectOnly: true,
    );
    request._checkActive();
    final sourceLanguage = detection['src'];
    if (sourceLanguage is! String || sourceLanguage.isEmpty) {
      throw const LyricsTranslationException();
    }
    if (sourceLanguage.split('-').first == targetLanguage) {
      return TranslatedLyricsView(
        syncedLines: List.unmodifiable(sourceLines),
        plainLyrics: null,
        sourceLanguage: sourceLanguage,
        alreadyInTargetLanguage: true,
      );
    }
    final translations = <String, String>{};
    var batch = <String>[];
    var byteCount = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      request._checkActive();
      final response = await session.request(batch.join('\n'), targetLanguage);
      request._checkActive();
      final lines = _translatedText(response).split('\n');
      if (lines.length == batch.length &&
          lines.every((line) => line.trim().isNotEmpty)) {
        for (var index = 0; index < batch.length; index++) {
          translations[batch[index]] = lines[index].trim();
        }
      } else {
        // Never shift a translation onto another timestamp if the service
        // merges or inserts line breaks. Fall back serially, not in a burst.
        for (final line in batch) {
          request._checkActive();
          final response = await session.request(line, targetLanguage);
          request._checkActive();
          translations[line] = _translatedText(
            response,
          ).replaceAll('\n', ' ').trim();
        }
      }
      batch = [];
      byteCount = 0;
    }

    for (final text in texts) {
      final length = utf8.encode(text).length;
      if (length > maximumBatchBytes) {
        throw const LyricsTranslationException();
      }
      if (byteCount + length + 1 > maximumBatchBytes) await flush();
      batch.add(text);
      byteCount += length + 1;
    }
    await flush();
    return TranslatedLyricsView(
      syncedLines: List.unmodifiable([
        for (final line in sourceLines)
          line.trim().isEmpty ? '' : translations[line.trim()]!,
      ]),
      plainLyrics: null,
      sourceLanguage: sourceLanguage,
      alreadyInTargetLanguage: false,
    );
  }

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

  void dispose() {
    _disposed = true;
    for (final request in _active.toList()) {
      request.cancel();
    }
    _active.clear();
    _cache.clear();
  }
}
