import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/platform_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const deviceChannel = MethodChannel('com.tv.watch_tube/device');
  const platformChannel = SystemChannels.platform;

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(deviceChannel, null)
      ..setMockMethodCallHandler(platformChannel, null);
  });

  test('TV browse orientation stays landscape', () async {
    final orientations = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(deviceChannel, (call) async => true)
      ..setMockMethodCallHandler(platformChannel, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientations
            ..clear()
            ..addAll((call.arguments as List<Object?>)
                .cast<String>()
                .map((value) => value.split('.').last));
        }
        return null;
      });

    await applyBrowseOrientation();

    expect(orientations, <String>['landscapeLeft', 'landscapeRight']);
  });

  test('phone browse orientation stays portrait', () async {
    final orientations = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(deviceChannel, (call) async => false)
      ..setMockMethodCallHandler(platformChannel, (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientations
            ..clear()
            ..addAll((call.arguments as List<Object?>)
                .cast<String>()
                .map((value) => value.split('.').last));
        }
        return null;
      });

    await applyBrowseOrientation();

    expect(orientations, <String>['portraitUp']);
  });
}
