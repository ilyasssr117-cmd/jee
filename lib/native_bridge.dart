import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'playback_launcher.dart';
import 'playback_source.dart';
import 'playback_progress.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class _PipSession {
  const _PipSession(this.video, this.queue, this.source);

  final Video video;
  final List<Video>? queue;

  final PlaybackSource? source;
}

class NativeBridge {
  NativeBridge._();

  static final NativeBridge instance = NativeBridge._();

  static const MethodChannel _channel = MethodChannel('flow/native');

  _PipSession? _session;
  bool _pipSupported = false;

  bool get pipSupported => _pipSupported;

  Future<void> init() async {
    _channel.setMethodCallHandler(_onCall);
    try {
      _pipSupported = await _channel.invokeMethod<bool>('pipSupported') ?? false;
    } catch (_) {
      _pipSupported = false;
    }
  }

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
      if (started) {
        _session = _PipSession(
          video,
          queue,
          isFile ? null : PlaybackSource(url, headers),
        );
      }
      return started;
    } catch (error) {
      debugPrint('[PIP] start failed: ${error.runtimeType}');
      return false;
    }
  }

  /// Shows or updates the download Live Activity (lock screen / Dynamic
  /// Island). [progress] is 0..1, or negative when unknown.
  Future<void> updateLiveActivity({
    required String title,
    required double progress,
    required int count,
  }) async {
    try {
      await _channel.invokeMethod<bool>('liveUpdate', <String, Object?>{
        'title': title,
        'progress': progress,
        'count': count,
      });
    } catch (_) {}
  }

  Future<void> endLiveActivity({
    String? title,
    bool finished = true,
  }) async {
    try {
      await _channel.invokeMethod<bool>('liveEnd', <String, Object?>{
        if (title != null) 'title': title,
        'finished': finished,
      });
    } catch (_) {}
  }

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
      launchPlayer(
        overlay,
        session.video,
        startAt: position,
        queue: session.queue,
        source: session.source,
      ),
    );
  }
}
