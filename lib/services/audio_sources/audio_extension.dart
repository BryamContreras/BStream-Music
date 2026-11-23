enum AudioExtensionProtocol { bitChord, monochrome }

/// A user-configured HTTP audio source.
class AudioExtension {
  const AudioExtension({
    required this.id,
    required this.name,
    required this.manifestUri,
    this.protocol = AudioExtensionProtocol.bitChord,
    this.enabled = true,
    this.allowDownloads = true,
  });

  final String id;
  final String name;
  final Uri manifestUri;
  final AudioExtensionProtocol protocol;
  final bool enabled;
  final bool allowDownloads;

  AudioExtension copyWith({bool? enabled, bool? allowDownloads}) =>
      AudioExtension(
        id: id,
        name: name,
        manifestUri: manifestUri,
        protocol: protocol,
        enabled: enabled ?? this.enabled,
        allowDownloads: allowDownloads ?? this.allowDownloads,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'manifestUri': manifestUri.toString(),
    if (protocol != AudioExtensionProtocol.bitChord) 'protocol': protocol.name,
    'enabled': enabled,
    'allowDownloads': allowDownloads,
  };

  static AudioExtension? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = audioExtensionText(value['id'], maximumLength: 256);
    final name = audioExtensionText(value['name'], maximumLength: 256);
    final uri = audioExtensionHttpsUri(value['manifestUri']);
    final protocol = switch (value['protocol']) {
      null || 'bitChord' => AudioExtensionProtocol.bitChord,
      'monochrome' => AudioExtensionProtocol.monochrome,
      _ => null,
    };
    if (id == null || name == null || uri == null || protocol == null) {
      return null;
    }
    return AudioExtension(
      id: id,
      name: name,
      manifestUri: uri,
      protocol: protocol,
      enabled: value['enabled'] != false,
      allowDownloads: value['allowDownloads'] != false,
    );
  }
}

String? audioExtensionText(Object? value, {int maximumLength = 1024}) {
  if (value is! String || value.length > maximumLength) return null;
  final text = value.trim();
  return text.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)
      ? null
      : text;
}

Uri? audioExtensionHttpsUri(Object? value) {
  final text = audioExtensionText(value, maximumLength: 8192);
  if (text == null) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535) {
    return null;
  }
  return uri;
}
