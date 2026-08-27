import SwiftUI
import WebKit

/// 全局隐藏 WKWebView，供小红书解析器执行页面反爬 JS 后提取数据
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
}

struct HiddenWebViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        HiddenWebView.shared.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
