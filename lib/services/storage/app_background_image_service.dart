import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum AppBackgroundImageError { tooLarge, tooManyPixels, invalidImage }

class AppBackgroundImageException implements Exception {
  const AppBackgroundImageException(this.error);

  final AppBackgroundImageError error;

  @override
  String toString() => 'AppBackgroundImageException($error)';
}

/// Copies a selected photo into private app storage as a bounded JPEG.
///
/// Only the returned *file name* should be persisted in settings. iOS may
/// relocate the app container, so persisting the absolute path is unsafe.
class AppBackgroundImageService {
  AppBackgroundImageService({
    Future<Directory> Function()? supportDirectoryProvider,
    this.maxSourceBytes = 30 * 1024 * 1024,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const int maxEdgePixels = 2048;
  static const int maxSourcePixels = 36 * 1024 * 1024;
  static const int jpegQuality = 85;

  final Future<Directory> Function() _supportDirectoryProvider;
  final int maxSourceBytes;
  static final RegExp _validFileName = RegExp(
    r'^background_[0-9]+_[0-9]+\.jpg$',
  );

  /// Reads a picked file in bounded chunks; it never modifies the original.
  Future<String> save(PlatformFile file) async {
    final knownLength = file.lengthSync();
    if (knownLength != null && knownLength > maxSourceBytes) {
      throw const AppBackgroundImageException(AppBackgroundImageError.tooLarge);
    }
    return saveStream(file.readAsByteStream());
  }

  /// Useful with `image_picker`'s [File] path on Android and iOS.
  Future<String> saveFile(File file) async {
    if (await file.length() > maxSourceBytes) {
      throw const AppBackgroundImageException(AppBackgroundImageError.tooLarge);
    }
    return saveStream(file.openRead().map(Uint8List.fromList));
  }

  /// Public for pickers that expose bytes or streams instead of a local path.
  Future<String> saveStream(Stream<Uint8List> source) async {
    final input = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in source) {
      length += chunk.length;
      if (length > maxSourceBytes) {
        throw const AppBackgroundImageException(
          AppBackgroundImageError.tooLarge,
        );
      }
      input.add(chunk);
    }

    final optimized = await compute(_optimizePhoto, input.takeBytes());
    final directory = await _appBackgroundDirectory();
    await directory.create(recursive: true);
    final fileName =
        'background_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}.jpg';
    final temporary = File(path.join(directory.path, '$fileName.tmp'));
    final destination = File(path.join(directory.path, fileName));
    try {
      await temporary.writeAsBytes(optimized, flush: true);
      await temporary.rename(destination.path);
      return fileName;
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  /// Resolves a stored relative name against the *current* app container.
  Future<String?> resolve(String? fileName) async {
    if (fileName == null || !_validFileName.hasMatch(fileName)) return null;
    final directory = await _appBackgroundDirectory();
    final file = File(path.join(directory.path, fileName));
    return await file.exists() ? file.path : null;
  }

  /// Call only after the new setting has been committed, or when clearing it.
  Future<void> delete(String? fileName) async {
    if (fileName == null || !_validFileName.hasMatch(fileName)) return;
    final directory = await _appBackgroundDirectory();
    final file = File(path.join(directory.path, fileName));
    if (await file.exists()) await file.delete();
  }

  Future<Directory> _appBackgroundDirectory() async {
    final support = await _supportDirectoryProvider();
    return Directory(path.join(support.path, 'app_backgrounds'));
  }
}

Uint8List _optimizePhoto(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const AppBackgroundImageException(
      AppBackgroundImageError.invalidImage,
    );
  }

  try {
    final decoder = image.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (decoder == null ||
        info == null ||
        info.width <= 0 ||
        info.height <= 0) {
      throw const AppBackgroundImageException(
        AppBackgroundImageError.invalidImage,
      );
    }
    if (info.width * info.height > AppBackgroundImageService.maxSourcePixels) {
      throw const AppBackgroundImageException(
        AppBackgroundImageError.tooManyPixels,
      );
    }

    final decoded = decoder.decode(bytes, frame: 0);
    if (decoded == null) {
      throw const AppBackgroundImageException(
        AppBackgroundImageError.invalidImage,
      );
    }
    var normalized = decoded.exif.imageIfd.hasOrientation
        ? image.bakeOrientation(decoded)
        : decoded;
    final longestEdge = max(normalized.width, normalized.height);
    if (longestEdge > AppBackgroundImageService.maxEdgePixels) {
      normalized = normalized.width >= normalized.height
          ? image.copyResize(
              normalized,
              width: AppBackgroundImageService.maxEdgePixels,
              interpolation: image.Interpolation.linear,
            )
          : image.copyResize(
              normalized,
              height: AppBackgroundImageService.maxEdgePixels,
              interpolation: image.Interpolation.linear,
            );
    }
    // Do not copy location or other private EXIF metadata into app storage.
    normalized.exif = image.ExifData();
    return Uint8List.fromList(
      image.encodeJpg(
        normalized,
        quality: AppBackgroundImageService.jpegQuality,
      ),
    );
  } on AppBackgroundImageException {
    rethrow;
  } catch (_) {
    throw const AppBackgroundImageException(
      AppBackgroundImageError.invalidImage,
    );
  }
}
