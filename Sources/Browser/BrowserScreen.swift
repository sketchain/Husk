import SwiftUI

/// 浏览界面：全屏 WebView，除页面外没有任何常驻 UI。
/// 顶部一条细进度条，加载完淡出；其余一切靠手势唤出的工具箱。
struct BrowserScreen: View {
    @Environment(SiteStore.self) private var store

    @State private var session: WebSession
    @State private var showToolbox = false
    @State private var showSiteSettings = false

    /// 临时站点不在列表里，配置改不了也存不下
    let canPersist: Bool
    let onExit: () -> Void

    init(site: Site, canPersist: Bool, onExit: @escaping () -> Void) {
        _session = State(initialValue: WebSession(site: site))
        self.canPersist = canPersist
        self.onExit = onExit
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            BrowserWebView(
                session: session,
                gestures: store.settings.gestures,
                onToolbox: { showToolbox = true },
                onHandoff: { url in
                    session.notifyHandoff(Site.normalizedHost(of: url) ?? "外部链接")
                }
            )
            // 内容延伸到边缘；键盘避让交给 WebContainerView 里的 keyboardLayoutGuide，
            // 所以这里连 .keyboard 一起忽略掉，不然两套避让会打架。
            .ignoresSafeArea()

            if let error = session.loadError, session.currentURL == nil || session.progress == 0 {
                failureOverlay(error)
            }
        }
        .overlay(alignment: .top) { TopProgressBar(progress: session.progress, isLoading: session.isLoading) }
        .overlay(alignment: .bottom) { handoffToast }
        .overlay(alignment: .bottomTrailing) { escapeHatch }
        .sheet(isPresented: $showToolbox) {
            ToolboxSheet(
                session: session,
                canPersist: canPersist,
                onCommitZoom: commitZoom,
                onOpenSiteSettings: { showSiteSettings = true },
                onExitToLibrary: onExit
            )
        }
        .sheet(isPresented: $showSiteSettings) {
            NavigationStack {
                SiteEditorView(site: session.site, mode: .edit) { updated in
                    store.update(updated)
                    session.site = updated
                }
            }
        }
        .fullScreenCover(item: popupBinding) { popup in
            PopupBrowserView(popup: popup) { session.popup = nil }
        }
        // 站点在别处被改了（比如设置页），把新配置同步进当前会话
        .onChange(of: store.sites) { _, sites in
            guard canPersist, let updated = sites.first(where: { $0.id == session.site.id }) else { return }
            session.site = updated
        }
    }

    private var popupBinding: Binding<PopupSession?> {
        Binding(get: { session.popup }, set: { session.popup = $0 })
    }

    private func commitZoom(_ zoom: Double) {
        guard canPersist else { return }
        var site = session.site
        site.zoom = zoom
        store.update(site)
    }

    // MARK: - 覆盖层

    /// 四个手势全关掉的话就没法唤出工具箱了，等于被困在站点里出不来。
    /// 这种情况下给一个不起眼的小按钮兜底。
    @ViewBuilder
    private var escapeHatch: some View {
        if !store.settings.gestures.anyEnabled {
            Button {
                Haptics.tap()
                showToolbox = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(SpringyPressStyle())
            .padding(.trailing, 14)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var handoffToast: some View {
        if let notice = session.handoffNotice {
            Text(notice)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: session.handoffNotice)
        }
    }

    private func failureOverlay(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 38))
                .foregroundStyle(Theme.secondaryText)
            Text("打不开这个页面")
                .font(.headline)
            Text(error)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            HStack(spacing: 12) {
                Button("重试") { session.reload() }
                    .buttonStyle(.borderedProminent)
                Button("返回列表", action: onExit)
                    .buttonStyle(.bordered)
            }
            .tint(Theme.accent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
