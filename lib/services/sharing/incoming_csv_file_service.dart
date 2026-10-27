import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A user-opened document. [temporary] files are owned by the native transport,
/// not the source document, and must be released after the import preview closes.
class IncomingCsvFile {
  const IncomingCsvFile({
    required this.path,
    required this.name,
    required this.source,
    this.temporary = false,
    this.id,
  });

  final String path;
  final String name;
  final String source;
  final bool temporary;
  final String? id;
}

abstract interface class IncomingCsvFileService {
  Stream<IncomingCsvFile> get files;
  Future<void> release(IncomingCsvFile file);
  void dispose();
}

/// Registers the receiver before asking native code to drain cold-start opens.
/// Native messages retain their activation id until acknowledged, so the same
/// activation cannot open two dialogs when registration races with delivery.
class NativeIncomingCsvFileService implements IncomingCsvFileService {
  NativeIncomingCsvFileService({
    Stream<Uri>? links,
    MethodChannel? channel,
    TargetPlatform? platform,
  }) : _channel = channel ?? const MethodChannel('bstream_music/incoming_csv') {
    _platform = platform ?? defaultTargetPlatform;
    _controller = StreamController<IncomingCsvFile>(
      onListen: () {
        _channel.setMethodCallHandler(_handle);
        unawaited(_start());
      },
    );
    // Older desktop runners may deliver file URLs via app_links. Mobile file
    // opens always use the native bridge to retain scoped URI permissions.
    final linkSource = links;
    if (linkSource != null &&
        (_platform == TargetPlatform.windows ||
            _platform == TargetPlatform.linux)) {
      _links = linkSource.listen(_acceptLink, onError: _addError);
    }
  }

  final MethodChannel _channel;
  late final TargetPlatform _platform;
  late final StreamController<IncomingCsvFile> _controller;
  StreamSubscription<Uri>? _links;
  final Set<String> _seen = {};
  bool _disposed = false;

  @override
  Stream<IncomingCsvFile> get files => _controller.stream;

  Future<void> _start() async {
    try {
      final pending = await _channel.invokeListMethod<Object?>('start');
      for (final entry in pending ?? const []) {
        _accept(entry);
      }
    } on MissingPluginException {
      // Unsupported/older runner; desktop app_links remains usable.
      if (_platform == TargetPlatform.linux && _links == null && !_disposed) {
        _links = AppLinks().uriLinkStream.listen(
          _acceptLink,
          onError: _addError,
        );
      }
    } catch (error, stack) {
      _addError(error, stack);
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'open') throw MissingPluginException();
    _accept(call.arguments);
    return null;
  }

  void _accept(Object? data) {
    if (_disposed || data is! Map) return;
    final id = data['id'] as String?;
    if (id == null || !_seen.add(id)) return;
    final error = data['error'] as String?;
    if (error != null) {
      _addError(
        PlatformException(code: error, message: data['message'] as String?),
      );
      return;
    }
    final path = data['path'] as String?;
    final name = data['name'] as String?;
    final source = data['source'] as String?;
    if (path == null || name == null || source == null) return;
    _controller.add(
      IncomingCsvFile(
        path: path,
        name: name,
        source: source,
        temporary: data['temporary'] == true,
        id: id,
      ),
    );
  }

  void _acceptLink(Uri uri) {
    if (_disposed ||
        (uri.scheme != 'file' && uri.scheme.isNotEmpty) ||
        !uri.path.toLowerCase().endsWith('.csv')) {
      return;
    }
    try {
      final path = uri.toFilePath(windows: _platform == TargetPlatform.windows);
      // GTK also forwards local filenames, rather than only file:// URLs.
      if (uri.scheme.isEmpty && !path.startsWith('/')) return;
      final name = uri.pathSegments.last;
      _controller.add(
        IncomingCsvFile(path: path, name: name, source: uri.toString()),
      );
    } catch (error, stack) {
      _addError(error, stack);
    }
  }

  void _addError(Object error, [StackTrace? stack]) {
    if (!_disposed) _controller.addError(error, stack);
  }

  @override
  Future<void> release(IncomingCsvFile file) async {
    if (!file.temporary || file.id == null) return;
    await _channel.invokeMethod<void>('release', {'id': file.id});
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    unawaited(_links?.cancel());
    unawaited(_channel.invokeMethod<void>('stop').catchError((Object _) {}));
    unawaited(_controller.close());
  }
}
