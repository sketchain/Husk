import WebKit

/// 实验室用：一个不上屏的 WKWebView，加载一个地址，把结果原样交回来。
///
/// 代理诊断要看的是**真 WebView** 的行为（WebKit 网络进程里那条路），
/// 不是 app 自己 URLSession 的行为——两者用的代理实现不是同一份。
@MainActor
final class WebViewProbe: NSObject, WKNavigationDelegate {
    enum Outcome: Sendable {
        case loaded(url: URL?, text: String?)
        case failed(NSError)
        case timedOut

        var summary: String {
            switch self {
            case .loaded(let url, let text):
                let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return "加载成功 \(url?.absoluteString ?? "")" + (body.isEmpty ? "" : "\n页面文字：\(body.prefix(200))")
            case .failed(let error):
                return "加载失败\n" + Self.describe(error)
            case .timedOut:
                return "超时（30 秒没有结果）。网络进程崩溃时常见这种表现，配合系统日志看"
            }
        }

        /// 错误连同 underlying 链一路展开，真机上贴回来能直接对照 CFNetwork 错误码
        static func describe(_ error: NSError, depth: Int = 0) -> String {
            let indent = String(repeating: "  ", count: depth)
            var line = "\(indent)\(error.domain) \(error.code)：\(error.localizedDescription)"
            let extra = error.userInfo
                .filter { $0.key != NSUnderlyingErrorKey && $0.key != NSLocalizedDescriptionKey }
                .map { "\(indent)  \($0.key) = \($0.value)" }
                .sorted()
            if !extra.isEmpty { line += "\n" + extra.joined(separator: "\n") }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, depth < 4 {
                line += "\n" + describe(underlying, depth: depth + 1)
            }
            return line
        }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private let credential: URLCredential?

    init(store: WKWebsiteDataStore, proxyCredential: URLCredential? = nil) {
        credential = proxyCredential
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
    }

    /// 加载一次。同一个探针上连续调两次，就是"同一个 WebView 的第二次导航"
    func load(_ url: URL, timeout: Duration = .seconds(30)) async -> Outcome {
        guard let webView else { return .timedOut }
        finish(.timedOut)   // 上一次还挂着的话先了结
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(.timedOut)
            }
        }
    }

    func tearDown() {
        finish(.timedOut)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url
        Task {
            let text = try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
            finish(.loaded(url: url, text: text))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failed(error as NSError))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failed(error as NSError))
    }

    /// 和浏览页一样：代理问凭据时答一次，答不上就取消，绝不走系统弹框
    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.isProxy() else { return (.performDefaultHandling, nil) }
        guard challenge.previousFailureCount == 0, let credential else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, credential)
    }
}
