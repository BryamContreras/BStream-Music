String safeFileName(String value) {
  final sanitized = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  if (sanitized.isEmpty) {
    return 'bstream_track';
  }

  return sanitized.length > 140
      ? sanitized.substring(0, 140).trim()
      : sanitized;
}
