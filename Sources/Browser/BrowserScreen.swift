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
    /// 整窗尺寸（忽略安全区和键盘）。进度环判断方向的主要依据。
    @State private var containerSize: CGSize?
    /// 转屏时序没对齐时的延迟复查。新的一次重算会先取消它。
    @State private var ringRecheck: Task<Void, Never>?
    /// 这个站点的 profile 开了代理时，代理就绪之前**不建 WebView**，见 `ProxyGate`
    @State private var proxyGate: ProxyGate
    /// 代理配置变了就 +1，WebView 跟着拆掉重建（新的 configuration、新的加固、重新加载当前地址）
    @State private var webViewGeneration = 0
    @State private var gateTask: Task<Void, Never>?

    /// 临时站点不在列表里，配置改不了也存不下
    let canPersist: Bool
    let onExit: () -> Void

    init(site: Site, canPersist: Bool, onExit: @escaping () -> Void) {
        _session = State(initialValue: WebSession(site: site))
        // 没开代理、或者代理已经就绪的，第一帧就有 WebView——不为代理多闪一下
        _proxyGate = State(initialValue: ProxyGate(ProxyManager.shared.readiness(for: site.profile)))
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
                    containerSize = size
                    refreshIslandRing()
                }

            switch proxyGate {
            case .ready:
                BrowserWebView(
                    session: session,
                    gestures: store.settings.gestures,
                    onToolbox: { showToolbox = true },
                    onHandoff: { url in
                        session.notifyHandoff(Site.normalizedHost(of: url) ?? "外部链接")
                    }
                )
                .id(webViewGeneration)
                // 内容延伸到边缘；键盘避让交给 WebContainerView 里的 keyboardLayoutGuide，
                // 所以这里连 .keyboard 一起忽略掉，不然两套避让会打架。
                .ignoresSafeArea()

                if let error = session.loadError, session.currentURL == nil || session.progress == 0 {
                    failureOverlay(error, retry: { session.reload() })
                }
            case .preparing:
                ProgressView("正在连接代理…")
                    .tint(Theme.accent)
            case .failed(let failure):
                failureOverlay(LoadFailure(failure), retry: rebuildForProxyChange)
            }
        }
        .task {
            if proxyGate == .preparing { openGate() }
        }
        // 这个 profile 的代理设置改了（或者回前台时中继换了端口），拆掉 WebView 重来
        .onChange(of: ProxyManager.shared.revision(for: session.site.profile)) { rebuildForProxyChange() }
        // 站点换了 profile，而新旧两边有一边开了代理：出口变了，同样重来。
        // 两边都没开代理时不动——profile 名是在输入框里逐字改的，每敲一个字重建一次 WebView 受不了，
        // 那种情况维持以前的行为（下次进站点才换 store）。
        .onChange(of: session.site.profile) { old, new in
            if ProxyManager.shared.isProxied(old) || ProxyManager.shared.isProxied(new) { rebuildForProxyChange() }
        }
        .onDisappear { gateTask?.cancel() }
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
        .onDisappear { ringRecheck?.cancel() }
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

    /// 重算进度环几何。只挂在进页面 / 尺寸变化 / 回前台 / 改设置这几个时机上，
    /// 绝不跟着 progress 走——走到最后会读一次私有 API。
    private func refreshIslandRing() {
        ringRecheck?.cancel()
        ringRecheck = nil
        guard store.settings.progressStyle == .islandRing else {
            islandRing = nil
            return
        }
        applyIslandRing(recheckAttempt: 0)
    }

    /// 算一次，赋值；要是转屏还没落定（视图已经竖了，scene / 屏幕尺寸还没跟上），
    /// 先画细条，隔一会儿再查，最多查 `ringRecheckLimit` 次。
    ///
    /// 方向判断以 `containerSize` 为主，见 `IslandRingResolver.resolve`：视图一横过来
    /// 就直接退回细条，不存在"横屏下留着一个按竖屏坐标画的环"。对不上的只剩
    /// "视图竖了、scene 还横着"这一种，它不会画错，只会晚一点画上，所以用延迟复查兜住；
    /// 查满次数还对不上就一直是细条，也是安全的那一边。
    private func applyIslandRing(recheckAttempt attempt: Int) {
        let result = IslandRingResolver.resolve(
            in: ExclusionAreaReader.activeScene,
            containerSize: containerSize
        )
        islandRing = result

        guard result == .fallback(.orientationSettling), attempt < Self.ringRecheckLimit else { return }
        ringRecheck = Task {
            // 取消（新的一次重算、或离开页面）时 sleep 直接抛 CancellationError，就此作罢
            do { try await Task.sleep(for: Self.ringRecheckDelay) } catch { return }
            applyIslandRing(recheckAttempt: attempt + 1)
        }
    }

    /// 转屏动画大约 0.3–0.4 秒。300ms × 5 次，足够盖住一次转屏
    private static let ringRecheckDelay = Duration.milliseconds(300)
    private static let ringRecheckLimit = 5

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

    // MARK: - 代理

    /// 代理配置变了：先把 WebView 拿掉（`.preparing` 下根本不渲染它），准备好了再用新的
    /// generation 建一个新的。顺序很重要——先拆后配，旧 WebView 就没有机会按新旧交替的
    /// 那一瞬间的配置发请求。
    ///
    /// 选"自动重建并重载"而不是"提示用户"：代理开关是出口 IP 级别的事，
    /// 让已经打开的页面继续按旧路走，恰恰是用户改设置时最不想要的。代价是当前页的
    /// 前进后退历史和没提交的表单会丢，README 里写了。
    private func rebuildForProxyChange() {
        session.popup = nil
        session.loadError = nil
        proxyGate = .preparing
        openGate()
    }

    private func openGate() {
        gateTask?.cancel()
        let profile = session.site.profile
        gateTask = Task {
            let result = await ProxyManager.shared.prepare(profile: profile)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                webViewGeneration += 1
                proxyGate = .ready
            case .failure(let failure):
                proxyGate = .failed(failure)
            }
        }
    }

    private func failureOverlay(_ failure: LoadFailure, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure.symbol)
        } description: {
            Text(failure.message)
        } actions: {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button("重试", action: retry)
                        .buttonStyle(.glassProminent)
                    Button("返回列表", action: onExit)
                        .buttonStyle(.glass)
                }
                // 开了代理的 profile 出错时给个直达入口：没有 WebView 就没有手势，工具箱唤不出来
                if ProxyManager.shared.isProxied(session.site.profile) {
                    ProfileProxyRow(profile: session.site.profile)
                        .buttonStyle(.glass)
                        .fixedSize()
                }
            }
            .tint(Theme.accent)
        }
        .background(Theme.background)
    }
}

/// 浏览页和代理之间的闸门
enum ProxyGate: Equatable {
    case ready
    case preparing
    case failed(ProxyFailure)

    init(_ readiness: ProxyManager.Readiness) {
        switch readiness {
        case .ready: self = .ready
        case .pending: self = .preparing
        case .failed(let failure): self = .failed(failure)
        }
    }
}
