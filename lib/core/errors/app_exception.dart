class AppException implements Exception {
  const AppException(this.message, {this.code, this.details});

  final String message;
  final String? code;
  final Object? details;

  @override
  String toString() {
    if (code == null) {
      return message;
    }
    return '$code: $message';
  }
}

class DownloaderException extends AppException {
  const DownloaderException(super.message, {super.code, super.details});
}

class PlayerException extends AppException {
  const PlayerException(super.message, {super.code, super.details});
}

class StorageException extends AppException {
  const StorageException(super.message, {super.code, super.details});
}

class UnsupportedPlatformException extends AppException {
  const UnsupportedPlatformException(
    super.message, {
    super.code,
    super.details,
  });
}
