import AVFoundation
import AVKit
#if canImport(ActivityKit)
import ActivityKit
#endif
import Flutter
import UIKit
import WebKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  var bridge: NativeBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "FlowNativeBridge") {
      bridge = NativeBridge(messenger: registrar.messenger())
    }

    return super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
  }
}

/// Picture in Picture + file sharing for the Flutter side.
final class NativeBridge: NSObject, AVPictureInPictureControllerDelegate, WKNavigationDelegate, WKScriptMessageHandler {
  private let channel: FlutterMethodChannel

  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var host: UIView?
  private var pip: AVPictureInPictureController?
  private var itemObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?

  private var pending: FlutterResult?
  private var timeout: DispatchWorkItem?
  private var startPositionMs = 0
  private var rate: Float = 1.0
  private var restoring = false
  private var active = false
  private var liveActivity: Any?
  private var pendingUrl: String?
  private var dartReady = false

  // A persistent, same-origin WebKit session for XFree. This shares WebKit
  // cookies with its own page context instead of issuing a separate HTTP
  // request that XFree's edge protection may reject.
  private struct XFreeWebRequest {
    let id: Int
    let url: URL
    let accept: String
    let result: FlutterResult
  }

  private var xfreeWebView: WKWebView?
  private var xfreeQueue: [XFreeWebRequest] = []
  private var xfreeNextRequestId = 1
  private var xfreeActiveRequestId: Int?
  private var xfreeReady = false
  private var xfreeLoading = false
  private var xfreeLoadTimeout: DispatchWorkItem?
  private var xfreeRequestTimeout: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "flow/native",
      binaryMessenger: messenger
    )

    super.init()

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    switch call.method {

    case "xfreeFetch":
      xfreeFetch(
        call.arguments as? [String: Any] ?? [:],
        result
      )

    case "pipSupported":
      result(
        AVPictureInPictureController.isPictureInPictureSupported()
      )

    case "pipStart":
      startPip(
        call.arguments as? [String: Any] ?? [:],
        result
      )

    case "pipStop":
      pip?.stopPictureInPicture()
      result(nil)

    case "takeInitialUrl":
      dartReady = true
      let url = pendingUrl
      pendingUrl = nil
      result(url)

    case "widgetContainer":
      result(SharedGroup.containerURL(appBundleURL: Bundle.main.bundleURL)?.path)

    case "widgetReload":
      if #available(iOS 14.0, *) { WidgetCenter.shared.reloadAllTimelines() }
      result(true)

    case "liveUpdate":
      liveUpdate(call.arguments as? [String: Any] ?? [:], result)

    case "liveEnd":
      liveEnd(call.arguments as? [String: Any] ?? [:], result)

    case "shareFile":
      shareFile(
        call.arguments as? [String: Any] ?? [:],
        result
      )

    // MARK: - Share multiple files
    case "shareFiles":
      shareFiles(
        call.arguments as? [String: Any] ?? [:],
        result
      )

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - XFree WebKit session

  private func xfreeFetch(
    _ args: [String: Any],
    _ result: @escaping FlutterResult
  ) {
    guard
      let rawURL = args["url"] as? String,
      let url = URL(string: rawURL),
      url.scheme == "https",
      let host = url.host?.lowercased(),
      host == "xfree.com" || host.hasSuffix(".xfree.com")
    else {
      result(FlutterError(
        code: "XFREE_INVALID_URL",
        message: "Only HTTPS XFree URLs are allowed.",
        details: nil
      ))
      return
    }

    let accept = (args["accept"] as? String)
      ?? "application/json, text/plain, */*"

    DispatchQueue.main.async {
      let request = XFreeWebRequest(
        id: self.xfreeNextRequestId,
        url: url,
        accept: accept,
        result: result
      )
      self.xfreeNextRequestId += 1
      self.xfreeQueue.append(request)
      self.ensureXFreeWebView()
    }
  }

  private func ensureXFreeWebView() {
    if xfreeWebView == nil {
      guard let top = topViewController() else {
        failXFreeQueue(
          code: "XFREE_NO_VIEW",
          message: "The iOS browser could not attach to the app window."
        )
        return
      }

      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .default()
      configuration.preferences.javaScriptEnabled = true
      configuration.userContentController.add(self, name: "xfreeResult")

      let browser = WKWebView(
        frame: top.view.bounds,
        configuration: configuration
      )
      browser.navigationDelegate = self
      browser.isOpaque = false
      browser.backgroundColor = .clear
      browser.scrollView.isScrollEnabled = false
      browser.isUserInteractionEnabled = false
      browser.accessibilityElementsHidden = true
      browser.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      // Keep a real viewport so responsive layouts and browser checks behave
      // like an ordinary iPhone page. The view is visually transparent and
      // does not intercept touches intended for Flutter.
      browser.alpha = 0.01
      top.view.addSubview(browser)
      xfreeWebView = browser
    }

    guard let browser = xfreeWebView else { return }

    if xfreeReady {
      runNextXFreeRequest()
      return
    }

    guard !xfreeLoading else { return }
    xfreeLoading = true

    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.xfreeLoading else { return }
      self.xfreeLoading = false
      self.failXFreeQueue(
        code: "XFREE_WEBVIEW_TIMEOUT",
        message: "Timed out while opening the XFree page in iOS WebKit."
      )
    }
    xfreeLoadTimeout?.cancel()
    xfreeLoadTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)

    guard let startURL = URL(string: "https://www.xfree.com/trans/") else {
      failXFreeQueue(code: "XFREE_BAD_START_URL", message: "Invalid XFree start URL.")
      return
    }
    var request = URLRequest(
      url: startURL,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 40
    )
    request.setValue(
      "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      forHTTPHeaderField: "Accept"
    )
    browser.load(request)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === xfreeWebView else { return }
    xfreeLoadTimeout?.cancel()
    xfreeLoadTimeout = nil
    xfreeLoading = false
    xfreeReady = true
    runNextXFreeRequest()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    guard webView === xfreeWebView else { return }
    failXFreeNavigation(error)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard webView === xfreeWebView else { return }
    failXFreeNavigation(error)
  }

  private func failXFreeNavigation(_ error: Error) {
    xfreeLoadTimeout?.cancel()
    xfreeLoadTimeout = nil
    xfreeLoading = false
    xfreeReady = false
    failXFreeQueue(
      code: "XFREE_WEBVIEW_LOAD",
      message: "Could not load XFree in iOS WebKit: \(error.localizedDescription)"
    )
  }

  private func runNextXFreeRequest() {
    guard
      xfreeReady,
      xfreeActiveRequestId == nil,
      let request = xfreeQueue.first,
      let browser = xfreeWebView
    else { return }

    xfreeActiveRequestId = request.id
    let requestId = request.id
    let timeout = DispatchWorkItem { [weak self] in
      self?.completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(
          code: "XFREE_REQUEST_TIMEOUT",
          message: "Timed out while requesting \(request.url.path) through iOS WebKit.",
          details: nil
        )
      )
    }
    xfreeRequestTimeout?.cancel()
    xfreeRequestTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: timeout)

    if request.url.path == "/trans/" && request.url.query == nil {
      browser.evaluateJavaScript(
        "document.documentElement ? document.documentElement.outerHTML : ''"
      ) { [weak self] value, error in
        guard let self = self else { return }
        if let error = error {
          self.completeXFreeRequest(
            id: requestId,
            text: nil,
            error: FlutterError(
              code: "XFREE_HTML_READ",
              message: error.localizedDescription,
              details: nil
            )
          )
          return
        }
        let text = value as? String ?? ""
        if text.isEmpty {
          self.completeXFreeRequest(
            id: requestId,
            text: nil,
            error: FlutterError(
              code: "XFREE_EMPTY_HTML",
              message: "XFree returned an empty Trans page.",
              details: nil
            )
          )
          return
        }
        if self.isXFreeChallenge(text) {
          self.completeXFreeRequest(
            id: requestId,
            text: nil,
            error: FlutterError(
              code: "XFREE_CHALLENGE",
              message: "XFree is showing a browser verification page instead of the Trans feed.",
              details: String(text.prefix(1200))
            )
          )
          return
        }
        self.completeXFreeRequest(id: requestId, text: text, error: nil)
      }
      return
    }

    guard
      let urlData = try? JSONSerialization.data(
        withJSONObject: request.url.absoluteString,
        options: [.fragmentsAllowed]
      ),
      let acceptData = try? JSONSerialization.data(
        withJSONObject: request.accept,
        options: [.fragmentsAllowed]
      ),
      let urlLiteral = String(data: urlData, encoding: .utf8),
      let acceptLiteral = String(data: acceptData, encoding: .utf8)
    else {
      completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(code: "XFREE_JS_ENCODING", message: "Could not encode the XFree request URL.", details: nil)
      )
      return
    }

    let script = """
    (() => {
      const requestId = \(requestId);
      fetch(\(urlLiteral), {
        method: 'GET',
        credentials: 'include',
        cache: 'no-store',
        headers: { 'Accept': \(acceptLiteral), 'apiversion': '1.0', 'language': 'en' }
      }).then(async response => {
        const text = await response.text();
        window.webkit.messageHandlers.xfreeResult.postMessage(JSON.stringify({
          id: requestId,
          status: response.status,
          text: text,
          finalUrl: response.url
        }));
      }).catch(error => {
        window.webkit.messageHandlers.xfreeResult.postMessage(JSON.stringify({
          id: requestId,
          error: String(error)
        }));
      });
      return true;
    })();
    """
    browser.evaluateJavaScript(script) { [weak self] _, error in
      guard let self = self, let error = error else { return }
      self.completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(
          code: "XFREE_FETCH_START",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard
      message.name == "xfreeResult",
      let raw = message.body as? String,
      let data = raw.data(using: .utf8),
      let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let requestId = payload["id"] as? Int
    else { return }

    if let jsError = payload["error"] as? String {
      completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(
          code: "XFREE_FETCH_ERROR",
          message: jsError,
          details: nil
        )
      )
      return
    }

    let status = payload["status"] as? Int ?? 0
    let text = payload["text"] as? String ?? ""
    if status != 200 {
      completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(
          code: "XFREE_HTTP",
          message: "XFree returned HTTP \(status) in iOS WebKit.",
          details: String(text.prefix(1200))
        )
      )
      return
    }
    if isXFreeChallenge(text) {
      completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(
          code: "XFREE_CHALLENGE",
          message: "XFree returned a browser verification page to the app.",
          details: String(text.prefix(1200))
        )
      )
      return
    }
    completeXFreeRequest(id: requestId, text: text, error: nil)
  }

  private func isXFreeChallenge(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("just a moment") ||
      lower.contains("cf-chl-") ||
      lower.contains("challenge-platform")
  }

  private func completeXFreeRequest(
    id: Int,
    text: String?,
    error: FlutterError?
  ) {
    guard let first = xfreeQueue.first, first.id == id else { return }
    xfreeRequestTimeout?.cancel()
    xfreeRequestTimeout = nil
    xfreeActiveRequestId = nil
    _ = xfreeQueue.removeFirst()
    if let error = error {
      first.result(error)
    } else {
      first.result(text)
    }
    runNextXFreeRequest()
  }

  private func failXFreeQueue(code: String, message: String) {
    xfreeLoadTimeout?.cancel()
    xfreeLoadTimeout = nil
    xfreeRequestTimeout?.cancel()
    xfreeRequestTimeout = nil
    xfreeLoading = false
    xfreeActiveRequestId = nil
    let queued = xfreeQueue
    xfreeQueue.removeAll()
    for request in queued {
      request.result(FlutterError(code: code, message: message, details: nil))
    }
  }

  // MARK: - Picture in Picture

  private func startPip(
    _ args: [String: Any],
    _ result: @escaping FlutterResult
  ) {
    guard
      AVPictureInPictureController.isPictureInPictureSupported(),
      let urlString = args["url"] as? String,
      !urlString.isEmpty
    else {
      result(false)
      return
    }

    tearDown()

    let isFile = (args["isFile"] as? Bool) ?? false

    guard
      let mediaURL = isFile
        ? URL(fileURLWithPath: urlString)
        : URL(string: urlString)
    else {
      result(false)
      return
    }

    var options: [String: Any] = [:]

    if !isFile,
       let headers = args["headers"] as? [String: String],
       !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }

    let asset = AVURLAsset(
      url: mediaURL,
      options: options
    )

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)

    self.player = player

    startPositionMs =
      (args["positionMs"] as? Int) ?? 0

    rate =
      Float((args["rate"] as? Double) ?? 1.0)

    restoring = false

    do {
      let session = AVAudioSession.sharedInstance()

      try session.setCategory(
        .playback,
        mode: .moviePlayback,
        options: []
      )

      try session.setActive(true)
    } catch {}

    guard let window = keyWindow() else {
      tearDown()
      result(false)
      return
    }

    // Small native view required by PiP.
    let host = UIView(
      frame: CGRect(
        x: 0,
        y: 0,
        width: 160,
        height: 90
      )
    )

    host.isUserInteractionEnabled = false
    host.alpha = 0.011

    let layer = AVPlayerLayer(player: player)

    layer.frame = host.bounds
    layer.videoGravity = .resizeAspect

    host.layer.addSublayer(layer)

    window.insertSubview(host, at: 0)

    self.host = host
    self.playerLayer = layer

    guard
      let controller =
        AVPictureInPictureController(playerLayer: layer)
    else {
      tearDown()
      result(false)
      return
    }

    controller.delegate = self

    pip = controller
    pending = result

    // Timeout if PiP never becomes ready.
    let work = DispatchWorkItem { [weak self] in
      self?.failStart()
    }

    timeout = work

    DispatchQueue.main.asyncAfter(
      deadline: .now() + 12,
      execute: work
    )

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.pip?.stopPictureInPicture()
    }

    itemObservation = item.observe(
      \.status,
      options: [.new]
    ) { [weak self] item, _ in

      DispatchQueue.main.async {
        guard let self = self else {
          return
        }

        switch item.status {

        case .readyToPlay:
          self.seekThenStart()

        case .failed:
          self.failStart()

        default:
          break
        }
      }
    }
  }

  private func seekThenStart() {
    guard
      let player = player,
      pending != nil
    else {
      return
    }

    itemObservation = nil

    let time = CMTime(
      value: Int64(startPositionMs),
      timescale: 1000
    )

    player.seek(
      to: time,
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] _ in

      DispatchQueue.main.async {
        guard let self = self else {
          return
        }

        self.player?.playImmediately(
          atRate: self.rate
        )

        self.attemptStart(0)
      }
    }
  }

  private func attemptStart(_ tries: Int) {
    guard
      let pip = pip,
      pending != nil
    else {
      return
    }

    if pip.isPictureInPicturePossible {
      pip.startPictureInPicture()

    } else if tries < 24 {

      DispatchQueue.main.asyncAfter(
        deadline: .now() + 0.25
      ) { [weak self] in

        self?.attemptStart(tries + 1)
      }

    } else {
      failStart()
    }
  }

  private func failStart() {
    timeout?.cancel()

    let callback = pending
    pending = nil

    tearDown()

    callback?(false)
  }

  private func finishSession() {
    var positionMs = 0
    var durationMs = 0

    if let player = player {

      let seconds =
        player.currentTime().seconds

      if seconds.isFinite {
        positionMs =
          Int(seconds * 1000)
      }

      if let item = player.currentItem {

        let length =
          item.duration.seconds

        if length.isFinite {
          durationMs =
            Int(length * 1000)
        }
      }
    }

    let wasRestore = restoring

    tearDown()

    channel.invokeMethod(
      "pipEnded",
      arguments: [
        "positionMs": positionMs,
        "durationMs": durationMs,
        "restore": wasRestore
      ]
    )
  }

  /// Releases everything.
  private func tearDown() {
    timeout?.cancel()
    timeout = nil

    itemObservation = nil

    if let observer = endObserver {
      NotificationCenter.default.removeObserver(observer)
      endObserver = nil
    }

    player?.pause()
    player?.replaceCurrentItem(with: nil)

    playerLayer?.player = nil
    playerLayer?.removeFromSuperlayer()

    host?.removeFromSuperview()

    pip?.delegate = nil
    pip = nil

    player = nil
    playerLayer = nil
    host = nil

    active = false
    restoring = false

    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController:
      AVPictureInPictureController
  ) {
    active = true

    timeout?.cancel()

    let callback = pending
    pending = nil

    callback?(true)
  }

  func pictureInPictureController(
    _ pictureInPictureController:
      AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    failStart()
  }

  func pictureInPictureController(
    _ pictureInPictureController:
      AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
      completionHandler: @escaping (Bool) -> Void
  ) {
    restoring = true

    completionHandler(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController:
      AVPictureInPictureController
  ) {
    if active {
      finishSession()
    } else {
      tearDown()
    }
  }

  // MARK: - Share single file

  private func shareFile(
    _ args: [String: Any],
    _ result: @escaping FlutterResult
  ) {
    guard
      let path = args["path"] as? String,
      FileManager.default.fileExists(atPath: path)
    else {
      result(false)
      return
    }

    DispatchQueue.main.async {

      guard let top = self.topViewController() else {
        result(false)
        return
      }

      let sheet = UIActivityViewController(
        activityItems: [
          URL(fileURLWithPath: path)
        ],
        applicationActivities: nil
      )

      if let popover =
        sheet.popoverPresentationController {

        popover.sourceView = top.view

        popover.sourceRect = CGRect(
          x: top.view.bounds.midX,
          y: top.view.bounds.maxY - 80,
          width: 1,
          height: 1
        )

        popover.permittedArrowDirections = []
      }

      sheet.completionWithItemsHandler = {
        _,
        completed,
        _,
        _ in

        result(completed)
      }

      top.present(
        sheet,
        animated: true
      )
    }
  }

  // MARK: - Share multiple files

  private func shareFiles(
    _ args: [String: Any],
    _ result: @escaping FlutterResult
  ) {
    guard
      let paths = args["paths"] as? [String],
      !paths.isEmpty
    else {
      result(false)
      return
    }

    // Keep only files that actually exist.
    let existingPaths = paths.filter {
      FileManager.default.fileExists(atPath: $0)
    }

    guard !existingPaths.isEmpty else {
      result(false)
      return
    }

    let urls = existingPaths.map {
      URL(fileURLWithPath: $0)
    }

    DispatchQueue.main.async {

      guard let top = self.topViewController() else {
        result(false)
        return
      }

      let sheet = UIActivityViewController(
        activityItems: urls,
        applicationActivities: nil
      )

      // iPad
      if let popover =
        sheet.popoverPresentationController {

        popover.sourceView = top.view

        popover.sourceRect = CGRect(
          x: top.view.bounds.midX,
          y: top.view.bounds.midY,
          width: 0,
          height: 0
        )

        popover.permittedArrowDirections = []
      }

      sheet.completionWithItemsHandler = {
        _,
        completed,
        _,
        _ in

        result(completed)
      }

      top.present(
        sheet,
        animated: true
      )
    }
  }

  // MARK: - Links from the home-screen widget

  func deliver(url: URL) {
    guard url.scheme == "watchtube" else { return }
    if dartReady {
      channel.invokeMethod("openUrl", arguments: url.absoluteString)
    } else {
      pendingUrl = url.absoluteString
    }
  }

  // MARK: - Download Live Activity

  private func liveState(
    _ args: [String: Any],
    finished: Bool
  ) -> Any? {
    guard #available(iOS 16.1, *) else { return nil }
    return DownloadAttributes.ContentState(
      title: (args["title"] as? String) ?? "Downloads",
      progress: (args["progress"] as? Double) ?? -1,
      activeCount: (args["count"] as? Int) ?? 1,
      finished: finished
    )
  }

  private func liveUpdate(
    _ args: [String: Any],
    _ result: @escaping FlutterResult
  ) {
    guard #available(iOS 16.1, *) else {
      result(false)
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled,
          let state = liveState(args, finished: false)
            as? DownloadAttributes.ContentState
    else {
      result(false)
      return
    }

    if liveActivity == nil {
      liveActivity = Activity<DownloadAttributes>.activities.first
    }

    if let activity = liveActivity as? Activity<DownloadAttributes> {
      Task { await activity.update(using: state) }
      result(true)
      return
    }

    do {
      let activity = try Activity<DownloadAttributes>.request(
        attributes: DownloadAttributes(name: "Downloads"),
        contentState: state,
        pushType: nil
      )
      liveActivity = activity
      result(true)
    } catch {
      result(false)
    }
  }

  private func liveEnd(
    _ args: [String: Any],
    _ result: @escaping FlutterResult
  ) {
    guard #available(iOS 16.1, *) else {
      result(false)
      return
    }
    if liveActivity == nil {
      liveActivity = Activity<DownloadAttributes>.activities.first
    }
    guard let activity = liveActivity as? Activity<DownloadAttributes> else {
      result(false)
      return
    }
    let finished = (args["finished"] as? Bool) ?? true
    var state = activity.contentState
    state.finished = finished
    state.progress = finished ? 1 : state.progress
    if let title = args["title"] as? String { state.title = title }
    liveActivity = nil
    Task {
      await activity.end(
        using: state,
        dismissalPolicy: .after(Date().addingTimeInterval(8))
      )
    }
    result(true)
  }

  // MARK: - Helpers

  private func keyWindow() -> UIWindow? {
    return UIApplication.shared.connectedScenes
      .compactMap {
        $0 as? UIWindowScene
      }
      .flatMap {
        $0.windows
      }
      .first {
        $0.isKeyWindow
      }
  }

  private func topViewController() -> UIViewController? {
    var top =
      keyWindow()?.rootViewController

    while let presented =
      top?.presentedViewController {
      top = presented
    }

    return top
  }
}
