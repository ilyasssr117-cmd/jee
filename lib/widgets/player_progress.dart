import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'package:vxtube_final/app_theme.dart';

/// The player's seek row (position label, scrubbable track with
/// buffered indicator, duration label), extracted from player_page
/// so the page state no longer carries leaf-widget code.

/// Formats a playback duration as m:ss (or h:mm:ss over an hour).
/// Shared by the player page and the progress row.
String formatPlayerDuration(Duration duration) {
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

class PlayerProgressRow extends StatelessWidget {
  const PlayerProgressRow({
    required this.controller,
    required this.scrubTarget,
    required this.dragging,
    required this.onSeekFraction,
    required this.onDragStart,
    required this.onDragEnd,
  });

  final VideoPlayerController controller;
  final ValueNotifier<Duration?> scrubTarget;
  final ValueNotifier<bool> dragging;
  final ValueChanged<double> onSeekFraction;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller,
        scrubTarget,
        dragging,
      ]),
      builder: (context, _) {
        final value = controller.value;
        final total = value.duration;
        final position = scrubTarget.value ?? value.position;
        final totalMs = total.inMilliseconds;
        final played = totalMs > 0
            ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0).toDouble()
            : 0.0;
        final buffered = totalMs > 0 && value.buffered.isNotEmpty
            ? (value.buffered.last.end.inMilliseconds / totalMs)
                .clamp(0.0, 1.0)
                .toDouble()
            : 0.0;
        final active = dragging.value;
        final trackHeight = active ? 6.0 : 4.0;
        final thumb = active ? 18.0 : 12.0;
        const labelStyle = TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          fontFeatures: [FontFeature.tabularFigures()],
        );

        return Semantics(
          label: 'Seek bar',
          value: '${formatPlayerDuration(position)} of ${formatPlayerDuration(total)}',
          child: Row(
            children: [
              SizedBox(
                width: 50,
                child: Text(formatPlayerDuration(position), style: labelStyle),
              ),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      double fractionAt(double dx) =>
                          width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);
                      return Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (e) {
                          onDragStart();
                          onSeekFraction(fractionAt(e.localPosition.dx));
                        },
                        onPointerMove: (e) =>
                            onSeekFraction(fractionAt(e.localPosition.dx)),
                        onPointerUp: (_) => onDragEnd(),
                        onPointerCancel: (_) => onDragEnd(),
                        child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (_) {},
                        onHorizontalDragUpdate: (_) {},
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          clipBehavior: Clip.none,
                          children: [
                            AnimatedContainer(
                              duration: Motion.quick,
                              height: trackHeight,
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(
                                  trackHeight,
                                ),
                              ),
                            ),
                            AnimatedContainer(
                              duration: Motion.quick,
                              height: trackHeight,
                              width: width * buffered,
                              decoration: BoxDecoration(
                                color: Colors.white38,
                                borderRadius: BorderRadius.circular(
                                  trackHeight,
                                ),
                              ),
                            ),
                            AnimatedContainer(
                              duration: Motion.quick,
                              height: trackHeight,
                              width: width * played,
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                borderRadius: BorderRadius.circular(
                                  trackHeight,
                                ),
                              ),
                            ),
                            Positioned(
                              left: (width * played - thumb / 2)
                                  .clamp(-thumb / 2, width - thumb / 2)
                                  .toDouble(),
                              child: AnimatedContainer(
                                duration: Motion.quick,
                                width: thumb,
                                height: thumb,
                                decoration: const BoxDecoration(
                                  color: OnDark.textPrimary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ],
                        ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 50,
                child: Text(
                  formatPlayerDuration(total),
                  textAlign: TextAlign.end,
                  style: labelStyle.copyWith(color: OnDark.textSecondary),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
