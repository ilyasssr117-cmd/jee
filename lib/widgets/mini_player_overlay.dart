import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app_theme.dart';
import '../mini_player.dart';
import '../native_bridge.dart';
import '../playback_launcher.dart';
import 'bottom_bar.dart';

/// Floating mini player shown above every screen while a video is minimized.
class MiniPlayerOverlay extends StatelessWidget {
  const MiniPlayerOverlay({super.key});

  Future<void> _expand() async {
    final session = MiniPlayer.instance.release();
    if (session == null) return;
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) {
      unawaited(MiniPlayer.instance.disposeSession(session));
      return;
    }
    await launchPlayer(
      context,
      session.video,
      queue: session.queue,
      adopted: session,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MiniPlayer.instance,
      builder: (context, _) {
        final session = MiniPlayer.instance.session;
        if (session == null) return const SizedBox.shrink();
        final media = MediaQuery.of(context);
        return Positioned(
          left: 12,
          right: 12,
          bottom: kBottomBarHeight + media.padding.bottom + 8,
          child: Dismissible(
            key: ValueKey<String>('mini-${session.video.id}'),
            direction: DismissDirection.horizontal,
            onDismissed: (_) => unawaited(MiniPlayer.instance.close()),
            child: Material(
              color: AppColors.surfaceHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _expand,
                child: SizedBox(
                  height: 72,
                  child: Row(
                    children: [
                      AspectRatio(
                        aspectRatio: 16 / 9,
                        child: ColoredBox(
                          color: Colors.black,
                          child: Center(
                            child: AspectRatio(
                              aspectRatio:
                                  session.controller.value.aspectRatio > 0
                                      ? session.controller.value.aspectRatio
                                      : 16 / 9,
                              child: VideoPlayer(session.controller),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          session.video.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.cardTitle,
                        ),
                      ),
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: session.controller,
                        builder: (context, value, _) => IconButton(
                          tooltip: value.isPlaying ? 'Pause' : 'Play',
                          icon: Icon(
                            value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: AppColors.textPrimary,
                          ),
                          onPressed: () =>
                              unawaited(MiniPlayer.instance.togglePlay()),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: Icon(
                          Icons.close_rounded,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () => unawaited(MiniPlayer.instance.close()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
