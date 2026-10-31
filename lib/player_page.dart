import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'app_settings.dart';
import 'app_theme.dart';
import 'download_store.dart';
import 'history_store.dart';
import 'media_headers.dart';
import 'mini_player.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'platform_ui.dart';
import 'playback_progress.dart';
import 'playback_source.dart';
import 'touch.dart';
import 'video_repository.dart';
import 'widgets/ios_sheets.dart';
import 'widgets/app_button.dart';
import 'widgets/dialogs.dart';
import 'widgets/state_views.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.video,
    this.startAt,
    this.queue,
    this.localPath,
    this.initialSource,
    this.adopted,
  });

  final Video video;

  final MiniSession? adopted;

  final PlaybackSource? initialSource;

  final List<Video>? queue;

  final String? localPath;

  final Duration? startAt;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlaybackProblem {
  const _PlaybackProblem(this.title, this.message, this.icon);

  final String title;
  final String message;
  final IconData icon;
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  static final Expando<Future<void>> _disposalFutures =
      Expando<Future<void>>('tvTubePlayerDisposal');
  static Future<void> _pendingDisposals = Future<void>.value();

  static const Duration _controlsTimeout = Duration(seconds: 4);
  static const Duration _scrubCommitDelay = Duration(milliseconds: 350);
  static const Duration _initTimeout = Duration(seconds: 30);

  final ValueNotifier<Duration?> _scrubTarget = ValueNotifier<Duration?>(null);
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _buffering = ValueNotifier<bool>(false);

  VideoPlayerController? _controller;
  Timer? _hideTimer;
  Timer? _scrubTimer;
  final ValueNotifier<bool> _reloading = ValueNotifier<bool>(false);
  int _reloadToken = 0;
  bool _reloadOk = false;
  Timer? _spinnerTimer;
  Duration _lastSeen = Duration.zero;
  bool _pipBusy = false;
  MiniSession? _adopted;

  String? _activeUrl;
  Map<String, String>? _activeHeaders;
  bool _activeIsFile = false;

  bool _scrubBadge = true;
  String _scrubText = '';
  double _speed = 1.0;
  bool _boosting = false;
  final ValueNotifier<bool> _boost = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _dragging = ValueNotifier<bool>(false);
  final ValueNotifier<_SeekFlash?> _flash = ValueNotifier<_SeekFlash?>(null);
  _SeekFlash? _lastFlash;
  Timer? _flashTimer;
  DateTime? _lastTapAt;
  _Side? _lastTapSide;
  bool _loading = true;
  bool _showControls = true;
  bool _completed = false;
  bool _wasPlayingBeforePause = false;
  bool _isLeaving = false;
  bool _popping = false;
  Future<bool>? _releaseTask;
  _PlaybackProblem? _problem;
  int _initializationGeneration = 0;

  static const int _maxAutoRetries = 3;
  static const Duration _stallAfter = Duration(seconds: 8);
  final ValueNotifier<bool> _stalled = ValueNotifier<bool>(false);
  late Video _video = _preferred(widget.video);
  late String? _localPath = widget.localPath;
  PlaybackSource? _initialSource;
  bool _usedKnownSource = false;
  String? _recordedId;
  Duration? _resumeAt;
  Duration _lastPosition = Duration.zero;
  Duration _scrubOrigin = Duration.zero;
  Duration _retryBase = Duration.zero;
  Timer? _stallTimer;
  int _autoRetries = 0;
  bool _reconnecting = false;
  bool _manualReload = false;

  bool _portrait = false;
  bool _orientationForced = false;

  static const int _autoplaySeconds = 5;
  final ValueNotifier<int?> _countdown = ValueNotifier<int?>(null);
  Timer? _autoplayTimer;
  bool _autoplayCancelled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(applyPlayerOrientation());
    _resumeAt = widget.startAt;
    _initialSource =
        _video.streamUrl == widget.video.streamUrl ? widget.initialSource : null;
    _adopted = widget.adopted;
    final adopted = _adopted;
    if (adopted != null) _speed = adopted.speed;
    _initializePlayer();
  }

  Future<void> _initializePlayer({bool refreshSource = false}) async {
    if (_isLeaving) return;
    final generation = ++_initializationGeneration;
    _hideTimer?.cancel();
    _scrubTimer?.cancel();
    _stallTimer?.cancel();
    _autoplayTimer?.cancel();
    _countdown.value = null;
    _stalled.value = false;
    _scrubTarget.value = null;
    if (refreshSource && _lastPosition > const Duration(seconds: 3)) {
      _resumeAt = _lastPosition - const Duration(seconds: 2);
    }

    final oldController = _controller;
    _controller = null;
    if (oldController != null) {
      oldController.removeListener(_onControllerChanged);
      await _disposeController(oldController);
    }
    await _waitForPendingDisposals();
    if (!mounted || generation != _initializationGeneration || _isLeaving) {
      return;
    }

    setState(() {
      _loading = true;
      _problem = null;
      _completed = false;
      _showControls = true;
    });

    final adopted = _adopted;
    if (adopted != null) {
      _adopted = null;
      final live = adopted.controller;
      _activeUrl = adopted.url;
      _activeHeaders = adopted.headers;
      _activeIsFile = adopted.isFile;
      _controller = live;
      live.addListener(_onControllerChanged);
      _usedKnownSource = false;
      _retryBase = live.value.position;
      _applyVideoOrientation(live);
      setState(() {
        _loading = false;
        _reconnecting = false;
        _manualReload = false;
      });
      _onControllerChanged();
      _scheduleHide();
      return;
    }

    final lookAgain = refreshSource && !(_reconnecting && _autoRetries < 2);
    if (lookAgain && _localPath == null && !_video.isReel) {
      try {
        final fresh = await videoRepository.resolveForPlayback(
          _video.copyWith(streamUrl: ''),
          refresh: true,
        );
        if (fresh.streamUrl.trim().isNotEmpty) _video = _preferred(fresh);
      } catch (error) {
        debugPrint('[PLAYER] Source refresh failed, reusing URL: $error');
      }
      if (!mounted || generation != _initializationGeneration || _isLeaving) {
        return;
      }
    }

    VideoPlayerController? controller;
    try {
      controller = await _createController(generation, refresh: lookAgain);
      if (controller == null) return;
      _controller = controller;
      await controller.initialize().timeout(_initTimeout);
      if (!mounted || generation != _initializationGeneration || _isLeaving) {
        await _disposeController(controller);
        return;
      }

      controller.addListener(_onControllerChanged);
      await controller.setLooping(false);

      final startAt = _resumeAt;
      _resumeAt = null;
      if (startAt != null && startAt > Duration.zero) {
        final limit = controller.value.duration - const Duration(seconds: 5);
        final target = limit > Duration.zero && startAt > limit ? limit : startAt;
        await controller.seekTo(target);
      }
      await controller.play();
      if (_speed != 1.0) await controller.setPlaybackSpeed(_speed);
      if (!mounted || generation != _initializationGeneration || _isLeaving) {
        controller.removeListener(_onControllerChanged);
        await _disposeController(controller);
        return;
      }

      _usedKnownSource = false;
      _retryBase = controller.value.position;
      _applyVideoOrientation(controller);
      if (_recordedId != _video.id) {
        _recordedId = _video.id;
        HistoryStore.instance.record(_video);
      }
      setState(() {
        _loading = false;
        _reconnecting = false;
        _manualReload = false;
      });
      _onControllerChanged();
      _scheduleHide();
    } catch (error, stackTrace) {
      debugPrint('[PLAYER] Initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (controller != null) {
        controller.removeListener(_onControllerChanged);
        if (identical(_controller, controller)) _controller = null;
        await _disposeController(controller);
      }
      if (!mounted || generation != _initializationGeneration || _isLeaving) {
        return;
      }
      if (_usedKnownSource) {
        _usedKnownSource = false;
        unawaited(_initializePlayer(refreshSource: true));
        return;
      }
      if (_reconnecting && _autoRetries < _maxAutoRetries) {
        _autoRetries++;
        await Future<void>.delayed(Duration(seconds: 2 * _autoRetries));
        if (!mounted || generation != _initializationGeneration || _isLeaving) {
          return;
        }
        unawaited(_initializePlayer(refreshSource: true));
        return;
      }
      setState(() {
        _loading = false;
        _reconnecting = false;
        _manualReload = false;
        _problem = _describeProblem(error);
      });
    }
  }

  void _applyVideoOrientation(VideoPlayerController controller) {
    if (_orientationForced) return;
    final size = controller.value.size;
    final vertical = size.width > 0 && size.height > size.width;
    _setPortrait(vertical);
  }

  void _setPortrait(bool portrait) {
    if (_portrait == portrait) return;
    _portrait = portrait;
    unawaited(applyPlayerOrientation(portrait: portrait));
  }

  void _toggleOrientation() {
    _orientationForced = true;
    _setPortrait(!_portrait);
    _revealControls();
  }

  Future<VideoPlayerController?> _createController(
    int generation, {
    bool refresh = false,
  }) async {
    final localPath = _localPath;
    if (localPath != null && File(localPath).existsSync()) {
      _activeUrl = localPath;
      _activeIsFile = true;
      _activeHeaders = null;
      return VideoPlayerController.file(File(localPath));
    }
    _localPath = null;
    _activeIsFile = false;

    final known = _initialSource;
    if (known != null && !refresh) {
      _initialSource = null;
      _usedKnownSource = true;
      _activeUrl = known.url;
      _activeHeaders = known.headers;
      return VideoPlayerController.networkUrl(
        Uri.parse(known.url),
        httpHeaders: known.headers,
      );
    }
    _initialSource = null;

    final rawUrl = _video.streamUrl.trim();
    if (rawUrl.isEmpty) {
      throw const _MissingStreamException();
    }
    final streamUri = Uri.tryParse(rawUrl);
    if (streamUri == null ||
        (streamUri.scheme != 'http' && streamUri.scheme != 'https') ||
        streamUri.host.isEmpty) {
      throw const FormatException('Invalid video stream URL.');
    }

    if (_video.isReel) {
      _activeUrl = rawUrl;
      _activeHeaders = kReelMediaHeaders;
      return VideoPlayerController.networkUrl(
        streamUri,
        httpHeaders: kReelMediaHeaders,
      );
    }
    final source = await resolvePlaybackSource(
      streamUri,
      _video.pageUrl,
      refresh: refresh,
    );
    if (!mounted || generation != _initializationGeneration || _isLeaving) {
      return null;
    }

    final finalUri = Uri.parse(source.url);
    ResLog.video(pageUrl: _video.pageUrl, videoUrl: source.url);
    _activeUrl = source.url;
    _activeHeaders = source.headers;
    return VideoPlayerController.networkUrl(
      finalUri,
      httpHeaders: source.headers,
    );
  }

  Video _preferred(Video video) {
    final url = video.streamForQuality(AppSettings.instance.preferredQuality);
    return url == video.streamUrl ? video : video.copyWith(streamUrl: url);
  }

  void _setQuality(int height) {
    AppSettings.instance.setPreferredQuality(height);
    final previous = _video;
    final next = _preferred(_video);
    if (next.streamUrl == _video.streamUrl) return;
    _video = next;
    if (_localPath != null || _isLeaving) return;
    _reloadOk = false;
    unawaited(() async {
      await _reloadInPlace(keepSource: true);
      // Couldn't switch: keep state (and the wheel) in sync with what plays.
      if (!_reloadOk && mounted && _video.streamUrl == next.streamUrl) {
        _video = previous;
      }
    }());
  }

  Future<void> _reloadInPlace({bool auto = false, bool keepSource = false}) async {
    final old = _controller;
    if (old == null || !old.value.isInitialized || _isLeaving) return;
    if (_reloading.value) return;

    final token = ++_reloadToken;
    final generation = _initializationGeneration;
    final wasPlaying = old.value.isPlaying;
    _reloading.value = true;
    if (!auto) Haptics.play(Haptic.light);
    _stallTimer?.cancel();
    _stalled.value = false;

    bool cancelled() =>
        token != _reloadToken ||
        !mounted ||
        _isLeaving ||
        generation != _initializationGeneration;

    final lookAgain = !keepSource && (!auto || _autoRetries >= 2);
    VideoPlayerController? fresh;
    try {
      if (lookAgain && _localPath == null && !_video.isReel) {
        try {
          final next = await videoRepository.resolveForPlayback(
            _video.copyWith(streamUrl: ''),
            refresh: true,
          );
          if (next.streamUrl.trim().isNotEmpty) _video = _preferred(next);
        } catch (error) {
          debugPrint('[PLAYER] Source refresh failed, reusing URL: $error');
        }
      }
      if (cancelled()) return;

      fresh = await _createController(generation, refresh: lookAgain);
      if (fresh == null || cancelled()) {
        if (fresh != null) await _disposeController(fresh);
        return;
      }
      await fresh.initialize().timeout(_initTimeout);
      if (cancelled()) {
        await _disposeController(fresh);
        return;
      }
      await fresh.setLooping(false);
      final target = old.value.position;
      if (target > Duration.zero) await fresh.seekTo(target);
      if (_speed != 1.0) await fresh.setPlaybackSpeed(_speed);
      if (wasPlaying) await fresh.play();
      if (cancelled()) {
        await _disposeController(fresh);
        return;
      }

      old.removeListener(_onControllerChanged);
      fresh.addListener(_onControllerChanged);
      _controller = fresh;
      _retryBase = fresh.value.position;
      _buffering.value = false;
      _stalled.value = false;
      _spinnerTimer?.cancel();
      _spinnerTimer = null;
      if (mounted) setState(() => _problem = null);
      unawaited(_disposeController(old));
      _onControllerChanged();
      fresh = null;
      _reloadOk = true;
    } catch (error) {
      debugPrint('[PLAYER] Reload in place failed: ${error.runtimeType}');
      if (fresh != null) await _disposeController(fresh);
      if (!cancelled() && mounted) {
        showToast(
          context,
          'Couldn\u2019t reconnect. Try again in a moment.',
          aboveBar: false,
        );
      }
    } finally {
      if (token == _reloadToken && mounted) _reloading.value = false;
    }
  }

  void _cancelReload() {
    if (!_reloading.value) return;
    _reloadToken++;
    _reloading.value = false;
    Haptics.play(Haptic.light);
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      unawaited(_safeControllerAction(controller.pause));
    }
  }

  Future<void> _enterPip() async {
    final controller = _controller;
    final url = _activeUrl;
    if (controller == null ||
        url == null ||
        !controller.value.isInitialized ||
        _isLeaving ||
        _pipBusy ||
        _reloading.value) {
      return;
    }
    _pipBusy = true;
    final position = controller.value.position;
    try {
      await controller.pause();
      final started = await NativeBridge.instance.startPip(
        video: _video,
        url: url,
        isFile: _activeIsFile,
        headers: _activeHeaders ?? const <String, String>{},
        position: position,
        rate: _speed,
        queue: widget.queue,
      );
      if (!mounted || _isLeaving) return;
      if (started) {
        await _leave();
        return;
      }
      showToast(
        context,
        'Picture in Picture isn\u2019t available right now.',
        aboveBar: false,
      );
      await controller.play();
    } catch (_) {
      try {
        await controller.play();
      } catch (_) {}
    } finally {
      _pipBusy = false;
    }
  }

  Future<void> _minimize() async {
    final controller = _controller;
    final url = _activeUrl;
    if (controller == null ||
        url == null ||
        !controller.value.isInitialized ||
        _isLeaving ||
        _popping ||
        _loading ||
        _problem != null ||
        _reloading.value) {
      return;
    }
    _popping = true;
    _isLeaving = true;
    ++_initializationGeneration;
    ++_reloadToken;
    _hideTimer?.cancel();
    _scrubTimer?.cancel();
    _stallTimer?.cancel();
    _spinnerTimer?.cancel();
    _autoplayTimer?.cancel();
    _saveProgress();
    PlaybackProgress.instance.flush();
    controller.removeListener(_onControllerChanged);
    _controller = null;
    MiniPlayer.instance.adopt(
      MiniSession(
        video: _video,
        controller: controller,
        url: url,
        headers: _activeHeaders,
        isFile: _activeIsFile,
        speed: _speed,
        queue: widget.queue,
      ),
    );
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  void _reload() {
    if (_reloading.value) {
      _cancelReload();
      return;
    }
    final controller = _controller;
    if (controller != null &&
        controller.value.isInitialized &&
        _problem == null &&
        !_loading) {
      unawaited(_reloadInPlace());
      return;
    }
    _autoRetries = 0;
    _reconnecting = false;
    _manualReload = true;
    unawaited(_initializePlayer(refreshSource: true));
  }

  void _autoReconnect() {
    if (!mounted || _isLeaving || _reloading.value) return;
    if (_autoRetries >= _maxAutoRetries) {
      _controller?.removeListener(_onControllerChanged);
      setState(() {
        _reconnecting = false;
        _loading = false;
        _problem = const _PlaybackProblem(
          'Playback stopped',
          'The stream was interrupted. Check your connection and try again.',
          Icons.error_outline_rounded,
        );
      });
      return;
    }
    _autoRetries++;
    final controller = _controller;
    if (controller != null && controller.value.isInitialized && !_loading) {
      unawaited(_reloadInPlace(auto: true));
      return;
    }
    controller?.removeListener(_onControllerChanged);
    setState(() => _reconnecting = true);
    unawaited(_initializePlayer(refreshSource: true));
  }

  Future<void> _disposeController(VideoPlayerController controller) {
    final existing = _disposalFutures[controller];
    if (existing != null) return existing;

    final disposal = _pendingDisposals.then(
      (_) => _disposeControllerSafely(controller),
    );
    _disposalFutures[controller] = disposal;
    _pendingDisposals = disposal;
    return disposal;
  }

  static Future<void> _disposeControllerSafely(
    VideoPlayerController controller,
  ) async {
    try {
      await controller.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {
    }
  }

  static Future<void> _waitForPendingDisposals() async {
    while (true) {
      final pending = _pendingDisposals;
      await pending;
      if (identical(pending, _pendingDisposals)) return;
    }
  }

  Future<bool> _releaseBeforeExit() {
    return _releaseTask ??= _releaseControllerBeforeExit();
  }

  Future<bool> _releaseControllerBeforeExit() async {
    _isLeaving = true;
    ++_initializationGeneration;
    _hideTimer?.cancel();
    _scrubTimer?.cancel();
    _stallTimer?.cancel();
    _spinnerTimer?.cancel();
    _autoplayTimer?.cancel();
    ++_reloadToken;
    _saveProgress();
    PlaybackProgress.instance.flush();

    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      try {
        if (controller.value.isInitialized) await controller.pause();
      } catch (_) {
      }
      await _disposeController(controller);
    }
    await _waitForPendingDisposals();
    return true;
  }

  void _handleBack() {
    if (_popping) return;
    final canHideControls = _showControls &&
        _problem == null &&
        !_loading &&
        !_completed &&
        (_controller?.value.isInitialized ?? false);
    if (canHideControls) {
      _hideControls();
      return;
    }
    unawaited(_leave());
  }

  Future<void> _leave() async {
    if (_popping) return;
    _popping = true;
    try {
      await _releaseBeforeExit().timeout(
        const Duration(seconds: 4),
        onTimeout: () => true,
      );
    } catch (error) {
      debugPrint('[PLAYER] Release before exit failed: $error');
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  void _saveProgress() {
    final value = _controller?.value;
    if (value == null || !value.isInitialized) return;
    PlaybackProgress.instance.save(
      _video.id,
      value.position,
      value.duration,
    );
  }

  _PlaybackProblem _describeProblem(Object error) {
    if (error is _MissingStreamException) {
      return const _PlaybackProblem(
        'No video link',
        'This video doesn\u2019t have a playable link right now.',
        Icons.link_off_rounded,
      );
    }
    if (error is FormatException) {
      return const _PlaybackProblem(
        'Invalid video link',
        'The link for this video isn\u2019t valid, so it can\u2019t be played.',
        Icons.link_off_rounded,
      );
    }
    if (error is TimeoutException ||
        error is SocketException ||
        error is HttpException) {
      return const _PlaybackProblem(
        'Connection problem',
        'The video server didn\u2019t respond. Check your network and try again.',
        Icons.wifi_off_rounded,
      );
    }
    return const _PlaybackProblem(
      'Playback failed',
      'This video couldn\u2019t be played. Try again, or go back and pick another.',
      Icons.error_outline_rounded,
    );
  }

  void _onControllerChanged() {
    if (!mounted || _isLeaving) return;
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;

    if (value.hasError) {
      if (_problem == null && !_loading && !_reloading.value) {
        debugPrint('[PLAYER] Controller error: ${value.errorDescription}');
        _autoReconnect();
      }
      return;
    }

    if (value.isInitialized) {
      _lastPosition = value.position;
      if (_autoRetries > 0 &&
          value.position - _retryBase > const Duration(seconds: 10)) {
        _autoRetries = 0;
      }
    }

    final atEnd = value.isInitialized &&
        value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 800);

    _playing.value = value.isPlaying;

    final moving = value.position != _lastSeen && value.isPlaying;
    _lastSeen = value.position;
    final buffering = value.isBuffering && !atEnd && !moving;
    if (!buffering) {
      _spinnerTimer?.cancel();
      _spinnerTimer = null;
      if (_buffering.value) {
        _buffering.value = false;
        _stallTimer?.cancel();
        _stalled.value = false;
      }
    } else if (!_buffering.value && _spinnerTimer == null) {
      _spinnerTimer = Timer(const Duration(milliseconds: 700), () {
        _spinnerTimer = null;
        final current = _controller;
        if (!mounted || _isLeaving || current == null) return;
        if (current.value.isBuffering && !_completed && !_buffering.value) {
          _buffering.value = true;
          _stallTimer?.cancel();
          _stallTimer = Timer(_stallAfter, _onStalled);
        }
      });
    }

    final finished = atEnd && !value.isPlaying;
    if (finished != _completed) {
      setState(() {
        _completed = finished;
        if (finished) {
          _showControls = false;
          _hideTimer?.cancel();
          PlaybackProgress.instance.markCompleted(_video.id);
        }
      });
      if (finished) {
        _startAutoplay();
      } else {
        _autoplayTimer?.cancel();
        _countdown.value = null;
      }
    }
  }

  Video? get _nextVideo {
    final queue = widget.queue;
    if (queue == null) return null;
    final index = queue.indexWhere((video) => video.id == _video.id);
    if (index < 0 || index + 1 >= queue.length) return null;
    return queue[index + 1];
  }

  Video? get _previousVideo {
    final queue = widget.queue;
    if (queue == null) return null;
    final index = queue.indexWhere((video) => video.id == _video.id);
    if (index <= 0) return null;
    return queue[index - 1];
  }

  void _startAutoplay() {
    _autoplayTimer?.cancel();
    if (_autoplayCancelled ||
        _nextVideo == null ||
        !AppSettings.instance.autoplayNext) {
      _countdown.value = null;
      return;
    }
    _countdown.value = _autoplaySeconds;
    _autoplayTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _isLeaving) {
        timer.cancel();
        return;
      }
      final left = (_countdown.value ?? 0) - 1;
      if (left <= 0) {
        timer.cancel();
        _countdown.value = null;
        unawaited(_playNext());
      } else {
        _countdown.value = left;
      }
    });
  }

  void _cancelAutoplay() {
    _autoplayTimer?.cancel();
    _countdown.value = null;
    setState(() => _autoplayCancelled = true);
  }

  Future<void> _playNext() => _switchTo(_nextVideo);

  Future<void> _playPrevious() => _switchTo(_previousVideo);

  Future<void> _switchTo(Video? next) async {
    if (next == null || _isLeaving) return;
    if (!_completed) _saveProgress();
    _autoplayTimer?.cancel();
    _countdown.value = null;
    _autoplayCancelled = false;
    _video = next;
    _localPath = DownloadStore.instance.localPath(next.id);
    _orientationForced = false;
    _lastPosition = Duration.zero;
    _autoRetries = 0;
    _reconnecting = false;
    _resumeAt = PlaybackProgress.instance.resumePosition(next.id);
    await _initializePlayer(refreshSource: true);
  }

  void _onStalled() {
    if (!mounted || _isLeaving || !_buffering.value) return;
    _stalled.value = true;
    _stallTimer?.cancel();
    _stallTimer = Timer(_stallAfter, () {
      if (!mounted || _isLeaving || !_buffering.value) return;
      _autoReconnect();
    });
    _revealControls();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (_isLeaving || controller == null || !controller.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _wasPlayingBeforePause = controller.value.isPlaying;
      if (_wasPlayingBeforePause) {
        unawaited(_safeControllerAction(controller.pause));
      }
    } else if (state == AppLifecycleState.resumed && _wasPlayingBeforePause) {
      _wasPlayingBeforePause = false;
      unawaited(_safeControllerAction(controller.play));
    }
  }

  Future<void> _safeControllerAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) return;
    _hideTimer = Timer(_controlsTimeout, () {
      if (!mounted || _isLeaving || !_showControls) return;
      if (!(_controller?.value.isPlaying ?? false)) return;
      if (_scrubTarget.value != null || _stalled.value) {
        _scheduleHide();
        return;
      }
      _hideControls();
    });
  }

  void _hideControls() {
    if (!mounted || !_showControls) return;
    setState(() => _showControls = false);
  }

  void _revealControls() {
    if (!mounted) return;
    if (!_showControls) setState(() => _showControls = true);
    _scheduleHide();
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isLeaving) {
      return;
    }
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
        _hideTimer?.cancel();
        if (mounted && !_showControls) {
          setState(() => _showControls = true);
        }
      } else {
        await controller.play();
        _revealControls();
      }
    } catch (error) {
      debugPrint('[PLAYER] Toggle failed: $error');
      if (mounted && !_isLeaving) {
        setState(() => _problem = _describeProblem(error));
      }
    }
  }

  Future<void> _replay() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      unawaited(_initializePlayer());
      return;
    }
    _lastPosition = Duration.zero;
    try {
      await controller.seekTo(Duration.zero);
      await controller.play();
      if (mounted) {
        setState(() => _completed = false);
        _revealControls();
      }
    } catch (error) {
      debugPrint('[PLAYER] Replay failed: $error');
      unawaited(_initializePlayer());
    }
  }

  static const int _seekStepSeconds = 10;

  void _scrubBySeconds(int seconds, {bool badge = true}) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isLeaving) {
      return;
    }
    final value = controller.value;
    final base = _scrubTarget.value ?? value.position;
    _scrubTo(base + Duration(seconds: seconds), reveal: badge);
  }

  void _scrubToFraction(double fraction) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isLeaving) {
      return;
    }
    final total = controller.value.duration;
    _scrubTo(total * fraction.clamp(0.0, 1.0));
  }

  void _scrubTo(Duration wanted, {bool reveal = true}) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isLeaving) {
      return;
    }
    final value = controller.value;
    if (_scrubTarget.value == null) _scrubOrigin = value.position;
    var target = wanted;
    if (target < Duration.zero) target = Duration.zero;
    if (value.duration > Duration.zero && target > value.duration) {
      target = value.duration;
    }
    _scrubBadge = reveal;
    _scrubTarget.value = target;
    if (reveal) _revealControls();
    _hideTimer?.cancel();
    _scrubTimer?.cancel();
    _scrubTimer = Timer(_scrubCommitDelay, _commitScrub);
  }

  Future<void> _commitScrub() async {
    final controller = _controller;
    final target = _scrubTarget.value;
    if (controller == null || target == null || _isLeaving) return;
    try {
      await controller.seekTo(target);
    } catch (error) {
      debugPrint('[PLAYER] Seek failed: $error');
    }
    if (!mounted || _isLeaving) return;
    if (_scrubTimer?.isActive ?? false) return;
    _scrubTarget.value = null;
    _scheduleHide();
  }

  void _onScreenTap(TapUpDetails details, double width) {
    if (_problem != null || _loading || _completed) return;
    final x = details.localPosition.dx;
    final _Side? side =
        x < width * 0.38 ? _Side.left : (x > width * 0.62 ? _Side.right : null);
    final now = DateTime.now();
    final last = _lastTapAt;
    final isDouble = last != null &&
        side != null &&
        side == _lastTapSide &&
        now.difference(last) < const Duration(milliseconds: 300);
    _lastTapAt = now;
    _lastTapSide = side;

    if (isDouble) {
      _skip(side == _Side.left ? -_seekStepSeconds : _seekStepSeconds, side);
      return;
    }
    if (_showControls) {
      _hideControls();
    } else {
      _revealControls();
    }
  }

  void _skip(int seconds, _Side side) {
    Haptics.play(Haptic.selection);
    _scrubBySeconds(seconds, badge: false);
    final current = _flash.value;
    final total = (current != null && current.side == side)
        ? current.seconds + seconds.abs()
        : seconds.abs();
    _lastFlash = _SeekFlash(side, total);
    _flash.value = _lastFlash;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) _flash.value = null;
    });
  }

  void _startBoost() {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        !controller.value.isPlaying ||
        _boosting ||
        _isLeaving) {
      return;
    }
    _boosting = true;
    _boost.value = true;
    Haptics.play(Haptic.medium);
    unawaited(_safeControllerAction(() => controller.setPlaybackSpeed(2.0)));
  }

  void _endBoost() {
    if (!_boosting) return;
    _boosting = false;
    _boost.value = false;
    final controller = _controller;
    if (controller == null || _isLeaving) return;
    unawaited(_safeControllerAction(() => controller.setPlaybackSpeed(_speed)));
  }

  static const List<double> _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  static String _speedLabel(double speed) =>
      '${speed == speed.roundToDouble() ? speed.toInt() : speed}x';

  /// Native iOS wheels (UIPickerView) for quality + playback speed.
  Future<void> _pickSpeed() async {
    _hideTimer?.cancel();
    final hasQuality = _video.qualities.length >= 2 && _localPath == null;
    var qualityIndex = 0;
    if (hasQuality && AppSettings.instance.preferredQuality != 0) {
      var i = _video.qualities.indexWhere(
        (option) => option.url == _video.streamUrl,
      );
      // Refreshed links get new tokens, so fall back to the preferred height.
      if (i < 0) {
        i = _video.qualityIndexFor(AppSettings.instance.preferredQuality);
      }
      qualityIndex = i < 0 ? 0 : i + 1;
    }
    final speedIndex =
        _speeds.indexOf(_speed).clamp(0, _speeds.length - 1).toInt();

    final result = await showWheelPicker(
      context,
      title: hasQuality ? 'Quality & Speed' : 'Playback Speed',
      dark: true,
      columns: [
        if (hasQuality)
          WheelColumn(
            title: 'Quality',
            labels: <String>[
              'Auto',
              for (final option in _video.qualities) '${option.height}p',
            ],
            initialIndex: qualityIndex,
          ),
        WheelColumn(
          title: 'Speed',
          labels: <String>[for (final speed in _speeds) _speedLabel(speed)],
          initialIndex: speedIndex,
        ),
      ],
    );
    if (!mounted) return;
    if (result != null) {
      final speed = _speeds[result.last];
      if (hasQuality && result.first != qualityIndex) {
        final choice = result.first;
        _setQuality(choice == 0 ? 0 : _video.qualities[choice - 1].height);
      }
      final controller = _controller;
      if (controller != null && !_isLeaving && speed != _speed) {
        setState(() => _speed = speed);
        await _safeControllerAction(() => controller.setPlaybackSpeed(speed));
      }
    }
    _scheduleHide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _scrubTimer?.cancel();
    _stallTimer?.cancel();
    _autoplayTimer?.cancel();
    _flashTimer?.cancel();
    _spinnerTimer?.cancel();
    ++_reloadToken;
    _saveProgress();
    PlaybackProgress.instance.flush();
    _isLeaving = true;
    ++_initializationGeneration;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      unawaited(_disposeController(controller));
    }
    _stalled.dispose();
    _scrubTarget.dispose();
    _countdown.dispose();
    _playing.dispose();
    _buffering.dispose();
    _boost.dispose();
    _reloading.dispose();
    _dragging.dispose();
    _flash.dispose();
    unawaited(applyBrowseOrientation());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final VideoPlayerController? live =
        (controller != null && controller.value.isInitialized && _problem == null)
            ? controller
            : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              fit: StackFit.expand,
              children: [
                if (live != null)
                  Positioned.fill(
                    child: _FadeIn(
                      key: ObjectKey(live),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: live.value.aspectRatio > 0
                              ? live.value.aspectRatio
                              : 16 / 9,
                          child: VideoPlayer(live),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => _onScreenTap(details, width),
                    onVerticalDragEnd: (details) {
                      if ((details.primaryVelocity ?? 0) > 700) {
                        unawaited(_minimize());
                      }
                    },
                    onLongPressStart: (_) => _startBoost(),
                    onLongPressEnd: (_) => _endBoost(),
                    onLongPressCancel: _endBoost,
                  ),
                ),
                _buildBuffering(),
                _buildSeekFlash(width),
                _buildBoostBadge(),
                _buildScrubBadge(),
                if (live != null) _buildControls(live),
                _buildLoading(),
                AnimatedSwitcher(
                  duration: Motion.fade,
                  child: _buildOverlay() ??
                      const SizedBox.shrink(key: ValueKey<String>('none')),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBuffering() {
    return IgnorePointer(
      child: ValueListenableBuilder<bool>(
        valueListenable: _buffering,
        builder: (context, buffering, _) => AnimatedOpacity(
          opacity: buffering && !_completed && !_loading ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: const Spinner(size: 40, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    final text = _reconnecting
        ? 'Reconnecting\u2026 ($_autoRetries/$_maxAutoRetries)'
        : (_manualReload ? 'Reloading\u2026' : 'Preparing video\u2026');
    return IgnorePointer(
      ignoring: !_loading,
      child: AnimatedOpacity(
        opacity: _loading ? 1 : 0,
        duration: Motion.fade,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Spinner(size: 36, color: Colors.white),
                    const SizedBox(height: Gaps.lg),
                    Text(text, style: darkText.body),
                  ],
                ),
              ),
              Positioned(
                left: context.hMargin + context.safe.left,
                top: context.safe.top + 10,
                child: RoundIconButton(
                  icon: CupertinoIcons.chevron_back,
                  iconSize: 20,
                  tapSize: kMinTapSize,
                  label: 'Back',
                  onTap: () => unawaited(_leave()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _buildOverlay() {
    final problem = _problem;
    if (problem != null) {
      return ColoredBox(
        key: const ValueKey<String>('problem'),
        color: Colors.black,
        child: StatusView(
          dark: true,
          icon: problem.icon,
          title: problem.title,
          message: problem.message,
          actionLabel: 'Try again',
          onAction: _reload,
          secondaryLabel: 'Back',
          onSecondary: () => unawaited(_leave()),
        ),
      );
    }
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    if (!ready || !_completed) return null;

    final next = _nextVideo;
    if (next != null &&
        !_autoplayCancelled &&
        AppSettings.instance.autoplayNext) {
      return _buildUpNext(next);
    }
    return ColoredBox(
      key: const ValueKey<String>('finished'),
      color: const Color(0xCC000000),
      child: StatusView(
        dark: true,
        icon: Icons.check_circle_outline_rounded,
        title: 'Finished watching',
        message: _video.title,
        actionLabel: 'Watch again',
        actionIcon: Icons.replay_rounded,
        onAction: () => unawaited(_replay()),
        secondaryLabel: 'Back',
        onSecondary: () => unawaited(_leave()),
      ),
    );
  }

  Widget _buildUpNext(Video next) {
    return ColoredBox(
      key: const ValueKey<String>('upnext'),
      color: const Color(0xCC000000),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Gaps.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('UP NEXT', style: darkText.overline),
                const SizedBox(height: Gaps.sm),
                Text(
                  next.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: darkText.headline,
                ),
                const SizedBox(height: Gaps.xs),
                ValueListenableBuilder<int?>(
                  valueListenable: _countdown,
                  builder: (context, left, _) => Text(
                    left == null ? 'Starting\u2026' : 'Playing in $left\u2026',
                    style: darkText.body,
                  ),
                ),
                const SizedBox(height: Gaps.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Gaps.sm,
                  runSpacing: Gaps.sm,
                  children: [
                    AppButton(
                      label: 'Cancel',
                      icon: Icons.close_rounded,
                      style: AppButtonStyle.secondary,
                      onDark: true,
                      onPressed: _cancelAutoplay,
                    ),
                    AppButton(
                      label: 'Play now',
                      icon: Icons.skip_next_rounded,
                      onPressed: () => unawaited(_playNext()),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrubBadge() {
    return IgnorePointer(
      child: ValueListenableBuilder<Duration?>(
        valueListenable: _scrubTarget,
        builder: (context, target, _) {
          if (target != null) {
            final delta = target - _scrubOrigin;
            final forward = !delta.isNegative;
            final seconds = delta.inSeconds.abs();
            final deltaText = '${forward ? '+' : '\u2212'}'
                '${seconds >= 60 ? _formatDuration(Duration(seconds: seconds)) : '${seconds}s'}';
            _scrubText = '$deltaText   ${_formatDuration(target)}';
          }
          return Align(
            alignment: const Alignment(0, -0.45),
            child: AnimatedOpacity(
              opacity: target != null && _scrubBadge ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: _Pill(child: Text(_scrubText, style: _pillText)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBoostBadge() {
    return IgnorePointer(
      child: ValueListenableBuilder<bool>(
        valueListenable: _boost,
        builder: (context, boosting, _) => Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(top: context.safe.top + 14),
            child: AnimatedOpacity(
              opacity: boosting ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: const _Pill(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fast_forward_rounded, size: 20, color: Colors.white),
                    SizedBox(width: 6),
                    Text('2x', style: _pillText),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSeekFlash(double width) {
    return IgnorePointer(
      child: ValueListenableBuilder<_SeekFlash?>(
        valueListenable: _flash,
        builder: (context, flash, _) {
          final shown = flash ?? _lastFlash;
          Widget half(_Side side) {
            final active = flash != null && flash.side == side;
            final data = shown != null && shown.side == side ? shown : null;
            return Positioned(
              top: 0,
              bottom: 0,
              left: side == _Side.left ? 0 : null,
              right: side == _Side.right ? 0 : null,
              width: width * 0.36,
              child: AnimatedOpacity(
                opacity: active ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Center(
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0x40FFFFFF),
                    ),
                    child: SizedBox(
                      width: 92,
                      height: 92,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            side == _Side.left
                                ? Icons.fast_rewind_rounded
                                : Icons.fast_forward_rounded,
                            size: 28,
                            color: Colors.white,
                          ),
                          Text('${data?.seconds ?? 10}s', style: _pillText),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          return Stack(children: [half(_Side.left), half(_Side.right)]);
        },
      ),
    );
  }

  Widget _buildControls(VideoPlayerController controller) {
    final margin = context.hMargin;
    final safe = context.safe;
    final visible = _showControls && !_completed;
    final gap = context.isPhone ? 18.0 : 28.0;

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: Duration(milliseconds: visible ? 260 : 420),
          curve: Curves.easeInOut,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xB3000000),
                        Color(0x14000000),
                        Color(0xD9000000),
                      ],
                      stops: [0, 0.45, 1],
                    ),
                  ),
                  child: SizedBox.expand(),
                ),
              ),
              Positioned(
                left: margin + safe.left,
                right: margin + safe.right,
                top: safe.top + 10,
                child: _buildTopBar(),
              ),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_previousVideo != null) ...[
                      RoundIconButton(
                        icon: Icons.skip_previous_rounded,
                        label: 'Previous video',
                        size: 42,
                        tapSize: kMinTapSize,
                        iconSize: 26,
                        onTap: () => unawaited(_playPrevious()),
                      ),
                      SizedBox(width: gap),
                    ],
                    RoundIconButton(
                      icon: Icons.replay_10_rounded,
                      label: 'Back 10 seconds',
                      size: 48,
                      iconSize: 30,
                      haptic: Haptic.selection,
                      onTap: () => _scrubBySeconds(-_seekStepSeconds),
                    ),
                    SizedBox(width: gap),
                    ValueListenableBuilder<bool>(
                      valueListenable: _reloading,
                      builder: (context, reloading, _) {
                        if (reloading) {
                          return _ReloadingButton(onTap: _cancelReload);
                        }
                        return ValueListenableBuilder<bool>(
                          valueListenable: _playing,
                          builder: (context, playing, _) => RoundIconButton(
                            icon: playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            label: playing ? 'Pause' : 'Play',
                            size: 64,
                            iconSize: 40,
                            background: const Color(0x4DFFFFFF),
                            onTap: () => unawaited(_togglePlayback()),
                          ),
                        );
                      },
                    ),
                    SizedBox(width: gap),
                    RoundIconButton(
                      icon: Icons.forward_10_rounded,
                      label: 'Forward 10 seconds',
                      size: 48,
                      iconSize: 30,
                      haptic: Haptic.selection,
                      onTap: () => _scrubBySeconds(_seekStepSeconds),
                    ),
                    if (_nextVideo != null) ...[
                      SizedBox(width: gap),
                      RoundIconButton(
                        icon: Icons.skip_next_rounded,
                        label: 'Next video',
                        size: 42,
                        tapSize: kMinTapSize,
                        iconSize: 26,
                        onTap: () => unawaited(_playNext()),
                      ),
                    ],
                  ],
                ),
              ),
              Positioned(
                left: margin + safe.left,
                right: margin + safe.right,
                bottom: safe.bottom + 12,
                child: _ProgressRow(
                  controller: controller,
                  scrubTarget: _scrubTarget,
                  dragging: _dragging,
                  onSeekFraction: _scrubToFraction,
                  onDragStart: () {
                    _dragging.value = true;
                    Haptics.play(Haptic.selection);
                  },
                  onDragEnd: () => _dragging.value = false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        RoundIconButton(
          icon: CupertinoIcons.chevron_back,
          iconSize: 20,
          label: 'Back',
          tapSize: kMinTapSize,
          onTap: () => unawaited(_leave()),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _video.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: darkText.title,
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _stalled,
                builder: (context, stalled, _) => stalled
                    ? Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Connection is slow \u2013 tap reload',
                          style: darkText.caption.copyWith(color: OnDark.error),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Pressable(
          semanticLabel: 'Playback speed',
          haptic: Haptic.selection,
          pressedScale: 0.9,
          onTap: _pickSpeed,
          child: SizedBox(
            height: kMinTapSize,
            child: Center(
              child: Container(
                height: 38,
                margin: const EdgeInsets.only(right: 3),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0x8C000000),
                  borderRadius: BorderRadius.circular(19),
                  border: Border.all(color: const Color(0x26FFFFFF)),
                ),
                child: Text(
                  _speedLabel(_speed),
                  style: darkText.label.copyWith(fontSize: 13),
                ),
              ),
            ),
          ),
        ),
        RoundIconButton(
          icon: Icons.keyboard_arrow_down_rounded,
          label: 'Minimize',
          tapSize: kMinTapSize,
          onTap: () => unawaited(_minimize()),
        ),
        const SizedBox(width: 2),
        if (NativeBridge.instance.pipSupported) ...[
          const SizedBox(width: 2),
          RoundIconButton(
            icon: Icons.picture_in_picture_alt_rounded,
            label: 'Picture in Picture',
          tapSize: kMinTapSize,
            onTap: () => unawaited(_enterPip()),
          ),
        ],
        const SizedBox(width: 2),
        RoundIconButton(
          icon: Icons.screen_rotation_rounded,
          label: 'Rotate',
          tapSize: kMinTapSize,
          onTap: _toggleOrientation,
        ),
        const SizedBox(width: 2),
        RoundIconButton(
          icon: Icons.refresh_rounded,
          label: 'Reload',
          tapSize: kMinTapSize,
          onTap: _reload,
        ),
      ],
    );
  }
}

class _MissingStreamException implements Exception {
  const _MissingStreamException();
}

enum _Side { left, right }

class _SeekFlash {
  const _SeekFlash(this.side, this.seconds);

  final _Side side;
  final int seconds;
}

String _formatDuration(Duration duration) {
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

const TextStyle _pillText = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w700,
  color: Colors.white,
  fontFeatures: [FontFeature.tabularFigures()],
);

class _Pill extends StatelessWidget {
  const _Pill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xB3000000),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: child,
      ),
    );
  }
}

class _FadeIn extends StatelessWidget {
  const _FadeIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: child,
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
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
          value: '${_formatDuration(position)} of ${_formatDuration(total)}',
          child: Row(
            children: [
              SizedBox(
                width: 50,
                child: Text(_formatDuration(position), style: labelStyle),
              ),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      double fractionAt(double dx) =>
                          width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) =>
                            onSeekFraction(fractionAt(d.localPosition.dx)),
                        onHorizontalDragStart: (_) => onDragStart(),
                        onHorizontalDragUpdate: (d) =>
                            onSeekFraction(fractionAt(d.localPosition.dx)),
                        onHorizontalDragEnd: (_) => onDragEnd(),
                        onHorizontalDragCancel: onDragEnd,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          clipBehavior: Clip.none,
                          children: [
                            AnimatedContainer(
                              duration: Motion.quick,
                              height: trackHeight,
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(trackHeight),
                              ),
                            ),
                            AnimatedContainer(
                              duration: Motion.quick,
                              height: trackHeight,
                              width: width * buffered,
                              decoration: BoxDecoration(
                                color: Colors.white38,
                                borderRadius: BorderRadius.circular(trackHeight),
                              ),
                            ),
                            AnimatedContainer(
                              duration: Motion.quick,
                              height: trackHeight,
                              width: width * played,
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                borderRadius: BorderRadius.circular(trackHeight),
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
                      );
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 50,
                child: Text(
                  _formatDuration(total),
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

class _ReloadingButton extends StatelessWidget {
  const _ReloadingButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      semanticLabel: 'Cancel reload',
      pressedScale: 0.9,
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x4DFFFFFF),
          border: Border.all(color: const Color(0x26FFFFFF)),
        ),
        child: const Center(
          child: CupertinoActivityIndicator(radius: 14, color: Colors.white),
        ),
      ),
    );
  }
}
