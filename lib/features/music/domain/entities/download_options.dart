import 'track_info.dart';

enum DownloadMediaType { audio }

class DownloadOptions {
  const DownloadOptions({
    required this.outputDirectory,
    this.fileName,
    this.restrictFileNames = true,
    this.taskId,
    this.track,
  });

  final String outputDirectory;
  final String? fileName;
  final bool restrictFileNames;
  final String? taskId;

  /// Already-resolved catalog data, shared with optional audio providers.
  final TrackInfo? track;

  DownloadOptions copyWith({
    String? outputDirectory,
    String? fileName,
    bool? restrictFileNames,
    String? taskId,
    TrackInfo? track,
  }) {
    return DownloadOptions(
      outputDirectory: outputDirectory ?? this.outputDirectory,
      fileName: fileName ?? this.fileName,
      restrictFileNames: restrictFileNames ?? this.restrictFileNames,
      taskId: taskId ?? this.taskId,
      track: track ?? this.track,
    );
  }
}
