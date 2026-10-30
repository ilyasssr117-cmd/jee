import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'app_settings.dart';
import 'models.dart';
import 'media_headers.dart';
import 'playback_source.dart';
import 'video_repository.dart';

class PreviewSession {
  const PreviewSession(this.id, this.controller, {this.fadingOut = false});

  final String id;
  final VideoPlayerController controller;

  final bool fadingOut;

  PreviewSession faded() => PreviewSession(id, controller, fadingOut: true);
}

class PreviewManager {
  PreviewManager._();

  static final PreviewManager instance = PreviewManager._();

  static const Duration fadeDuration = Duration(milliseconds: 300);

  static const Duration _maxPlay = Duration(seconds: 30);
  static const Duration _initTimeout = Duration(seconds: 12);

  final ValueNotifier<PreviewSession?> session =
      ValueNotifier<PreviewSession?>(null);

  final ValueNotifier<String?> active = ValueNotifier<String?>(null);

  final ValueNotifier<bool> loading = ValueNotifier<bool>(false);

  Timer? _limitTimer;
  int _generation = 0;
  VideoPlayerController? _live;
  Future<void>? _initializing;
  Future<void> _disposing = Future<void>.value();
  Future<void> _pendingTeardown = Future<void>.value();
  _LifecycleObserver? _observer;

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

  void clearCaches() {
    stopNow(fade: false);
    videoRepository.clearPlaybackCaches();
  }

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

  Future<void> stopAndWait() async {
    stopNow(fade: false);
    await Future<void>.delayed(Duration.zero);
    await _pendingTeardown;
    try {
      await _initializing?.timeout(const Duration(seconds: 2));
    } catch (_) {}
    await _disposing;
  }

  Future<void> _start(Video video, int generation) async {
    if (generation != _generation) return;
    try {
      final wantSound = AppSettings.instance.previewSound;
      final clip = video.previewUrl.trim();

      if (!wantSound && clip.isNotEmpty && await _play(video, clip, generation)) {
        return;
      }
      if (generation != _generation) return;

      var url = video.streamUrl.trim();
      if (url == clip) url = '';
      var pageUrl = video.pageUrl;
      if (url.isEmpty) {
        final resolved = await videoRepository
            .resolveForPlayback(video.copyWith(streamUrl: ''));
        url = resolved.streamUrl.trim();
        pageUrl = resolved.pageUrl ?? pageUrl;
      }
      if (generation != _generation) return;
      if (url.isNotEmpty &&
          await _play(video, url, generation, real: true, pageUrl: pageUrl)) {
        return;
      }
      if (generation != _generation) return;

      if (wantSound && clip.isNotEmpty) await _play(video, clip, generation);
    } catch (error) {
      debugPrint('[PREVIEW] ${video.id}: $error');
    } finally {
      if (generation == _generation) {
        loading.value = false;
        if (_live == null) active.value = null;
      }
    }
  }

  Future<bool> _play(
    Video video,
    String url,
    int generation, {
    bool real = false,
    String? pageUrl,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return false;
    }

    var headers = streamHeaders(uri, pageUrl ?? video.pageUrl);
    var playUri = uri;
    if (real) {
      final source = await resolvePlaybackSource(
        uri,
        pageUrl ?? video.pageUrl,
        tolerant: true,
      );
      if (generation != _generation) return true;
      headers = source.headers;
      playUri = Uri.parse(source.url);
    }

    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(
        playUri,
        httpHeaders: headers,
        videoPlayerOptions: VideoPlayerOptions(
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

  void _teardown({bool fade = true}) {
    final controller = _live;
    if (controller == null) return;
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
    try {
      final binding = WidgetsBinding.instance;
      binding.scheduleFrame();
      await binding.endOfFrame.timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    try {
      await controller.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {
    }
  }
}

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
