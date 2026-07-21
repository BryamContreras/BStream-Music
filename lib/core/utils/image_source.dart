import 'dart:io';

bool isNetworkImageSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return false;
  }
  return normalized.startsWith('http://') || normalized.startsWith('https://');
}

File? imageFileFromSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  final uri = Uri.tryParse(normalized);
  if (uri != null && uri.scheme == 'file') {
    return File.fromUri(uri);
  }

  if (isNetworkImageSource(normalized)) {
    return null;
  }

  return File(normalized);
}
