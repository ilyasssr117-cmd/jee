import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/services/remote_config_service.dart';

void main() {
  group('RemoteAppConfig', () {
    const valid = <String, Object?>{
      'maintenance_enabled': false,
      'maintenance_message': 'Maintenance',
      'force_update': false,
      'latest_version': '2.1.0',
      'minimum_version': '2.0.0',
      'download_url': <String, String>{
        'android': 'https://example.org/app.apk',
        'windows': 'http://example.org/app.zip',
      },
      'features': <String, Object?>{
        'reels': false,
        'search': true,
        'unknown': false,
      },
    };

    test('keeps known flags and only HTTPS update links', () {
      final config = RemoteAppConfig.fromJson(valid);

      expect(config.features['reels'], isFalse);
      expect(config.features['search'], isTrue);
      expect(config.features['downloads'], isTrue);
      expect(config.features.containsKey('unknown'), isFalse);
      expect(config.downloadUrls, const <String, String>{
        'android': 'https://example.org/app.apk',
      });
      final credentialUrl = RemoteAppConfig.fromJson(
        Map<String, Object?>.from(valid)
          ..['download_url'] = const <String, String>{
            'android': 'https://user:pass@example.org/app.apk',
          },
      );
      expect(credentialUrl.downloadUrls, isEmpty);
    });

    test('rejects malformed required config fields', () {
      expect(
        () => RemoteAppConfig.fromJson(
          Map<String, Object?>.from(valid)..['maintenance_enabled'] = 'yes',
        ),
        throwsFormatException,
      );
      expect(() => RemoteAppConfig.fromJson(null), throwsFormatException);
    });

    test('rejects oversized maintenance text and ignores invalid versions', () {
      expect(
        () => RemoteAppConfig.fromJson(Map<String, Object?>.from(valid)
          ..['maintenance_message'] = List<String>.filled(800, 'x').join()),
        throwsFormatException,
      );
      final config = RemoteAppConfig.fromJson(
        Map<String, Object?>.from(valid)..['minimum_version'] = 'latest!',
      );
      expect(config.minimumVersion, isEmpty);
    });

    test('round trips an accepted configuration through JSON', () {
      final config = RemoteAppConfig.fromJson(valid);
      final restored = RemoteAppConfig.fromJson(config.toJson());

      expect(restored.maintenanceEnabled, config.maintenanceEnabled);
      expect(restored.latestVersion, config.latestVersion);
      expect(restored.features, config.features);
      expect(restored.downloadUrls, config.downloadUrls);
    });
  });
}
