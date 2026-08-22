import 'package:flutter/material.dart';

import '../../../../services/youtube_music/auth/youtube_music_auth_models.dart';

/// Presentation-only avatar that never attaches account headers or cookies.
class YouTubeMusicAccountAvatar extends StatelessWidget {
  const YouTubeMusicAccountAvatar({
    super.key,
    required this.profile,
    this.size = 40,
  });

  static const Set<String> allowedAvatarHosts = <String>{
    'lh3.googleusercontent.com',
    'yt3.ggpht.com',
    'yt3.googleusercontent.com',
  };

  final YouTubeMusicAccountProfile? profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = _safeAvatarUrl(profile?.avatarUrl);
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          profile == null ? Icons.person_outline : Icons.person,
          size: size * 0.55,
        ),
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: url == null
            ? fallback
            : Image.network(
                url.toString(),
                fit: BoxFit.cover,
                headers: const <String, String>{},
                errorBuilder: (context, error, stackTrace) => fallback,
              ),
      ),
    );
  }

  Uri? _safeAvatarUrl(Uri? value) {
    if (value == null ||
        value.scheme.toLowerCase() != 'https' ||
        value.userInfo.isNotEmpty ||
        (value.hasPort && value.port != 443) ||
        !allowedAvatarHosts.contains(value.host.toLowerCase())) {
      return null;
    }
    return value;
  }
}
