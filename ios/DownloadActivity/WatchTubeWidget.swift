import SwiftUI
import WidgetKit

struct WidgetPayload: Codable {
  var resumeId: String?
  var resumeTitle: String?
  var resumeProgress: Double?
  var downloadsDone: Int?
  var downloadsActive: Int?
  var activeProgress: Double?
}

struct WatchTubeEntry: TimelineEntry {
  let date: Date
  let payload: WidgetPayload?
  let image: UIImage?
  var note: String? = nil
}

struct WatchTubeProvider: TimelineProvider {
  func placeholder(in context: Context) -> WatchTubeEntry {
    WatchTubeEntry(
      date: Date(),
      payload: WidgetPayload(
        resumeId: nil, resumeTitle: "Continue watching",
        resumeProgress: 0.4, downloadsDone: 3, downloadsActive: 0,
        activeProgress: nil),
      image: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (WatchTubeEntry) -> Void) {
    completion(load())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WatchTubeEntry>) -> Void) {
    // The app asks WidgetKit to reload whenever the data changes.
    let next = Date().addingTimeInterval(30 * 60)
    completion(Timeline(entries: [load()], policy: .after(next)))
  }

  private func load() -> WatchTubeEntry {
    // The widget lives in <App>.app/PlugIns/X.appex, so the app is two levels up.
    let appURL = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    guard let dir = SharedGroup.containerURL(appBundleURL: appURL) else {
      return WatchTubeEntry(
        date: Date(), payload: nil, image: nil,
        note: "App Group unavailable")
    }

    var payload: WidgetPayload?
    if let data = try? Data(contentsOf: dir.appendingPathComponent("widget.json")) {
      payload = try? JSONDecoder().decode(WidgetPayload.self, from: data)
    }
    let image = UIImage(contentsOfFile: dir.appendingPathComponent("resume.jpg").path)
    return WatchTubeEntry(
      date: Date(), payload: payload, image: image,
      note: payload == nil ? "Open WatchTube once" : nil)
  }
}

private func videoURL(_ id: String?) -> URL {
  guard let id = id,
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
        let url = URL(string: "watchtube://video?id=\(encoded)")
  else { return URL(string: "watchtube://home")! }
  return url
}

private extension View {
  @ViewBuilder
  func widgetBackground(_ color: Color) -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(color, for: .widget)
    } else {
      background(color)
    }
  }
}

private struct ResumeCard: View {
  let entry: WatchTubeEntry

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      if let image = entry.image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color(white: 0.12)
      }
      LinearGradient(
        colors: [.clear, .black.opacity(0.85)],
        startPoint: .center, endPoint: .bottom)
      VStack(alignment: .leading, spacing: 5) {
        Spacer()
        if let title = entry.payload?.resumeTitle {
          Text(title)
            .font(.footnote.weight(.semibold))
            .lineLimit(2)
            .foregroundColor(.white)
          if let p = entry.payload?.resumeProgress {
            ProgressView(value: min(max(p, 0), 1))
              .tint(.white)
          }
        } else {
          Text(entry.note ?? "Nothing to continue yet")
            .font(.footnote)
            .foregroundColor(.white.opacity(0.8))
        }
      }
      .padding(10)
    }
    .clipped()
  }
}

private struct DownloadsPanel: View {
  let payload: WidgetPayload?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.down.circle.fill")
        Text("Downloads").font(.subheadline.weight(.semibold))
      }
      Text("\(payload?.downloadsDone ?? 0)")
        .font(.system(size: 34, weight: .bold, design: .rounded))
      Text("saved videos")
        .font(.caption)
        .opacity(0.7)
      Spacer(minLength: 0)
      if let active = payload?.downloadsActive, active > 0 {
        if let p = payload?.activeProgress, p >= 0 {
          ProgressView(value: min(max(p, 0), 1)).tint(.white)
          Text("Downloading \(Int((p * 100).rounded()))%")
            .font(.caption2)
            .opacity(0.8)
        } else {
          ProgressView().tint(.white)
        }
      }
    }
    .foregroundColor(.white)
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct WatchTubeWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: WatchTubeEntry

  var body: some View {
    switch family {
    case .systemMedium:
      HStack(spacing: 0) {
        Link(destination: videoURL(entry.payload?.resumeId)) {
          ResumeCard(entry: entry)
        }
        .frame(maxWidth: .infinity)
        DownloadsPanel(payload: entry.payload)
          .frame(maxWidth: .infinity)
      }
      .widgetBackground(Color(white: 0.08))
    default:
      ResumeCard(entry: entry)
        .widgetURL(videoURL(entry.payload?.resumeId))
        .widgetBackground(Color(white: 0.08))
    }
  }
}

struct WatchTubeWidget: Widget {
  let kind = "WatchTubeWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: WatchTubeProvider()) { entry in
      WatchTubeWidgetView(entry: entry)
    }
    .configurationDisplayName("WatchTube")
    .description("Continue watching and your downloads.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
