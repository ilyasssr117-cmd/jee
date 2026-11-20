import 'package:flutter/services.dart';

Future<void> applyBrowseOrientation() async {
  try {
    var isTelevision = false;
    try {
      isTelevision = await const MethodChannel(
            'com.tv.watch_tube/device',
          ).invokeMethod<bool>('isTelevision') ??
          false;
    } on PlatformException {
      // Older Android builds keep their native orientation preference.
    } on MissingPluginException {
      // Non-Android platforms do not expose the television channel.
    }
    final orientations = isTelevision
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp];
    await SystemChrome.setPreferredOrientations(orientations);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
}

Future<void> applyPlayerOrientation({bool portrait = false}) async {
  try {
    await SystemChrome.setPreferredOrientations(
      portrait
          ? const [DeviceOrientation.portraitUp]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } catch (_) {}
}
