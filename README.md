# Watch Tube — scraper-only source update

This package updates the Dart source of the existing Flutter Android TV app. It keeps the existing Android platform folder in your project untouched.

## What changed

- Removed `DemoVideoRepository`, its sample catalogue, and the `USE_DEMO_CATALOGUE` switch completely.
- The homepage, categories, search, related videos, and playback resolution now all use `HtmlScraperVideoRepository` and `Scraper`.
- Kept the current route templates and environment overrides, while expanding default CSS selectors to also match `.thumbs__list .item.thumb` card layouts.
- Added console diagnostics showing the request URL, HTTP status, selector/card counts, parsed video count, search, related-video, and playback activity.
- Kept the TV UI, player, navigation, and pagination behavior.

## Apply the source update

1. Extract this package to a separate folder.
2. Open PowerShell in the extracted `watch_tube_scraper_only` folder.
3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\apply_patch.ps1
```

The script defaults to `C:\Users\<your-user>\Downloads\watch_tube`. If your project is elsewhere, pass the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\apply_patch.ps1 -ProjectRoot "C:\path\to\watch_tube"
```

The script backs up your existing `lib`, `pubspec.yaml`, and `test` folders before copying the updated files. It does not replace your existing `android/` folder.

Then stop any running Flutter session, open a terminal at your project root, and run:

```powershell
flutter pub get
flutter test
flutter run -d 127.0.0.1:5556
```

## Scraper configuration

The default base URL remains `https://x-bae.tube`; this patch does not change the source domain or route templates. It can be overridden without changing source code:

```powershell
flutter run -d 127.0.0.1:5556 --dart-define=VIDEO_SOURCE_BASE_URL=https://your-source.example
```

The scraper parameters and defaults are preserved in `lib/video_repository.dart`:

| Define | Default | Purpose |
|---|---|---|
| `VIDEO_HOME_PATH` | `/` | Homepage path |
| `VIDEO_PAGE_PATH_TEMPLATE` | `/video/{page}/` | Next listing pages |
| `VIDEO_SEARCH_PATH_TEMPLATE` | `/search/{query}/?page={page}` | Search route |
| `VIDEO_CATEGORY_PATH_TEMPLATE` | `/categories/{slug}/?page={page}` | Category route |
| `VIDEO_CARD_SELECTOR` | `.thumbs__list .item.thumb, article[data-video], .video-card, .video-item` | Video cards on listing pages |
| `VIDEO_ANCHOR_SELECTOR` | `a[href]` | Video-page link within a card |
| `VIDEO_IMAGE_SELECTOR` | `img` | Thumbnail within a card |
| `VIDEO_TITLE_SELECTOR` | `[itemprop="name"], .thumb-spot__title, .thumb__title, .video-title, .title, h2, h3` | Video title within a card |
| `VIDEO_DURATION_SELECTOR` | `.thumb-spot__data li:first-child, .duration, [data-duration]` | Optional duration text |
| `VIDEO_VIEWS_SELECTOR` | `.thumb-spot__data li:nth-child(3), .views, [data-views]` | Optional view-count text |
| `VIDEO_DESCRIPTION_SELECTOR` | Open Graph/meta description | Detail-page description |
| `VIDEO_RELATED_CARD_SELECTOR` | `.related .item.thumb, .related-videos .item.thumb, .related .video-card, .related .video-item` | Related-video cards |
| `VIDEO_STREAM_URL_PATTERN` | `video_url`, `file`, or `src` assignment | Direct stream URL pattern |
| `VIDEO_DETAIL_TITLE_PATTERN` | `video_title` or `title` assignment | Detail-page title pattern |
| `VIDEO_PREVIEW_PATTERN` | `preview_url`, `preview_url1`, or `poster` assignment | Preview/poster pattern |
| `VIDEO_CATEGORIES` | empty | Optional comma-separated category labels |

To override one of the settings, pass the matching `--dart-define`, for example:

```powershell
flutter run -d 127.0.0.1:5556 --dart-define=VIDEO_CARD_SELECTOR=".video-card"
```

## Reading console diagnostics

When the homepage loads, the console should include messages similar to:

```text
[WATCH_TUBE] repository: getVideos page=0 category=null
[SCRAPER] GET https://x-bae.tube/
[SCRAPER] HTTP 200 from https://x-bae.tube/
[SCRAPER] Selector "article[data-video], .video-card, .video-item" matched 12 cards at https://x-bae.tube/
[SCRAPER] Parsed 12 videos from https://x-bae.tube/
[WATCH_TUBE] repository: homepage returned 12 videos
```

If the HTTP request succeeds but the selector matches zero cards, update `VIDEO_CARD_SELECTOR` and the related selector values to match the actual HTML. The parser now recognizes thumb-list cards, lazy thumbnail attributes, duration/views metadata, and `video_url` / `preview_url1` detail-page assignments. It parses server-returned HTML; it does not execute client-side JavaScript or bypass authentication, DRM, encryption, or other access controls. A site's HTML/API and streaming format determine what can be read and played.

## Android networking

Ensure `android/app/src/main/AndroidManifest.xml` includes this permission before the `<application>` element:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```
