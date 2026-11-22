import ActivityKit
import Foundation

/// Shared by the app (starts/updates the activity) and the widget extension
/// (draws it). This file is compiled into both targets.
@available(iOS 16.1, *)
struct DownloadAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var title: String
    /// 0...1, or a negative number when the size is not known yet.
    var progress: Double
    var activeCount: Int
    var finished: Bool
  }

  var name: String
}
