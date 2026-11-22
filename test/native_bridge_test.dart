// Contract tests for the Dart side of the `flow/native` channel.
//
// These pin the exact method names and argument shapes that
// MainActivity.kt (Android) and AppDelegate.swift (iOS) implement,
// and the honest-failure behavior when no native implementation
// answers (MissingPluginException -> false + AppLog, never a fake
// success). Run with `flutter test` on the host; native behavior
// itself still needs a device pass (see docs/ANDROID_NOTES.md).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vxtube_final/native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flow/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void mock(Future<Object?>? Function(MethodCall call) handler) {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('shareFile sends {path} and returns the platform result', () async {
    mock((call) async {
      calls.add(call);
      return true;
    });
    final ok = await NativeBridge.instance.shareFile('/data/files/a.mp4');
    expect(ok, isTrue);
    expect(calls.single.method, 'shareFile');
    expect(calls.single.arguments, <String, Object?>{'path': '/data/files/a.mp4'});
  });

  test('shareText sends {text} to the sharesheet bridge', () async {
    mock((call) async {
      calls.add(call);
      return true;
    });
    final ok = await NativeBridge.instance.shareText('https://x.test/v');
    expect(ok, isTrue);
    expect(calls.single.method, 'shareText');
    expect(calls.single.arguments, <String, Object?>{'text': 'https://x.test/v'});
  });

  test('shareFiles with one path delegates to shareFile', () async {
    mock((call) async {
      calls.add(call);
      return true;
    });
    final ok = await NativeBridge.instance.shareFiles(['/data/files/a.mp4']);
    expect(ok, isTrue);
    expect(calls.single.method, 'shareFile');
  });

  test('shareFiles sends {paths} for multiple files', () async {
    mock((call) async {
      calls.add(call);
      return false;
    });
    final ok = await NativeBridge.instance
        .shareFiles(['/data/files/a.mp4', '/data/files/b.mp4']);
    expect(ok, isFalse, reason: 'platform refusal must surface as false');
    expect(calls.single.method, 'shareFiles');
    expect(calls.single.arguments, <String, Object?>{
      'paths': ['/data/files/a.mp4', '/data/files/b.mp4'],
    });
  });

  test('shareFiles with no paths never touches the channel', () async {
    mock((call) async {
      calls.add(call);
      return true;
    });
    expect(await NativeBridge.instance.shareFiles(const []), isFalse);
    expect(calls, isEmpty);
  });

  test('missing native implementation returns honest false', () async {
    // No mock handler -> MissingPluginException, exactly what Android
    // produced before MainActivity implemented flow/native.
    messenger.setMockMethodCallHandler(channel, null);
    expect(await NativeBridge.instance.shareFile('/x.mp4'), isFalse);
    expect(await NativeBridge.instance.shareText('hi'), isFalse);
  });

  test('platform error returns false instead of throwing', () async {
    mock((call) async => throw PlatformException(code: 'share_failed'));
    expect(await NativeBridge.instance.shareFile('/x.mp4'), isFalse);
  });

  test('keep-screen-on is reference counted across surfaces', () async {
    final bridge = NativeBridge.instance;
    final player = Object();
    final reels = Object();
    expect(bridge.keepScreenOnHeld, isFalse);

    await bridge.acquireKeepScreenOn(reels);
    await bridge.acquireKeepScreenOn(player);
    expect(bridge.keepScreenOnHolderCount, 2);
    expect(bridge.keepScreenOnHeld, isTrue);

    // The nested-surface case: the player closing must NOT release
    // the hold Reels still owns.
    await bridge.releaseKeepScreenOn(player);
    expect(bridge.keepScreenOnHeld, isTrue);
    expect(bridge.keepScreenOnHolderCount, 1);

    // Double-acquire by the same holder counts once.
    await bridge.acquireKeepScreenOn(reels);
    expect(bridge.keepScreenOnHolderCount, 1);

    await bridge.releaseKeepScreenOn(reels);
    expect(bridge.keepScreenOnHeld, isFalse);
    expect(bridge.keepScreenOnHolderCount, 0);

    // Releasing an unknown holder is a safe no-op.
    await bridge.releaseKeepScreenOn(Object());
    expect(bridge.keepScreenOnHeld, isFalse);
  });

  test('takePendingUrl is consumed exactly once', () {
    // No pending URL was delivered in tests.
    expect(NativeBridge.instance.takePendingUrl(), isNull);
    expect(NativeBridge.instance.takePendingUrl(), isNull);
  });
}
