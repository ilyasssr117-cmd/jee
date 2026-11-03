import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app_theme.dart';
import '../mini_player.dart';
import '../native_bridge.dart';
import '../playback_launcher.dart';
import 'bottom_bar.dart';

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
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                // One compact blur surface only; avoid stacking blur filters
                // across every reel control on older iPhones.
                filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  height: 78,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: AppColors.palette.brightness == Brightness.dark
                          ? const [Color(0xE52E3A70), Color(0xD21B2448)]
                          : const [Color(0xF4FFFFFF), Color(0xE8EAEDFF)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: Colors.white.withValues(
                        alpha: AppColors.palette.brightness == Brightness.dark
                            ? 0.24
                            : 0.78,
                      ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 24,
                        offset: const Offset(0, 9),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _expand,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(7, 7, 4, 8),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: SizedBox(
                                      width: 92,
                                      height: 62,
                                      child: ColoredBox(
                                        color: Colors.black,
                                        child: Center(
                                          child: AspectRatio(
                                            aspectRatio: session.controller
                                                        .value.aspectRatio >
                                                    0
                                                ? session.controller.value
                                                    .aspectRatio
                                                : 16 / 9,
                                            child: VideoPlayer(
                                              session.controller,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 11),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'NOW PLAYING',
                                          maxLines: 1,
                                          style: AppText.caption.copyWith(
                                            fontSize: 9,
                                            letterSpacing: 1.05,
                                            fontWeight: FontWeight.w800,
                                            color: AppColors.accentStrong,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          session.video.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppText.cardTitle.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ValueListenableBuilder<VideoPlayerValue>(
                                    valueListenable: session.controller,
                                    builder: (context, value, _) => _MiniAction(
                                      tooltip:
                                          value.isPlaying ? 'Pause' : 'Play',
                                      icon: value.isPlaying
                                          ? CupertinoIcons.pause_fill
                                          : CupertinoIcons.play_fill,
                                      onPressed: () => unawaited(
                                        MiniPlayer.instance.togglePlay(),
                                      ),
                                    ),
                                  ),
                                  _MiniAction(
                                    tooltip: 'Close',
                                    icon: CupertinoIcons.xmark,
                                    onPressed: () =>
                                        unawaited(MiniPlayer.instance.close()),
                                    muted: true,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 0,
                        child: IgnorePointer(
                          child: ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: session.controller,
                            builder: (context, value, _) {
                              final duration = value.duration.inMilliseconds;
                              final progress = duration <= 0
                                  ? 0.0
                                  : (value.position.inMilliseconds / duration)
                                      .clamp(0.0, 1.0)
                                      .toDouble();
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(99),
                                child: SizedBox(
                                  height: 2,
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    backgroundColor: Colors.white24,
                                    color: AppColors.accent,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
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

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.muted = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 38, height: 42),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: muted ? 16 : 20,
        color: muted ? AppColors.textSecondary : AppColors.textPrimary,
      ),
    );
  }
}
