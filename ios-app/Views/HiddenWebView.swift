import SwiftUI
import WebKit

/// 全局隐藏 WKWebView：小红书 / Instagram 的页面数据靠它兜底获取
final class HiddenWebView: NSObject, ObservableObject {
    static let shared = HiddenWebView()

    let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.alpha = 0.01
        wv.customUserAgent = UrlUtils.UA.desktop
        return wv
    }()

    @MainActor
    func load(_ url: String, userAgent: String) {
        webView.customUserAgent = userAgent
        guard let target = URL(string: url) else { return }
        webView.stopLoading()
        webView.load(URLRequest(url: target))
    }

    @MainActor
    func reset() {
        webView.stopLoading()
        if let blank = URL(string: "about:blank") {
            webView.load(URLRequest(url: blank))
        }
    }

    @MainActor
    func evaluate(_ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js) { value, _ in
                if let s = value as? String {
                    cont.resume(returning: s)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// 加载页面后反复执行 js，直到拿到非空结果或超时
    @MainActor
    func loadAndExtract(url: String,
                        userAgent: String,
                        js: String,
                        initialWaitSeconds: Double = 3.0,
                        attempts: Int = 30,
                        intervalSeconds: Double = 0.7) async -> String? {
        load(url, userAgent: userAgent)
        try? await Task.sleep(nanoseconds: UInt64(initialWaitSeconds * 1_000_000_000))
        for _ in 0..<attempts {
            if let value = await evaluate(js), !value.isEmpty {
                reset()
                return value
            }
            try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
        }
        reset()
        return nil
    }
}

struct HiddenWebViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        HiddenWebView.shared.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
