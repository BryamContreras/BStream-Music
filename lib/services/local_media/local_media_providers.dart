import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_platform.dart';
import 'android_device_audio_catalog.dart';
import 'desktop_device_audio_catalog.dart';
import 'device_audio_catalog.dart';
import 'device_audio_filter.dart';
import 'ios_device_audio_catalog.dart';

class DeviceAudioQuery {
  const DeviceAudioQuery({
    this.options = const DeviceAudioFilterOptions(),
    this.bstreamRoot,
  });

  final DeviceAudioFilterOptions options;
  final String? bstreamRoot;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DeviceAudioQuery &&
            options == other.options &&
            bstreamRoot == other.bstreamRoot;
  }

  @override
  int get hashCode => Object.hash(options, bstreamRoot);
}

final deviceAudioCatalogProvider = Provider<DeviceAudioCatalog>((ref) {
  return switch (AppPlatform.current) {
    AppPlatformType.android => AndroidDeviceAudioCatalog(),
    AppPlatformType.ios => IosDeviceAudioCatalog(),
    AppPlatformType.windows ||
    AppPlatformType.linux ||
    AppPlatformType.macos => DesktopDeviceAudioCatalog(),
    AppPlatformType.unsupported => const UnsupportedDeviceAudioCatalog(),
  };
});

final deviceAudioCatalogResultProvider = FutureProvider.autoDispose
    .family<DeviceAudioCatalogResult, DeviceAudioQuery>((ref, query) {
      return ref
          .watch(deviceAudioCatalogProvider)
          .load(options: query.options, bstreamRoot: query.bstreamRoot);
    });
