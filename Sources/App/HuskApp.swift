import AppIntents
import SwiftUI

@main
struct HuskApp: App {
    /// 只为了 `configurationForConnecting`：冷启动的 husk:// 要在第一帧之前拿到。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                // 三个真相来源都是进程级单例（AppDelegate 和 App Intents 都够不着 @State），
                // 这里只是把它们送进 environment 供视图取用
                .environment(SiteStore.shared)
                .environment(IconStore.shared)
                .environment(Router.shared)
                .tint(Theme.accent)
                // 整个 app 锁深色（Info.plist 里也写了 UIUserInterfaceStyle=Dark）。
                // 顺带让 WKWebView 的 prefers-color-scheme 跟着深色走。
                .preferredColorScheme(.dark)
        }
    }
}

/// 根视图。首页常驻在底下，浏览界面直接盖在它上面。
///
/// 为什么不是 `.fullScreenCover`：模态呈现有自己的动画和生命周期，
/// deep link 冷启动时必然是"先有首页，再上滑盖住"，站 A 跳站 B 还要先 dismiss
/// 再 present。换成同一个 ZStack 里的一层之后，换站就是换一个 `id`，
/// 中间没有任何一帧属于别人。
///
/// 首页**留在层级里**而不是被 if/else 换掉：这样从站点退回来时
/// tab 选中项、滚动位置都还在。
struct RootView: View {
    @Environment(SiteStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            HomeTabs()

            if let active = router.active {
                BrowserScreen(site: active.site, canPersist: active.canPersist) {
                    router.close()
                }
                // 换 id = 换会话。同一个站点重复打开时 Router 不会换 id，
                // 所以什么都不会重建。
                .id(active.id)
                .transition(.move(edge: .bottom))
            }
        }
        .onOpenURL { url in
            router.handleOpenURL(url, store: store)
        }
        // App Intents 的 scene 派发：告诉系统这个场景什么 intent 都能接
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        // iOS 26：系统在把 app 端到前台**之前**先把 intent 送到这里，
        // 所以快捷指令冷启动也能在第一帧就已经是"正在浏览"的状态。
        .onAppIntentExecution(OpenSiteIntent.self) { intent in
            router.open(siteID: intent.site.id, store: store, animated: false)
        }
        // 有 profile 开了代理的话，先把 DNS 预取拦截规则编好。不预热也能用（浏览页会等它），
        // 预热了进站点时就少转一下圈。
        .task {
            guard store.profileProxies.values.contains(where: \.isEnabled) else { return }
            await ProxyManager.shared.ensureRuleList()
        }
    }
}
