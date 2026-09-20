import SwiftUI
import WebKit

/// window.open 弹出的窗口。模态盖住当前页，关掉回原页。
///
/// 它拿的是 WebKit 在 `createWebViewWith` 里递来的那个 WebView 实例——
/// 不能重建，否则 `window.opener` 断掉，OAuth 弹窗回不来（见 WebCoordinator+UI 的注释）。
struct PopupBrowserView: View {
    let popup: PopupSession
    let onClose: () -> Void

    @State private var title: String = ""

    var body: some View {
        NavigationStack {
            PopupWebViewHost(webView: popup.webView, title: $title)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title.isEmpty ? "新窗口" : title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { onClose() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let url = popup.webView.url {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
        }
        .tint(Theme.accent)
    }
}

private struct PopupWebViewHost: UIViewRepresentable {
    let webView: WKWebView
    @Binding var title: String

    func makeUIView(context: Context) -> WKWebView {
        // 注意：这里不发起任何 load。WebKit 在 createWebViewWith 返回后会自己
        // 对这个 WebView 执行那次被拦下的导航，我们再 load 一遍会变成加载两次。
        webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let current = webView.title ?? ""
        if current != title {
            Task { @MainActor in title = current }
        }
    }
}
