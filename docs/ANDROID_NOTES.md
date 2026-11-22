# Android platform notes

## flow/native channel — now implemented on Android
`NativeBridge` (Dart) talks to a `flow/native` MethodChannel that was
originally implemented **only** in the iOS AppDelegate. On Android
every call threw MissingPluginException and was swallowed, which
meant, silently:

- **Sharing downloaded files always failed** (Downloads → Share,
  album batch share, Save-to-Photos fallback).
- Capability probes (PiP) reported "unsupported" by accident.

`MainActivity.kt` now implements the channel on Android:

| Method | Android behavior |
|---|---|
| `shareText` | Real: ACTION_SEND text/plain chooser (Reels URL sharing); iOS presents UIActivityViewController |
| `shareFile` / `shareFiles` | Real: FileProvider URIs + ACTION_SEND / SEND_MULTIPLE chooser, video MIME by extension, read grants |
| `setKeepScreenOn` | Real: FLAG_KEEP_SCREEN_ON toggle (used by Player and Reels) |
| `takeInitialUrl` | Real: launch intent data string |
| `pipSupported` | **false, truthfully** — see below |
| `pipStop` | no-op success |
| `widgetContainer` | null (no Android app-group container; Dart null-guards it) |
| `widgetReload` / `liveUpdate` / `liveEnd` | false (iOS-only concepts: WidgetKit / Live Activities) |

## Picture-in-Picture on Android — remaining work
iOS PiP is a *native* AVPlayer that takes over the stream (the Dart
side pauses its controller and leaves the page). Android has no
equivalent in this repo yet, and faking `pipSupported=true` with
activity-PiP would strand the user on a paused page. Proper Android
PiP needs a small native player activity (media3/ExoPlayer) that
accepts the same `pipStart` arguments (url, headers, position, rate)
plus session restore — schedule it as native work with device tests.
The manifest would then also need
`android:supportsPictureInPicture="true"` (configChanges already
includes the PiP-required flags).

## Touch targets
Shared minimum tap size is 48dp (`kMinTapSize`), AppButton minimum
height is 48, chip tap height floors at 48. `Pressable` exposes its
enabled/disabled state to accessibility services.

## Keep screen on
Reference-counted in NativeBridge (acquireKeepScreenOn /
releaseKeepScreenOn, keyed by holder identity): the native flag is
set on the first acquisition and cleared only when the last holder
releases, so a Player opened above Reels cannot drop the Reels hold
when it closes. Player holds for its page lifetime; Reels holds
while its section is active; both release on dispose.
