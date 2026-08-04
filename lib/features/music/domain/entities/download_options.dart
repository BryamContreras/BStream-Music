enum DownloadMediaType { audio }

class DownloadOptions {
  const DownloadOptions({
    required this.outputDirectory,
    this.fileName,
    this.restrictFileNames = true,
    this.taskId,
  });

  final String outputDirectory;
  final String? fileName;
  final bool restrictFileNames;
  final String? taskId;

  DownloadOptions copyWith({
    String? outputDirectory,
    String? fileName,
    bool? restrictFileNames,
    String? taskId,
  }) {
    return DownloadOptions(
      outputDirectory: outputDirectory ?? this.outputDirectory,
      fileName: fileName ?? this.fileName,
      restrictFileNames: restrictFileNames ?? this.restrictFileNames,
      taskId: taskId ?? this.taskId,
    );
  }
}
