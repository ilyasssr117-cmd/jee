import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';

import 'vast.dart';

class PreRollAd extends StatefulWidget {
  const PreRollAd({
    super.key,
    required this.ad,
    required this.onFinished,
  });

  final VastAd ad;
  final VoidCallback onFinished;

  @override
  State<PreRollAd> createState() => _PreRollAdState();
}

class _PreRollAdState extends State<PreRollAd>
    with WidgetsBindingObserver {
  static const _initializeTimeout = Duration(seconds: 8);
  static const _playbackTimeout = Duration(seconds: 30);

  late final VideoPlayerController _controller;
  late final VoidCallback _controllerListener;
  final Set<String> _firedEvents = <String>{};
  Timer? _skipTimer;
  Timer? _timeoutTimer;
  int _secondsUntilSkip = 5;
  bool _finished = false;
  bool _resumeAfterLifecycle = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller =
        VideoPlayerController.networkUrl(Uri.parse(widget.ad.videoUrl));
    _controllerListener = _onControllerChanged;
    _controller.addListener(_controllerListener);
    _timeoutTimer = Timer(_playbackTimeout, _finish);
    unawaited(_initializeAndPlay());
  }

  Future<void> _initializeAndPlay() async {
    try {
      await _controller.initialize().timeout(_initializeTimeout);
      if (!mounted || _finished) return;
      setState(() {});
      await _controller.play();
      if (!mounted || _finished) return;
      ping(widget.ad.impressions);
      _track('start');
      _skipTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || _finished) {
          timer.cancel();
          return;
        }
        if (_secondsUntilSkip > 0) {
          setState(() => _secondsUntilSkip--);
        }
      });
    } catch (_) {
      _finish();
    }
  }

  void _onControllerChanged() {
    if (_finished) return;
    final value = _controller.value;
    if (value.hasError) {
      _finish();
      return;
    }
    if (!value.isInitialized || value.duration <= Duration.zero) return;

    final progress =
        value.position.inMilliseconds / value.duration.inMilliseconds;
    if (progress >= 0.25) _track('firstQuartile');
    if (progress >= 0.5) _track('midpoint');
    if (progress >= 0.75) _track('thirdQuartile');
    if (progress >= 0.99) {
      _track('complete');
      _finish();
    }
  }

  void _track(String name) {
    if (_firedEvents.add(name)) ping(widget.ad.events[name] ?? const []);
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _skipTimer?.cancel();
    _timeoutTimer?.cancel();
    widget.onFinished();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _resumeAfterLifecycle = _controller.value.isPlaying;
      if (_resumeAfterLifecycle) unawaited(_controller.pause());
    } else if (state == AppLifecycleState.resumed &&
        _resumeAfterLifecycle &&
        !_finished) {
      _resumeAfterLifecycle = false;
      unawaited(_controller.play());
    }
  }

  Future<void> _openAdvertiser() async {
    final clickUrl = widget.ad.clickUrl;
    if (clickUrl == null) return;
    ping(widget.ad.clickTracking);
    try {
      await launchUrl(
        Uri.parse(clickUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // A failed external launch should not interrupt video playback.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _skipTimer?.cancel();
    _timeoutTimer?.cancel();
    _controller.removeListener(_controllerListener);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _controller.value;
    final safe = MediaQuery.paddingOf(context);
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (value.isInitialized)
            Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openAdvertiser,
                child: AspectRatio(
                  aspectRatio:
                      value.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
                  child: VideoPlayer(_controller),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          Positioned(
            left: 12 + safe.left,
            top: 12 + safe.top,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'Ad 18+',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
          Positioned(
            right: 12 + safe.right,
            bottom: 12 + safe.bottom,
            child: FilledButton(
              onPressed: _secondsUntilSkip == 0 ? _finish : null,
              child: Text(
                _secondsUntilSkip == 0 ? 'Skip' : 'Skip in $_secondsUntilSkip',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
