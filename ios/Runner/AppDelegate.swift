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
  private var xfreeConsentToolbar: UIView?
  private var xfreeConsentRequestId: Int?
  // The consent page stays in the existing WKWebView. Continue checks the
  // accepted session with a same-origin fetch; it must not navigate/reload it.
  private var xfreeConsentCheckRequestId: Int?

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
      browser.isOpaque = true
      browser.backgroundColor = .systemBackground
      browser.scrollView.isScrollEnabled = true
      browser.scrollView.alwaysBounceVertical = true
      browser.isUserInteractionEnabled = true
      browser.accessibilityElementsHidden = false
      browser.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      // Keep the real XFree page visible and touchable during its first load.
      // Hiding it before consent detection made the gate appear black and
      // prevented users from interacting with the website.
      browser.alpha = 1.0
      browser.isHidden = false
      browser.frame = top.view.bounds
      top.view.addSubview(browser)
      top.view.bringSubviewToFront(browser)
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

    // Consent completion is checked with fetch() from the current page.
    // Continue deliberately does not navigate, so didFinish only starts a
    // request if one is already queued and idle.
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
          message: "Timed out while requesting \(request.url.absoluteString) through iOS WebKit.",
          details: nil
        )
      )
    }
    xfreeRequestTimeout?.cancel()
    xfreeRequestTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 22, execute: timeout)

    if request.url.path == "/trans/" && request.url.query == nil {
      // XFree hydrates the feed asynchronously after WKNavigationDelegate's
      // didFinish callback. A one-shot DOM read races that hydration and can
      // send an empty recommId back to Dart. Poll until the feed token appears,
      // a consent/challenge page is detected, or a bounded deadline expires.
      let script = """
      (() => {
        const requestId = \(requestId);
        const started = Date.now();
        const maxWaitMs = 16000;
        const inspect = () => {
          const html = document.documentElement ? document.documentElement.outerHTML : '';
          const text = document.body ? document.body.innerText : '';
          const lower = text.toLowerCase();
          const consent = lower.includes('only adults are allowed') ||
            lower.includes('agree & allow all') ||
            lower.includes('agree and allow all') ||
            (lower.includes('cookies to personalize') && lower.includes('agree'));
          const challenge = lower.includes('just a moment') ||
            lower.includes('checking your browser') ||
            lower.includes('verify you are human') ||
            !!document.querySelector('iframe[src*="challenges.cloudflare.com"]');
          const hasRecommId = /rec_[A-Za-z0-9_-]{6,}/.test(html);
          if (consent || challenge || hasRecommId || Date.now() - started >= maxWaitMs) {
            window.webkit.messageHandlers.xfreeResult.postMessage(JSON.stringify({
              id: requestId,
              kind: 'transPage',
              text: html,
              visibleText: text,
              hasRecommId,
              consent,
              challenge,
              timedOut: !consent && !challenge && !hasRecommId
            }));
            return;
          }
          setTimeout(inspect, 350);
        };
        inspect();
        return true;
      })();
      """
      browser.evaluateJavaScript(script) { [weak self] _, error in
        guard let self = self, let error = error else { return }
        self.completeXFreeRequest(
          id: requestId,
          text: nil,
          error: FlutterError(
            code: "XFREE_HTML_READ",
            message: error.localizedDescription,
            details: nil
          )
        )
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

    if (payload["kind"] as? String) == "transPage" {
      let text = payload["text"] as? String ?? ""
      let visibleText = payload["visibleText"] as? String ?? ""
      let needsConsent = (payload["consent"] as? Bool) == true
      let challenge = (payload["challenge"] as? Bool) == true
      let timedOut = (payload["timedOut"] as? Bool) == true
      if let jsError = payload["error"] as? String {
        xfreeConsentCheckRequestId = nil
        completeXFreeRequest(
          id: requestId,
          text: nil,
          error: FlutterError(code: "XFREE_CONSENT_FETCH", message: jsError, details: nil)
        )
        return
      }
      if needsConsent || challenge || isXFreeConsentPage(visibleText) || isXFreeChallenge(text) {
        if xfreeConsentCheckRequestId == requestId {
          // Continue checked the current browser session but XFree still
          // returned a consent/challenge page. Leave the live page visible so
          // the user can finish it; do not reload or dismiss it.
          xfreeConsentCheckRequestId = nil
          xfreeRequestTimeout?.cancel()
          xfreeRequestTimeout = nil
          showXFreeConsentAlert(
            challenge
              ? "XFree is still showing a browser verification. Complete it on the page, then tap Continue."
              : "XFree has not confirmed the age/cookie choice yet. Complete the on-page choice, then tap Continue."
          )
        } else {
          presentXFreeConsent(for: requestId)
        }
        return
      }
      if let status = payload["status"] as? Int, status != 200 {
        xfreeConsentCheckRequestId = nil
        completeXFreeRequest(
          id: requestId,
          text: nil,
          error: FlutterError(
            code: "XFREE_CONSENT_HTTP",
            message: "XFree returned HTTP \(status) after the consent action. The page was not reloaded.",
            details: String(visibleText.prefix(1000))
          )
        )
        return
      }
      guard !text.isEmpty else {
        completeXFreeRequest(
          id: requestId,
          text: nil,
          error: FlutterError(code: "XFREE_EMPTY_HTML", message: "The Trans page was empty after loading.", details: visibleText)
        )
        return
      }
      guard (payload["hasRecommId"] as? Bool) == true else {
        completeXFreeRequest(
          id: requestId,
          text: nil,
          error: FlutterError(
            code: "XFREE_RECOMM_ID_MISSING",
            message: timedOut
              ? "XFree's Trans page loaded, but its feed token did not appear within 16 seconds."
              : "XFree's Trans page does not contain a feed token.",
            details: String(visibleText.prefix(1000))
          )
        )
        return
      }
      xfreeConsentCheckRequestId = nil
      dismissXFreeConsentPage()
      completeXFreeRequest(id: requestId, text: text, error: nil)
      return
    }

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
    // XFree may answer an API request with an HTML consent/Cloudflare page.
    // Display that page instead of returning an opaque HTTP error to Flutter.
    if isXFreeConsentPage(text) || isXFreeChallenge(text) ||
       (text.lowercased().contains("<html") && status != 200) {
      presentXFreeConsent(for: requestId)
      return
    }
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
    completeXFreeRequest(id: requestId, text: text, error: nil)
  }

  private func isXFreeConsentPage(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("only adults are allowed") ||
      lower.contains("agree & allow all") ||
      lower.contains("agree and allow all") ||
      (lower.contains("cookies to personalize") && lower.contains("agree"))
  }

  /// Shows the existing WKWebView as a real, touch-enabled page when XFree
  /// requires age/cookie consent. The pending Flutter request is deliberately
  /// held until the user completes the page and taps Continue.
  private func presentXFreeConsent(for requestId: Int) {
    guard
      let first = xfreeQueue.first,
      first.id == requestId,
      let browser = xfreeWebView,
      let top = topViewController()
    else {
      completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(
          code: "XFREE_CONSENT_VIEW",
          message: "Could not show the XFree consent page.",
          details: nil
        )
      )
      return
    }

    // A human may need more than the normal network timeout to review consent.
    xfreeRequestTimeout?.cancel()
    xfreeRequestTimeout = nil
    xfreeConsentRequestId = requestId

    if browser.superview !== top.view {
      browser.removeFromSuperview()
      top.view.addSubview(browser)
    } else {
      top.view.bringSubviewToFront(browser)
    }
    browser.frame = top.view.bounds
    browser.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    browser.alpha = 1.0
    browser.isHidden = false
    browser.isUserInteractionEnabled = true
    browser.accessibilityElementsHidden = false
    browser.scrollView.isScrollEnabled = true
    top.view.bringSubviewToFront(browser)
    browser.scrollView.alwaysBounceVertical = true

    xfreeConsentToolbar?.removeFromSuperview()

    let toolbar = UIView()
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.backgroundColor = UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.97)

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Complete the age and cookie check on XFree, then tap Continue."
    label.textColor = .white
    label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    label.numberOfLines = 2
    label.accessibilityLabel = label.text

    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("Continue", for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    button.backgroundColor = .systemBlue
    button.layer.cornerRadius = 10
    button.contentEdgeInsets = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
    button.addTarget(self, action: #selector(continueXFreeConsent), for: .touchUpInside)
    button.accessibilityHint = "Continue after completing the XFree age and cookie check."

    let stack = UIStackView(arrangedSubviews: [label, button])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 12
    stack.distribution = .fill

    toolbar.addSubview(stack)
    top.view.addSubview(toolbar)
    top.view.bringSubviewToFront(toolbar)

    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: top.view.safeAreaLayoutGuide.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: top.view.safeAreaLayoutGuide.trailingAnchor),
      toolbar.topAnchor.constraint(equalTo: top.view.safeAreaLayoutGuide.topAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 72),
      stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 8),
      stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -8),
      button.widthAnchor.constraint(equalToConstant: 104)
    ])

    xfreeConsentToolbar = toolbar
  }

  @objc private func continueXFreeConsent() {
    guard
      let requestId = xfreeConsentRequestId,
      let browser = xfreeWebView,
      xfreeConsentCheckRequestId == nil
    else { return }

    // The user has already accepted the site's consent in this WKWebView.
    // Do NOT call browser.load() or browser.reload(): that visibly reloads the
    // age-gate page and may put the user straight back on the same screen.
    // Instead, use the same-origin fetch API inside the current document so
    // WKWebView automatically sends the just-saved cookies.
    xfreeConsentCheckRequestId = requestId
    xfreeRequestTimeout?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self,
            self.xfreeConsentCheckRequestId == requestId else { return }
      self.xfreeConsentCheckRequestId = nil
      self.completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(
          code: "XFREE_CONSENT_CHECK_TIMEOUT",
          message: "XFree did not confirm the consent session. The page was not reloaded; try Continue again after the page finishes updating.",
          details: nil
        )
      )
    }
    xfreeRequestTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 26, execute: timeout)

    let script = """
    (() => {
      const requestId = \(requestId);
      const post = (payload) => {
        window.webkit.messageHandlers.xfreeResult.postMessage(JSON.stringify({ id: requestId, kind: 'transPage', ...payload }));
      };
      const currentHtml = () => document.documentElement ? document.documentElement.outerHTML : '';
      const hasToken = value => /rec_[A-Za-z0-9_-]{6,}/.test(value || '');
      const textFromHtml = value => {
        try { return new DOMParser().parseFromString(value || '', 'text/html').body?.innerText || ''; }
        catch (_) { return ''; }
      };
      const isConsent = value => {
        const lower = (value || '').toLowerCase();
        return lower.includes('only adults are allowed') ||
          lower.includes('agree & allow all') ||
          lower.includes('agree and allow all') ||
          (lower.includes('cookies to personalize') && lower.includes('agree'));
      };
      const isChallenge = value => {
        const lower = (value || '').toLowerCase();
        return lower.includes('just a moment') || lower.includes('checking your browser') ||
          lower.includes('verify you are human') || lower.includes('cf-chl-') ||
          lower.includes('challenge-platform');
      };
      const current = currentHtml();
      if (hasToken(current)) {
        post({ text: current, visibleText: document.body?.innerText || '', hasRecommId: true, consent: false, challenge: false, timedOut: false, status: 200 });
        return true;
      }
      // Let the page's own click handler finish writing consent cookies.
      setTimeout(async () => {
        try {
          const response = await fetch('/trans/', {
            method: 'GET',
            credentials: 'include',
            cache: 'no-store',
            headers: { 'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }
          });
          const html = await response.text();
          const visibleText = textFromHtml(html);
          const token = hasToken(html);
          const challenge = isChallenge(html);
          const consent = isConsent(visibleText);
          post({
            text: html,
            visibleText,
            hasRecommId: token,
            consent,
            challenge,
            timedOut: !token && !consent && !challenge,
            status: response.status
          });
        } catch (error) {
          post({ error: String(error), text: '', visibleText: '', hasRecommId: false, consent: false, challenge: false, timedOut: false });
        }
      }, 700);
      return true;
    })();
    """

    browser.evaluateJavaScript(script) { [weak self] _, error in
      guard let self = self, let error = error else { return }
      guard self.xfreeConsentCheckRequestId == requestId else { return }
      self.xfreeConsentCheckRequestId = nil
      self.completeXFreeRequest(
        id: requestId,
        text: nil,
        error: FlutterError(
          code: "XFREE_CONSENT_CHECK_JS",
          message: "Could not verify the accepted XFree session: \(error.localizedDescription)",
          details: nil
        )
      )
    }
  }

  private func showXFreeConsentAlert(_ message: String) {
    guard let top = topViewController() else { return }
    let alert = UIAlertController(title: "XFree verification", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    top.present(alert, animated: true)
  }

  private func dismissXFreeConsentPage() {
    xfreeConsentToolbar?.removeFromSuperview()
    xfreeConsentToolbar = nil
    xfreeConsentRequestId = nil

    // A nearly-transparent WKWebView can remain on top of Flutter and keep
    // intercepting hit tests. Hide it explicitly, while retaining the instance
    // and WKWebsiteDataStore so the accepted cookies remain available to fetch().
    if let browser = xfreeWebView {
      browser.isUserInteractionEnabled = false
      browser.scrollView.isScrollEnabled = false
      browser.alpha = 0.0
      browser.isHidden = true
    }
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
    let wasConsentFlow = xfreeConsentRequestId == id || xfreeConsentCheckRequestId == id
    xfreeRequestTimeout?.cancel()
    xfreeRequestTimeout = nil
    xfreeActiveRequestId = nil
    if wasConsentFlow { dismissXFreeConsentPage() }
    if xfreeConsentCheckRequestId == id { xfreeConsentCheckRequestId = nil }
    _ = xfreeQueue.removeFirst()
    if let error = error {
      first.result(error)
    } else {
      first.result(text)
    }
    runNextXFreeRequest()
  }

  private func failXFreeQueue(code: String, message: String) {
    if xfreeConsentRequestId != nil || xfreeConsentCheckRequestId != nil {
      dismissXFreeConsentPage()
    }
    xfreeLoadTimeout?.cancel()
    xfreeLoadTimeout = nil
    xfreeRequestTimeout?.cancel()
    xfreeRequestTimeout = nil
    xfreeLoading = false
    xfreeActiveRequestId = nil
    xfreeConsentCheckRequestId = nil
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
