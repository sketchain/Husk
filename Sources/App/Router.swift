import Observation
import SwiftUI

/// 当前正在显示的站点。
struct ActiveSite: Identifiable, Equatable {
    /// 换一个 id 就等于"重建会话"。**同一个目标重复打开时刻意不换**，
    /// 见 `Router.isShowing(_:canPersist:)`。
    let id: UUID
    let site: Site
    /// 列表里的站点才能写回配置
    let canPersist: Bool

    init(site: Site, canPersist: Bool) {
        self.id = UUID()
        self.site = site
        self.canPersist = canPersist
    }

    static func == (lhs: ActiveSite, rhs: ActiveSite) -> Bool { lhs.id == rhs.id }
}

/// 根视图层面的"现在在看哪儿"。
///
/// 做成单例而不是 `@State`，是为了让**第一帧之前**就能写进来：
/// `AppDelegate.application(_:configurationForConnecting:options:)` 里拿到冷启动的
/// `husk://` 之后要立刻落库，那会儿 SwiftUI 的 `WindowGroup` 还没开始求值。
@MainActor
@Observable
final class Router {
    static let shared = Router()

    /// nil = 在首页
    private(set) var active: ActiveSite?

    /// 冷启动时从 `options.urlContexts` 取走的那个 URL。
    ///
    /// SwiftUI 之后**还会**把同一个 URL 再送一次给 `onOpenURL`——两条路径都存在，
    /// 谁先谁后不保证。记下来去重，免得同一次冷启动把会话建两遍。
    private var consumedLaunchURL: URL?

    private init() {}

    // MARK: - 打开

    /// 目标就是当前正在显示的那个站点吗？
    ///
    /// - 列表里的站点按 **id** 判：地址、缩放、UA 之后改了都还是同一个站。
    /// - 临时站点（`husk://open?url=`）按**去掉 fragment 的完整 URL** 判：
    ///   没有 id 可依，host 又太粗（同一个站的两个页面会被当成同一个目标，
    ///   结果是"打开另一篇文章却什么都不发生"）。fragment 不算，因为 `#anchor`
    ///   的差别是页内跳转，为它重建整个会话没有道理。
    func isShowing(_ site: Site, canPersist: Bool) -> Bool {
        guard let active, active.canPersist == canPersist else { return false }
        if canPersist { return active.site.id == site.id }
        return Router.adHocKey(active.site.url) == Router.adHocKey(site.url)
    }

    static func adHocKey(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.scheme = components?.scheme?.lowercased()
        components?.host = components?.host?.lowercased()
        return components?.url?.absoluteString ?? url.absoluteString
    }

    /// 打开一个站点。目标就是当前这个的话**什么都不做**——
    /// 不重建会话、不重载、不回站点首页。
    ///
    /// `animated`：从首页点进去时留过渡动画；deep link / 快捷指令进来时直接换，
    /// 中间不能有任何一帧是别的东西。
    func open(_ site: Site, canPersist: Bool, animated: Bool) {
        guard !isShowing(site, canPersist: canPersist) else { return }
        let next = ActiveSite(site: site, canPersist: canPersist)
        if animated {
            withAnimation(.snappy(duration: 0.3)) { active = next }
        } else {
            // 站 A 跳站 B 也走这里：直接替换，不经过"先 dismiss 再 present"
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { active = next }
        }
    }

    /// 按 id 打开列表里的站点。找不到就当没这回事（站点可能已经被删了）。
    @discardableResult
    func open(siteID: UUID, store: SiteStore, animated: Bool) -> Bool {
        guard let site = store.site(id: siteID) else { return false }
        open(site, canPersist: true, animated: animated)
        store.rememberLastOpened(site.id)
        return true
    }

    func close() {
        withAnimation(.snappy(duration: 0.3)) { active = nil }
    }

    // MARK: - husk://

    /// 冷启动路径：在第一帧之前把目标定下来。
    func handleLaunchURL(_ url: URL, store: SiteStore) {
        consumedLaunchURL = url
        handle(url, store: store, animated: false)
    }

    /// `onOpenURL` 路径。冷启动那一条已经处理过了就跳过。
    func handleOpenURL(_ url: URL, store: SiteStore) {
        if let consumedLaunchURL, consumedLaunchURL == url {
            self.consumedLaunchURL = nil
            return
        }
        consumedLaunchURL = nil
        handle(url, store: store, animated: false)
    }

    private func handle(_ url: URL, store: SiteStore, animated: Bool) {
        guard let target = DeepLink.parse(url) else { return }
        switch target {
        case .site(let id):
            open(siteID: id, store: store, animated: animated)
        case .adHoc(let target):
            open(
                Site.adHoc(url: target, defaults: store.settings.newSiteDefaults),
                canPersist: false,
                animated: animated
            )
        }
    }
}
