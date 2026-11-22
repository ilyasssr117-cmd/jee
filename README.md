# VXTUBE

Premium video streaming app for Android, Android TV / Google TV, iOS
and Windows. Browse, search, download and watch videos and reels from
configurable content sources, with favorites, history, resume points
and a remote-configurable feature/maintenance system.

## Architecture

- **Flutter/Dart**, single codebase. State: `ChangeNotifier` stores
  (`AppSettings`, `FavoritesStore`, `HistoryStore`, `DownloadStore`,
  `PlaybackProgress`, …) persisted through one `LocalStore` layer.
- **Content pipeline**: `VideoRepository` → per-source scrapers
  (`lib/scraper.dart`, `lib/xxx_follow_trans_reels.dart`) with strict
  HTML/JSON parsing and an in-memory + disk request cache.
- **Playback**: `video_player` (+ media_kit on Windows) behind
  `PlaybackLauncher` / `MiniPlayerController`; Reels use a pooled
  controller window with preloading.
- **Backend**: Supabase. The client ships only the *publishable* key.
  All privileged access goes through Edge Functions
  (`vxtube-control` — public bootstrap/remote-config, apikey-validated
  and rate-limited; `vxtube-admin` — token-gated config writes;
  `telegram-control`). RLS is enabled with no client policies;
  `service_role` never leaves the server.
- **Remote config**: validated strictly on client and server
  (maintenance mode, force-update, feature flags, download URLs).
- **Analytics**: PostHog, user-revocable in Settings → Privacy.
- **Errors**: structured in-app log (`lib/app_log.dart`) wired to
  `FlutterError`, `PlatformDispatcher`, zone and `ErrorWidget`
  handlers; attach Sentry/Crashlytics via `AppLog.sink`.
- **Device classes**: detected once in `lib/device_profile.dart`
  (TV vs phone vs large-screen) and consumed everywhere.

## Platforms & device classes

| Platform | Experience |
|---|---|
| Android phone | Portrait browsing, bottom bar, content-aware player |
| Android TV | Rail + D-pad, TV cards, landscape-only, remote keys |
| iOS | Same mobile UX, platform scroll physics |
| Windows | Navigation rail, mouse/keyboard, media_kit playback |
| Tablet/foldable | Large-screen layout tier (shortest side ≥ 600dp) |

## Development

```bash
flutter pub get
flutter analyze   # must pass — CI gate
flutter test      # must pass — CI gate
flutter run
```

Pinned CI Flutter: **3.47.7** (verified stable of the 3.47 line).
Flutter 3.50 deprecated the bundled Material/Cupertino libraries, so
the 3.50 upgrade is a separate migration, not a version bump.

## Release

- Android signing: see `docs/RELEASE_SIGNING.md`. Release builds
  **fail** without production signing configuration; the debug key is
  never used for release.
- Network: HTTPS only (`network_security_config.xml`); add a scoped
  domain exception only for a proven HTTP-only CDN.
- CI: `.github/workflows/main.yml` and `mvain.yml` run
  `flutter analyze` + `flutter test` as blocking gates before builds.

## Design

Brand identity, tokens and platform rules: `docs/BRAND.md` and
`lib/design_tokens.dart`. TV design notes: `docs/ANDROID_TV_DESIGN.md`,
`docs/ANDROID_TV_FIX.md` (behavior verified against code in the
2026-11 transformation pass — see the transformation report).
