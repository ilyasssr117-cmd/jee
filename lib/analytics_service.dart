import 'dart:math';

import 'package:crypto/crypto.dart';
import 'app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

class AnalyticsService {
  AnalyticsService._();

  static final AnalyticsService instance = AnalyticsService._();

  static const String _projectKey =
      'phc_vdE5dvQHWDwMLsSvtWetpJftb8MCLYd7QEukGgpWHx22';
  static const String _host = 'https://us.i.posthog.com';
  static const String _installationKey = 'analytics_installation_id_v1';
  static const String _firstSeenKey = 'analytics_first_seen_v1';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  bool _ready = false;
  bool _wasBackgrounded = false;
  String? _installationId;

  bool get isReady => _ready;

  Future<void> initialize() async {
    if (_ready) return;
    final platform = _platformName;
    if (platform == null) return;

    try {
      var installationId = await _secureStorage.read(key: _installationKey);
      if (installationId == null || installationId.isEmpty) {
        installationId = _newInstallationId();
        await _secureStorage.write(
          key: _installationKey,
          value: installationId,
        );
      }

      var firstSeen = await _secureStorage.read(key: _firstSeenKey);
      final firstOpen = firstSeen == null || firstSeen.isEmpty;
      if (firstOpen) {
        firstSeen = DateTime.now().toUtc().toIso8601String();
        await _secureStorage.write(key: _firstSeenKey, value: firstSeen);
      }
      final packageInfo = await PackageInfo.fromPlatform();
      final config = PostHogConfig(_projectKey)
        ..host = _host
        ..captureApplicationLifecycleEvents = false
        ..sessionReplay = false
        // ignore: experimental_member_use
        ..enableWindowsAndLinux = true
        ..personProfiles = PostHogPersonProfiles.never
        ..bootstrap = PostHogBootstrapConfig(distinctId: installationId);

      await Posthog().setup(config);
      _installationId = installationId;
      await identifyInstallation();
      await Posthog().register('platform', platform);
      await Posthog().register('app_version', packageInfo.version);
      await Posthog().register('app_build', packageInfo.buildNumber);
      await Posthog().register('device_type', _deviceType(platform));
      await Posthog().register('first_seen', firstSeen);
      await Posthog().register(
        'app_language',
        PlatformDispatcher.instance.locale.languageCode,
      );
      _ready = true;

      if (firstOpen) {
        await _capture('first_open');
        await _capture('app_open', {'is_first_open': true});
      } else {
        await _capture('app_open', {'is_first_open': false});
      }
      await _capture('app_session_started');
    } catch (error) {
      _ready = false;
    }
  }

  Future<void> identifyInstallation() async {
    final installationId = _installationId;
    if (installationId == null) return;
    final sdkDistinctId = await Posthog().getDistinctId();
    if (sdkDistinctId != installationId) {
      throw StateError('PostHog did not retain the installation identity.');
    }
  }

  void onLifecycleState(AppLifecycleState state) {
    if (!_ready) return;
    if (state == AppLifecycleState.resumed) {
      if (_wasBackgrounded) {
        _wasBackgrounded = false;
        _capture('app_foreground');
        _capture('app_session_started');
      }
      return;
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (!_wasBackgrounded) {
        _wasBackgrounded = true;
        _capture('app_background');
      }
    }
  }

  Future<void> trackVideoPlay(String contentId, {String source = 'player'}) =>
      _capture('video_play', {
        'content_id': _contentId(contentId),
        'source': source,
      });

  Future<void> trackVideoPause(String contentId, {String source = 'player'}) =>
      _capture('video_pause', {
        'content_id': _contentId(contentId),
        'source': source,
      });

  Future<void> trackVideoResume(String contentId, {String source = 'player'}) =>
      _capture('video_resume', {
        'content_id': _contentId(contentId),
        'source': source,
      });

  Future<void> trackVideoComplete(String contentId,
          {String source = 'player'}) =>
      _capture('video_complete', {
        'content_id': _contentId(contentId),
        'source': source,
      });

  Future<void> trackVideoWatchDuration(String contentId, Duration duration,
          {String source = 'player'}) =>
      _capture('video_watch_duration', {
        'content_id': _contentId(contentId),
        'watch_seconds': duration.inSeconds,
        'source': source,
      });

  Future<void> trackSearch(
    String query, {
    required int resultCount,
    required String searchType,
  }) =>
      _capture('search', {
        'query_length': query.runes.length,
        'result_count': resultCount,
        'search_type': searchType,
      });

  Future<void> trackCategoryOpen(String category) =>
      _capture('category_open', {'category_id': _contentId(category)});

  Future<void> trackVideoDetailsOpen(String contentId) => _capture(
        'video_details_open',
        {'content_id': _contentId(contentId)},
      );

  Future<void> trackFavorite(String contentId, {required bool added}) =>
      _capture(added ? 'favorite_added' : 'favorite_removed', {
        'content_id': _contentId(contentId),
      });

  Future<void> trackDownload(
    String status,
    String contentId,
  ) {
    final event = switch (status) {
      'started' => 'video_download_started',
      'completed' => 'video_download_completed',
      'failed' => 'video_download_failed',
      _ => null,
    };
    if (event == null) return Future<void>.value();
    return _capture(event, {'content_id': _contentId(contentId)});
  }

  Future<void> reset() async {
    try {
      await Posthog().reset();
      await Posthog().close();
      await _secureStorage.delete(key: _installationKey);
      await _secureStorage.delete(key: _firstSeenKey);
    } catch (_) {} finally {
      _ready = false;
      _installationId = null;
      _wasBackgrounded = false;
    }
    await initialize();
  }

  Future<void> _capture(String event, [Map<String, Object>? properties]) async {
    // User consent (fix 42): nothing is captured while analytics is off.
    if (!AppSettings.instance.analyticsEnabled) return;
    if (!_ready && event != 'first_open' && event != 'app_open') return;
    try {
      await Posthog().capture(eventName: event, properties: properties);
    } catch (_) {}
  }

  static String _newInstallationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return 'install_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static String _contentId(String id) =>
      sha256.convert(id.codeUnits).toString();

  static String? get _platformName => switch (defaultTargetPlatform) {
        TargetPlatform.android => 'android',
        TargetPlatform.iOS => 'ios',
        TargetPlatform.windows => 'windows',
        _ => null,
      };

  static String _deviceType(String platform) => switch (platform) {
        'windows' => 'desktop',
        _ => 'mobile',
      };
}
