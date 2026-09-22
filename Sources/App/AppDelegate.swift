import UIKit

/// 存在的唯一理由：**把冷启动的 `husk://` 提前到第一帧之前拿到手**。
///
/// SwiftUI 的 `.onOpenURL` 是在窗口建好、第一帧画完之后才送到的，所以从快捷指令
/// 点进来必然先看见一下首页。`application(_:configurationForConnecting:options:)`
/// 比那早得多——scene 还没连上，`UIScene.ConnectionOptions.urlContexts` 里已经有
/// 这次启动带来的 URL 了。在这儿写进 `Router.shared`，`WindowGroup` 第一次求值时
/// 就已经是"在浏览某个站点"的状态，首页一帧都不会出现。
///
/// 返回值是一份默认配置：SwiftUI 的 App 生命周期不依赖这里返回的 `delegateClass`
/// （给它塞一个自定义 `UISceneDelegate` 是社区里通行的做法，说明这块是留给 app 的），
/// 所以原样给回系统即可。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // 一次启动只会带一个 URL；真有多个也只认第一个，多开几个会话没有意义
        if let url = options.urlContexts.first?.url {
            Router.shared.handleLaunchURL(url, store: SiteStore.shared)
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}
