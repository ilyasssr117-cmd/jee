import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'app_theme.dart';
import 'models.dart';
import 'platform_ui.dart';
import 'playback_progress.dart';
import 'tv_focusable.dart';
import 'video_repository.dart';
import 'res_log.dart';
import 'widgets/state_views.dart';
import 'widgets/tv_button.dart';

/// Full-screen TV player.
///
/// Remote mapping:
///  * OK / PLAY-PAUSE ........ play or pause
///  * LEFT / RIGHT / REW / FF  seek (hold to accelerate)
///  * UP / DOWN .............. show controls, move between control rows
///  * BACK ................... leave the player
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.video,
    this.startAt,
    this.queue,
  });

  final Video video;

  /// The list the video was opened from. When one video ends, Autoplay Next
  /// continues with the following entry (null / last entry: nothing to play).
  final List<Video>? queue;

  /// Optional position to resume from.
  final Duration? startAt;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// A playback problem described for the viewer.
class _PlaybackProblem {
  const _PlaybackProblem(this.title, this.message, this.icon);

  final String title;
  final String message;
  final IconData icon;
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  // VideoPlayer uses a native decoder/texture. Keep its asynchronous teardown
  // visible to the next player so opening a second video cannot race disposal.
  static final Expando<Future<void>> _disposalFutures =
      Expando<Future<void>>('tvTubePlayerDisposal');
  static Future<void> _pendingDisposals = Future<void>.value();

  static const Duration _controlsTimeout = Duration(seconds: 4);
  static const Duration _scrubCommitDelay = Duration(milliseconds: 350);
  static const Duration _initTimeout = Duration(seconds: 30);

  final FocusNode _rootNode = FocusNode(debugLabel: 'Player root');
  final FocusNode _backNode = FocusNode(debugLabel: 'Player back');
  final FocusNode _seekNode = FocusNode(debugLabel: 'Player seek bar');
  final FocusNode _playNode = FocusNode(debugLabel: 'Player play/pause');

  /// Pending seek target while the viewer is scrubbing (null otherwise).
  final ValueNotifier<Duration?> _scrubTarget = ValueNotifier<Duration?>(null);
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _buffering = ValueNotifier<bool>(false);

  VideoPlayerController? _controller;
  Timer? _hideTimer;
  Timer? _scrubTimer;
  int _scrubRepeat = 0;
  bool _loading = true;
  bool _showControls = true;
  bool _completed = false;
  bool _wasPlayingBeforePause = false;
  bool _isLeaving = false;
  bool _popping = false;
  Future<bool>? _releaseTask;
  _PlaybackProblem? _problem;
  int _initializationGeneration = 0;

  // Reload / reconnect state.
  static const int _maxAutoRetries = 2;
  static const Duration _stallAfter = Duration(seconds: 12);
  final FocusNode _reloadNode = FocusNode(debugLabel: 'Player reload');
  final ValueNotifier<bool> _stalled = ValueNotifier<bool>(false);
  late Video _video = widget.video; // May be replaced by a fresh stream URL.
  Duration? _resumeAt;
  Duration _lastPosition = Duration.zero;
  Duration _scrubOrigin = Duration.zero;
  Duration _retryBase = Duration.zero;
  Timer? _stallTimer;
  int _autoRetries = 0;
  bool _reconnecting = false;
  bool _manualReload = false;

  // Vertical (9:16) videos: the screen flips to portrait on phones.
  bool _portrait = false;
  bool _orientationForced = false; // The viewer used the rotate button.

  // Autoplay Next. The countdown lives in a ValueNotifier so the one-second
  // tick rebuilds only the small number label, never the whole page.
  static const int _autoplaySeconds = 5;
  final ValueNotifier<int?> _countdown = ValueNotifier<int?>(null);
  Timer? _autoplayTimer;
  bool _autoplayCancelled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Landscape + immersive while watching (phones are portrait elsewhere).
    unawaited(applyPlayerOrientation());
    _resumeAt = widget.startAt;
    _initializePlayer();
  }

  // -------------------------------------------------------------------------
  // Initialisation & teardown
  // -------------------------------------------------------------------------

  /// Starts (or restarts) playback. With [refreshSource] the detail page is
  /// re-read first, because stream URLs can expire, and playback resumes from
  /// where it stopped instead of from the beginning.
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

    if (refreshSource) {
      try {
        final fresh = await videoRepository.resolveForPlayback(
          _video.copyWith(streamUrl: ''),
        );
        if (fresh.streamUrl.trim().isNotEmpty) _video = fresh;
      } catch (error) {
        // Fall back to the URL we already have; init will report real errors.
        debugPrint('[PLAYER] Source refresh failed, reusing URL: $error');
      }
      if (!mounted || generation != _initializationGeneration || _isLeaving) {
        return;
      }
    }

    VideoPlayerController? controller;
    try {
      final rawUrl = _video.streamUrl.trim();
      debugPrint('[PLAYER] URL attempting to play: $rawUrl');
      if (rawUrl.isEmpty) {
        throw const _MissingStreamException();
      }
      final streamUri = Uri.tryParse(rawUrl);
      if (streamUri == null ||
          (streamUri.scheme != 'http' && streamUri.scheme != 'https') ||
          streamUri.host.isEmpty) {
        throw const FormatException('Invalid video stream URL.');
      }

      // Some sources/CDNs reject native ExoPlayer requests without the same
      // browser-like headers used to open the detail page. Prefer that page as
      // the Referer, and only fall back to the stream origin when unavailable.
      final pageUri = Uri.tryParse(_video.pageUrl?.trim() ?? '');
      final pageOrigin = pageUri != null &&
              (pageUri.scheme == 'http' || pageUri.scheme == 'https') &&
              pageUri.host.isNotEmpty
          ? pageUri.origin
          : streamUri.origin;
      final referer = pageUri != null &&
              (pageUri.scheme == 'http' || pageUri.scheme == 'https') &&
              pageUri.host.isNotEmpty
          ? pageUri.toString()
          : '$pageOrigin/';

      debugPrint('[PLAYER] Initializing stream host=${streamUri.host}');
      ResLog.video(
        pageUrl: _video.pageUrl,
        videoUrl: streamUri.toString(),
      );
      controller = VideoPlayerController.networkUrl(
        streamUri,
        httpHeaders: <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 11; TV) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Referer': referer,
          'Origin': pageOrigin,
          'Accept': '*/*',
          'Cookie': 'kt_acctoken=OTQuMTA5LjI4LjI0MSwxNjAuMTc3LjE3Ni44NQ',
        },
      );
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
      if (!mounted || generation != _initializationGeneration || _isLeaving) {
        controller.removeListener(_onControllerChanged);
        await _disposeController(controller);
        return;
      }

      _retryBase = controller.value.position;
      _applyVideoOrientation(controller);
      setState(() {
        _loading = false;
        _reconnecting = false;
        _manualReload = false;
      });
      _onControllerChanged();
      _focusSeekBarSoon();
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

  /// Phones only: a vertical video (width < height) flips the screen to
  /// portrait so it fills it; anything else stays landscape. Once the viewer
  /// presses the rotate button their choice wins for this video.
  void _applyVideoOrientation(VideoPlayerController controller) {
    if (!isPhoneDevice || _orientationForced) return;
    final size = controller.value.size;
    final vertical = size.width > 0 && size.height > size.width;
    _setPortrait(vertical);
  }

  void _setPortrait(bool portrait) {
    if (_portrait == portrait) return;
    _portrait = portrait;
    unawaited(applyPlayerOrientation(portrait: portrait));
  }

  /// Rotate button: flip between portrait and landscape by hand.
  void _toggleOrientation() {
    _orientationForced = true;
    _setPortrait(!_portrait);
    _revealControls();
  }

  /// Manual reload (Reload button / "Try again"): fresh URL, same position.
  void _reload() {
    _autoRetries = 0;
    _reconnecting = false;
    _manualReload = true;
    unawaited(_initializePlayer(refreshSource: true));
  }

  /// Automatic recovery from a stream that dropped mid-playback.
  void _autoReconnect() {
    if (!mounted || _isLeaving) return;
    // Stop reacting to the broken controller while it is being replaced.
    _controller?.removeListener(_onControllerChanged);
    if (_autoRetries >= _maxAutoRetries) {
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
    setState(() => _reconnecting = true);
    unawaited(_initializePlayer(refreshSource: true));
  }

  Future<void> _disposeController(VideoPlayerController controller) {
    final existing = _disposalFutures[controller];
    if (existing != null) return existing;

    // Serialize native teardown so two platform decoders are never being
    // released at the same time during rapid video changes.
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
      // Bounded: a stuck native release must never block every later player
      // (or the exit path) behind it.
      await controller.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {
      // A native player may already have been released while a route was
      // closing. Never let cleanup failures prevent opening another video.
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
    // Multiple fast Back presses share one awaited release operation.
    return _releaseTask ??= _releaseControllerBeforeExit();
  }

  Future<bool> _releaseControllerBeforeExit() async {
    _isLeaving = true;
    ++_initializationGeneration;
    _hideTimer?.cancel();
    _scrubTimer?.cancel();
    _stallTimer?.cancel();
    _autoplayTimer?.cancel();
    _saveProgress();
    PlaybackProgress.instance.flush();

    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerChanged);
      try {
        if (controller.value.isInitialized) await controller.pause();
      } catch (_) {
        // The native player can already be stopping as the route is popped.
      }
      await _disposeController(controller);
    }
    await _waitForPendingDisposals();
    return true;
  }

  /// BACK: if the controls are on screen, hide them first; BACK again leaves.
  void _handleBack() {
    if (_popping) return; // Already leaving: ignore extra BACK presses.
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

  /// Leaves the player after the native decoder has been released.
  ///
  /// `Navigator.pop` does not consult [PopScope] (only `maybePop` / the system
  /// BACK key do), so popping here is safe even with `canPop: false`. The
  /// release is bounded and wrapped in try/finally so a stuck or failing
  /// native player can never leave BACK dead.
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

  // -------------------------------------------------------------------------
  // Errors
  // -------------------------------------------------------------------------

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

  // -------------------------------------------------------------------------
  // Controller events
  // -------------------------------------------------------------------------

  void _onControllerChanged() {
    // Cheap by design: this fires several times a second. Only state that the
    // page itself depends on triggers setState; position updates are rendered
    // by small ListenableBuilders.
    if (!mounted || _isLeaving) return;
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;

    if (value.hasError) {
      if (_problem == null && !_loading) {
        debugPrint('[PLAYER] Controller error: ${value.errorDescription}');
        _autoReconnect();
      }
      return;
    }

    if (value.isInitialized) {
      _lastPosition = value.position;
      // Playback is healthy again once it has advanced a little.
      if (_autoRetries > 0 &&
          value.position - _retryBase > const Duration(seconds: 10)) {
        _autoRetries = 0;
      }
    }

    // The end of the stream: the position reached the duration. Some decoders
    // keep reporting `isBuffering` (and never `isPlaying`) once they get
    // there, which used to leave an endless spinner on a finished video.
    final atEnd = value.isInitialized &&
        value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 800);

    _playing.value = value.isPlaying;
    final buffering = value.isBuffering && !atEnd;
    if (_buffering.value != buffering) {
      _buffering.value = buffering;
      _stallTimer?.cancel();
      if (buffering) {
        _stallTimer = Timer(_stallAfter, _onStalled);
      } else {
        _stalled.value = false;
      }
    }

    final finished = atEnd && !value.isPlaying;
    if (finished != _completed) {
      setState(() {
        _completed = finished;
        if (finished) {
          _showControls = false;
          _hideTimer?.cancel();
          // Reached the end: nothing to resume, and the card shows "watched".
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

  // -------------------------------------------------------------------------
  // Autoplay Next
  // -------------------------------------------------------------------------

  /// The entry after the current one in [PlayerPage.queue], if any.
  Video? get _nextVideo {
    final queue = widget.queue;
    if (queue == null) return null;
    final index = queue.indexWhere((video) => video.id == _video.id);
    if (index < 0 || index + 1 >= queue.length) return null;
    return queue[index + 1];
  }

  /// The entry before the current one in [PlayerPage.queue], if any.
  Video? get _previousVideo {
    final queue = widget.queue;
    if (queue == null) return null;
    final index = queue.indexWhere((video) => video.id == _video.id);
    if (index <= 0) return null;
    return queue[index - 1];
  }

  void _startAutoplay() {
    _autoplayTimer?.cancel();
    if (_autoplayCancelled || _nextVideo == null) {
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

  /// CANCEL: stay on the "Finished watching" screen instead.
  void _cancelAutoplay() {
    _autoplayTimer?.cancel();
    _countdown.value = null;
    setState(() => _autoplayCancelled = true);
  }

  /// Switches this same player to the next video (one controller at a time;
  /// the old one is released before the new one is created).
  Future<void> _playNext() => _switchTo(_nextVideo);

  Future<void> _playPrevious() => _switchTo(_previousVideo);

  Future<void> _switchTo(Video? next) async {
    if (next == null || _isLeaving) return;
    if (!_completed) _saveProgress(); // Keep where we stopped in this one.
    _autoplayTimer?.cancel();
    _countdown.value = null;
    _autoplayCancelled = false;
    _video = next;
    _orientationForced = false;
    _lastPosition = Duration.zero;
    _autoRetries = 0;
    _reconnecting = false;
    _resumeAt = PlaybackProgress.instance.resumePosition(next.id);
    await _initializePlayer(refreshSource: true);
  }

  /// Buffering for too long: show the controls and put focus on Reload.
  void _onStalled() {
    if (!mounted || _isLeaving || !_buffering.value) return;
    _stalled.value = true;
    // Still stuck a while later: reconnect on our own with a fresh URL.
    _stallTimer?.cancel();
    _stallTimer = Timer(_stallAfter, () {
      if (!mounted || _isLeaving || !_buffering.value) return;
      _autoReconnect();
    });
    _revealControls(focusSeekBar: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _showControls && _stalled.value) {
        _reloadNode.requestFocus();
      }
    });
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
      // Ignore late platform callbacks during app pause/resume.
    }
  }

  // -------------------------------------------------------------------------
  // Controls visibility
  // -------------------------------------------------------------------------

  void _scheduleHide() {
    _hideTimer?.cancel();
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) return;
    _hideTimer = Timer(_controlsTimeout, () {
      if (!mounted || _isLeaving || !_showControls) return;
      if (!(_controller?.value.isPlaying ?? false)) return;
      if (_scrubTarget.value != null || _stalled.value) {
        _scheduleHide(); // Still scrubbing / stalled: try again later.
        return;
      }
      _hideControls();
    });
  }

  void _hideControls() {
    if (!mounted || !_showControls) return;
    setState(() => _showControls = false);
    // Hand focus back to the root so every key keeps working while hidden.
    _rootNode.requestFocus();
  }

  /// Shows the controls (if hidden) and optionally focuses the seek bar.
  void _revealControls({bool focusSeekBar = true}) {
    if (!mounted) return;
    if (!_showControls) {
      setState(() => _showControls = true);
      if (focusSeekBar) _focusSeekBarSoon();
    }
    _scheduleHide();
  }

  void _focusSeekBarSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _showControls && !_completed && _problem == null) {
        _seekNode.requestFocus();
      }
    });
  }

  // -------------------------------------------------------------------------
  // Playback actions
  // -------------------------------------------------------------------------

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
          _focusSeekBarSoon();
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
        _focusSeekBarSoon();
      }
    } catch (error) {
      debugPrint('[PLAYER] Replay failed: $error');
      unawaited(_initializePlayer());
    }
  }

  /// Every seek step is exactly 10 seconds (also while a key is held).
  static const int _seekStepSeconds = 10;

  void _scrub(int direction, {required bool repeat}) {
    _scrubRepeat = repeat ? _scrubRepeat + 1 : 0;
    _scrubBySeconds(direction * _seekStepSeconds);
  }

  /// Moves the (debounced) seek target by [seconds]. The actual `seekTo` is
  /// only issued once the viewer pauses, so holding a key stays smooth.
  void _scrubBySeconds(int seconds) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isLeaving) {
      return;
    }
    final value = controller.value;
    final base = _scrubTarget.value ?? value.position;
    _scrubTo(base + Duration(seconds: seconds));
  }

  /// Touch: tap or drag on the seek bar ([fraction] 0..1 of the duration).
  void _scrubToFraction(double fraction) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isLeaving) {
      return;
    }
    final total = controller.value.duration;
    _scrubTo(total * fraction.clamp(0.0, 1.0));
  }

  void _scrubTo(Duration wanted) {
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
    _scrubTarget.value = target;
    _revealControls();
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
    // The page may have been closed while the seek was running.
    if (!mounted || _isLeaving) return;
    // A newer scrub may have started while this seek was running.
    if (_scrubTimer?.isActive ?? false) return;
    _scrubTarget.value = null;
    _scrubRepeat = 0;
    _scheduleHide();
  }

  // -------------------------------------------------------------------------
  // Key handling
  // -------------------------------------------------------------------------

  static bool _isActivation(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  /// Handles media keys everywhere, and every key while the root itself has
  /// focus (controls hidden, or just revealed and not focused yet). While the
  /// controls own focus, arrows are left to focus traversal.
  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isDown = event is KeyDownEvent;
    final isRepeat = event is KeyRepeatEvent;
    final ready = _problem == null && !_loading && !_completed;

    if (key == LogicalKeyboardKey.mediaStop) {
      if (isDown) unawaited(_leave());
      return KeyEventResult.handled;
    }

    if (!ready) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (isDown) unawaited(_togglePlayback());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      if (isDown && !(_controller?.value.isPlaying ?? true)) {
        unawaited(_togglePlayback());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      if (isDown && (_controller?.value.isPlaying ?? false)) {
        unawaited(_togglePlayback());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _scrub(-1, repeat: isRepeat);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _scrub(1, repeat: isRepeat);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaSkipBackward ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (isDown) _scrubBySeconds(-_seekStepSeconds);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaSkipForward ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      if (isDown) _scrubBySeconds(_seekStepSeconds);
      return KeyEventResult.handled;
    }

    if (!_showControls || node.hasPrimaryFocus) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _scrub(-1, repeat: isRepeat);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _scrub(1, repeat: isRepeat);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        _revealControls();
        _focusSeekBarSoon();
        return KeyEventResult.handled;
      }
      if (_isActivation(key) || key == LogicalKeyboardKey.space) {
        if (isDown) unawaited(_togglePlayback());
        return KeyEventResult.handled;
      }
    } else {
      // Any remote activity keeps the controls on screen.
      _scheduleHide();
    }
    return KeyEventResult.ignored;
  }

  /// Seek bar: LEFT/RIGHT scrub, OK toggles playback, UP/DOWN pick the row.
  KeyEventResult _onSeekKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _scrub(-1, repeat: event is KeyRepeatEvent);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _scrub(1, repeat: event is KeyRepeatEvent);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _backNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _playNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (_isActivation(key)) {
      if (event is KeyDownEvent) unawaited(_togglePlayback());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _scrubTimer?.cancel();
    _stallTimer?.cancel();
    _autoplayTimer?.cancel();
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
    _rootNode.dispose();
    _backNode.dispose();
    _seekNode.dispose();
    _playNode.dispose();
    _reloadNode.dispose();
    _stalled.dispose();
    _scrubTarget.dispose();
    _countdown.dispose();
    _playing.dispose();
    _buffering.dispose();
    unawaited(applyBrowseOrientation());
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    // Non-null only while there is a healthy, initialised controller.
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
        body: Focus(
          focusNode: _rootNode,
          autofocus: true,
          onKeyEvent: _onRootKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showControls ? _hideControls() : _revealControls(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (live != null)
                  Center(
                    child: AspectRatio(
                      aspectRatio: live.value.aspectRatio > 0
                          ? live.value.aspectRatio
                          : 16 / 9,
                      child: VideoPlayer(live),
                    ),
                  ),
                if (live != null && !_completed) _buildBufferingIndicator(),
                if (live != null && !_completed) _buildControls(live),
                if (live != null && !_completed) _buildSeekBadge(),
                if (_loading) _buildLoading(),
                if (_problem != null) _buildProblem(_problem!),
                if (live != null && _completed) _buildFinished(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBufferingIndicator() {
    return ValueListenableBuilder<bool>(
      valueListenable: _buffering,
      builder: (context, buffering, _) {
        if (!buffering) return const SizedBox.shrink();
        return const IgnorePointer(child: TvSpinner(size: 56));
      },
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TvSpinner(size: 52),
          SizedBox(height: context.s(Gaps.lg)),
          Text(
            _reconnecting
                ? 'Reconnecting\u2026 ($_autoRetries/$_maxAutoRetries)'
                : (_manualReload
                    ? 'Reloading\u2026'
                    : 'Preparing video\u2026'),
            style: AppText.body,
          ),
        ],
      ),
    );
  }

  Widget _buildProblem(_PlaybackProblem problem) {
    // A scope of its own so the Retry button can take focus from the root.
    return FocusScope(
      child: ColoredBox(
        color: Colors.black,
        child: TvStatusView(
          icon: problem.icon,
          title: problem.title,
          message: problem.message,
          actionLabel: 'Try again',
          onAction: _reload,
          secondaryLabel: 'Back',
          onSecondary: () => unawaited(_leave()),
        ),
      ),
    );
  }

  Widget _buildFinished() {
    final next = _nextVideo;
    if (next != null && !_autoplayCancelled) return _buildUpNext(next);
    return FocusScope(
      child: ColoredBox(
        color: const Color(0xCC000000),
        child: TvStatusView(
          icon: Icons.check_circle_outline_rounded,
          title: 'Finished watching',
          message: _video.title,
          actionLabel: 'Watch again',
          actionIcon: Icons.replay_rounded,
          onAction: () => unawaited(_replay()),
          secondaryLabel: 'Back',
          onSecondary: () => unawaited(_leave()),
        ),
      ),
    );
  }

  /// "Up next" with a short countdown. CANCEL has focus, so OK stops it.
  Widget _buildUpNext(Video next) {
    return FocusScope(
      child: ColoredBox(
        color: const Color(0xCC000000),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(context.s(Gaps.xl)),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: context.s(640)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('UP NEXT', style: AppText.overline),
                  SizedBox(height: context.s(Gaps.sm + 4)),
                  Text(
                    next.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppText.headline,
                  ),
                  SizedBox(height: context.s(Gaps.sm)),
                  ValueListenableBuilder<int?>(
                    valueListenable: _countdown,
                    builder: (context, left, _) => Text(
                      left == null ? 'Starting\u2026' : 'Playing in $left\u2026',
                      style: AppText.body,
                    ),
                  ),
                  SizedBox(height: context.s(Gaps.xl)),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: context.s(Gaps.md),
                    runSpacing: context.s(Gaps.md),
                    children: [
                      TvButton(
                        label: 'Cancel',
                        icon: Icons.close_rounded,
                        autofocus: true,
                        onPressed: _cancelAutoplay,
                      ),
                      TvButton(
                        label: 'Play now',
                        icon: Icons.skip_next_rounded,
                        style: TvButtonStyle.secondary,
                        onPressed: () => unawaited(_playNext()),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Big "+30s  12:34" pill shown while a seek is pending.
  Widget _buildSeekBadge() {
    return IgnorePointer(
      child: ValueListenableBuilder<Duration?>(
        valueListenable: _scrubTarget,
        builder: (context, target, _) {
          if (target == null) return const SizedBox.shrink();
          final delta = target - _scrubOrigin;
          final forward = !delta.isNegative;
          final seconds = delta.inSeconds.abs();
          final deltaText = '${forward ? '+' : '\u2212'}'
              '${seconds >= 60 ? _formatDuration(Duration(seconds: seconds)) : '${seconds}s'}';
          return Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xD9000000),
                borderRadius: BorderRadius.circular(context.s(Radii.pill)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.s(Gaps.lg),
                  vertical: context.s(Gaps.sm + 4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      forward
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      size: context.s(34),
                      color: AppColors.textPrimary,
                    ),
                    SizedBox(width: context.s(Gaps.sm + 4)),
                    Text(deltaText, style: AppText.title),
                    SizedBox(width: context.s(Gaps.md)),
                    Text(
                      _formatDuration(target),
                      style: AppText.title.copyWith(
                        color: AppColors.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildControls(VideoPlayerController controller) {
    final margin = context.hMargin;
    return AnimatedOpacity(
      opacity: _showControls ? 1 : 0,
      duration: Motion.scroll,
      child: IgnorePointer(
        ignoring: !_showControls,
        // Hidden controls must not be focusable or traversable.
        child: ExcludeFocus(
          excluding: !_showControls,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xCC000000), Color(0x00000000), Color(0xD9000000)],
                stops: [0, 0.4, 1],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                margin + context.safe.left,
                context.s(Gaps.screenV) + context.safe.top,
                margin + context.safe.right,
                context.s(Gaps.screenV) + context.safe.bottom,
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      _RoundControl(
                        icon: Icons.arrow_back_rounded,
                        label: 'Back',
                        focusNode: _backNode,
                        onTap: () => unawaited(_leave()),
                      ),
                      SizedBox(width: context.s(Gaps.md)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _video.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.title,
                            ),
                            ValueListenableBuilder<bool>(
                              valueListenable: _stalled,
                              builder: (context, stalled, _) => stalled
                                  ? Padding(
                                      padding: EdgeInsets.only(top: context.s(4)),
                                      child: Text(
                                        'Connection is slow \u2013 press OK to reload',
                                        style: AppText.body
                                            .copyWith(color: AppColors.error),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: context.s(Gaps.md)),
                      if (context.isPhone) ...[
                        _RoundControl(
                          icon: Icons.screen_rotation_rounded,
                          label: 'Rotate',
                          onTap: _toggleOrientation,
                        ),
                        SizedBox(width: context.s(Gaps.md)),
                      ],
                      _RoundControl(
                        icon: Icons.refresh_rounded,
                        label: 'Reload',
                        focusNode: _reloadNode,
                        onTap: _reload,
                      ),
                    ],
                  ),
                  const Spacer(),
                  _ProgressRow(
                    controller: controller,
                    scrubTarget: _scrubTarget,
                    focusNode: _seekNode,
                    onKey: _onSeekKey,
                    onSeekFraction: _scrubToFraction,
                  ),
                  SizedBox(height: context.s(Gaps.md)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_previousVideo != null) ...[
                        _RoundControl(
                          icon: Icons.skip_previous_rounded,
                          label: 'Previous video',
                          onTap: () => unawaited(_playPrevious()),
                        ),
                        SizedBox(width: context.s(context.isPhone ? Gaps.md : Gaps.xl)),
                      ],
                      _RoundControl(
                        icon: Icons.replay_10_rounded,
                        label: 'Back 10 seconds',
                        onTap: () => _scrubBySeconds(-10),
                      ),
                      SizedBox(width: context.s(context.isPhone ? Gaps.md : Gaps.xl)),
                      ValueListenableBuilder<bool>(
                        valueListenable: _playing,
                        builder: (context, playing, _) => _RoundControl(
                          icon: playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          label: playing ? 'Pause' : 'Play',
                          large: true,
                          focusNode: _playNode,
                          onTap: () => unawaited(_togglePlayback()),
                        ),
                      ),
                      SizedBox(width: context.s(context.isPhone ? Gaps.md : Gaps.xl)),
                      _RoundControl(
                        icon: Icons.forward_10_rounded,
                        label: 'Forward 10 seconds',
                        onTap: () => _scrubBySeconds(10),
                      ),
                      if (_nextVideo != null) ...[
                        SizedBox(width: context.s(context.isPhone ? Gaps.md : Gaps.xl)),
                        _RoundControl(
                          icon: Icons.skip_next_rounded,
                          label: 'Next video',
                          onTap: () => unawaited(_playNext()),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MissingStreamException implements Exception {
  const _MissingStreamException();
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

String _formatDuration(Duration duration) {
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

/// Circular, remote-focusable control button.
class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.label,
    required this.onTap,
    this.focusNode,
    this.large = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final diameter = context.s(large ? 84 : 64);
    return TvFocusable(
      semanticLabel: label,
      focusNode: focusNode,
      onTap: onTap,
      scale: 1.1,
      scrollAlignment: null,
      builder: (context, focused) => AnimatedContainer(
        duration: Motion.quick,
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: focused
              ? AppColors.textPrimary
              : (large ? const Color(0x33FFFFFF) : const Color(0x99000000)),
          border: Border.all(
            color: focused ? AppColors.textPrimary : const Color(0x33FFFFFF),
            width: 2,
          ),
        ),
        child: Icon(
          icon,
          size: context.s(large ? 52 : 36),
          color: focused ? AppColors.background : AppColors.textPrimary,
        ),
      ),
    );
  }
}

/// Seek bar with elapsed / total time. Focusable; the owning page handles keys.
class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    required this.controller,
    required this.scrubTarget,
    required this.focusNode,
    required this.onKey,
    required this.onSeekFraction,
  });

  final ValueChanged<double> onSeekFraction;
  final VideoPlayerController controller;
  final ValueNotifier<Duration?> scrubTarget;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKey;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller,
        scrubTarget,
        focusNode,
      ]),
      builder: (context, _) {
        final value = controller.value;
        final total = value.duration;
        final position = scrubTarget.value ?? value.position;
        final totalMs = total.inMilliseconds;
        final played =
            totalMs > 0
                ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0).toDouble()
                : 0.0;
        final buffered = totalMs > 0 && value.buffered.isNotEmpty
            ? (value.buffered.last.end.inMilliseconds / totalMs)
                .clamp(0.0, 1.0)
                .toDouble()
            : 0.0;
        final focused = focusNode.hasFocus;
        final labelWidth = context.s(84);
        final trackHeight = context.s(focused ? 10 : 6);
        final thumb = context.s(22);

        return Semantics(
          label: 'Seek bar',
          value: '${_formatDuration(position)} of ${_formatDuration(total)}',
          child: Focus(
            focusNode: focusNode,
            onKeyEvent: onKey,
            child: Row(
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    _formatDuration(position),
                    style: AppText.label.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: SizedBox(
                    height: context.s(36),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        double fractionAt(double dx) =>
                            width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) =>
                              onSeekFraction(fractionAt(d.localPosition.dx)),
                          onHorizontalDragUpdate: (d) =>
                              onSeekFraction(fractionAt(d.localPosition.dx)),
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
                              child: AnimatedOpacity(
                                opacity: focused ? 1 : 0,
                                duration: Motion.quick,
                                child: Container(
                                  width: thumb,
                                  height: thumb,
                                  decoration: const BoxDecoration(
                                    color: AppColors.textPrimary,
                                    shape: BoxShape.circle,
                                  ),
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
                  width: labelWidth,
                  child: Text(
                    _formatDuration(total),
                    textAlign: TextAlign.end,
                    style: AppText.label.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
