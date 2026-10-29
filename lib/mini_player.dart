import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'models.dart';
import 'playback_progress.dart';

/// Everything needed to keep a video playing outside the full-screen player
/// and to hand it back to the full-screen player later.
class MiniSession {
  MiniSession({
    required this.video,
    required this.controller,
    required this.url,
    required this.headers,
    required this.isFile,
    required this.speed,
    this.queue,
  });

  final Video video;
  final VideoPlayerController controller;
  final String url;
  final Map<String, String>? headers;
  final bool isFile;
  final double speed;
  final List<Video>? queue;
}

/// Owns the controller of a minimized video so it keeps playing while the
/// user browses the rest of the app.
class MiniPlayer extends ChangeNotifier with WidgetsBindingObserver {
  MiniPlayer._();

  static final MiniPlayer instance = MiniPlayer._();

  MiniSession? _session;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _pausedByApp = false;
  bool _observing = false;

  MiniSession? get session => _session;
  bool get active => _session != null;

  void adopt(MiniSession session) {
    final old = _session;
    if (old != null) unawaited(_dispose(old));
    _session = session;
    session.controller.addListener(_onTick);
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    notifyListeners();
  }

  /// Hands the session back (to expand it); the controller stays alive.
  MiniSession? release() {
    final session = _session;
    if (session == null) return null;
    session.controller.removeListener(_onTick);
    _session = null;
    _save(session, force: true);
    notifyListeners();
    return session;
  }

  Future<void> close() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    notifyListeners();
    await _dispose(session);
  }

  Future<void> disposeSession(MiniSession session) => _dispose(session);

  Future<void> togglePlay() async {
    final controller = _session?.controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        final value = controller.value;
        if (value.duration > Duration.zero &&
            value.position >= value.duration - const Duration(milliseconds: 800)) {
          await controller.seekTo(Duration.zero);
        }
        await controller.play();
      }
    } catch (_) {}
  }

  Future<void> _dispose(MiniSession session) async {
    session.controller.removeListener(_onTick);
    _save(session, force: true);
    PlaybackProgress.instance.flush();
    try {
      await session.controller.pause();
    } catch (_) {}
    try {
      await session.controller.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  void _onTick() {
    final session = _session;
    if (session == null) return;
    _save(session);
  }

  void _save(MiniSession session, {bool force = false}) {
    final value = session.controller.value;
    if (!value.isInitialized) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSave) < const Duration(seconds: 5)) return;
    _lastSave = now;
    PlaybackProgress.instance.save(
      session.video.id,
      value.position,
      value.duration,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _session?.controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _pausedByApp = controller.value.isPlaying;
      if (_pausedByApp) unawaited(controller.pause().catchError((_) {}));
    } else if (state == AppLifecycleState.resumed && _pausedByApp) {
      _pausedByApp = false;
      unawaited(controller.play().catchError((_) {}));
    }
  }
}
