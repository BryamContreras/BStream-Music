import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_dialog.dart';
import '../../../../services/youtube_music/auth/youtube_music_auth_models.dart';
import 'youtube_music_account_avatar.dart';

class YouTubeMusicChannelPickerDialog extends StatelessWidget {
  const YouTubeMusicChannelPickerDialog({super.key, required this.channels});

  final List<YouTubeMusicAccountChannel> channels;

  static Future<YouTubeMusicAccountChannel?> show(
    BuildContext context,
    List<YouTubeMusicAccountChannel> channels,
  ) => showAppDialog<YouTubeMusicAccountChannel>(
    context: context,
    barrierDismissible: false,
    builder: (context) => YouTubeMusicChannelPickerDialog(channels: channels),
  );

  @override
  Widget build(BuildContext context) {
    return AppAlertDialog(
      key: const Key('youtube-music-channel-picker'),
      title: const Text('Elige un canal'),
      content: SizedBox(
        width: 420,
        height: math.min(420, math.max(72, channels.length * 72)).toDouble(),
        child: ListView.separated(
          itemCount: channels.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final channel = channels[index];
            return ListTile(
              key: Key('youtube-music-channel-${channel.profile.channelId}'),
              leading: YouTubeMusicAccountAvatar(
                profile: channel.profile,
                size: 42,
              ),
              title: Text(
                channel.profile.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: channel.profile.handle == null
                  ? null
                  : Text(
                      channel.profile.handle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: channel.isSelected
                  ? const Icon(Icons.check_circle_outline)
                  : null,
              onTap: () => Navigator.of(context).pop(channel),
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('youtube-music-channel-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
