import UIKit
import WebKit

/// WKNavigationDelegate / WKUIDelegate / 脚本消息 的实现体。
@MainActor
final class WebCoordinator: NSObject {
    let session: WebSession
    /// 站点配置变化时用来判断"要不要真的动 WebView"，避免 updateUIView 每次都 reload
    var appliedUserAgent: String??
    var appliedZoom: Double?
    var appliedGestures: GestureSettings?
    var gestureInstaller: ToolboxGestureInstaller?
    /// 外链交给 Safari 时的回调（UI 层弹提示）
    var onHandoff: ((URL) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private(set) lazy var messageProxy = ScriptMessageProxy(target: self)

    init(session: WebSession) {
        self.session = session
        super.init()
    }

    deinit {
        // NSKeyValueObservation 析构时会自己注销，这里显式清一下更直白
        observations.forEach { $0.invalidate() }
    }

    // MARK: - KVO

    /// 进度条 / 前进后退可用性 / 标题 / 地址 都靠 KVO。
    ///
    /// 回调里一律 `Task { @MainActor in }` 跳一下，而不是直接写。KVO 的回调闭包在
    /// Swift 6 严格并发下没有隔离保证，跳一次是唯一稳当的写法；
    /// 代价是进度更新晚一个 runloop，肉眼看不出来。
    func observe(_ webView: WKWebView) {
        observations.forEach { $0.invalidate() }
        let session = self.session

        observations = [
            webView.observe(\.estimatedProgress, options: [.new, .initial]) { _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in session.progress = value }
            },
            webView.observe(\.isLoading, options: [.new, .initial]) { _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in session.isLoading = value }
            },
            webView.observe(\.title, options: [.new]) { _, change in
                let value = change.newValue ?? nil
                Task { @MainActor in session.pageTitle = value }
            },
            webView.observe(\.url, options: [.new]) { _, change in
                let value = change.newValue ?? nil
                Task { @MainActor in session.currentURL = value }
            },
            webView.observe(\.canGoBack, options: [.new, .initial]) { _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in session.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.new, .initial]) { _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in session.canGoForward = value }
            },
        ]
    }
}

// MARK: - 导航策略

extension WebCoordinator: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased()

        // 非 web scheme（mailto: tel: itms-apps: 各种 app 跳转）交给系统，
        // WebView 自己处理不了，不拦的话就是一个"点了没反应"。
        if scheme != "http", scheme != "https", scheme != "about", scheme != "blob", scheme != "data" {
            decisionHandler(.cancel)
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            }
            return
        }

        // 只拦"用户点出来的主框架导航"。
        // iframe、重定向、表单提交、资源请求一律放行——
        // 一起拦会把 OAuth 跳转、支付回调、单页应用的路由全打断。
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        guard let targetFrame = navigationAction.targetFrame else {
            // targetFrame == nil 表示要开新窗口（target=_blank / window.open）。
            // 这里放行，交给 createWebViewWith 去处理，别在这儿截胡。
            decisionHandler(.allow)
            return
        }
        guard targetFrame.isMainFrame else {
            decisionHandler(.allow)
            return
        }

        if shouldHandOffToSafari(url) {
            decisionHandler(.cancel)
            handOff(url)
        } else {
            decisionHandler(.allow)
        }
    }

    func shouldHandOffToSafari(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        switch session.site.externalLinkPolicy {
        case .inApp: return false
        case .safari: return true
        case .sameDomain: return !session.site.isSameSite(url)
        }
    }

    func handOff(_ url: URL) {
        UIApplication.shared.open(url)
        onHandoff?(url)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        session.loadError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 缩放在这里设——didFinish 之前设会被这次导航重置
        WebViewFactory.applyZoom(session.site.zoom, to: webView)
        appliedZoom = session.site.zoom
        session.loadError = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        recordFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        recordFailure(error)
    }

    private func recordFailure(_ error: any Error) {
        let nsError = error as NSError
        // -999 是"这次导航被新的导航取代了"，不是错误，别拿它弹脸
        guard nsError.code != NSURLErrorCancelled else { return }
        session.loadError = nsError.localizedDescription
    }
}

// MARK: - 页面回传的消息

extension WebCoordinator: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == ContentScripts.messageName,
              let body = message.body as? [String: Any],
              body["type"] as? String == "background"
        else { return }

        let candidates = [body["body"] as? String, body["html"] as? String].compactMap(\.self)
        guard let color = candidates.compactMap(UIColor.fromCSS).first else { return }
        message.webView?.backgroundColor = color
        message.webView?.scrollView.backgroundColor = color
    }
}

extension UIColor {
    /// 解析 `rgb(r, g, b)` / `rgba(r, g, b, a)`。完全透明的当没拿到。
    static func fromCSS(_ value: String) -> UIColor? {
        let scanner = value.lowercased()
        guard scanner.hasPrefix("rgb") else { return nil }
        let numbers = scanner
            .drop(while: { $0 != "(" })
            .dropFirst()
            .prefix(while: { $0 != ")" })
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count >= 4 ? numbers[3] : 1
        guard alpha > 0.05 else { return nil }
        return UIColor(
            red: numbers[0] / 255,
            green: numbers[1] / 255,
            blue: numbers[2] / 255,
            alpha: alpha
        )
    }
}
