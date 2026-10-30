import Foundation

/// Finds the App Group that this install was really signed with.
/// Sideloading tools often rename `group.com.tv.watchTube`, so instead of
/// hard-coding it we read the groups from the embedded provisioning profile.
enum SharedGroup {
  static let defaultId = "group.com.tv.watchTube"

  /// `appBundleURL` is the main app's `.app` folder (the widget passes its
  /// host app, not its own `.appex`).
  static func containerURL(appBundleURL: URL) -> URL? {
    for id in candidates(appBundleURL: appBundleURL) {
      if let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: id)
      {
        return url
      }
    }
    return nil
  }

  static func candidates(appBundleURL: URL) -> [String] {
    var ids = groups(inProfileAt: appBundleURL)
    if !ids.contains(defaultId) { ids.append(defaultId) }
    return ids
  }

  private static func groups(inProfileAt appBundleURL: URL) -> [String] {
    let file = appBundleURL.appendingPathComponent("embedded.mobileprovision")
    guard let data = try? Data(contentsOf: file),
          let start = data.range(of: Data("<?xml".utf8)),
          let end = data.range(of: Data("</plist>".utf8))
    else { return [] }
    let xml = data.subdata(in: start.lowerBound..<end.upperBound)
    guard let plist = try? PropertyListSerialization.propertyList(
            from: xml, options: [], format: nil) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any],
          let groups = entitlements["com.apple.security.application-groups"]
            as? [String]
    else { return [] }
    return groups
  }
}
