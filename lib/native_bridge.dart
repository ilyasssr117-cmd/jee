import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

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

  void Function(String url)? onOpenUrl;
  String? _pendingUrl;

  String? takePendingUrl() {
    final url = _pendingUrl;
    _pendingUrl = null;
    return url;
  }

  Future<String?> widgetContainerPath() async {
    try {
      return await _channel.invokeMethod<String>('widgetContainer');
    } catch (_) {
      return null;
    }
  }

  /// Reference-counted keep-screen-on coordination.
  ///
  /// Playback surfaces (player, reels) each hold the screen awake
  /// under their own identity. The native FLAG_KEEP_SCREEN_ON is set
  /// on the first acquisition and cleared only when the LAST holder
  /// releases — so a Player opened above Reels no longer kills the
  /// Reels hold when it closes (Phase 5 fix for the nested-request
  /// problem). Holders must release in dispose; a holder that never
  /// releases keeps the screen awake, which is why ownership is
  /// explicit instead of a bare boolean.
  final Set<Object> _keepScreenOnHolders = <Object>{};

  /// Number of live keep-screen-on holders (testing/diagnostics).
  int get keepScreenOnHolderCount => _keepScreenOnHolders.length;

  /// Whether any surface currently holds the screen awake.
  bool get keepScreenOnHeld => _keepScreenOnHolders.isNotEmpty;

  Future<void> acquireKeepScreenOn(Object holder) async {
    final wasHeld = keepScreenOnHeld;
    _keepScreenOnHolders.add(holder);
    if (!wasHeld && keepScreenOnHeld) {
      await _applyKeepScreenOn(true);
    }
  }

  Future<void> releaseKeepScreenOn(Object holder) async {
    final wasHeld = keepScreenOnHeld;
    _keepScreenOnHolders.remove(holder);
    if (wasHeld && !keepScreenOnHeld) {
      await _applyKeepScreenOn(false);
    }
  }

  Future<void> _applyKeepScreenOn(bool enabled) async {
    // Android: FLAG_KEEP_SCREEN_ON. iOS: isIdleTimerDisabled.
    // Other platforms have no bridge implementation: no-op.
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('setKeepScreenOn', <String, Object?>{
        'enabled': enabled,
      });
    } catch (_) {}
  }

  Future<void> reloadWidgets() async {
    try {
      await _channel.invokeMethod<bool>('widgetReload');
    } catch (_) {}
  }

  Future<void> init() async {
    _channel.setMethodCallHandler(_onCall);
    try {
      _pipSupported =
          await _channel.invokeMethod<bool>('pipSupported') ?? false;
    } catch (_) {
      _pipSupported = false;
    }
    try {
      _pendingUrl = await _channel.invokeMethod<String>('takeInitialUrl');
    } catch (_) {}
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
      final started =
          await _channel.invokeMethod<bool>('pipStart', <String, Object?>{
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
      return false;
    }
  }

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

  Future<void> endLiveActivity({String? title, bool finished = true}) async {
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
    } on MissingPluginException {
      // Surfaced, not swallowed: on a platform without a flow/native
      // implementation this is a build/integration bug, not a user
      // error. The caller still gets an honest `false`.
      AppLog.warn('NativeBridge', 'shareFile: no native implementation');
      return false;
    } catch (e) {
      AppLog.warn('NativeBridge', 'shareFile failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Shares plain text (e.g. a video URL) through the platform
  /// sharesheet. Android: ACTION_SEND via MainActivity. Returns false
  /// where no native implementation exists.
  Future<bool> shareText(String text) async {
    try {
      return await _channel.invokeMethod<bool>('shareText', <String, Object?>{
            'text': text,
          }) ??
          false;
    } on MissingPluginException {
      AppLog.warn('NativeBridge', 'shareText: no native implementation');
      return false;
    } catch (e) {
      AppLog.warn('NativeBridge', 'shareText failed: ${e.runtimeType}');
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
    } on MissingPluginException {
      AppLog.warn('NativeBridge', 'shareFiles: no native implementation');
      return false;
    } catch (e) {
      AppLog.warn('NativeBridge', 'shareFiles failed: ${e.runtimeType}');
      return false;
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'openUrl') {
      final url = call.arguments;
      if (url is String) {
        final handler = onOpenUrl;
        if (handler != null) {
          handler(url);
        } else {
          _pendingUrl = url;
        }
      }
      return null;
    }
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
