package com.tv.watch_tube

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
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONTokener

class MainActivity : FlutterActivity() {
    private val reelsChannelName = "com.tv.watch_tube/reels_browser"
    private val mainHandler = Handler(Looper.getMainLooper())

    private var reelsWebView: WebView? = null
    private var reelsRequestId = 0
    private var reelsResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
