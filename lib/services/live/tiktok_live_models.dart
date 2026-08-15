enum TikTokLiveStatus {
  idle,
  connecting,
  connected,
  disconnected,
  liveEnded,
  error,
}

class TikTokLiveEvent {
  const TikTokLiveEvent({
    required this.type,
    this.status,
    this.user,
    this.roomId,
    this.message,
    this.command,
  });

  final String type;
  final TikTokLiveStatus? status;
  final String? user;
  final String? roomId;
  final String? message;
  final TikTokLiveChatCommand? command;
}

class TikTokLiveChatCommand {
  const TikTokLiveChatCommand({
    required this.action,
    required this.user,
    required this.text,
    this.query,
    this.isModerator = false,
  });

  final String action;
  final String user;
  final String text;
  final String? query;
  final bool isModerator;

  factory TikTokLiveChatCommand.fromJson(Map<String, dynamic> json) {
    return TikTokLiveChatCommand(
      action: json['action']?.toString() ?? '',
      query: json['query']?.toString(),
      user: json['user']?.toString() ?? 'unknown',
      text: json['text']?.toString() ?? '',
      isModerator: _jsonBool(json['is_moderator']),
    );
  }

  static bool _jsonBool(Object? value) {
    if (value is bool) {
      return value;
    }
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' || normalized == '1';
  }
}

String normalizeCreatorInput(String value) {
  var text = value.trim();
  if (text.isEmpty) {
    return '';
  }

  final liveUrlMatch = RegExp(
    r'tiktok\.com/@([^/?#\s]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (liveUrlMatch != null) {
    text = liveUrlMatch.group(1) ?? '';
  }

  text = text.trim();
  if (text.startsWith('@')) {
    text = text.substring(1);
  }
  text = text.split('?').first.split('#').first.split('/').first.trim();
  return text.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
}
