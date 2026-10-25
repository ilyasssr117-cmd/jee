import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../preview_manager.dart';

/// Preview surface of one card.
///
/// Only the focused card (and the one whose preview is still fading out) ever
/// mounts this, and it listens to the [PreviewManager] only while it has
/// something to show, so there is at most one active listener and one video
/// texture in the whole tree.
///
/// Focus arriving starts the dwell timer; focus leaving releases the preview,
/// which fades out before its controller is freed.
class PreviewLayer extends StatefulWidget {
  const PreviewLayer({super.key, required this.video, required this.focused});

  final Video video;
  final bool focused;

  @override
  State<PreviewLayer> createState() => _PreviewLayerState();
}

class _PreviewLayerState extends State<PreviewLayer> {
  PreviewSession? _session;
  bool _listening = false;

  PreviewManager get _manager => PreviewManager.instance;

  PreviewSession? _mine() {
    final session = _manager.session.value;
    return session != null && session.id == widget.video.id ? session : null;
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    _manager.session.addListener(_onSession);
    _session = _mine(); // No setState: only called while building.
  }

  void _unlisten() {
    if (!_listening) return;
    _listening = false;
    _manager.session.removeListener(_onSession);
  }

  void _onSession() {
    if (!mounted) return;
    final mine = _mine();
    if (!identical(mine, _session)) setState(() => _session = mine);
    // Nothing left to show and not focused: stop listening altogether.
    if (mine == null && !widget.focused) _unlisten();
  }

  @override
  void initState() {
    super.initState();
    if (widget.focused) _manager.requestPreview(widget.video);
    _listen();
  }

  @override
  void didUpdateWidget(PreviewLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id) {
      _manager.release(oldWidget.video.id);
      _session = _mine();
    }
    if (widget.focused && !oldWidget.focused) {
      _manager.requestPreview(widget.video);
      _listen();
    } else if (!widget.focused && oldWidget.focused) {
      _manager.release(widget.video.id); // Starts the fade-out.
    }
  }

  @override
  void dispose() {
    _unlisten();
    _manager.release(widget.video.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null || !session.controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final size = session.controller.value.size;
    if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();

    // Starts transparent, fades to 1; fades back to 0 when fadingOut flips.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: session.fadingOut ? 0 : 1),
      duration: PreviewManager.fadeDuration,
      curve: Curves.easeInOut,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: IgnorePointer(
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
      ),
    );
  }
}
