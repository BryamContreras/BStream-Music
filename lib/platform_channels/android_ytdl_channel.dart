import 'package:flutter/services.dart';

import '../core/constants/app_constants.dart';
import '../core/errors/app_exception.dart';
import '../features/music/data/models/download_result_model.dart';
import '../features/music/data/models/track_info_model.dart';
import '../features/music/domain/entities/download_options.dart';
import '../features/music/domain/entities/download_result.dart';
import '../features/music/domain/entities/track_info.dart';

class AndroidYtdlChannel {
  AndroidYtdlChannel({
    MethodChannel? methodChannel,
    EventChannel? progressChannel,
  }) : _methodChannel =
           methodChannel ??
           const MethodChannel(AppConstants.androidYtdlChannel),
       _progressChannel =
           progressChannel ??
           const EventChannel(AppConstants.androidYtdlProgressChannel);

  final MethodChannel _methodChannel;
  final EventChannel _progressChannel;

  Stream<DownloadProgress> get progressStream {
    return _progressChannel.receiveBroadcastStream().map((event) {
      final data = Map<Object?, Object?>.from(event as Map);
      final statusName = data['status']?.toString() ?? 'running';
      return DownloadProgress(
        taskId: data['taskId']?.toString() ?? '',
        url: data['url']?.toString() ?? '',
        status: DownloadProgressStatus.values.firstWhere(
          (status) => status.name == statusName,
          orElse: () => DownloadProgressStatus.running,
        ),
        progress: _doubleValue(data['progress']),
        message: data['message']?.toString(),
        eta: _durationValue(data['etaSeconds']),
      );
    });
  }

  Future<void> initYtdl() async {
    try {
      await _methodChannel.invokeMethod<Object?>('initYtdl');
    } on PlatformException catch (error) {
      throw DownloaderException(
        error.message ?? 'No se pudo inicializar youtubedl-android.',
        code: error.code,
        details: error.details,
      );
    }
  }

  Future<TrackInfo> getInfo(String url) async {
    final result = await _invoke<Map<Object?, Object?>>('getInfo', {
      'url': url,
    });
    return TrackInfoModel.fromMethodChannel(result);
  }

  Future<TrackInfo> getPlaybackInfo(String url) async {
    final result = await _invoke<Map<Object?, Object?>>('getPlaybackInfo', {
      'url': url,
    });
    return TrackInfoModel.fromMethodChannel(result);
  }

  Future<List<TrackInfo>> search(String query) async {
    final result = await _invoke<List<Object?>>('search', {'query': query});
    return result
        .whereType<Map<Object?, Object?>>()
        .map(TrackInfoModel.fromMethodChannel)
        .toList(growable: false);
  }

  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    final result = await _invoke<Map<Object?, Object?>>('downloadAudio', {
      'url': url,
      'path': options.outputDirectory,
      'quality': options.quality ?? AppConstants.defaultAudioQuality,
      'fileName': options.fileName,
      'audioFormat': options.audioFormat,
      'embedMetadata': options.embedMetadata,
      'restrictFileNames': options.restrictFileNames,
    });
    return _downloadResult(result, DownloadMediaType.audio, url);
  }

  Future<T> _invoke<T>(String method, [Object? arguments]) async {
    try {
      final value = await _methodChannel.invokeMethod<T>(method, arguments);
      if (value == null) {
        throw const DownloaderException('Android no devolvio datos.');
      }
      return value;
    } on PlatformException catch (error) {
      throw DownloaderException(
        error.message ?? 'Fallo la integracion Android.',
        code: error.code,
        details: error.details,
      );
    }
  }

  DownloadResult _downloadResult(
    Map<Object?, Object?> result,
    DownloadMediaType mediaType,
    String sourceUrl,
  ) {
    final filePath = result['filePath']?.toString();
    if (filePath == null || filePath.isEmpty) {
      throw const DownloaderException('La descarga finalizo sin archivo.');
    }
    return DownloadResultModel.completed(
      sourceUrl: sourceUrl,
      filePath: filePath,
      mediaType: mediaType,
    );
  }

  double? _doubleValue(Object? value) {
    if (value == null) {
      return null;
    }
    return value is num ? value.toDouble() : double.tryParse(value.toString());
  }

  Duration? _durationValue(Object? value) {
    if (value == null) {
      return null;
    }
    final seconds = value is num
        ? value.toInt()
        : int.tryParse(value.toString());
    return seconds == null ? null : Duration(seconds: seconds);
  }
}
