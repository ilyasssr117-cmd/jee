import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

const MethodChannel _deviceChannel =
    MethodChannel('com.tv.watch_tube/device');

bool _isAndroidTv = false;
bool _deviceProfileResolved = false;
Future<bool>? _deviceProfileFuture;

/// True when the app is running on an Android TV / Google TV device.
/// The native Android UI mode is used instead of guessing from screen size.
bool get isAndroidTv => _isAndroidTv;

Future<bool> initializeDeviceProfile() {
  if (_deviceProfileResolved) return Future<bool>.value(_isAndroidTv);
  return _deviceProfileFuture ??= _readDeviceProfile();
}

Future<bool> _readDeviceProfile() async {
  var isTv = false;
  if (!kIsWeb && Platform.isAndroid) {
    try {
      isTv = await _deviceChannel.invokeMethod<bool>('isTelevision') ?? false;
    } on PlatformException {
      isTv = false;
    } on MissingPluginException {
      isTv = false;
    }
  }
  _isAndroidTv = isTv;
  _deviceProfileResolved = true;
  return isTv;
}

Future<void> applyBrowseOrientation() async {
  try {
    final tv = await initializeDeviceProfile();
    await SystemChrome.setPreferredOrientations(
      tv
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(
      tv ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  } catch (_) {}
}

Future<void> applyPlayerOrientation({bool portrait = false}) async {
  try {
    final tv = await initializeDeviceProfile();
    await SystemChrome.setPreferredOrientations(
      !tv && portrait
          ? const [DeviceOrientation.portraitUp]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } catch (_) {}
}
