import SwiftUI
import WebKit

/// WKWebView 的 SwiftUI 桥接。
///
/// 为什么不用 iOS 26 的 SwiftUI `WebView`/`WebPage`：本项目要自定义 UA、`pageZoom`、
/// 拦截外链导航、接管 `window.open`，这四件事在 `WKWebView` 上是确定可用的老接口，
/// 换到新 API 上映射关系不明确，不值得拿核心功能去赌。
struct BrowserWebView: UIViewRepresentable {
    let session: WebSession
    let gestures: GestureSettings
    let onToolbox: () -> Void
    let onHandoff: (URL) -> Void

    func makeCoordinator() -> WebCoordinator {
        WebCoordinator(session: session)
    }

    func makeUIView(context: Context) -> WebContainerView {
        let coordinator = context.coordinator
        let configuration = WebViewFactory.makeConfiguration(for: session.site, handler: coordinator.messageProxy)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        WebViewFactory.decorate(webView, site: session.site)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.observe(webView)

        let installer = ToolboxGestureInstaller()
        installer.install(on: webView, settings: gestures)
        coordinator.gestureInstaller = installer
        coordinator.appliedGestures = gestures
        coordinator.appliedUserAgent = .some(session.site.userAgent)
        coordinator.appliedZoom = nil   // 等 didFinish 再设，见 WebViewFactory.applyZoom 的注释

        session.webView = webView
        webView.load(URLRequest(url: session.url(for: session.site)))

        return WebContainerView(webView: webView)
    }

    func updateUIView(_ container: WebContainerView, context: Context) {
        let coordinator = context.coordinator
        let webView = container.webView
        coordinator.gestureInstaller?.onTrigger = onToolbox
        coordinator.onHandoff = onHandoff

        // UA：只有真变了才动，并且必须 reload 才对当前页生效
        if coordinator.appliedUserAgent != .some(session.site.userAgent) {
            coordinator.appliedUserAgent = .some(session.site.userAgent)
            webView.customUserAgent = session.site.userAgent
            webView.reloadFromOrigin()
        }

        // 缩放：滑块拖动时 session.site.zoom 一直在变，这里跟着刷
        if coordinator.appliedZoom != session.site.zoom {
            coordinator.appliedZoom = session.site.zoom
            WebViewFactory.applyZoom(session.site.zoom, to: webView)
        }

        if coordinator.appliedGestures != gestures {
            coordinator.appliedGestures = gestures
            coordinator.gestureInstaller?.install(on: webView, settings: gestures)
            coordinator.gestureInstaller?.onTrigger = onToolbox
        }
    }

    /// 视图拆掉时把 WebView 彻底断开。
    ///
    /// 这步直接关系到 WKWebsiteDataStore 的删除：只要还有 WebView 活着抓着那个 store，
    /// `remove(forIdentifier:)` 就会报 "Data store is in use"。
    static func dismantleUIView(_ container: WebContainerView, coordinator: WebCoordinator) {
        let webView = container.webView
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ContentScripts.messageName)
        coordinator.gestureInstaller?.removeAll()
        coordinator.session.webView = nil
    }
}

/// 装 WKWebView 的容器，存在的唯一理由是键盘。
///
/// WebView 铺满全屏（连状态栏底下都盖住），所以 SwiftUI 的键盘避让被关掉了；
/// 改用 `keyboardLayoutGuide` 把 WebView 底边顶上去，输入框就不会被键盘压住。
final class WebContainerView: UIView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        backgroundColor = UIColor(named: "LaunchBackground") ?? .black
        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false

        // 默认情况下键盘收起时这个 guide 会贴着底部安全区，于是 WebView 底下会空出一条。
        // 关掉它，收起时 guide 就贴到视图真正的底边，内容才是到边的。
        keyboardLayoutGuide.usesBottomSafeArea = false

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 用不到")
    }
}

extension WebSession {
    /// 首次加载的地址。临时站点可能带 query/fragment，不能只用 host。
    func url(for site: Site) -> URL {
        currentURL ?? site.url
    }
}
