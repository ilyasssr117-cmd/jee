import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'download_store.dart';
import 'error_text.dart';
import 'models.dart';
import 'player_page.dart';
import 'playback_source.dart';
import 'preview_manager.dart';
import 'video_repository.dart';

/// Resolves a playable stream for [video] and opens the player.
///
/// List pages may expose only a preview URL or an expiring stream URL, so the
/// detail page is re-read right before playback. Returns null on success or a
/// short, user-facing message on failure. Callers own the "busy" UI state.
///
/// With a [source] (the address and headers a player already used, e.g. when
/// Picture in Picture closes) nothing is looked up: the player opens at once.
Future<String?> launchPlayer(
  BuildContext context,
  Video video, {
  Duration? startAt,
  List<Video>? queue,
  PlaybackSource? source,
}) async {
  final navigator = Navigator.of(context);
  try {
    // Free the card-preview decoder before the real player needs one.
    await PreviewManager.instance.stopAndWait();
    if (!context.mounted) return null;
    // A saved copy plays straight from the phone (works without internet).
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
    // The screen fades to black and into the player (no sliding).
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
