import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/music_providers.dart';
import '../widgets/search_input.dart';
import '../widgets/track_result_tile.dart';

class SearchView extends ConsumerWidget {
  const SearchView({required this.onOpenPlayer, super.key});

  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchControllerProvider);
    final strings = ref.watch(appStringsProvider);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    strings.searchTitle,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: SearchInput(
                    hintText: strings.searchHint,
                    tooltip: strings.search,
                    clearTooltip: strings.clearSearch,
                    onSubmitted: (query) => ref
                        .read(searchControllerProvider.notifier)
                        .submit(query),
                  ),
                ),
              ],
            ),
          ),
        ),
        results.when(
          data: (tracks) {
            if (tracks.isEmpty) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: _SearchEmptyState(
                  icon: Icons.album_rounded,
                  title: strings.searchEmptyTitle,
                  subtitle: strings.searchEmptySubtitle,
                ),
              );
            }
            return SliverPadding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 18),
              sliver: SliverList.separated(
                itemCount: tracks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  return TrackResultTile(
                    track: tracks[index],
                    onOpenPlayer: onOpenPlayer,
                  );
                },
              ),
            );
          },
          loading: () => const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => SliverFillRemaining(
            hasScrollBody: false,
            child: _SearchEmptyState(
              icon: Icons.error_outline_rounded,
              title: strings.searchErrorTitle,
              subtitle: error.toString(),
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 46,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
