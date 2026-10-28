import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/platform/app_platform.dart';
import '../../platform_channels/android_file_export_channel.dart';
import '../../platform_channels/ios_file_export_channel.dart';

abstract interface class LyricsImageShareService {
  /// Linux has no native attachment share sheet; saving remains available.
  bool get canShare;

  Future<void> shareImage({
    required Uint8List pngBytes,
    required String title,
    required Rect sharePositionOrigin,
  });

  /// Returns the chosen destination, or null when the picker is cancelled.
  Future<String?> saveImage({
    required Uint8List pngBytes,
    required String title,
  });
}

typedef LyricsImageNativeShare = Future<void> Function(ShareParams params);
typedef LyricsImageMobileSave =
    Future<String?> Function({
      required String sourcePath,
      required String fileName,
      required String mimeType,
    });
typedef LyricsImageDesktopSave =
    Future<String?> Function({
      required Uint8List bytes,
      required String fileName,
      required String title,
    });

/// Exports a rendered lyric card without requesting broad storage access.
///
/// Shared files live in a dedicated temporary folder. A receiver may open the
/// file after its share sheet closes, so exports are retained for seven days.
/// Only marked BStream exports are considered during later cache maintenance.
class DefaultLyricsImageShareService implements LyricsImageShareService {
  const DefaultLyricsImageShareService({
    this.platform = _currentPlatform,
    this.nativeShare = _nativeShare,
    this.androidSave = _androidSave,
    this.iosSave = _iosSave,
    this.desktopSave = _desktopSave,
    this.temporaryDirectoryFactory = getTemporaryDirectory,
    this.clock = DateTime.now,
  });

  final AppPlatformType Function() platform;
  final LyricsImageNativeShare nativeShare;
  final LyricsImageMobileSave androidSave;
  final LyricsImageMobileSave iosSave;
  final LyricsImageDesktopSave desktopSave;
  final Future<Directory> Function() temporaryDirectoryFactory;
  final DateTime Function() clock;

  static const _directoryName = 'bstream-lyrics-images';
  static const _markerName = '.bstream-lyrics-image';
  static const _retention = Duration(days: 7);
  static const _maximumBytes = 32 * 1024 * 1024;

  @override
  bool get canShare => switch (platform()) {
    AppPlatformType.android ||
    AppPlatformType.ios ||
    AppPlatformType.windows ||
    AppPlatformType.macos => true,
    _ => false,
  };

  @override
  Future<void> shareImage({
    required Uint8List pngBytes,
    required String title,
    required Rect sharePositionOrigin,
  }) async {
    if (!canShare) {
      throw UnsupportedError('Image sharing is unavailable on this platform.');
    }
    _validatePng(pngBytes);
    final file = await _writeTemporaryImage(pngBytes, title);
    final fileName = p.basename(file.path);
    await nativeShare(
      ShareParams(
        files: [XFile(file.path, name: fileName, mimeType: 'image/png')],
        fileNameOverrides: [fileName],
        title: title,
        subject: title,
        sharePositionOrigin: _safeOrigin(sharePositionOrigin),
      ),
    );
    // Preserve the file even when dispatch throws: the platform may already
    // have handed its URI to another application.
  }

  @override
  Future<String?> saveImage({
    required Uint8List pngBytes,
    required String title,
  }) async {
    _validatePng(pngBytes);
    final target = platform();
    if (AppPlatform.isMobileOn(target)) {
      final file = await _writeTemporaryImage(pngBytes, title);
      try {
        final save = target == AppPlatformType.android ? androidSave : iosSave;
        return await save(
          sourcePath: file.path,
          fileName: p.basename(file.path),
          mimeType: 'image/png',
        );
      } finally {
        // Document exporters finish copying before returning. Unlike sharing,
        // they do not require the temporary source to outlive this operation.
        await _removeExportDirectory(file.parent);
      }
    }
    if (target == AppPlatformType.unsupported) {
      throw UnsupportedError('Image saving is unavailable on this platform.');
    }
    return desktopSave(
      bytes: pngBytes,
      fileName: _fileName(title),
      title: title,
    );
  }

  Future<File> _writeTemporaryImage(Uint8List bytes, String title) async {
    final temporaryDirectory = await temporaryDirectoryFactory();
    final root = await Directory(
      p.join(temporaryDirectory.path, _directoryName),
    ).create(recursive: true);
    await _pruneExpiredExports(root);
    final directory = await root.createTemp('image_');
    final file = File(p.join(directory.path, _fileName(title)));
    try {
      await File(
        p.join(directory.path, _markerName),
      ).writeAsString('BStream lyrics image', flush: true);
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (_) {
      await _removeExportDirectory(directory);
      rethrow;
    }
  }

  String _fileName(String title) {
    var name = title
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (name.toLowerCase().endsWith('.png')) {
      name = name.substring(0, name.length - 4).trim();
    }
    if (name.isEmpty) name = 'BStream Music';
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(name)) {
      name = '_$name';
    }
    final shortened = StringBuffer();
    var byteCount = 0;
    for (final rune in name.runes) {
      final character = String.fromCharCode(rune);
      final length = utf8.encode(character).length;
      if (byteCount + length > 100) break;
      shortened.write(character);
      byteCount += length;
    }
    final safeName = shortened.toString().replaceAll(RegExp(r'[. ]+$'), '');
    return '$safeName-${clock().microsecondsSinceEpoch}.png';
  }

  Future<void> _pruneExpiredExports(Directory root) async {
    try {
      final resolvedRoot = await root.resolveSymbolicLinks();
      final expiration = clock().subtract(_retention);
      // Maintenance is bounded; successive exports continue reclaiming old
      // files without scanning an unlimited cache on a user's share action.
      var inspected = 0;
      await for (final entry in root.list(followLinks: false)) {
        if (++inspected > 256) break;
        if (entry is! Directory ||
            !RegExp(
              r'^image_[A-Za-z0-9_-]+$',
            ).hasMatch(p.basename(entry.path))) {
          continue;
        }
        final resolved = await entry.resolveSymbolicLinks();
        if (!p.isWithin(resolvedRoot, resolved)) continue;
        final marker = File(p.join(entry.path, _markerName));
        if (await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        if ((await marker.lastModified()).isBefore(expiration)) {
          await _removeExportDirectory(entry);
        }
      }
    } on FileSystemException {
      // A cache cleanup failure must not prevent exporting a new image.
    }
  }
}

void _validatePng(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length > DefaultLyricsImageShareService._maximumBytes) {
    throw const FormatException('The lyrics image exceeds the export limit.');
  }
  if (bytes.length < signature.length) {
    throw const FormatException('The lyrics image is not a PNG.');
  }
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) {
      throw const FormatException('The lyrics image is not a PNG.');
    }
  }
}

Future<void> _removeExportDirectory(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // Temporary cleanup must not replace the original export result/error.
  }
}

Rect _safeOrigin(Rect origin) {
  if (origin.left.isFinite &&
      origin.top.isFinite &&
      origin.width.isFinite &&
      origin.height.isFinite &&
      origin.left >= 0 &&
      origin.top >= 0 &&
      origin.width > 0 &&
      origin.height > 0) {
    return origin;
  }
  return const Rect.fromLTWH(0, 0, 1, 1);
}

AppPlatformType _currentPlatform() => AppPlatform.current;

Future<void> _nativeShare(ShareParams params) async {
  await SharePlus.instance.share(params);
}

Future<String?> _androidSave({
  required String sourcePath,
  required String fileName,
  required String mimeType,
}) => const AndroidFileExportChannel().saveFile(
  sourcePath: sourcePath,
  fileName: fileName,
  mimeType: mimeType,
);

Future<String?> _iosSave({
  required String sourcePath,
  required String fileName,
  required String mimeType,
}) => const IosFileExportChannel().saveFile(
  sourcePath: sourcePath,
  fileName: fileName,
  mimeType: mimeType,
);

Future<String?> _desktopSave({
  required Uint8List bytes,
  required String fileName,
  required String title,
}) async {
  final destination = await FilePicker.saveFile(
    dialogTitle: title,
    fileName: fileName,
    mimeType: 'image/png',
    bytes: bytes,
    type: FileType.custom,
    allowedExtensions: const ['png'],
    windowsOptions: const WindowsOptions(lockParentWindow: true),
    linuxOptions: const LinuxOptions(lockParentWindow: true),
  );
  return destination?.toString();
}
