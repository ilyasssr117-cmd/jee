import 'package:flutter/services.dart';

Future<void> applyBrowseOrientation() async {
  try {
    await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp],
    );
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
