import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';

/// Navigator of the whole app (used to re-open the player from outside it).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class _PipSession {
  const _PipSession(this.video, this.queue);

  final Video video;
  final List<Video>? queue;
}

/// Talks to the small iOS part of the app (see ios/Runner/AppDelegate.swift):
/// Picture in Picture and the iOS share sheet ("Save Video" / "Save to
/// Files"). Everything returns false / does nothing on platforms without it.
class NativeBridge {
  NativeBridge._();

  static final NativeBridge instance = NativeBridge._();

  static const MethodChannel _channel = MethodChannel('flow/native');

  _PipSession? _session;
  bool _pipSupported = false;

  /// Whether this phone can show Picture in Picture.
  bool get pipSupported => _pipSupported;

  /// Call once at start-up.
  Future<void> init() async {
    _channel.setMethodCallHandler(_onCall);
    try {
      _pipSupported = await _channel.invokeMethod<bool>('pipSupported') ?? false;
    } catch (_) {
      _pipSupported = false; // Not iOS, or the native part isn't installed.
    }
  }

  /// Starts PiP with a second, native player that continues from [position].
  /// Completes with true once the PiP window is really showing.
  Future<bool> startPip({
    required Video video,
    required String url,
    required bool isFile,
    required Map<String, String> headers,
    required Duration position,
    required double rate,
    List<Video>? queue,
  }) async {
    if (!_pipSupported) return false;
    try {
      final started = await _channel.invokeMethod<bool>('pipStart', <String, Object?>{
            'url': url,
            'isFile': isFile,
            'headers': headers,
            'positionMs': position.inMilliseconds,
            'rate': rate,
          }) ??
          false;
      if (started) _session = _PipSession(video, queue);
      return started;
    } catch (error) {
      debugPrint('[PIP] start failed: ${error.runtimeType}');
      return false;
    }
  }

  Future<void> stopPip() async {
    try {
      await _channel.invokeMethod<void>('pipStop');
    } catch (_) {}
  }

  /// Opens the iOS share sheet for a saved video (Save Video, Save to Files…).
  Future<bool> shareFile(String path) async {
    try {
      return await _channel.invokeMethod<bool>('shareFile', <String, Object?>{
            'path': path,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the iOS share sheet for several files at once ("Save N Images" puts
  /// them all in the Photos app). Needs the `shareFiles` method on the iOS
  /// side; returns false when it is missing, so the caller can tell the viewer.
  Future<bool> shareFiles(List<String> paths) async {
    if (paths.isEmpty) return false;
    if (paths.length == 1) return shareFile(paths.first);
    try {
      return await _channel.invokeMethod<bool>('shareFiles', <String, Object?>{
            'paths': paths,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'pipEnded') return null;
    final args = call.arguments;
    final map = args is Map ? args : const <Object?, Object?>{};
    final positionMs = (map['positionMs'] as num?)?.toInt() ?? 0;
    final durationMs = (map['durationMs'] as num?)?.toInt() ?? 0;
    final restore = map['restore'] == true;
    _pipEnded(positionMs, durationMs, restore);
    return null;
  }

  /// The PiP window closed. Nothing stays on screen: the native player is
  /// already released. "Restore" brings the full player back at the same spot.
  void _pipEnded(int positionMs, int durationMs, bool restore) {
    final session = _session;
    _session = null;
    if (session == null) return;
    final position = Duration(milliseconds: positionMs);
    if (durationMs > 0) {
      PlaybackProgress.instance.save(
        session.video.id,
        position,
        Duration(milliseconds: durationMs),
      );
      PlaybackProgress.instance.flush();
    }
    if (!restore) return;
    final overlay = rootNavigatorKey.currentState?.overlay?.context;
    if (overlay == null || !overlay.mounted) return;
    unawaited(
      launchPlayer(overlay, session.video, startAt: position, queue: session.queue),
    );
  }
}
