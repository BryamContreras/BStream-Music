import 'package:flutter/material.dart';

/// Artist/duration line used by playlist entries.
///
/// A small outlined cloud marks entries that need streaming. The icon has its
/// own semantic label and tooltip without taking space away from long artist
/// names beyond its fixed 13 logical pixels.
class PlaylistTrackSubtitle extends StatelessWidget {
  const PlaylistTrackSubtitle({
    required this.artist,
    required this.duration,
    required this.isDownloaded,
    required this.streamOnlyLabel,
    this.textStyle,
    this.cloudKey,
    super.key,
  });

  final String artist;
  final String duration;
  final bool isDownloaded;
  final String streamOnlyLabel;
  final TextStyle? textStyle;
  final Key? cloudKey;

  @override
  Widget build(BuildContext context) {
    final color = textStyle?.color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!isDownloaded) ...<Widget>[
          Semantics(
            key: cloudKey,
            container: true,
            image: true,
            label: streamOnlyLabel,
            child: ExcludeSemantics(
              child: Tooltip(
                message: streamOnlyLabel,
                excludeFromSemantics: true,
                child: Icon(
                  Icons.cloud_outlined,
                  size: 13,
                  color: color.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            '$artist  -  $duration',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
      ],
    );
  }
}
