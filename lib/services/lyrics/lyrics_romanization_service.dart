import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:romanize/romanize.dart';

import '../../features/music/domain/entities/lyrics.dart';
import 'kuromoji_asset_tokenizer.dart';

const _kuromojiDictionaryAsset = 'assets/dictionaries/kuromoji-ipadic.bin.bz2';

typedef KuromojiDictionaryAssetLoader = Future<Uint8List> Function();
typedef LyricsWorkerIdleTimerFactory =
    Timer Function(Duration duration, void Function() callback);

Timer _createLyricsWorkerIdleTimer(
  Duration duration,
  void Function() callback,
) => Timer(duration, callback);

class RomanizedLyricsView {
  const RomanizedLyricsView({
    required this.syncedLines,
    required this.plainLyrics,
  });

  final List<String> syncedLines;
  final String? plainLyrics;
}

class LyricsRomanizationService {
  LyricsRomanizationService({
    this.maximumCacheEntries = 8,
    Duration workerRequestTimeout = const Duration(seconds: 45),
    Duration workerIdleTimeout = const Duration(minutes: 5),
    int maximumPendingRequests = 12,
    KuromojiDictionaryAssetLoader? kuromojiDictionaryAssetLoader,
    LyricsWorkerIdleTimerFactory? workerIdleTimerFactory,
  }) : assert(maximumCacheEntries > 0),
       assert(workerRequestTimeout > Duration.zero),
       assert(workerIdleTimeout > Duration.zero),
       assert(maximumPendingRequests > 0),
       _worker = _LyricsRomanizationWorker(
         requestTimeout: workerRequestTimeout,
         idleTimeout: workerIdleTimeout,
         maximumPendingRequests: maximumPendingRequests,
         dictionaryAssetLoader:
             kuromojiDictionaryAssetLoader ?? _loadKuromojiDictionaryAsset,
         idleTimerFactory:
             workerIdleTimerFactory ?? _createLyricsWorkerIdleTimer,
       );

  final int maximumCacheEntries;
  final _LyricsRomanizationWorker _worker;
  final LinkedHashMap<String, Future<List<String>>> _cache =
      LinkedHashMap<String, Future<List<String>>>();
  bool _disposed = false;

  Future<RomanizedLyricsView> romanizeDocument(
    LyricsDocument document,
    Set<LyricsRomanizationLanguage> languages,
  ) {
    final sourceTexts = <String>[
      for (final line in document.lines) line.text,
      ?document.plainLyrics,
    ];
    final plainIndex = document.plainLyrics == null
        ? null
        : sourceTexts.length - 1;
    return _romanizeTexts(sourceTexts, languages).then(
      (texts) => RomanizedLyricsView(
        syncedLines: List<String>.unmodifiable(
          texts.take(document.lines.length),
        ),
        plainLyrics: plainIndex == null ? null : texts[plainIndex],
      ),
    );
  }

  Future<List<String>> romanizePreview(
    List<String> lines,
    Set<LyricsRomanizationLanguage> languages,
  ) => _romanizeTexts(lines, languages);

  Future<List<String>> _romanizeTexts(
    List<String> texts,
    Set<LyricsRomanizationLanguage> languages,
  ) {
    if (_disposed) {
      return Future<List<String>>.error(
        StateError('LyricsRomanizationService has been disposed.'),
      );
    }
    if (texts.isEmpty || languages.isEmpty) {
      return SynchronousFuture<List<String>>(List<String>.unmodifiable(texts));
    }
    final codes = languages.map((language) => language.code).toList()..sort();
    final key = '${codes.join(',')}\u0000${texts.join('\u0001')}';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }

    final future = _worker.romanize(codes, List<String>.of(texts));
    _cache[key] = future;
    while (_cache.length > maximumCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_cache[key], future)) {
            _cache.remove(key);
          }
        },
      ),
    );
    return future;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cache.clear();
    _worker.dispose();
  }

  @visibleForTesting
  void debugTerminateWorker() => _worker.debugTerminate();
}

class _LyricsRomanizationWorker {
  _LyricsRomanizationWorker({
    required this.requestTimeout,
    required this.idleTimeout,
    required this.maximumPendingRequests,
    required this.dictionaryAssetLoader,
    required this.idleTimerFactory,
  });

  final Duration requestTimeout;
  final Duration idleTimeout;
  final int maximumPendingRequests;
  final KuromojiDictionaryAssetLoader dictionaryAssetLoader;
  final LyricsWorkerIdleTimerFactory idleTimerFactory;
  final Map<int, _PendingRomanizationRequest> _pending = {};
  RawReceivePort? _responsePort;
  RawReceivePort? _errorPort;
  RawReceivePort? _exitPort;
  Isolate? _isolate;
  Future<_WorkerConnection>? _startFuture;
  Completer<SendPort>? _ready;
  int _nextRequestId = 0;
  int _generation = 0;
  int? _dictionarySentGeneration;
  Future<void>? _dictionarySendFuture;
  Timer? _idleTimer;
  int _activeCalls = 0;
  bool _disposed = false;

  Future<List<String>> romanize(List<String> codes, List<String> texts) async {
    if (_disposed) {
      throw StateError('Lyrics romanization worker has been disposed.');
    }
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeCalls++;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final start = _startFuture ??= _start();
        late final _WorkerConnection connection;
        try {
          connection = await start;
        } catch (_) {
          if (identical(_startFuture, start)) {
            _startFuture = null;
          }
          rethrow;
        }
        if (_disposed) {
          throw StateError('Lyrics romanization worker has been disposed.');
        }
        if (connection.generation != _generation ||
            !identical(_startFuture, start)) {
          continue;
        }
        if (_requiresJapaneseTokenizer(codes.toSet(), texts)) {
          try {
            await _ensureJapaneseDictionary(connection);
          } catch (_) {
            if (connection.generation != _generation ||
                !identical(_startFuture, start)) {
              continue;
            }
            rethrow;
          }
        }
        if (_pending.length >= maximumPendingRequests) {
          throw StateError('Lyrics romanization worker is busy.');
        }
        final requestId = _nextRequestId++;
        final completer = Completer<List<String>>();
        final pending = _PendingRomanizationRequest(
          completer,
          generation: connection.generation,
        );
        pending.timer = Timer(
          requestTimeout,
          () => _handleRequestTimeout(requestId, connection.generation),
        );
        _pending[requestId] = pending;
        connection.commands.send(<Object>[requestId, codes, texts]);
        return await completer.future;
      }
      throw StateError('Lyrics romanization worker restarted repeatedly.');
    } finally {
      _activeCalls--;
      _scheduleIdleTermination();
    }
  }

  void _scheduleIdleTermination() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_disposed ||
        _activeCalls != 0 ||
        _pending.isNotEmpty ||
        _isolate == null) {
      return;
    }
    _idleTimer = idleTimerFactory(idleTimeout, _terminateWorkerIfIdle);
  }

  void _terminateWorkerIfIdle() {
    _idleTimer = null;
    if (_disposed ||
        _activeCalls != 0 ||
        _pending.isNotEmpty ||
        _isolate == null) {
      return;
    }
    _generation++;
    _dictionarySentGeneration = null;
    _dictionarySendFuture = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _startFuture = null;
    _ready = null;
    _closePorts();
  }

  Future<void> _ensureJapaneseDictionary(_WorkerConnection connection) {
    if (_dictionarySentGeneration == connection.generation) {
      return Future<void>.value();
    }
    final active = _dictionarySendFuture;
    if (active != null) {
      return active;
    }
    late final Future<void> send;
    send =
        () async {
          final bytes = await dictionaryAssetLoader();
          if (_disposed || connection.generation != _generation) {
            throw StateError('Lyrics romanization worker restarted.');
          }
          connection.commands.send(<Object>[
            _dictionaryCommand,
            TransferableTypedData.fromList(<Uint8List>[bytes]),
          ]);
          _dictionarySentGeneration = connection.generation;
        }().whenComplete(() {
          if (identical(_dictionarySendFuture, send)) {
            _dictionarySendFuture = null;
          }
        });
    _dictionarySendFuture = send;
    return send;
  }

  Future<_WorkerConnection> _start() async {
    final generation = ++_generation;
    final ready = _ready = Completer<SendPort>();
    final responsePort = RawReceivePort(
      (message) => _handleResponse(generation, message),
    );
    final errorPort = RawReceivePort(
      (message) => _handleWorkerError(generation, message),
    );
    final exitPort = RawReceivePort((_) => _handleWorkerExit(generation));
    _responsePort = responsePort;
    _errorPort = errorPort;
    _exitPort = exitPort;
    Isolate? spawnedIsolate;
    try {
      spawnedIsolate = await Isolate.spawn<SendPort>(
        _lyricsRomanizationWorkerEntry,
        responsePort.sendPort,
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
        debugName: 'BStream lyrics romanization',
      );
      if (_disposed || generation != _generation) {
        spawnedIsolate.kill(priority: Isolate.immediate);
        throw StateError('Lyrics romanization worker has been disposed.');
      }
      _isolate = spawnedIsolate;
      final commands = await ready.future;
      return _WorkerConnection(commands, generation: generation);
    } catch (_) {
      spawnedIsolate?.kill(priority: Isolate.immediate);
      responsePort.close();
      errorPort.close();
      exitPort.close();
      if (generation == _generation) {
        _generation++;
        _dictionarySentGeneration = null;
        _dictionarySendFuture = null;
        _isolate = null;
        _ready = null;
        _responsePort = null;
        _errorPort = null;
        _exitPort = null;
      }
      rethrow;
    }
  }

  void _handleResponse(int generation, dynamic message) {
    if (_disposed || generation != _generation) {
      return;
    }
    if (message is SendPort) {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) {
        ready.complete(message);
      }
      return;
    }
    if (message is! List<Object?> || message.length < 3) {
      return;
    }
    final requestId = message[0];
    final succeeded = message[1];
    if (requestId is! int || succeeded is! bool) {
      return;
    }
    final pending = _pending[requestId];
    if (pending == null ||
        pending.generation != generation ||
        pending.completer.isCompleted) {
      return;
    }
    _pending.remove(requestId);
    pending.timer.cancel();
    if (succeeded) {
      try {
        final result = (message[2] as List<Object?>).cast<String>();
        pending.completer.complete(List<String>.unmodifiable(result));
      } catch (error, stackTrace) {
        pending.completer.completeError(error, stackTrace);
        _resetAfterFailure(generation, error, stackTrace);
      }
      return;
    }
    final error = StateError(message[2]?.toString() ?? 'Romanization failed.');
    final stackTrace = message.length > 3
        ? StackTrace.fromString(message[3]?.toString() ?? '')
        : StackTrace.current;
    pending.completer.completeError(error, stackTrace);
  }

  void _handleWorkerError(int generation, dynamic message) {
    if (_disposed || generation != _generation) {
      return;
    }
    final details = message is List<Object?> ? message : const <Object?>[];
    final error = StateError(
      details.isEmpty
          ? 'Lyrics romanization worker failed.'
          : details.first.toString(),
    );
    final stackTrace = details.length > 1
        ? StackTrace.fromString(details[1].toString())
        : StackTrace.current;
    _resetAfterFailure(generation, error, stackTrace);
  }

  void _handleWorkerExit(int generation) {
    if (_disposed || generation != _generation) {
      return;
    }
    final error = StateError('Lyrics romanization worker stopped.');
    _resetAfterFailure(generation, error, StackTrace.current);
  }

  void _handleRequestTimeout(int requestId, int generation) {
    final pending = _pending[requestId];
    if (pending == null ||
        pending.generation != generation ||
        pending.completer.isCompleted) {
      return;
    }
    _pending.remove(requestId);
    final error = TimeoutException(
      'Lyrics romanization did not finish in time.',
      requestTimeout,
    );
    pending.completer.completeError(error, StackTrace.current);
    _resetAfterFailure(generation, error, StackTrace.current);
  }

  void _resetAfterFailure(int generation, Object error, StackTrace stackTrace) {
    if (_disposed || generation != _generation) {
      return;
    }
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error, stackTrace);
    }
    _failAll(error, stackTrace);
    _idleTimer?.cancel();
    _idleTimer = null;
    _generation++;
    _dictionarySentGeneration = null;
    _dictionarySendFuture = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _startFuture = null;
    _ready = null;
    _closePorts();
  }

  void _failAll(Object error, [StackTrace? stackTrace]) {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final request in pending) {
      request.timer.cancel();
      if (!request.completer.isCompleted) {
        request.completer.completeError(
          error,
          stackTrace ?? StackTrace.current,
        );
      }
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _generation++;
    _dictionarySentGeneration = null;
    _dictionarySendFuture = null;
    final error = StateError('Lyrics romanization worker has been disposed.');
    final ready = _ready;
    if (_isolate != null && ready != null && !ready.isCompleted) {
      ready.completeError(error, StackTrace.current);
    }
    _failAll(error);
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _startFuture = null;
    _ready = null;
    _closePorts();
  }

  @visibleForTesting
  void debugTerminate() => _isolate?.kill(priority: Isolate.immediate);

  void _closePorts() {
    _responsePort?.close();
    _responsePort = null;
    _errorPort?.close();
    _errorPort = null;
    _exitPort?.close();
    _exitPort = null;
  }
}

class _PendingRomanizationRequest {
  _PendingRomanizationRequest(this.completer, {required this.generation});

  final Completer<List<String>> completer;
  final int generation;
  late final Timer timer;
}

class _WorkerConnection {
  const _WorkerConnection(this.commands, {required this.generation});

  final SendPort commands;
  final int generation;
}

void _lyricsRomanizationWorkerEntry(SendPort responses) async {
  final commands = ReceivePort();
  Uint8List? japaneseDictionaryArchive;
  responses.send(commands.sendPort);
  await for (final message in commands) {
    if (message is List<Object?> &&
        message.length == 2 &&
        message[0] == _dictionaryCommand &&
        message[1] is TransferableTypedData) {
      japaneseDictionaryArchive = (message[1] as TransferableTypedData)
          .materialize()
          .asUint8List();
      continue;
    }
    if (message is! List<Object?> || message.length != 3) {
      continue;
    }
    final requestId = message[0];
    if (requestId is! int) {
      continue;
    }
    try {
      final codes = (message[1] as List<Object?>).cast<String>();
      final texts = (message[2] as List<Object?>).cast<String>();
      final result = await _romanizeLyricsPayload(<Object>[
        codes,
        texts,
      ], japaneseDictionaryArchive: japaneseDictionaryArchive);
      if (_requiresJapaneseTokenizer(codes.toSet(), texts)) {
        japaneseDictionaryArchive = null;
      }
      responses.send(<Object>[requestId, true, result]);
    } catch (error, stackTrace) {
      responses.send(<Object>[
        requestId,
        false,
        error.toString(),
        stackTrace.toString(),
      ]);
    }
  }
}

Future<List<String>> _romanizeLyricsPayload(
  List<Object> payload, {
  Uint8List? japaneseDictionaryArchive,
}) async {
  final languageCodes = (payload[0] as List<Object?>).cast<String>().toSet();
  final texts = (payload[1] as List<Object?>).cast<String>();
  final needsJapaneseTokenizer = _requiresJapaneseTokenizer(
    languageCodes,
    texts,
  );
  final japaneseTokenizer = needsJapaneseTokenizer
      ? await _loadJapaneseTokenizer(japaneseDictionaryArchive)
      : null;
  final selectedRomanizers = TextRomanizer.romanizers
      .where((romanizer) => languageCodes.contains(romanizer.language))
      .toSet();

  return List<String>.unmodifiable(
    texts.map(
      (text) => _romanizeSelectedParts(
        text,
        languageCodes: languageCodes,
        selectedRomanizers: selectedRomanizers,
        japaneseTokenizer: japaneseTokenizer,
      ),
    ),
  );
}

String _romanizeSelectedParts(
  String input, {
  required Set<String> languageCodes,
  required Set<Romanizer> selectedRomanizers,
  required _JapaneseTokenizer? japaneseTokenizer,
}) {
  if (input.trim().isEmpty) {
    return input;
  }
  final parts = TextRomanizer.analyze(input);
  final japaneseContextByPart = _japaneseContextByPart(parts);
  final output = _RomanizedTextWriter();
  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    if (part.language.isEmpty) {
      if (_separatorOnlyPattern.hasMatch(part.rawText)) {
        output.writeSeparator(part.rawText);
      } else {
        output.writeWord(part.rawText);
      }
      continue;
    }
    if (languageCodes.contains(LyricsRomanizationLanguage.japanese.code) &&
        japaneseContextByPart[index] &&
        part.language == LyricsRomanizationLanguage.chinese.code &&
        _containsHan(part.rawText)) {
      final japaneseRomanizer = selectedRomanizers
          .where(
            (romanizer) =>
                romanizer.language == LyricsRomanizationLanguage.japanese.code,
          )
          .firstOrNull;
      if (japaneseRomanizer != null) {
        output.writeWord(
          _romanizeJapaneseTokens(
            part.rawText,
            japaneseRomanizer,
            japaneseTokenizer,
          ),
        );
        continue;
      }
    }
    if (languageCodes.contains(part.language)) {
      if (part.language == LyricsRomanizationLanguage.japanese.code) {
        final japaneseRomanizer = selectedRomanizers
            .where(
              (romanizer) =>
                  romanizer.language ==
                  LyricsRomanizationLanguage.japanese.code,
            )
            .firstOrNull;
        output.writeWord(
          japaneseRomanizer == null
              ? part.romanizedText
              : _romanizeJapaneseTokens(
                  part.rawText,
                  japaneseRomanizer,
                  japaneseTokenizer,
                ),
        );
      } else {
        output.writeWord(part.romanizedText);
      }
      continue;
    }

    // Pure Han text is ambiguous. If Chinese is disabled but Japanese is
    // selected, give the selected Japanese engine a chance to interpret it.
    final alternative = TextRomanizer.detectLanguage(
      part.rawText,
      selectedRomanizers,
    );
    if (!languageCodes.contains(alternative.language)) {
      output.writeWord(part.rawText);
      continue;
    }
    output.writeWord(
      alternative.language == LyricsRomanizationLanguage.japanese.code
          ? _romanizeJapaneseTokens(
              part.rawText,
              alternative,
              japaneseTokenizer,
            )
          : alternative.romanize(part.rawText),
    );
  }
  return output.toString();
}

List<bool> _japaneseContextByPart(List<RomanizedText> parts) {
  final result = List<bool>.filled(parts.length, false);
  var phraseStart = 0;

  void markPhrase(int phraseEnd) {
    var hasKana = false;
    for (var index = phraseStart; index < phraseEnd; index++) {
      if (_containsKana(parts[index].rawText)) {
        hasKana = true;
        break;
      }
    }
    if (hasKana) {
      for (var index = phraseStart; index < phraseEnd; index++) {
        result[index] = true;
      }
    }
  }

  for (var index = 0; index < parts.length; index++) {
    final part = parts[index];
    if (part.language.isEmpty &&
        _strongPhraseBoundaryPattern.hasMatch(part.rawText)) {
      markPhrase(index);
      phraseStart = index + 1;
    }
  }
  markPhrase(parts.length);
  return result;
}

typedef _JapaneseTokenizer = JapaneseTokenizer;

Future<_JapaneseTokenizer?>? _japaneseTokenizerFuture;

Future<_JapaneseTokenizer?> _loadJapaneseTokenizer(
  Uint8List? dictionaryArchive,
) => _japaneseTokenizerFuture ??= () async {
  try {
    if (dictionaryArchive == null) {
      return null;
    }
    return buildKuromojiTokenizer(dictionaryArchive);
  } catch (_) {
    // Kana can still be romanized if the optional dictionary fails to
    // load. Unknown Kanji is intentionally left untouched by that
    // fallback.
    return null;
  }
}();

Future<Uint8List> _loadKuromojiDictionaryAsset() async {
  final data = await rootBundle.load(_kuromojiDictionaryAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

bool _requiresJapaneseTokenizer(Set<String> languageCodes, List<String> texts) {
  if (!languageCodes.contains(LyricsRomanizationLanguage.japanese.code)) {
    return false;
  }
  final hasJapaneseContext = texts.any(_containsKana);
  if (hasJapaneseContext) {
    return true;
  }
  return texts.any(_containsHan) &&
      !languageCodes.contains(LyricsRomanizationLanguage.chinese.code);
}

const _dictionaryCommand = 'kuromoji-dictionary';

String _romanizeJapaneseTokens(
  String input,
  Romanizer romanizer,
  _JapaneseTokenizer? tokenize,
) {
  if (tokenize == null) {
    return romanizer.romanize(input);
  }
  try {
    final words = <String>[];
    for (final token in tokenize(input)) {
      final reading = token['reading'];
      final surface = token['surface_form'];
      final source = reading is String && reading.isNotEmpty && reading != '*'
          ? reading
          : surface is String
          ? surface
          : '';
      if (source.isEmpty) {
        continue;
      }
      final word = romanizer.romanize(source).trim();
      if (word.isNotEmpty) {
        words.add(word);
      }
    }
    if (words.isNotEmpty) {
      return words.join(' ');
    }
  } catch (_) {
    // Preserve romanize's direct-Kana fallback if tokenization is unavailable.
  }
  return romanizer.romanize(input);
}

class _RomanizedTextWriter {
  final StringBuffer _buffer = StringBuffer();
  bool _pendingSpaceAfterPunctuation = false;

  void writeWord(String value) {
    if (value.isEmpty) {
      return;
    }
    final first = String.fromCharCode(value.runes.first);
    final startsWithWord = _wordCharacterPattern.hasMatch(first);
    if (startsWithWord && _pendingSpaceAfterPunctuation) {
      _buffer.write(' ');
    }
    _buffer.write(value);
    _pendingSpaceAfterPunctuation = false;
  }

  void writeSeparator(String value) {
    if (value.isEmpty) {
      return;
    }
    _buffer.write(value);
    final last = String.fromCharCode(value.runes.last);
    _pendingSpaceAfterPunctuation =
        !_whitespacePattern.hasMatch(last) &&
        _phraseEndingPunctuationPattern.hasMatch(last);
  }

  @override
  String toString() => _buffer.toString();
}

final _kanaPattern = RegExp(r'[\u3040-\u30FA\u30FC-\u30FF\uFF66-\uFF9F]');
final _hanPattern = RegExp(r'[\u3400-\u9FFF]');
final _separatorOnlyPattern = RegExp(r'^[\s\p{P}\p{S}]+$', unicode: true);
final _wordCharacterPattern = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _whitespacePattern = RegExp(r'\s', unicode: true);
final _strongPhraseBoundaryPattern = RegExp(r'[\r\n.!?;:/|。！？；：／｜]');
final _phraseEndingPunctuationPattern = RegExp(
  r'[,.;:!?，。；：！？、…\)\]\}）］｝」』】〉》”’]',
);

bool _containsKana(String input) => _kanaPattern.hasMatch(input);

bool _containsHan(String input) => _hanPattern.hasMatch(input);
