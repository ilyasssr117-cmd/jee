import AVFoundation
import AVKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var bridge: NativeBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "FlowNativeBridge") {
      bridge = NativeBridge(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Picture in Picture + share sheet for the Flutter side (flow/native).
///
/// PiP works with a second, native AVPlayer that continues from the exact
/// position the Flutter player stopped at. When the PiP window closes, the
/// player, its layer and the audio session are all released, so nothing is
/// left on screen.
final class NativeBridge: NSObject, AVPictureInPictureControllerDelegate {
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

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "flow/native", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "pipSupported":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "pipStart":
      startPip(call.arguments as? [String: Any] ?? [:], result)
    case "pipStop":
      pip?.stopPictureInPicture()
      result(nil)
    case "shareFile":
      shareFile(call.arguments as? [String: Any] ?? [:], result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Picture in Picture

  private func startPip(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          let urlString = args["url"] as? String, !urlString.isEmpty else {
      result(false)
      return
    }
    tearDown()

    let isFile = (args["isFile"] as? Bool) ?? false
    guard let mediaURL = isFile ? URL(fileURLWithPath: urlString) : URL(string: urlString) else {
      result(false)
      return
    }

    var options: [String: Any] = [:]
    if !isFile, let headers = args["headers"] as? [String: String], !headers.isEmpty {
      // Same headers (User-Agent, Referer, Origin, Cookie) as the Flutter player.
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }

    let item = AVPlayerItem(asset: AVURLAsset(url: mediaURL, options: options))
    let player = AVPlayer(playerItem: item)
    self.player = player
    startPositionMs = (args["positionMs"] as? Int) ?? 0
    rate = Float((args["rate"] as? Double) ?? 1.0)
    restoring = false

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
    } catch {}

    guard let window = keyWindow() else {
      tearDown()
      result(false)
      return
    }

    // PiP needs a real, on-screen layer. A small, almost invisible view
    // behind the Flutter view is enough.
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
    host.isUserInteractionEnabled = false
    host.alpha = 0.011
    let layer = AVPlayerLayer(player: player)
    layer.frame = host.bounds
    layer.videoGravity = .resizeAspect
    host.layer.addSublayer(layer)
    window.insertSubview(host, at: 0)
    self.host = host
    self.playerLayer = layer

    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      tearDown()
      result(false)
      return
    }
    controller.delegate = self
    pip = controller
    pending = result

    // Give up cleanly if it never becomes ready.
    let work = DispatchWorkItem { [weak self] in self?.failStart() }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      self?.pip?.stopPictureInPicture()
    }

    itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
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
    guard let player = player, pending != nil else { return }
    itemObservation = nil
    let time = CMTime(value: Int64(startPositionMs), timescale: 1000)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        self?.player?.playImmediately(atRate: self?.rate ?? 1.0)
        self?.attemptStart(0)
      }
    }
  }

  private func attemptStart(_ tries: Int) {
    guard let pip = pip, pending != nil else { return }
    if pip.isPictureInPicturePossible {
      pip.startPictureInPicture()
    } else if tries < 24 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
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
      let seconds = player.currentTime().seconds
      if seconds.isFinite { positionMs = Int(seconds * 1000) }
      if let item = player.currentItem {
        let length = item.duration.seconds
        if length.isFinite { durationMs = Int(length * 1000) }
      }
    }
    let wasRestore = restoring
    tearDown()
    channel.invokeMethod("pipEnded", arguments: [
      "positionMs": positionMs,
      "durationMs": durationMs,
      "restore": wasRestore,
    ])
  }

  /// Releases everything: nothing stays on screen or in the audio session.
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
      false, options: .notifyOthersOnDeactivation)
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    active = true
    timeout?.cancel()
    let callback = pending
    pending = nil
    callback?(true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    failStart()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    // The viewer tapped "return to app": Flutter re-opens the player.
    restoring = true
    completionHandler(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    if active { finishSession() } else { tearDown() }
  }

  // MARK: - Share sheet ("Save Video", "Save to Files")

  private func shareFile(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let path = args["path"] as? String,
          FileManager.default.fileExists(atPath: path) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      guard let top = self.topViewController() else {
        result(false)
        return
      }
      let sheet = UIActivityViewController(
        activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
      if let popover = sheet.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(
          x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        popover.permittedArrowDirections = []
      }
      sheet.completionWithItemsHandler = { _, completed, _, _ in result(completed) }
      top.present(sheet, animated: true)
    }
  }

  // MARK: - Helpers

  private func keyWindow() -> UIWindow? {
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private func topViewController() -> UIViewController? {
    var top = keyWindow()?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
