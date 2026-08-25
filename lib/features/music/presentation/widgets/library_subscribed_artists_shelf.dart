import 'package:flutter/material.dart';

import '../../../../services/youtube_music/account/youtube_music_account.dart';
import 'source_image.dart';

class LibrarySubscribedArtistsShelf extends StatelessWidget {
  const LibrarySubscribedArtistsShelf({
    required this.title,
    required this.artists,
    required this.onOpenArtist,
    super.key,
  });

  final String title;
  final List<RemoteSubscribedArtist> artists;
  final ValueChanged<RemoteSubscribedArtist> onOpenArtist;

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 122,
          child: ListView.separated(
            key: const ValueKey('library-subscribed-artists-list'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: artists.length,
            separatorBuilder: (_, _) => const SizedBox(width: 4),
            itemBuilder: (context, index) {
              final artist = artists[index];
              return _SubscribedArtistCard(
                artist: artist,
                onTap: () => onOpenArtist(artist),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SubscribedArtistCard extends StatelessWidget {
  const _SubscribedArtistCard({required this.artist, required this.onTap});

  final RemoteSubscribedArtist artist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      key: ValueKey('library-subscribed-artist-${artist.identity}'),
      width: 94,
      child: Semantics(
        button: true,
        label: artist.name,
        child: InkWell(
          key: ValueKey('library-open-artist-${artist.identity}'),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Column(
              children: [
                ClipOval(
                  child: SizedBox.square(
                    dimension: 78,
                    child: SourceImage(
                      source: artist.thumbnailUrl,
                      cacheWidth: 320,
                      fallback: ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person_rounded,
                          size: 34,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  artist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
