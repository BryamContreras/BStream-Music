import 'package:flutter/material.dart';

import '../providers/app_strings.dart';
import 'youtube_music_auth_strings.dart';

/// Mandatory disclosure shown before opening the isolated Google login page.
class YouTubeMusicLoginDisclosureDialog extends StatelessWidget {
  const YouTubeMusicLoginDisclosureDialog({super.key, this.strings});

  final AppStrings? strings;

  static Future<bool> show(BuildContext context, {AppStrings? strings}) async {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => YouTubeMusicLoginDisclosureDialog(strings: strings),
    );
    return accepted ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final text = resolveYouTubeMusicAppStrings(context, strings);
    return AlertDialog(
      key: const Key('youtube-music-login-disclosure'),
      icon: const Icon(Icons.security_outlined),
      title: Text(text.youtubeMusicUnofficialTitle),
      content: SingleChildScrollView(
        child: Text(text.youtubeMusicUnofficialDisclosure),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('youtube-music-disclosure-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(text.choose('Cancelar', 'Cancel')),
        ),
        FilledButton(
          key: const Key('youtube-music-disclosure-accept'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(text.understandAndContinue),
        ),
      ],
    );
  }
}
