import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../../platform_channels/android_local_media_channel.dart';

/// Loads artwork embedded in a device audio file through Android on demand.
///
/// The provider key includes the requested width so a small scrolling-card
/// rendition never becomes the blurry source for the full player. Flutter's
/// image cache shares repeated requests for the same URI and size.
@immutable
class DeviceAudioArtworkImageProvider
    extends ImageProvider<DeviceAudioArtworkImageProvider> {
  const DeviceAudioArtworkImageProvider({
    required this.audioUri,
    required this.targetWidth,
    this.scale = 1,
    this.channel = const AndroidLocalMediaChannel(),
  });

  final String audioUri;
  final int targetWidth;
  final double scale;
  final AndroidLocalMediaChannel channel;

  @override
  Future<DeviceAudioArtworkImageProvider> obtainKey(ImageConfiguration _) =>
      SynchronousFuture<DeviceAudioArtworkImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    DeviceAudioArtworkImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key.audioUri,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('Audio URI', audioUri),
        DiagnosticsProperty<int>('Target width', targetWidth),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    DeviceAudioArtworkImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await key.channel.loadArtwork(
      audioUri: key.audioUri,
      targetWidth: key.targetWidth,
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('The device audio file has no embedded artwork.');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceAudioArtworkImageProvider &&
          other.audioUri == audioUri &&
          other.targetWidth == targetWidth &&
          other.scale == scale &&
          identical(other.channel, channel);

  @override
  int get hashCode =>
      Object.hash(audioUri, targetWidth, scale, identityHashCode(channel));
}
