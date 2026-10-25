import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'models.dart';
import 'stream_headers.dart';
import 'video_repository.dart';

/// The one live card preview.
class PreviewSession {
  const PreviewSession(this.id, this.controller, {this.fadingOut = false});

  final String id;
  final VideoPlayerController controller;

  /// True while the preview fades out (the controller is still alive).
  final bool fadingOut;

  PreviewSession faded() => PreviewSession(id, controller, fadingOut: true);
}

/// Owns the single muted preview shared by every card.
///
/// * At most ONE [VideoPlayerController] exists at any time, and only while a
///   card has stayed focused for [dwell].
/// * Moving focus tears the old one down immediately and restarts the wait.
/// * Native teardown is serialised ([_disposing]) so two decoders are never
///   released (or the player opened) on top of each other.
/// * Widget-facing calls ([requestPreview], [release]) never notify
///   listeners synchronously, so they are safe from initState / dispose.
class PreviewManager {
  PreviewManager._();

  static final PreviewManager instance = PreviewManager._();

  /// How long a card must stay focused before its preview starts. Moving to
  /// another card before this elapses starts nothing (change it here).
  static const Duration dwell = Duration(seconds: 2);

  /// Fade in / fade out of the preview over the thumbnail.
  static const Duration fadeDuration = Duration(milliseconds: 300);

  /// A preview stops by itself so an idle TV never streams forever.
  static const Duration _maxPlay = Duration(seconds: 30);
  static const Duration _initTimeout = Duration(seconds: 12);
  static const int _urlCacheSize = 24;

  final ValueNotifier<PreviewSession?> session =
      ValueNotifier<PreviewSession?>(null);

  // Tiny LRU of resolved stream URLs (a few dozen short strings).
  final LinkedHashMap<String, String> _urls = LinkedHashMap<String, String>();

  Timer? _dwellTimer;
  Timer? _limitTimer;
  String? _target;
  int _generation = 0;
  VideoPlayerController? _live;
  Future<void>? _initializing;
  Future<void> _disposing = Future<void>.value();
  Future<void> _pendingTeardown = Future<void>.value();
  _LifecycleObserver? _observer;

  // -------------------------------------------------------------------------
  // Called by widgets
  // -------------------------------------------------------------------------

  /// [video] just received focus: stop whatever is playing and start the wait.
  void requestPreview(Video video) {
    _observer ??= _LifecycleObserver(this);
    if (_target == video.id) return;
    _target = video.id;
    final generation = ++_generation;
    _dwellTimer?.cancel();
    _limitTimer?.cancel();
    _teardown();
    _dwellTimer = Timer(dwell, () => unawaited(_start(video, generation)));
  }

  /// The card for [id] lost focus (or went away).
  void release(String id) {
    if (_target != id) return; // Another card already took over.
    stopNow();
  }

  /// True while the preview of [id] is on screen (playing or fading out).
  bool isShowing(String id) => session.value?.id == id;

  void stopNow({bool fade = true}) {
    _target = null;
    ++_generation;
    _dwellTimer?.cancel();
    _limitTimer?.cancel();
    _teardown(fade: fade);
  }

  /// Stops the preview and waits until its native decoder is released. Call
  /// before opening the real player.
  Future<void> stopAndWait() async {
    stopNow(fade: false);
    await Future<void>.delayed(Duration.zero); // Let the teardown start.
    await _pendingTeardown; // Includes a fade-out that was already running.
    try {
      await _initializing?.timeout(const Duration(seconds: 2));
    } catch (_) {}
    await _disposing;
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  Future<void> _start(Video video, int generation) async {
    if (generation != _generation) return;
    try {
      // 1. The short clip the site puts on the card itself (data-preview):
      //    tiny, no extra page request, cheap for the decoder.
      final clip = video.previewUrl.trim();
      if (clip.isNotEmpty && await _play(video, clip, generation)) return;
      if (generation != _generation) return;

      // 2. Fallback: resolve the real stream and play it muted.
      var url = video.streamUrl.trim();
      if (url.isEmpty) {
        url = _urls.remove(video.id) ?? '';
        if (url.isNotEmpty) _urls[video.id] = url; // Mark as recently used.
      }
      if (url.isEmpty) {
        final resolved = await videoRepository
            .resolveForPlayback(video.copyWith(streamUrl: ''));
        url = resolved.streamUrl.trim();
        if (url.isNotEmpty) {
          _urls[video.id] = url;
          while (_urls.length > _urlCacheSize) {
            _urls.remove(_urls.keys.first);
          }
        }
      }
      if (generation != _generation || url.isEmpty) return;
      await _play(video, url, generation);
    } catch (error) {
      // A preview is a nicety: on any failure the thumbnail simply stays.
      debugPrint('[PREVIEW] ${video.id}: $error');
    }
  }

  /// Plays [url] muted in a fresh controller. Returns true when the attempt is
  /// finished (playing, or no longer wanted) and false when [url] failed and
  /// the caller may try something else.
  Future<bool> _play(Video video, String url, int generation) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return false;
    }

    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: streamHeaders(uri, video.pageUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      final init = controller.initialize().timeout(_initTimeout);
      _initializing = init.then((_) {}, onError: (Object _) {});
      await init;
      _initializing = null;

      if (generation != _generation) {
        unawaited(_scheduleDispose(controller));
        return true;
      }
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      if (generation != _generation) {
        unawaited(_scheduleDispose(controller));
        return true;
      }

      _live = controller;
      session.value = PreviewSession(video.id, controller);
      _limitTimer = Timer(_maxPlay, () {
        if (generation != _generation) return;
        ++_generation; // Keep _target so the same card doesn't restart.
        _teardown();
      });
      return true;
    } catch (error) {
      debugPrint('[PREVIEW] ${video.id} $url: $error');
      _initializing = null;
      if (controller != null && !identical(_live, controller)) {
        unawaited(_scheduleDispose(controller));
      }
      return generation != _generation;
    }
  }

  /// Fades the surface out, then releases the controller. Always runs outside
  /// any build phase (see [_runTeardown]).
  void _teardown({bool fade = true}) {
    final controller = _live;
    if (controller == null) return; // Nothing alive (or already retiring).
    _live = null;
    _pendingTeardown = Future<void>.microtask(
      () => _runTeardown(controller, fade),
    );
  }

  Future<void> _runTeardown(
    VideoPlayerController controller,
    bool fade,
  ) async {
    final current = session.value;
    if (fade && current != null && identical(current.controller, controller)) {
      session.value = current.faded();
      await Future<void>.delayed(fadeDuration);
    }
    if (identical(session.value?.controller, controller)) {
      session.value = null;
    }
    await _scheduleDispose(controller);
  }

  Future<void> _scheduleDispose(VideoPlayerController controller) {
    final done = _disposing.then((_) => _disposeAfterFrame(controller));
    _disposing = done;
    return done;
  }

  Future<void> _disposeAfterFrame(VideoPlayerController controller) async {
    // Let the tree drop the VideoPlayer texture before the controller dies.
    try {
      final binding = WidgetsBinding.instance;
      binding.scheduleFrame();
      await binding.endOfFrame.timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    try {
      await controller.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Already released, or a stuck native release: never block later ones.
    }
  }
}

/// Stops the preview whenever the app leaves the foreground.
class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._manager) {
    WidgetsBinding.instance.addObserver(this);
  }

  final PreviewManager _manager;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _manager.stopNow(fade: false);
  }
}
