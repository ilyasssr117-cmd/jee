# Android TV display and remote-control fix

This project now detects Android TV through the native Android UI mode / Leanback features.

- Android TV: requests landscape-left / landscape-right and immersive full-screen mode.
- Phones: retain portrait browsing and edge-to-edge system bars.
- The video player stays landscape on Android TV, including when the player UI attempts to switch to portrait.
- The content-source selection dialog is wider on TV, uses larger targets, and exposes visible focus for D-pad navigation.
- Main-section `PageView` touch/gesture paging is disabled on TV; navigation remains available through focus/remote navigation and the app's tab controls.
- The Android manifest declares touchscreen as optional and adds a Leanback launcher entry and TV banner.

## Validate on a TV

1. Build and install the app on the Android TV device.
2. Open VXTUBE and wait for the intro to finish.
3. On the content-source dialog, use Up/Down to move the focus, OK to select an option, then Down to reach Continue and press OK.
4. Confirm the app fills the 16:9 screen. The phone build should continue to use portrait orientation.

The source archive was updated, but an APK was not built in this environment because Flutter/Dart and the Android Gradle wrapper executable are unavailable here.
