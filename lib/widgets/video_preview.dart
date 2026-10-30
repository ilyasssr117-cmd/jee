import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../app_theme.dart';
import '../models.dart';
import '../preview_manager.dart';

class PreviewSlot extends StatefulWidget {
  const PreviewSlot({super.key, required this.video});

  final Video video;

  @override
  State<PreviewSlot> createState() => _PreviewSlotState();
}

class _PreviewSlotState extends State<PreviewSlot> {
  PreviewManager get _manager => PreviewManager.instance;

  late bool _mine = _compute();

  bool _compute() =>
      _manager.active.value == widget.video.id ||
      _manager.session.value?.id == widget.video.id;

  @override
  void initState() {
    super.initState();
    _manager.active.addListener(_sync);
    _manager.session.addListener(_sync);
  }

  void _sync() {
    if (!mounted) return;
    final next = _compute();
    if (next == _mine) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
      return;
    }
    setState(() => _mine = next);
  }

  @override
  void didUpdateWidget(PreviewSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id) {
      _manager.release(oldWidget.video.id);
      _mine = _compute();
    }
  }

  @override
  void dispose() {
    _manager.active.removeListener(_sync);
    _manager.session.removeListener(_sync);
    _manager.release(widget.video.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_mine) return const SizedBox.shrink();
    return _PreviewView(video: widget.video);
  }
}

class _PreviewView extends StatelessWidget {
  const _PreviewView({required this.video});

  final Video video;

  @override
  Widget build(BuildContext context) {
    final manager = PreviewManager.instance;
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          manager.session,
          manager.active,
          manager.loading,
        ]),
        builder: (context, _) {
          final session = manager.session.value;
          final mine = session != null && session.id == video.id ? session : null;
          final showVideo = mine != null &&
              mine.controller.value.isInitialized &&
              mine.controller.value.size.width > 0 &&
              mine.controller.value.size.height > 0;
          final waiting = manager.active.value == video.id &&
              manager.loading.value &&
              !showVideo;
          final holding = manager.active.value == video.id;

          return Stack(
            fit: StackFit.expand,
            children: [
              if (showVideo) _VideoFade(session: mine),
              AnimatedOpacity(
                opacity: waiting ? 1 : 0,
                duration: Motion.normal,
                child: const ColoredBox(
                  color: Color(0x66000000),
                  child: Center(
                    child: CupertinoActivityIndicator(
                      radius: 11,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              AnimatedOpacity(
                opacity: holding ? 1 : 0,
                duration: Motion.normal,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.card),
                    border: Border.all(color: AppColors.accent, width: 2),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _VideoFade extends StatelessWidget {
  const _VideoFade({required this.session});

  final PreviewSession session;

  @override
  Widget build(BuildContext context) {
    final size = session.controller.value.size;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: session.fadingOut ? 0 : 1),
      duration: PreviewManager.fadeDuration,
      curve: Curves.easeInOut,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: RepaintBoundary(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(session.controller),
          ),
        ),
      ),
    );
  }
}
