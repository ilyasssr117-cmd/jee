import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct DownloadLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DownloadAttributes.self) { context in
      DownloadLockScreenView(state: context.state)
        .activityBackgroundTint(Color.black.opacity(0.88))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: context.state.finished
                ? "checkmark.circle.fill" : "arrow.down.circle.fill")
            .font(.title2)
            .foregroundColor(.white)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(percentText(context.state))
            .font(.headline.monospacedDigit())
            .foregroundColor(.white)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.title)
            .font(.subheadline)
            .lineLimit(1)
            .foregroundColor(.white)
        }
        DynamicIslandExpandedRegion(.bottom) {
          DownloadBar(state: context.state)
        }
      } compactLeading: {
        Image(systemName: context.state.finished
              ? "checkmark.circle.fill" : "arrow.down.circle.fill")
          .foregroundColor(.white)
      } compactTrailing: {
        Text(percentText(context.state))
          .font(.caption.monospacedDigit())
          .foregroundColor(.white)
      } minimal: {
        Image(systemName: context.state.finished
              ? "checkmark.circle.fill" : "arrow.down.circle.fill")
          .foregroundColor(.white)
      }
    }
  }
}

@available(iOS 16.1, *)
private func percentText(_ state: DownloadAttributes.ContentState) -> String {
  if state.finished { return "Done" }
  if state.progress < 0 { return "…" }
  return "\(Int((state.progress * 100).rounded()))%"
}

@available(iOS 16.1, *)
private struct DownloadBar: View {
  let state: DownloadAttributes.ContentState

  var body: some View {
    if state.finished || state.progress >= 0 {
      ProgressView(value: state.finished ? 1 : min(max(state.progress, 0), 1))
        .tint(.white)
    } else {
      ProgressView().tint(.white)
    }
  }
}

@available(iOS 16.1, *)
private struct DownloadLockScreenView: View {
  let state: DownloadAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: state.finished
              ? "checkmark.circle.fill" : "arrow.down.circle.fill")
        Text(state.finished ? "Download complete" : "Downloading")
          .font(.headline)
        Spacer()
        Text(percentText(state))
          .font(.headline.monospacedDigit())
      }
      Text(state.title)
        .font(.subheadline)
        .lineLimit(1)
        .opacity(0.85)
      DownloadBar(state: state)
      if !state.finished && state.activeCount > 1 {
        Text("\(state.activeCount) downloads")
          .font(.caption)
          .opacity(0.7)
      }
    }
    .foregroundColor(.white)
    .padding(16)
  }
}
