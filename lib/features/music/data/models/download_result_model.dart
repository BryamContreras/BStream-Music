import 'dart:io';

import '../../domain/entities/download_options.dart';
import '../../domain/entities/download_result.dart';

class DownloadResultModel extends DownloadResult {
  const DownloadResultModel({
    required super.id,
    required super.sourceUrl,
    required super.filePath,
    required super.fileName,
    required super.mediaType,
    required super.completedAt,
    super.bytes,
  });

  factory DownloadResultModel.completed({
    required String sourceUrl,
    required String filePath,
    required DownloadMediaType mediaType,
  }) {
    final file = File(filePath);
    return DownloadResultModel(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      sourceUrl: sourceUrl,
      filePath: filePath,
      fileName: file.uri.pathSegments.isEmpty
          ? filePath
          : file.uri.pathSegments.last,
      mediaType: mediaType,
      completedAt: DateTime.now(),
      bytes: file.existsSync() ? file.lengthSync() : null,
    );
  }
}
