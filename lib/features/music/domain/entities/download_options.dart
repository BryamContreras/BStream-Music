enum DownloadMediaType { audio }

class DownloadOptions {
  const DownloadOptions({
    required this.outputDirectory,
    this.quality,
    this.fileName,
    this.audioFormat = 'mp3',
    this.embedMetadata = true,
    this.restrictFileNames = true,
  });

  final String outputDirectory;
  final String? quality;
  final String? fileName;
  final String audioFormat;
  final bool embedMetadata;
  final bool restrictFileNames;

  DownloadOptions copyWith({
    String? outputDirectory,
    String? quality,
    String? fileName,
    String? audioFormat,
    bool? embedMetadata,
    bool? restrictFileNames,
  }) {
    return DownloadOptions(
      outputDirectory: outputDirectory ?? this.outputDirectory,
      quality: quality ?? this.quality,
      fileName: fileName ?? this.fileName,
      audioFormat: audioFormat ?? this.audioFormat,
      embedMetadata: embedMetadata ?? this.embedMetadata,
      restrictFileNames: restrictFileNames ?? this.restrictFileNames,
    );
  }
}
