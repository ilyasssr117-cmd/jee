import 'package:flutter/material.dart';

import 'error_text.dart';
import 'models.dart';
import 'player_page.dart';
import 'video_repository.dart';

/// Resolves a playable stream for [video] and opens the player.
///
/// List pages may expose only a preview URL or an expiring stream URL, so the
/// detail page is re-read right before playback. Returns null on success or a
/// short, user-facing message on failure. Callers own the "busy" UI state.
Future<String?> launchPlayer(
  BuildContext context,
  Video video, {
  Duration? startAt,
}) async {
  final navigator = Navigator.of(context);
  try {
    final playable = await videoRepository.resolveForPlayback(
      video.copyWith(streamUrl: ''),
    );
    if (!context.mounted) return null;
    if (playable.streamUrl.trim().isEmpty) {
      return 'No playable link was found for this video.';
    }
    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(video: playable, startAt: startAt),
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
