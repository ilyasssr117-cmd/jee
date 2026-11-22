# VXTUBE PostHog analytics

VXTUBE sends first-party product events through the official `posthog_flutter`
SDK to `https://us.i.posthog.com`. The project key in the app is PostHog's
client-side write-only project token. The project ID is `712838`.

## Privacy and identity

- Each install gets a random 128-bit ID. It is stored in Android Keystore,
  Apple Keychain, or Windows secure storage through `flutter_secure_storage`.
- PostHog receives that ID as an anonymous distinct ID. VXTUBE does not call
  `identify()` and does not create a person profile.
- `first_open` is recorded once for an installation; subsequent process starts
  record `app_open`. A reinstall or explicit analytics reset creates a new
  installation ID.
- Video and category IDs are SHA-256 digests. Search terms are never sent;
  `search` includes only query length and result count. Titles, URLs,
  thumbnails, descriptions, explicit category text, precise location, names,
  email addresses, phone numbers, and passwords are excluded.
- Session Replay and automatic lifecycle tracking are disabled. Lifecycle
  events are emitted by VXTUBE to avoid duplicates.
- PostHog queues events asynchronously. Playback and navigation do not wait
  for network delivery. Android and Apple queue offline events to disk. Windows
  stores desktop state under application support when available; it falls back
  to memory if that directory cannot be used, so unsent events can be lost on
  exit in that case.

## Events

| Event | When it fires | Safe event properties |
| --- | --- | --- |
| `app_open` | Once at each process launch | `is_first_open` |
| `first_open` | First recorded launch per installation | platform/app/device properties |
| `app_background` | App moves into the background | platform/app/device properties |
| `app_foreground` | App returns from background | platform/app/device properties |
| `app_session_started` | Launch and each foreground return | platform/app/device properties |
| `video_play` | First playback start for an item in the player or Reels | hashed `content_id`, `source` |
| `video_pause` | Playback pauses or a Reel is left | hashed `content_id`, `source` |
| `video_resume` | Playback resumes after a pause | hashed `content_id`, `source` |
| `video_complete` | A standard player reaches the end | hashed `content_id`, `source` |
| `video_watch_duration` | A playback interval ends after at least one second | hashed `content_id`, `watch_seconds`, `source` |
| `search` | First result page for a video or people search is returned (cached results count too) | `query_length`, `result_count`, `search_type` |
| `category_open` | A non-default home category is selected | hashed `category_id` |
| `video_details_open` | A details page opens | hashed `content_id` |
| `favorite_added` / `favorite_removed` | Favorite state changes | hashed `content_id` |
| `video_download_started` | A new download or retry is queued | hashed `content_id` |
| `video_download_completed` | The file is confirmed saved | hashed `content_id` |
| `video_download_failed` | The downloader reports failure | hashed `content_id` |

All events also carry `platform`, `app_version`, `app_build`, `device_type`,
`first_seen`, and `app_language` as PostHog event properties.

## Suggested dashboard insights

1. **Unique installations:** Trend `app_open`, unique users, with a daily,
   weekly, or monthly interval. These are anonymous installation IDs, not
   verified human users.
2. **DAU / WAU / MAU:** Unique users for `app_open` with daily, weekly, and
   monthly intervals.
3. **New installations:** Unique users for `first_open`.
4. **App launches:** Total `app_open` events.
5. **Video plays / completed views:** Total `video_play` and
   `video_complete` events.
6. **Most watched content:** Sum `watch_seconds` for `video_watch_duration`,
   grouped by `content_id`.
7. **Average watch duration:** Average `watch_seconds` for
   `video_watch_duration`.
8. **Platform distribution:** Break down `app_open` or `video_play` by
   `platform`.
9. **Download activity:** Trend `video_download_started`,
   `video_download_completed`, and `video_download_failed`.

## Platform support

- Android and iOS use PostHog's Flutter SDK and native SDKs.
- Windows uses the Flutter SDK's core desktop analytics implementation. The
  package currently marks Windows/Linux support experimental; Session Replay,
  surveys, push notifications, logs, and native crash capture are not
  supported there. Custom event capture is enabled explicitly.
- Android and iOS native auto-init is disabled so the Dart configuration owns
  the single SDK instance and lifecycle policy.
