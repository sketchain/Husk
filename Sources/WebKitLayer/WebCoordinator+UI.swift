import UIKit
import WebKit

// MARK: - WKUIDelegate：window.open 与 JS 对话框

extension WebCoordinator: WKUIDelegate {
    /// window.open / target=_blank 走这里。
    ///
    /// **关键：必须用 WebKit 递进来的 `configuration` 建新 WebView。**
    /// 自己 new 一个 WKWebViewConfiguration 的话，新页面和开它的页面就不在同一个
    /// "浏览上下文组"里，`window.opener` 会变成 null——依赖 opener 回传 token 的
    /// 第三方登录（Google / GitHub 那类弹窗式 OAuth）会静默失败：授权完了弹窗干在那儿，
    /// 原页面永远收不到回调。这个坑排查起来非常费劲，别"优化"掉这行。
    ///
    /// 另一面：这个 configuration 没走过 `WebViewFactory.makeConfiguration`，
    /// 所以 configuration 层面的东西（user script、message handler）必须在这里重挂。
    /// websiteDataStore 不用管——WebKit 会从 opener 继承，这正是我们要的。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // 这里**刻意不套用外链策略**。
        //
        // 之前这儿有一段"目标域名按策略该去 Safari 就直接甩出去"，看着合理，实际上把
        // 下面那段关于 window.opener 的努力全废了：默认策略是"按域名判断"，而登录弹窗
        // 十有八九开在 accounts.google.com 这类外域上，于是每一个弹窗式 OAuth 都会被
        // 甩进 Safari——opener 根本不存在了，用户在 Safari 里授权完，Husk 这边干等。
        //
        // 定性上也说得通：外链策略管的是"从这个站导航走"，而 window.open 开出来的是
        // **站点自己流程的一部分**（授权、支付、打印预览），它和 opener 有绑定关系。
        // 所以弹窗一律留在站内的模态里，关掉就回原页。

        WebViewFactory.applyConfigurationExtras(to: configuration, handler: messageProxy)
        let popup = WKWebView(frame: .zero, configuration: configuration)
        WebViewFactory.decorate(popup, site: session.site)
        popup.navigationDelegate = self
        popup.uiDelegate = self

        // WebKit 返回之后会自己对这个 WebView 发起导航，我们不能自己 load，
        // 否则某些站点会加载两次（一次我们发的，一次 WebKit 发的）。
        session.popup = PopupSession(webView: popup)
        return popup
    }

    /// 页面调 window.close()
    func webViewDidClose(_ webView: WKWebView) {
        if session.popup?.webView === webView {
            session.popup = nil
        }
    }

    // MARK: JS 对话框
    //
    // 不实现这几个方法的话，alert / confirm / prompt 在 WKWebView 里是"什么都不发生"，
    // 而且 confirm 永远返回 false。对一个当 app 用的容器来说这是明显的功能缺失。
    //
    // 同样用 async 变体，理由见 WebCoordinator.decidePolicyFor 上面那段：
    // iOS 18 起这些 completion handler 带了 @MainActor，旧签名只"近似匹配"，
    // 编译器放过但运行时不会被调用。

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        guard let presenter = webView.owningViewController else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
                continuation.resume()
            })
            presenter.present(alert, animated: true)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        guard let presenter = webView.owningViewController else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alert, animated: true)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard let presenter = webView.owningViewController else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(title: frame.securityOrigin.host, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: "好", style: .default) { [weak alert] _ in
                continuation.resume(returning: alert?.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }
    }
}

extension UIView {
    /// 沿响应链找到能拿来 present 的 view controller
    var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                // 已经在 present 别的东西时往上找，否则 present 会失败
                return controller.presentedViewController ?? controller
            }
            responder = current.next
        }
        return nil
    }
}
