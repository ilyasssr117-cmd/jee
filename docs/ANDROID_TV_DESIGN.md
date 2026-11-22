# VXTUBE — Android TV interface and remote controls

This implementation keeps the existing touch-first phone pages and selects a separate TV presentation only when the native Android activity reports an Android TV / Google TV device.

## TV-specific screens

- Home: cinematic full-screen featured-video hero, Play/Resume and More Details actions, plus a horizontal Latest Videos shelf.
- Details: full-bleed artwork with dark gradients, title and metadata, description, large Play/Resume / Watchlist / Info actions, and horizontal Related Videos.
- Navigation: fixed left rail for Home, Search, Reels, Library, and Settings. The rail is only added to the TV shell/details route.
- Content-source picker: wider TV dialog with focusable source choices and a large Continue action.
- Horizontal page swipes are disabled on the TV shell; navigation is done through the rail and focusable controls.

## TCL remote mapping

| Physical remote control | VXTUBE behavior |
| --- | --- |
| Direction ring | Moves focus between visible controls/cards |
| Center OK | Activates the focused control |
| Back | Closes dialogs/search or returns to the previous page |
| Menu (three horizontal lines) | Opens the video Info dialog on the Details screen |
| Bookmark | Toggles the Watchlist item while a TV video control is focused, where Favorites is enabled |
| P+ / P− | Next / previous item in the current Details queue |
| Volume, mute, power, TV input, Google Assistant, system Settings and Home | Left to Android TV / the television system; VXTUBE does not intercept them |

There are intentionally no app shortcuts for dedicated Play/Pause, Rewind/Fast Forward, or color keys because those buttons are not present on the supplied TCL remote. Play is an on-screen focused action activated with OK.

## Device profile and orientation

`MainActivity` detects TV mode via Android UI mode and Leanback / television system features, exposes the result through the `com.tv.watch_tube/device` MethodChannel, and requests landscape orientation for TV. Flutter resolves this profile before `runApp`, then keeps Android TV in landscape immersive mode. Android and iOS phones retain the portrait-first browse experience. Desktop and web windows are not forced to portrait.

## Validation status

The manifest XML and TV banner resource were checked, local Dart imports and delimiter balance were checked, and ZIP archives were validated. This workspace does not contain Flutter or Dart SDK binaries, so `flutter analyze`, tests, and an APK build could not be run here. Final key-code behavior (especially Menu and Bookmark) should be confirmed on the actual TCL remote; manufacturers can send different Android key events.
