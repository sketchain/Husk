import Observation
import SwiftUI

/// 当前打开的站点。临时站点每次都换 id，这样连着开两次同一个地址也会重建会话。
struct ActiveSite: Identifiable {
    let id = UUID()
    let site: Site
    /// 列表里的站点才能写回配置
    let canPersist: Bool
}

@MainActor
@Observable
final class Router {
    var active: ActiveSite?

    /// 冷启动阶段：为 true 之前首页不渲染。
    ///
    /// 为的是 `husk://` 冷启动时**不要先闪一下首页**。SwiftUI 的 `.onOpenURL` 是在
    /// 第一帧之后才送到的，直接渲染首页就会看到"首页闪一下再盖上站点"。
    /// 这里先铺一张和启动屏同色的底，等 URL 落定（或者 140ms 内没有 URL）再放首页出来。
    private(set) var launchResolved = false

    /// 启动时给 deep link 留的那点窗口期
    func settleLaunch() async {
        guard !launchResolved else { return }
        try? await Task.sleep(for: .milliseconds(140))
        launchResolved = true
    }

    func handle(_ url: URL, store: SiteStore) {
        defer { launchResolved = true }
        guard let target = DeepLink.parse(url) else { return }
        switch target {
        case .site(let id):
            guard let site = store.site(id: id) else { return }
            active = ActiveSite(site: site, canPersist: true)
        case .adHoc(let target):
            active = ActiveSite(
                site: Site.adHoc(url: target, defaults: store.settings.newSiteDefaults),
                canPersist: false
            )
        }
    }

    func open(_ site: Site) {
        active = ActiveSite(site: site, canPersist: true)
    }

    func close() {
        active = nil
    }
}
