import SwiftUI

@main
struct HuskApp: App {
    @State private var store = SiteStore()
    @State private var icons = IconStore()
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(icons)
                .environment(router)
                .tint(Theme.accent)
                // 整个 app 锁深色（Info.plist 里也写了 UIUserInterfaceStyle=Dark）。
                // 顺带让 WKWebView 的 prefers-color-scheme 跟着深色走。
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(SiteStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if router.launchResolved {
                HomeScreen { site in router.open(site) }
                    .transition(.opacity)
            } else {
                // 冷启动挡板：和启动屏同色，所以看上去就是启动屏还没消失
                LaunchPlaceholder()
            }
        }
        .animation(.easeOut(duration: 0.2), value: router.launchResolved)
        .fullScreenCover(item: activeBinding) { active in
            BrowserScreen(site: active.site, canPersist: active.canPersist) {
                router.close()
            }
            .environment(store)
        }
        .onOpenURL { url in
            router.handle(url, store: store)
        }
        .task {
            await router.settleLaunch()
        }
    }

    private var activeBinding: Binding<ActiveSite?> {
        Binding(
            get: { router.active },
            set: { if $0 == nil { router.close() } }
        )
    }
}

private struct LaunchPlaceholder: View {
    var body: some View {
        Image(systemName: "square.grid.2x2.fill")
            .font(.system(size: 34))
            .foregroundStyle(Theme.accent.opacity(0.35))
    }
}
