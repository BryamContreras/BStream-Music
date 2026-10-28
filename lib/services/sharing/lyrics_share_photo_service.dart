import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform/app_platform.dart';

/// Distinguishes a recovered Android lyric-card photo from an app wallpaper.
const lyricsSharePhotoPendingKey = 'lyricsShare.photoPickerPending.v1';

abstract interface class LyricsSharePhotoService {
  /// The caller owns the returned image and must dispose it when finished.
  /// Returns null when the system picker is cancelled.
  Future<ui.Image?> pickPhoto();
}

typedef LyricsSharePhotoPicker = Future<String?> Function();

/// Decodes one bounded still image using the platform/engine image decoder.
///
/// Image manipulation and cropping remain in the GPU-backed preview. The
/// selected source is read asynchronously and is never decoded at full camera
/// resolution in Dart.
class DefaultLyricsSharePhotoService implements LyricsSharePhotoService {
  const DefaultLyricsSharePhotoService({
    this.platform = _currentPlatform,
    this.mobilePicker = _mobilePicker,
    this.desktopPicker = _desktopPicker,
  });

  final AppPlatformType Function() platform;
  final LyricsSharePhotoPicker mobilePicker;
  final LyricsSharePhotoPicker desktopPicker;

  static const maximumBytes = 32 * 1024 * 1024;
  static const maximumDimension = 2560;

  @override
  Future<ui.Image?> pickPhoto() async {
    final target = platform();
    if (target == AppPlatformType.unsupported) {
      throw UnsupportedError(
        'Photo selection is unavailable on this platform.',
      );
    }
    final SharedPreferences? prefs;
    if (target == AppPlatformType.android) {
      prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(lyricsSharePhotoPendingKey, true)) {
        throw StateError('Could not record the photo picker destination.');
      }
    } else {
      prefs = null;
    }
    final String? selectedPath;
    try {
      selectedPath = await (AppPlatform.isMobileOn(target)
          ? mobilePicker()
          : desktopPicker());
    } finally {
      // Process death leaves this marker intact; SettingsController consumes
      // that result without treating it as an app-background selection.
      await prefs?.remove(lyricsSharePhotoPendingKey);
    }
    if (selectedPath == null) return null;
    return _decodePhoto(File(selectedPath));
  }
}

Future<ui.Image> _decodePhoto(File source) async {
  final handle = await source.open();
  final Uint8List bytes;
  try {
    final length = await handle.length();
    if (length <= 0 || length > DefaultLyricsSharePhotoService.maximumBytes) {
      throw const FormatException(
        'The selected photo exceeds the image limit.',
      );
    }
    // Reading only the validated length also bounds a source that grows while
    // it is being read, without allocating a full unrestricted file buffer.
    bytes = await handle.read(length);
  } finally {
    await handle.close();
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longestSide = math.max(descriptor.width, descriptor.height);
    final ratio = math.min(
      1.0,
      DefaultLyricsSharePhotoService.maximumDimension / longestSide,
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * ratio).round()),
      targetHeight: math.max(1, (descriptor.height * ratio).round()),
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

AppPlatformType _currentPlatform() => AppPlatform.current;

Future<String?> _mobilePicker() async {
  final selected = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: DefaultLyricsSharePhotoService.maximumDimension.toDouble(),
    maxHeight: DefaultLyricsSharePhotoService.maximumDimension.toDouble(),
    imageQuality: 95,
    requestFullMetadata: false,
  );
  return selected?.path;
}

Future<String?> _desktopPicker() async {
  final selected = await FilePicker.pickFile(
    type: FileType.image,
    windowsOptions: const WindowsOptions(lockParentWindow: true),
    linuxOptions: const LinuxOptions(lockParentWindow: true),
  );
  return selected?.path;
}
