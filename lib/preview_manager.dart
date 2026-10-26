import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'app_settings.dart';
import 'models.dart';
import 'stream_headers.dart';
import 'stream_resolver.dart';
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

/// Owns the single preview shared by every card (with sound by default).
///
/// * The preview is started by the viewer (long-press on a card), never by
///   itself, and starts at once.
/// * At most ONE [VideoPlayerController] exists at any time.
/// * It stops when the viewer scrolls, opens something, long-presses another
///   card, leaves the app, or after [_maxPlay].
/// * Native teardown is serialised ([_disposing]) so two decoders are never
///   released (or the player opened) on top of each other.
class PreviewManager {
  PreviewManager._();

  static final PreviewManager instance = PreviewManager._();

  /// Fade in / fade out of the preview over the thumbnail.
  static const Duration fadeDuration = Duration(milliseconds: 300);

  /// A preview stops by itself so it never streams forever.
  static const Duration _maxPlay = Duration(seconds: 30);
  static const Duration _initTimeout = Duration(seconds: 12);
  static const int _urlCacheSize = 24;

  /// The live (or fading-out) preview surface.
  final ValueNotifier<PreviewSession?> session =
      ValueNotifier<PreviewSession?>(null);

  /// Id of the card the viewer asked a preview for (null = none).
  final ValueNotifier<String?> active = ValueNotifier<String?>(null);

  /// True between the long-press and the first preview frame.
  final ValueNotifier<bool> loading = ValueNotifier<bool>(false);

  // Tiny LRU of resolved stream URLs (a few dozen short strings).
  final LinkedHashMap<String, String> _urls = LinkedHashMap<String, String>();

  Timer? _limitTimer;
  int _generation = 0;
  VideoPlayerController? _live;
  Future<void>? _initializing;
  Future<void> _disposing = Future<void>.value();
  Future<void> _pendingTeardown = Future<void>.value();
  _LifecycleObserver? _observer;

  // -------------------------------------------------------------------------
  // Called by widgets
  // -------------------------------------------------------------------------

  /// Starts [video]'s preview now (stopping any other one).
  void requestPreview(Video video) {
    _observer ??= _LifecycleObserver(this);
    if (active.value == video.id) return;
    final generation = ++_generation;
    _limitTimer?.cancel();
    _teardown();
    active.value = video.id;
    loading.value = true;
    unawaited(_start(video, generation));
  }

  /// Forgets the resolved stream URLs (Settings → Clear cache).
  void clearCaches() {
    stopNow(fade: false);
    _urls.clear();
  }

  /// The card for [id] went away. Safe to call from dispose().
  void release(String id) {
    scheduleMicrotask(() {
      if (active.value == id) stopNow();
    });
  }

  void stopNow({bool fade = true}) {
    ++_generation;
    _limitTimer?.cancel();
    loading.value = false;
    active.value = null;
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
      final wantSound = AppSettings.instance.previewSound;
      final clip = video.previewUrl.trim();

      // 1. Sound off: the short clip the site puts on the card (data-preview)
      //    is tiny and cheap. With sound on we skip it, because those clips
      //    are very often silent.
      if (!wantSound && clip.isNotEmpty && await _play(video, clip, generation)) {
        return;
      }
      if (generation != _generation) return;

      // 2. The real stream (with sound), resolved once and remembered.
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
      if (generation != _generation) return;
      if (url.isNotEmpty && await _play(video, url, generation, real: true)) {
        return;
      }
      if (generation != _generation) return;

      // 3. Last resort: the clip, even if it may be silent.
      if (wantSound && clip.isNotEmpty) await _play(video, clip, generation);
    } catch (error) {
      // A preview is a nicety: on any failure the thumbnail simply stays.
      debugPrint('[PREVIEW] ${video.id}: $error');
    } finally {
      if (generation == _generation) {
        loading.value = false;
        // Nothing could be played: drop the "active" mark and its spinner.
        if (_live == null) active.value = null;
      }
    }
  }

  /// Plays [url] in a fresh controller. Returns true when the attempt is
  /// finished (playing, or no longer wanted) and false when [url] failed and
  /// the caller may try something else.
  Future<bool> _play(
    Video video,
    String url,
    int generation, {
    bool real = false,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return false;
    }

    var headers = streamHeaders(uri, video.pageUrl);
    var playUri = uri;
    if (real) {
      // The real video needs the same cookie as the player (from the
      // repository) and talks to its final server directly.
      try {
        final page = Uri.tryParse(video.pageUrl?.trim() ?? '');
        final validPage = page != null &&
            (page.scheme == 'http' || page.scheme == 'https') &&
            page.host.isNotEmpty;
        final cookie = await videoRepository.getPlaybackCookieHeader(
          streamUri: uri,
          pageUrl: validPage ? page.toString() : null,
          userAgent: headers['User-Agent'] ?? '',
        );
        if (cookie.isNotEmpty) {
          headers = <String, String>{...headers, 'Cookie': cookie};
        }
      } catch (_) {}
      if (generation != _generation) return true;
      playUri = await resolveFinalStreamUri(uri, headers);
      if (generation != _generation) return true;
    }

    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(
        playUri,
        httpHeaders: headers,
        videoPlayerOptions: VideoPlayerOptions(
          // With sound it plays like a normal video (works with the silent
          // switch on); without sound it never interrupts the viewer's music.
          mixWithOthers: !AppSettings.instance.previewSound,
        ),
      );
      final init = controller.initialize().timeout(_initTimeout);
      _initializing = init.then((_) {}, onError: (Object _) {});
      await init;
      _initializing = null;

      if (generation != _generation) {
        unawaited(_scheduleDispose(controller));
        return true;
      }
      await controller.setVolume(AppSettings.instance.previewSound ? 1.0 : 0.0);
      await controller.setLooping(true);
      // A long video previews from a little way in (skips logos / intros).
      final length = controller.value.duration;
      if (real && length > const Duration(seconds: 90)) {
        await controller.seekTo(length * 0.12);
      }
      await controller.play();
      if (AppSettings.instance.previewSound) await controller.setVolume(1.0);
      if (generation != _generation) {
        unawaited(_scheduleDispose(controller));
        return true;
      }

      _live = controller;
      session.value = PreviewSession(video.id, controller);
      _limitTimer = Timer(_maxPlay, () {
        if (generation != _generation) return;
        ++_generation;
        active.value = null;
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
