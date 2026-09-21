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
    /// 用 **async 变体**而不是 completion handler 版本。
    ///
    /// iOS 18 起 WebKit 给这些回调加上了 `@MainActor`，旧签名
    /// `decisionHandler: @escaping (WKNavigationActionPolicy) -> Void` 只是"近似匹配"
    /// 协议要求——编译器给个 warning 就过去了，但运行时这个方法**根本不会被调用**，
    /// 表现就是外链拦截、scheme 跳转全部静默失效。这种 bug 极难从现象反推。
    ///
    /// 手动补 `@MainActor @Sendable` 也能对上，但那是在追 SDK 的标注；
    /// 本项目最低 iOS 18，直接用 async 变体，签名里没有闭包就没有标注漂移的问题。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }

        let scheme = url.scheme?.lowercased()

        // 非 web scheme（mailto: tel: weixin: itms-apps: 各种 app 跳转）交给系统，
        // WebView 自己处理不了，不拦的话就是一个"点了没反应"。
        if scheme != "http", scheme != "https", scheme != "about", scheme != "blob", scheme != "data" {
            openExternalApp(url, from: navigationAction)
            return .cancel
        }

        // 只拦"用户点出来的主框架导航"。
        // iframe、重定向、表单提交、资源请求一律放行——
        // 一起拦会把 OAuth 跳转、支付回调、单页应用的路由全打断。
        guard navigationAction.navigationType == .linkActivated else { return .allow }
        guard let targetFrame = navigationAction.targetFrame else {
            // targetFrame == nil 表示要开新窗口（target=_blank / window.open）。
            // 这里放行，交给 createWebViewWith 去处理，别在这儿截胡。
            return .allow
        }
        guard targetFrame.isMainFrame else { return .allow }

        guard shouldHandOffToSafari(url) else { return .allow }
        handOff(url)
        return .cancel
    }

    func shouldHandOffToSafari(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https" else { return false }
        switch session.site.externalLinkPolicy {
        case .inApp:
            return false
        case .safari:
            // 字面意义的"全都甩出去"，用户既然选了这个就不替他耍小聪明
            return true
        case .sameDomain:
            if session.site.isSameSite(url) { return false }
            // 登录 / 授权流留在站内：甩进 Safari 的话回调落在 Safari，这边永远等不到
            if Site.looksLikeAuthFlow(url) { return false }
            return true
        }
    }

    /// 把非 web scheme 交给系统。
    ///
    /// 两个坑：
    /// 1. **不能用 `canOpenURL` 当前置判断**。iOS 9 起它对没写进 `LSApplicationQueriesSchemes`
    ///    的 scheme 一律返回 false，而那张表上限 50 条、还得预先知道要查哪些——
    ///    对一个开放的浏览容器根本没法穷举。结果就是 `weixin://`、`alipay://` 这类
    ///    点了完全没反应。`open` 本身**不受**这张表限制，直接调就是了，
    ///    打不开会在回调里给 false。
    /// 2. **只认主框架发起的**。广告 iframe 往 `itms-apps://` 一跳就能把人弹去 App Store，
    ///    这种劫持相当常见，来自子框架的一律吞掉。
    private func openExternalApp(_ url: URL, from navigationAction: WKNavigationAction) {
        guard navigationAction.sourceFrame.isMainFrame else { return }
        Task { [weak session] in
            let opened = await UIApplication.shared.open(url)
            if !opened {
                session?.notify("没有 app 能打开这个链接")
            }
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
