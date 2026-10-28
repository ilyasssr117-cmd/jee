import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'download_store.dart';
import 'error_text.dart';
import 'models.dart';
import 'player_page.dart';
import 'playback_source.dart';
import 'preview_manager.dart';
import 'video_repository.dart';

Future<String?> launchPlayer(
  BuildContext context,
  Video video, {
  Duration? startAt,
  List<Video>? queue,
  PlaybackSource? source,
}) async {
  final navigator = Navigator.of(context);
  try {
    await PreviewManager.instance.stopAndWait();
    if (!context.mounted) return null;
    final localPath = DownloadStore.instance.localPath(video.id);
    final playable = localPath != null || source != null
        ? video
        : await videoRepository.resolveForPlayback(
            video.copyWith(streamUrl: ''),
          );
    if (!context.mounted) return null;
    if (localPath == null && playable.streamUrl.trim().isEmpty) {
      return 'No playable link was found for this video.';
    }
    await navigator.push<void>(
      FadePageRoute<void>(
        builder: (_) => PlayerPage(
          video: playable,
          startAt: startAt,
          queue: queue,
          localPath: localPath,
          initialSource: localPath == null ? source : null,
        ),
      ),
    );
    return null;
  } catch (error) {
    final friendly = describeError(error, subject: 'this video');
    return friendly.offline
        ? 'No connection. Check the network and try again.'
        : 'Couldn\u2019t prepare this video. Please try again.';
  }
}
