import 'download_options.dart';

class DownloadResult {
  const DownloadResult({
    required this.id,
    required this.sourceUrl,
    required this.filePath,
    required this.fileName,
    required this.mediaType,
    required this.completedAt,
    this.bytes,
  });

  final String id;
  final String sourceUrl;
  final String filePath;
  final String fileName;
  final DownloadMediaType mediaType;
  final DateTime completedAt;
  final int? bytes;
}

enum DownloadProgressStatus { queued, running, completed, failed }

class DownloadProgress {
  const DownloadProgress({
    required this.taskId,
    required this.url,
    required this.status,
    this.progress,
    this.message,
    this.eta,
  });

  final String taskId;
  final String url;
  final DownloadProgressStatus status;
  final double? progress;
  final String? message;
  final Duration? eta;
}
