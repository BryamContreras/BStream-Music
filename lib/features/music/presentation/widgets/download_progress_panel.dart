import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/download_result.dart';
import '../providers/music_providers.dart';
import 'gradient_progress_bar.dart';

class DownloadProgressPanel extends ConsumerWidget {
  const DownloadProgressPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadControllerProvider).values.toList();
    final strings = ref.watch(appStringsProvider);
    if (tasks.isEmpty) {
      return const SizedBox.shrink();
    }

    final active = _activeTask(tasks);
    final queuedCount = tasks
        .where((task) => task.status == DownloadProgressStatus.queued)
        .length;
    final label = switch (active.status) {
      DownloadProgressStatus.queued => strings.queued,
      DownloadProgressStatus.running => strings.downloading,
      DownloadProgressStatus.completed => strings.completed,
      DownloadProgressStatus.failed => strings.error,
    };

    return Material(
      color: const Color(0xFF060806),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        child: Row(
          children: [
            Icon(
              Icons.music_note_rounded,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    active.status == DownloadProgressStatus.running
                        ? strings.downloadLabel(
                            label,
                            active.title ?? active.url,
                            queuedCount,
                          )
                        : strings.downloadLabel(
                            label,
                            active.title ?? active.url,
                            0,
                          ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  GradientProgressBar(
                    value: _visibleProgress(active),
                    indeterminate: _isIndeterminate(active),
                    height: 5,
                    colors: active.status == DownloadProgressStatus.failed
                        ? [
                            Theme.of(context).colorScheme.error,
                            const Color(0xFFFFB3B3),
                          ]
                        : const [Color(0xFF159071), Color(0xFF5FA833)],
                  ),
                  if (active.errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        active.errorMessage!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _visibleProgress(DownloadTaskState task) {
    return switch (task.status) {
      DownloadProgressStatus.queued => 0.06,
      DownloadProgressStatus.running => (task.progress ?? 0.08).clamp(
        0.08,
        0.98,
      ),
      DownloadProgressStatus.completed => 1,
      DownloadProgressStatus.failed => (task.progress ?? 1).clamp(0.08, 1),
    };
  }

  bool _isIndeterminate(DownloadTaskState task) {
    return task.status == DownloadProgressStatus.queued ||
        (task.status == DownloadProgressStatus.running &&
            (task.progress ?? 0) <= 0.02);
  }

  DownloadTaskState _activeTask(List<DownloadTaskState> tasks) {
    return tasks.firstWhere(
      (task) => task.status == DownloadProgressStatus.running,
      orElse: () => tasks.firstWhere(
        (task) => task.status == DownloadProgressStatus.queued,
        orElse: () => tasks.last,
      ),
    );
  }
}
