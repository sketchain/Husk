import AppIntents
import SwiftUI

/// 「打开站点」——注册给快捷指令的动作。
///
/// 这条 intent 走的是和 `husk://open?id=` **完全相同**的那段逻辑
/// （`Router.open`），所以第 1、2 条的行为自动成立：
/// 目标就是当前站点时什么都不动，换站时直接切、不走"先关再开"。
///
/// 冷启动下不闪首页靠的是 iOS 26 的 **scene 派发**：
/// 带上 `TargetContentProvidingIntent` 之后，系统会在把 app 端到前台**之前**
/// 先把 intent 送给场景（见 `RootView` 的 `.onAppIntentExecution`），
/// 给我们一次在第一帧之前把根视图摆好的机会。`perform()` 里那一次是兜底：
/// 万一派发没发生（比如场景匹配失败），这条路还能把站点打开，
/// 而重复调用本来就是空操作，多跑一次没有副作用。
struct OpenSiteIntent: AppIntent, TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "打开站点"
    static let description = IntentDescription(
        "在 Husk 里打开一个站点。已经在这个站点上时不做任何事——不重载、不回首页。",
        categoryName: "浏览"
    )

    /// 这条 intent 的意义就是把 app 端到前台
    static let openAppWhenRun = true

    @Parameter(title: "站点")
    var site: SiteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("打开 \(\.$site)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.open(siteID: site.id, store: SiteStore.shared, animated: false)
        return .result()
    }
}

/// 让每个站点在「快捷指令」app 的 Husk 分组里各占一条。
///
/// 参数化的 App Shortcut 会拿 `SiteEntityQuery.suggestedEntities()` 的结果
/// 逐个展开，所以站点增删改之后要调一次 `updateAppShortcutParameters()`
/// 把那份快照刷新（见 `SiteStore` 的调用点），否则列表会停在上一次的样子。
struct HuskShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSiteIntent(),
            phrases: [
                // 每条短语都必须出现 \(.applicationName)，这是框架的硬性要求
                "在 \(.applicationName) 里打开 \(\.$site)",
                "用 \(.applicationName) 打开 \(\.$site)",
                "\(.applicationName) 打开 \(\.$site)",
                "Open \(\.$site) in \(.applicationName)",
            ],
            shortTitle: "打开站点",
            systemImageName: "square.grid.2x2"
        )
    }
}
