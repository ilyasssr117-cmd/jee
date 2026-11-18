import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/services/remote_config_service.dart';
import 'package:vxtube_final/widgets/library_view.dart';

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
        'favorites': false,
        'unknown': false,
      },
    };

    test('keeps known flags and only HTTPS update links', () {
      final config = RemoteAppConfig.fromJson(valid);

      expect(config.features['reels'], isFalse);
      expect(config.features['search'], isTrue);
      expect(config.features['favorites'], isFalse);
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

  testWidgets('Library hides Favorites when remote config disables it', (
    tester,
  ) async {
    final remote = RemoteConfigService.instance;
    remote.replaceConfigForTesting(_configWithFavorites(true));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryView(
            onOpen: (_, __) {},
            onBrowse: () {},
            bottomInset: 0,
          ),
        ),
      ),
    );
    expect(find.text('Favorites'), findsOneWidget);

    remote.replaceConfigForTesting(_configWithFavorites(false));
    await tester.pumpAndSettle();
    expect(find.text('Favorites'), findsNothing);
    expect(find.text('Models'), findsOneWidget);
  });
}

RemoteAppConfig _configWithFavorites(bool enabled) {
  final json = <String, Object?>{
    'maintenance_enabled': false,
    'maintenance_message': 'Maintenance',
    'force_update': false,
    'latest_version': '',
    'minimum_version': '',
    'download_url': <String, String>{},
    'features': <String, bool>{
      'reels': true,
      'search': true,
      'downloads': true,
      'favorites': enabled,
    },
  };
  return RemoteAppConfig.fromJson(json);
}
