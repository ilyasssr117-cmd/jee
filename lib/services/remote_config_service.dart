import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../local_store.dart';

const String _supabaseUrl = 'https://igoqkqbkctcubozyaxnx.supabase.co';
const String _supabasePublishableKey =
    'sb_publishable_tUy_NmkoqYkUCCuKYA-b5Q_AJUGQs0T';

const Map<String, bool> _defaultFeatures = <String, bool>{
  'reels': true,
  'search': true,
  'downloads': true,
  'favorites': true,
};

/// Public, non-secret configuration delivered by the vxtube-control function.
@immutable
class RemoteAppConfig {
  const RemoteAppConfig({
    this.maintenanceEnabled = false,
    this.maintenanceMessage =
        'VXTUBE is temporarily unavailable. Please try again later.',
    this.forceUpdate = false,
    this.latestVersion = '',
    this.minimumVersion = '',
    this.downloadUrls = const <String, String>{},
    this.features = _defaultFeatures,
  });

  final bool maintenanceEnabled;
  final String maintenanceMessage;
  final bool forceUpdate;
  final String latestVersion;
  final String minimumVersion;
  final Map<String, String> downloadUrls;
  final Map<String, bool> features;

  factory RemoteAppConfig.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid remote config.');
    final json = Map<String, Object?>.from(value);
    if (json['maintenance_enabled'] is! bool ||
        json['force_update'] is! bool ||
        json['maintenance_message'] is! String ||
        (json['maintenance_message'] as String).length > 500 ||
        json['latest_version'] is! String ||
        json['minimum_version'] is! String) {
      throw const FormatException('Invalid remote config fields.');
    }
    final features = <String, bool>{..._defaultFeatures};
    final rawFeatures = json['features'];
    if (rawFeatures != null && rawFeatures is! Map) {
      throw const FormatException('Invalid remote feature flags.');
    }
    if (rawFeatures is Map) {
      for (final name in _defaultFeatures.keys) {
        final flag = rawFeatures[name];
        if (flag == null) continue;
        if (flag is! bool) {
          throw FormatException('Invalid remote feature flag: $name.');
        }
        features[name] = flag;
      }
    }

    final urls = <String, String>{};
    final rawUrls = json['download_url'] ?? json['download_urls'];
    if (rawUrls is Map) {
      for (final entry in rawUrls.entries) {
        if (entry.key is! String || entry.value is! String) continue;
        final uri = Uri.tryParse(entry.value as String);
        if (uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty) {
          urls[entry.key as String] = uri.toString();
        }
      }
    }

    String version(String key) {
      final raw = json[key];
      if (raw is! String ||
          raw.length > 40 ||
          !RegExp(r'^\d+(\.\d+){0,3}([+-][0-9A-Za-z.-]+)?$').hasMatch(raw)) {
        return '';
      }
      return raw;
    }

    final message = json['maintenance_message'];
    return RemoteAppConfig(
      maintenanceEnabled: json['maintenance_enabled'] == true,
      maintenanceMessage: message is String && message.trim().isNotEmpty
          ? message.trim().substring(0, min(message.trim().length, 500))
          : const RemoteAppConfig().maintenanceMessage,
      forceUpdate: json['force_update'] == true,
      latestVersion: version('latest_version'),
      minimumVersion: version('minimum_version'),
      downloadUrls: Map<String, String>.unmodifiable(urls),
      features: Map<String, bool>.unmodifiable(features),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'maintenance_enabled': maintenanceEnabled,
        'maintenance_message': maintenanceMessage,
        'force_update': forceUpdate,
        'latest_version': latestVersion,
        'minimum_version': minimumVersion,
        'download_url': downloadUrls,
        'features': features,
      };
}

/// Supabase-backed remote configuration and installation status.
///
/// The publishable key is intended for public clients; privileged writes and
/// ban decisions are made only by the Edge Function using server credentials.
class RemoteConfigService extends ChangeNotifier {
  RemoteConfigService._();

  static final RemoteConfigService instance = RemoteConfigService._();
  static const String _cacheKey = 'remote_app_config_v1';
  static const String _installationKey = 'vxtube_installation_id_v1';
  static const String _restrictionCacheKey = 'vxtube_restricted_v1';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const Duration _requestTimeout = Duration(seconds: 7);
  static const Duration _refreshInterval = Duration(minutes: 30);

  RemoteAppConfig _config = const RemoteAppConfig();
  Timer? _timer;
  String? _installationId;
  String _platform = 'unknown';
  String _appVersion = '0.0.0';
  bool _initialized = false;
  bool _supabaseReady = false;
  bool _banned = false;
  String? _updateUrl;
  Future<void>? _refreshing;
  bool _refreshQueued = false;

  RemoteAppConfig get config => _config;
  bool get isBanned => _banned;
  bool get isInitialized => _initialized;
  bool get isSupabaseAvailable => _supabaseReady;

  bool isFeatureEnabled(String feature) => _config.features[feature] ?? true;

  bool get updateAvailable =>
      _config.latestVersion.isNotEmpty &&
      _compareVersions(_config.latestVersion, _appVersion) > 0;

  bool get updateRequired =>
      _config.forceUpdate &&
      _config.minimumVersion.isNotEmpty &&
      _compareVersions(_appVersion, _config.minimumVersion) < 0;

  String? get platformDownloadUrl =>
      _config.downloadUrls[_platform] ?? _config.downloadUrls['default'];
  String? get updateUrl => _updateUrl ?? platformDownloadUrl;

  /// Initializes the SDK and restores the last valid configuration locally.
  /// This method performs no network request and is safe to await at startup.
  Future<void> initialize() async {
    if (_initialized) return;
    _config = _readCachedConfig();
    try {
      await Supabase.initialize(
        url: _supabaseUrl,
        publishableKey: _supabasePublishableKey,
      );
      _supabaseReady = true;
    } catch (error) {
      debugPrint(
          '[REMOTE] Supabase initialization unavailable: ${error.runtimeType}');
    }

    try {
      _installationId = await _readOrCreateInstallationId();
      _banned =
          (await _secureStorage.read(key: _restrictionCacheKey)) == 'true';
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.version;
      _platform = _platformName;
    } catch (error) {
      debugPrint(
          '[REMOTE] Installation metadata unavailable: ${error.runtimeType}');
    }
    _initialized = true;
    notifyListeners();
  }

  /// Starts best-effort server registration/config retrieval after the first
  /// frame. The bounded request cannot hold the initial application launch.
  Future<void> start() async {
    if (!_initialized) return;
    await refresh();
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) => unawaited(refresh()));
  }

  Future<void> onForeground() => refresh();

  Future<void> refresh() {
    final active = _refreshing;
    if (active != null) {
      _refreshQueued = true;
      return active;
    }
    late final Future<void> operation;
    operation = _refreshOnce().whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
      if (_refreshQueued) {
        _refreshQueued = false;
        unawaited(refresh());
      }
    });
    _refreshing = operation;
    return operation;
  }

  Future<void> _refreshOnce() async {
    final installationId = _installationId;
    if (!_initialized || installationId == null || !_supabaseReady) {
      return;
    }
    try {
      final response = await Supabase.instance.client.functions
          .invoke('vxtube-control', body: <String, Object?>{
        'action': 'bootstrap',
        'installation_id': installationId,
        'platform': _platform,
        'app_version': _appVersion,
      }).timeout(_requestTimeout);
      final data = response.data;
      if (data is! Map) throw const FormatException('Invalid server response.');
      final result = Map<String, Object?>.from(data);
      final rawConfig = result['config'];
      final validated = RemoteAppConfig.fromJson(rawConfig);
      final restricted = result['restricted'];
      if (restricted is! bool) {
        throw const FormatException('Missing installation status.');
      }
      final updateUrl = result['update_url'];

      // Publish fresh server state before best-effort local persistence. A
      // secure-storage write failure must never leave the UI on stale config.
      _config = validated;
      _banned = restricted;
      _updateUrl = _validatedUrl(updateUrl);
      notifyListeners();
      unawaited(_persistConfig(validated));
      unawaited(_persistRestriction(restricted));
    } on TimeoutException {
      debugPrint('[REMOTE] Bootstrap timed out; keeping the last valid state.');
    } catch (error) {
      // Do not include response bodies, request headers, URLs, or keys here.
      debugPrint(
        '[REMOTE] Bootstrap rejected or failed (${error.runtimeType}); '
        'keeping the last valid state.',
      );
    }
  }

  Future<void> _persistConfig(RemoteAppConfig config) async {
    try {
      await LocalStore.writeStringAsync(_cacheKey, jsonEncode(config.toJson()));
    } catch (error) {
      debugPrint('[REMOTE] Config cache write failed (${error.runtimeType}).');
    }
  }

  Future<void> _persistRestriction(bool restricted) async {
    try {
      await _secureStorage.write(
        key: _restrictionCacheKey,
        value: restricted ? 'true' : 'false',
      );
    } catch (error) {
      debugPrint(
        '[REMOTE] Restriction cache write failed (${error.runtimeType}).',
      );
    }
  }

  @visibleForTesting
  void replaceConfigForTesting(RemoteAppConfig config) {
    _config = config;
    notifyListeners();
  }

  void disposeService() {
    _timer?.cancel();
  }

  RemoteAppConfig _readCachedConfig() {
    try {
      final raw = LocalStore.readString(_cacheKey);
      if (raw == null) return const RemoteAppConfig();
      return RemoteAppConfig.fromJson(jsonDecode(raw));
    } catch (error) {
      debugPrint(
        '[REMOTE] Cached config rejected (${error.runtimeType}); using defaults.',
      );
      return const RemoteAppConfig();
    }
  }

  Future<String> _readOrCreateInstallationId() async {
    var id = await _secureStorage.read(key: _installationKey);
    if (id != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) return id;
    final random = Random.secure();
    id = List<int>.generate(16, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    await _secureStorage.write(key: _installationKey, value: id);
    return id;
  }

  static String? _validatedUrl(Object? raw) {
    if (raw is! String) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.toString();
  }

  static int _compareVersions(String left, String right) {
    ({List<int> numbers, List<String>? prerelease}) parse(String value) {
      final withoutBuild = value.split('+').first;
      final separator = withoutBuild.indexOf('-');
      final numeric =
          separator < 0 ? withoutBuild : withoutBuild.substring(0, separator);
      final prerelease = separator < 0
          ? null
          : withoutBuild.substring(separator + 1).split('.');
      return (
        numbers:
            numeric.split('.').map((part) => int.tryParse(part) ?? 0).toList(),
        prerelease: prerelease,
      );
    }

    final a = parse(left);
    final b = parse(right);
    for (var i = 0; i < max(a.numbers.length, b.numbers.length); i++) {
      final av = i < a.numbers.length ? a.numbers[i] : 0;
      final bv = i < b.numbers.length ? b.numbers[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    if (a.prerelease == null && b.prerelease == null) return 0;
    if (a.prerelease == null) return 1;
    if (b.prerelease == null) return -1;
    for (var i = 0; i < max(a.prerelease!.length, b.prerelease!.length); i++) {
      if (i >= a.prerelease!.length) return -1;
      if (i >= b.prerelease!.length) return 1;
      final av = a.prerelease![i];
      final bv = b.prerelease![i];
      final ai = int.tryParse(av);
      final bi = int.tryParse(bv);
      if (ai != null && bi != null) {
        if (ai != bi) return ai.compareTo(bi);
      } else if (ai != null) {
        return -1;
      } else if (bi != null) {
        return 1;
      } else {
        final compare = av.compareTo(bv);
        if (compare != 0) return compare;
      }
    }
    return 0;
  }

  static String get _platformName {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }
}
