package com.tv.watch_tube

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.content.pm.ActivityInfo
import android.os.Bundle
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.content.Intent
import android.net.Uri
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONTokener

class MainActivity : FlutterActivity() {
    private val reelsChannelName = "com.tv.watch_tube/reels_browser"
    private val deviceChannelName = "com.tv.watch_tube/device"
    private val nativeChannelName = "flow/native"
    private val mainHandler = Handler(Looper.getMainLooper())

    private var reelsWebView: WebView? = null
    private var reelsRequestId = 0
    private var reelsResult: MethodChannel.Result? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm-start deep links: replace the launch intent so a later
        // takeInitialUrl call sees the newest data, not the cold one.
        setIntent(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (isTelevisionDevice()) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // flow/native — implemented on Android (Phase 3 overhaul).
        // Previously this channel existed ONLY in the iOS AppDelegate,
        // so on Android every NativeBridge call died silently:
        // sharing downloaded files always failed, and capability
        // probes fell back to "unsupported" by accident, not by design.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nativeChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Native-player PiP is iOS-only today: the Dart side
                    // pauses its own controller and leaves the page, so
                    // answering true without a native Android player
                    // would strand the user on a dead screen. Truthful
                    // false until a media3 player activity exists.
                    "pipSupported" -> result.success(false)
                    "pipStart" -> result.success(false)
                    "pipStop" -> result.success(null)
                    "takeInitialUrl" -> result.success(intent?.dataString)
                    // iOS-only concepts (app-group widget container,
                    // Live Activities): report unsupported honestly.
                    "widgetContainer" -> result.success(null)
                    "widgetReload" -> result.success(false)
                    "liveUpdate" -> result.success(false)
                    "liveEnd" -> result.success(false)
                    "setKeepScreenOn" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    }
                    "shareText" -> {
                        val text = call.argument<String>("text")
                        if (text.isNullOrBlank()) {
                            result.success(false)
                        } else {
                            try {
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_TEXT, text)
                                }
                                startActivity(Intent.createChooser(send, null))
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "shareFile" -> {
                        val path = call.argument<String>("path")
                        result.success(path != null && shareFilesInternal(listOf(path)))
                    }
                    "shareFiles" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        result.success(paths.isNotEmpty() && shareFilesInternal(paths))
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceChannelName)
            .setMethodCallHandler { call, result ->
            when (call.method) {
                "isTelevision" -> result.success(isTelevisionDevice())
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, reelsChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "fetchReels") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val url = call.argument<String>("url")
                if (url.isNullOrBlank() || !url.startsWith("https://")) {
                    result.error("invalid_url", "A valid HTTPS URL is required.", null)
                    return@setMethodCallHandler
                }

                @Suppress("UNCHECKED_CAST")
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                runOnUiThread { loadReels(url, headers, result) }
            }
    }

    private fun isTelevisionDevice(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val televisionUiMode =
            uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        val leanbackFeature = packageManager.hasSystemFeature("android.software.leanback")
        val televisionFeature = packageManager.hasSystemFeature("android.hardware.type.television")
        val hasTouchscreen = packageManager.hasSystemFeature("android.hardware.touchscreen")
        val screenSize = resources.configuration.screenLayout and Configuration.SCREENLAYOUT_SIZE_MASK
        val largeNonTouchDisplay = !hasTouchscreen &&
            (screenSize == Configuration.SCREENLAYOUT_SIZE_LARGE ||
                screenSize == Configuration.SCREENLAYOUT_SIZE_XLARGE)
        return televisionUiMode || leanbackFeature || televisionFeature || largeNonTouchDisplay
    }

    private fun getReelsWebView(): WebView {
        reelsWebView?.let { return it }

        val webView = WebView(this).apply {
            setBackgroundColor(Color.TRANSPARENT)
            alpha = 0f
            isFocusable = false
            isFocusableInTouchMode = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
        }
        val decor = window.decorView as ViewGroup
        decor.addView(
            webView,
            FrameLayout.LayoutParams(2, 2, Gravity.BOTTOM or Gravity.END),
        )
        reelsWebView = webView
        return webView
    }

    private fun loadReels(
        url: String,
        headers: Map<String, String>,
        result: MethodChannel.Result,
    ) {
        reelsResult?.error("cancelled", "A newer Reels request replaced this one.", null)
        val requestId = ++reelsRequestId
        reelsResult = result

        val webView = try {
            getReelsWebView()
        } catch (error: Exception) {
            completeReels(requestId, error = error.message ?: "WebView could not start.")
            return
        }

        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, pageUrl: String) {
                if (requestId != reelsRequestId) return
                view.evaluateJavascript(
                    "(document.body && document.body.innerText) || ''",
                ) { encoded ->
                    if (requestId != reelsRequestId) return@evaluateJavascript
                    val body = try {
                        JSONTokener(encoded ?: "\"\"").nextValue() as? String
                    } catch (_: Exception) {
                        null
                    }
                    if (body != null &&
                        (body.trimStart().startsWith("{") || body.trimStart().startsWith("["))
                    ) {
                        completeReels(requestId, body = body)
                    } else {
                        completeReels(requestId, error = "The Reels service returned no JSON data.")
                    }
                }
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    completeReels(requestId, error = "Network error ${error.errorCode}.")
                }
            }
        }

        mainHandler.postDelayed({
            if (requestId == reelsRequestId) {
                completeReels(requestId, error = "The Reels request timed out.")
            }
        }, 25_000)

        try {
            webView.loadUrl(url, headers)
        } catch (error: Exception) {
            completeReels(requestId, error = error.message ?: "The Reels request failed.")
        }
    }

    private fun completeReels(requestId: Int, body: String? = null, error: String? = null) {
        if (requestId != reelsRequestId) return
        val result = reelsResult ?: return
        reelsResult = null
        if (body != null) {
            result.success(body)
        } else {
            result.error("reels_network", error ?: "The Reels request failed.", null)
        }
    }

    override fun onDestroy() {
        reelsResult?.error("cancelled", "The app closed during a Reels request.", null)
        reelsResult = null
        reelsWebView?.let { webView ->
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.destroy()
        }
        reelsWebView = null
        super.onDestroy()
    }

    private fun shareFilesInternal(paths: List<String>): Boolean {
        return try {
            // Defense in depth (audit 8.2): only files under the
            // FileProvider roots may ever be shared — never arbitrary
            // private app files, even if a bad path arrives.
            val roots = listOfNotNull(filesDir, cacheDir, getExternalFilesDir(null))
                .map { it.canonicalPath }
            val uris = ArrayList<Uri>()
            for (path in paths) {
                val file = File(path)
                if (!file.exists()) return false
                val canonical = file.canonicalPath
                if (roots.none { canonical == it || canonical.startsWith(it + File.separator) }) {
                    return false
                }
                uris.add(FileProvider.getUriForFile(this, "${packageName}.fileprovider", file))
            }
            val intent = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND).apply {
                    type = mimeFor(uris, paths)
                    putExtra(Intent.EXTRA_STREAM, uris[0])
                }
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = "video/*"
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                }
            }
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(Intent.createChooser(intent, null))
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun mimeFor(uris: List<Uri>, paths: List<String>): String {
        val ext = paths.firstOrNull()?.substringAfterLast('.', "")?.lowercase() ?: ""
        return when (ext) {
            "mp4" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "mov" -> "video/quicktime"
            else -> "video/*"
        }
    }
}
