import UIKit
import WebKit

/// WebView 的统一装配。
///
/// 抽出来是因为 `window.open` 弹窗那条路径拿到的是 **WebKit 自己造的 configuration**，
/// 没走过这里的初始化，所以 configuration 层面的东西（user scripts、message handler）
/// 必须在 `createWebViewWith` 里重新挂一遍——`applyConfigurationExtras` 就是为这个存在的。
@MainActor
enum WebViewFactory {
    static func makeConfiguration(for site: Site, handler: any WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // 每个站点自己的 data store（同 profile 的站点共用同一个实例，见 WebsiteDataStoreManager 坑 2）
        configuration.websiteDataStore = WebsiteDataStoreManager.shared.dataStore(forProfile: site.profile)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 明确不做阅读模式/广告拦截，这里不塞任何内容规则
        applyConfigurationExtras(to: configuration, handler: handler)
        return configuration
    }

    /// user script + message handler。弹窗那条路径要单独调这个。
    static func applyConfigurationExtras(to configuration: WKWebViewConfiguration, handler: any WKScriptMessageHandler) {
        let controller = configuration.userContentController
        // 防重复：WebKit 递来的 configuration 理论上是干净的，但保险起见
        controller.removeAllUserScripts()
        controller.removeScriptMessageHandler(forName: ContentScripts.messageName)
        controller.addUserScript(ContentScripts.backgroundReporter)
        controller.add(handler, name: ContentScripts.messageName)
    }

    /// WebView 本身（非 configuration）层面的设置。弹窗也要走一遍。
    static func decorate(_ webView: WKWebView, site: Site) {
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.customUserAgent = site.userAgent   // nil = 系统默认

        // 深色下白闪的解法：让 WebView 自身透明，底下垫深色。
        // 只设 backgroundColor 不够——WKWebView 默认 isOpaque = true，会先刷一层白。
        webView.isOpaque = false
        webView.backgroundColor = UIColor(named: "LaunchBackground") ?? .black
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.scrollView.indicatorStyle = .white
        // 内容延伸到边缘，但让 scroll view 按自身 safe area 自动插入内容内边距，
        // 这样背景铺满整屏而文字不会压在灵动岛底下。
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.scrollView.keyboardDismissMode = .interactive
    }

    /// pageZoom 要在 didFinish 之后设：设太早会被这次导航重置掉。
    /// 它等价于给整页加 CSS zoom，别拿注入 JS 改 viewport 那套来替代。
    static func applyZoom(_ zoom: Double, to webView: WKWebView) {
        let clamped = CGFloat(zoom.clamped(to: Site.zoomRange))
        if abs(webView.pageZoom - clamped) > 0.001 {
            webView.pageZoom = clamped
        }
    }
}

enum ContentScripts {
    static let messageName = "husk"

    /// 把页面根元素的背景色报回来，用它去刷 WebView 的 backgroundColor，
    /// 这样过度滚动（橡皮筋）露出来的那一条和页面同色，而不是一道突兀的黑边。
    static let backgroundReporter = WKUserScript(
        source: """
        (function () {
          function report() {
            try {
              var html = getComputedStyle(document.documentElement).backgroundColor;
              var body = document.body ? getComputedStyle(document.body).backgroundColor : null;
              window.webkit.messageHandlers.husk.postMessage({ type: 'background', html: html, body: body });
            } catch (e) {}
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', report);
          } else {
            report();
          }
          window.addEventListener('pageshow', report);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )
}

/// message handler 会被 `WKUserContentController` 强引用，直接把 coordinator 挂上去会形成
/// coordinator → webView → configuration → contentController → coordinator 的环。
/// 用这个弱引用中转打断它。
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
