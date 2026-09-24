import SwiftUI

/// 浏览界面：全屏 WebView，除页面外没有任何常驻 UI。
/// 加载进度是顶部一条细条，或者（设置里选了、设备也支持时）绕着灵动岛的一圈，
/// 加载完淡出；其余一切靠手势唤出的工具箱。
///
/// 现在它是**根视图层面**的一层，不是模态。这样 deep link 进来时不必先有个首页
/// 再盖上去，站 A 跳站 B 也不用"先 dismiss 再 present"。
struct BrowserScreen: View {
    @Environment(SiteStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var session: WebSession
    @State private var showToolbox = false
    @State private var toolboxDetent: PresentationDetent = .medium
    /// 灵动岛进度环的几何。nil = 设置里选的是细条。
    /// 只在进页面、尺寸变化（转屏）、回前台、改设置时重算，见 `refreshIslandRing()`。
    @State private var islandRing: IslandRingAvailability?

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
            Theme.background
                .ignoresSafeArea()
                // 量的是忽略了安全区（含键盘）的整窗尺寸：只有转屏会改它，键盘弹出不会，
                // 免得每次弹键盘都去读一遍私有 API。onGeometryChange 首次也会回调一次，
                // 进页面时的那次计算就靠它。
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    refreshIslandRing(containerSize: size)
                }

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
        .overlay(alignment: .top) { progressIndicator }
        .overlay(alignment: .bottom) { handoffToast }
        .overlay(alignment: .bottomTrailing) { escapeHatch }
        // 全局开关：浏览网页时把时间电池那条一起藏掉
        .statusBarHidden(store.settings.hideStatusBarWhileBrowsing)
        .sheet(isPresented: $showToolbox) {
            ToolboxSheet(
                session: session,
                canPersist: canPersist,
                onExitToLibrary: onExit,
                detent: $toolboxDetent
            )
        }
        // detent 原来是 sheet 自己的 @State，每次弹出都从半屏档开始。提到这里之后要手动复位。
        .onChange(of: showToolbox) { _, shown in
            if !shown { toolboxDetent = .medium }
        }
        .fullScreenCover(item: popupBinding) { popup in
            PopupBrowserView(popup: popup) { session.popup = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshIslandRing() }
        }
        .onChange(of: store.settings.progressStyle) { refreshIslandRing() }
        // 站点在别处被改了（比如设置 tab），把新配置同步进当前会话
        .onChange(of: store.sites) { _, sites in
            guard canPersist, let updated = sites.first(where: { $0.id == session.site.id }) else { return }
            session.site = updated
        }
    }

    private var popupBinding: Binding<PopupSession?> {
        Binding(get: { session.popup }, set: { session.popup = $0 })
    }

    // MARK: - 加载进度

    /// 选了「环绕灵动岛」且这台设备、这个方向画得了，就画环；其余一律细条。
    @ViewBuilder
    private var progressIndicator: some View {
        if let layout = islandRing?.layout {
            IslandProgressRing(layout: layout, progress: session.progress, isLoading: session.isLoading)
                // 环用的是屏幕坐标，自己要铺满整个窗口
                .ignoresSafeArea()
                .opacity(ringCoveredBySheet ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: ringCoveredBySheet)
        } else {
            TopProgressBar(progress: session.progress, isLoading: session.isLoading)
        }
    }

    /// 工具箱拉到大档时把环藏起来。
    ///
    /// 环画在浏览页这一层（sheet 和 fullScreenCover 都盖在它上面，这正是想要的：
    /// 弹窗盖上来时环跟着页面一起被盖住，不会浮在别人的界面上）。但大档 sheet 在 iPhone 上
    /// 是 page sheet，系统可能把底下的页面往后缩一点——环是按屏幕坐标对准岛的，页面一缩
    /// 它就跟着偏了。大档时用户在看设置，不是在看页面加载，干脆淡出。
    /// 半屏档底下的页面不动、还能点，环照常显示。
    private var ringCoveredBySheet: Bool {
        showToolbox && toolboxDetent == .large
    }

    /// 重算进度环几何。**会读一次私有 API**，所以只挂在进页面 / 尺寸变化 / 回前台 /
    /// 改设置这几个时机上，绝不跟着 progress 走。
    private func refreshIslandRing(containerSize: CGSize? = nil) {
        guard store.settings.progressStyle == .islandRing else {
            islandRing = nil
            return
        }
        let result = IslandRingResolver.resolve(in: ExclusionAreaReader.activeScene)
        islandRing = result

        // 从横屏转回竖屏的那一刻，万一 scene 的方向比视图尺寸晚一步更新，
        // 这一次会误判成横屏而一直退回细条。尺寸已经是竖的时候，等转屏动画走完再确认一次。
        if let size = containerSize, size.height > size.width, result == .fallback(.landscape) {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                refreshIslandRing()
            }
        }
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
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.trailing, 14)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var handoffToast: some View {
        if let notice = session.handoffNotice {
            GlassToast(text: notice)
                .padding(.bottom, 26)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: session.handoffNotice)
        }
    }

    private func failureOverlay(_ error: String) -> some View {
        ContentUnavailableView {
            Label("打不开这个页面", systemImage: "wifi.exclamationmark")
        } description: {
            Text(error)
        } actions: {
            HStack(spacing: 12) {
                Button("重试") { session.reload() }
                    .buttonStyle(.glassProminent)
                Button("返回列表", action: onExit)
                    .buttonStyle(.glass)
            }
            .tint(Theme.accent)
        }
        .background(Theme.background)
    }
}
