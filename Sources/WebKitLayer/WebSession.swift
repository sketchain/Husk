import Observation
import SwiftUI
import WebKit

/// 一次浏览会话的状态与遥控器。一个 BrowserScreen 配一个。
@MainActor
@Observable
final class WebSession {
    /// 当前站点配置。改它会在 `updateUIView` 里按差异落到 WebView 上。
    var site: Site

    var progress: Double = 0
    var isLoading: Bool = false
    var pageTitle: String?
    var currentURL: URL?
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    /// 拦下外链交给 Safari 时给一个短暂提示
    var handoffNotice: String?
    /// 加载失败的说明；成功后清空
    var loadError: String?

    /// window.open 弹出的那个 WebView（用 WebKit 递来的 configuration 建的，见 WebCoordinator）
    var popup: PopupSession?

    /// 不参与观察：这是个 UIKit 对象引用，被观察到会在视图更新期间触发"更新中修改状态"的警告
    @ObservationIgnored weak var webView: WKWebView?

    init(site: Site) {
        self.site = site
        self.currentURL = site.url
    }

    // MARK: - 遥控

    func reload() {
        guard let webView else { return }
        // 没加载成功过的话 reload() 是空操作，得重新发请求
        if webView.url == nil {
            webView.load(URLRequest(url: site.url))
        } else {
            webView.reloadFromOrigin()
        }
    }

    func goHome() {
        webView?.load(URLRequest(url: site.url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    /// 缩放滑块拖动时实时调用。写回配置由调用方在松手时做。
    func applyZoom(_ value: Double) {
        site.zoom = value.clamped(to: Site.zoomRange)
        webView?.pageZoom = site.zoom
    }

    /// 改 UA 必须 reload 才对当前页生效——`customUserAgent` 只影响之后发出的请求。
    func applyUserAgent(_ userAgent: String?) {
        site.userAgent = userAgent
        webView?.customUserAgent = userAgent
        webView?.reloadFromOrigin()
    }

    var shareURL: URL { currentURL ?? site.url }

    func openInSafari() {
        let url = shareURL
        guard url.scheme == "http" || url.scheme == "https" else { return }
        UIApplication.shared.open(url)
    }

    func copyCurrentURL() {
        UIPasteboard.general.url = shareURL
    }

    func notifyHandoff(_ host: String) {
        notify("已在 Safari 打开 \(host)")
    }

    /// 底部那条一闪而过的提示
    func notify(_ text: String) {
        handoffNotice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.handoffNotice = nil
        }
    }
}

/// window.open / target=_blank 弹出的窗口。
///
/// 这里**必须**持有 WebKit 在 `createWebViewWith` 里递过来的那个 WKWebView，
/// 不能自己另建一个——自己建的会让页面里的 `window.opener` 变成 null，
/// 依赖 opener 回传结果的第三方登录会静默失败（点完授权那个窗口就干在那儿）。
@MainActor
final class PopupSession: Identifiable {
    let id = UUID()
    let webView: WKWebView
    var title: String?

    init(webView: WKWebView) {
        self.webView = webView
    }
}
