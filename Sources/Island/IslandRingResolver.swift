import CoreGraphics
import UIKit

/// 进度环的几何：可见胶囊 + 外扩出来的那圈环的中心线。全部是**屏幕坐标**（points）。
struct IslandRingLayout: Equatable, Sendable {
    /// 眼睛看到的黑胶囊（`IslandEstimate.visiblePill` 的输出）
    let pill: CGRect
    /// 描边的**中心线**所在的矩形。stroke 是沿中心线往两边各画半个线宽，
    /// 所以它比胶囊大 `gap + lineWidth / 2`，线的内边缘离胶囊正好 `gap`。
    /// 圆角不单独存：`PillOutline` 按这个矩形高度的一半画，天然和胶囊同心。
    let strokeRect: CGRect

    init(pill: CGRect) {
        self.pill = pill
        let outset = IslandRing.gap + IslandRing.lineWidth / 2
        strokeRect = pill.insetBy(dx: -outset, dy: -outset)
    }
}

/// 进度环的可调常量。都集中在这里，调观感只动这一处。
enum IslandRing {
    /// 线宽。顶部细条是 2pt；环在岛外面一圈、离屏幕上沿只有十来个 pt，
    /// 背景又常常是深色状态栏区，同样 2pt 看着偏虚，加半个点。
    static let lineWidth: CGFloat = 2.5

    /// 线的**内边缘**和可见胶囊之间留的缝。
    ///
    /// 不能是 0：环压在胶囊边缘上的话，内侧那半条线会被系统画的黑胶囊盖掉
    /// （岛在所有 app 内容之上），看上去线宽忽粗忽细。1.5pt 在 @3x 下是
    /// 4.5 个像素，既能看出是"围着岛的一圈"，又不至于离远了像一个独立的框。
    static let gap: CGFloat = 1.5

    /// 判定"形状像不像灵动岛"的容差。见 `IslandRingResolver.check`。
    enum Plausible {
        /// 胶囊高度。实测 36.67（16 Pro），各带岛机型公开资料都在 37 上下。
        static let height: ClosedRange<CGFloat> = 28...46
        /// 胶囊宽度。实测 125。
        static let width: ClosedRange<CGFloat> = 95...165
        /// 宽高比。实测 3.41；刘海大约 6.5–7，远在范围外。
        static let aspect: ClosedRange<CGFloat> = 2.4...4.6
        /// 离屏幕上沿的距离。实测 14。刘海的避让区是贴着顶边的（y≈0），
        /// 这一条是区分"岛"和"刘海"最硬的依据。
        static let top: ClosedRange<CGFloat> = 5...30
        /// 中心偏离屏幕中线的最大距离。实测只差半个设备像素（0.17pt）。
        static let centerDrift: CGFloat = 2
    }
}

/// 进度环画不了、要退回顶部细条的原因
enum IslandRingFallback: Equatable, Sendable {
    /// 不是 iPhone（iPad 没有灵动岛）
    case notPhone
    /// 拿不到前台 scene
    case noScene
    /// 横屏：`_exclusionArea` 在横屏下的坐标系和岛的位置都没在真机上验证过
    case landscape
    /// 转屏进行中：视图尺寸已经是竖的，但 scene 的方向或 `UIScreen.bounds` 还没跟上。
    /// 这时读出来的数不可信，先画细条，调用方过一会儿再查一次。
    case orientationSettling
    /// `_exclusionArea` 没读到。附带读取卡住的那一步。
    case unreadable(String)
    /// 读到了，但形状不像灵动岛（刘海机、或者私有 API 变了样）。附带哪一条没过。
    case notIslandShaped(String)

    /// 给设置页看的一句话
    var summary: String {
        switch self {
        case .notPhone: "这台设备没有灵动岛"
        case .noScene: "暂时拿不到屏幕信息"
        case .landscape: "横屏下还没验证过"
        case .orientationSettling: "屏幕方向正在切换"
        case .unreadable: "这台设备读不到灵动岛的位置"
        case .notIslandShaped: "这台设备的屏幕顶部不是灵动岛"
        }
    }
}

enum IslandRingAvailability: Equatable, Sendable {
    case available(IslandRingLayout)
    case fallback(IslandRingFallback)

    var layout: IslandRingLayout? {
        switch self {
        case .available(let layout): layout
        case .fallback: nil
        }
    }

    /// 实验室诊断报告里那一行
    var labDescription: String {
        switch self {
        case .available(let layout):
            let r = layout.pill
            return String(
                format: "会画环（胶囊 x=%.2f y=%.2f w=%.2f h=%.2f）",
                Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)
            )
        case .fallback(let reason):
            switch reason {
            case .unreadable(let detail), .notIslandShaped(let detail):
                return "退回细条：\(reason.summary)——\(detail)"
            default:
                return "退回细条：\(reason.summary)"
            }
        }
    }
}

/// 决定进度环能不能画、画在哪。
///
/// **只在这几个时机调**：进浏览页、容器尺寸变化（转屏）、scene 回到前台、切换设置，
/// 以及转屏时序没对齐时的延迟复查。能走到最后的调用会读一遍私有 API，
/// 所以绝不能挂在 progress 变化上。
///
/// 读不到就退回细条，**不**用 `IslandEstimate.rect` 那组兜底常数：那是 16 Pro 一台机器
/// 的实测值，给未知设备画出来很可能是错位的环，比不画更难看。
@MainActor
enum IslandRingResolver {
    /// - Parameter containerSize: 调用方视图量到的**整窗尺寸**（忽略安全区）。浏览页一定要传：
    ///   它是判断方向的主要依据，见下。设置页、实验室只要个"这台设备支不支持"的结论，
    ///   不传，就只看 scene 和 `UIScreen.bounds`。
    static func resolve(in scene: UIWindowScene?, containerSize: CGSize? = nil) -> IslandRingAvailability {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .fallback(.notPhone) }

        // 方向以视图自己量到的尺寸为准，scene 的方向和 UIScreen.bounds 只做交叉核对。
        //
        // 转屏时这几样东西的更新先后没有文档保证。只信 scene 的话，竖→横那一刻它要是
        // 晚一步仍报 .portrait，UIScreen.bounds 也还是竖的，那就会照常读 rect、
        // 在横屏界面上按竖屏坐标画一个环，而且之后不会再有尺寸变化来触发重算。
        // 视图尺寸是 SwiftUI 真正拿去布局的那个，onGeometryChange 就是被它触发的，
        // 它说横了就是横了：直接退回细条，连私有 API 都不读。
        if let size = containerSize, size.width > size.height {
            return .fallback(.landscape)
        }

        guard let scene else { return .fallback(.noScene) }

        // 只认正竖屏。带岛的 iPhone 不支持倒置竖屏（Info.plist 里也没开），
        // 横屏左右两种都没在真机上验证过 `_exclusionArea` 的坐标系，先一律退回。
        // iOS 26 起 scene.interfaceOrientation 废弃，从 effectiveGeometry 读。
        // UIScreen.bounds 从 iOS 8 起跟着界面方向转，所以也能拿来核对。
        let screen = scene.screen.bounds.size
        let sceneIsPortrait = scene.effectiveGeometry.interfaceOrientation == .portrait
            && screen.width < screen.height

        if let size = containerSize {
            // 视图已经是竖的。scene / 屏幕尺寸还没跟上（方向不对，或者宽度对不上——
            // iPhone 上浏览页的窗口就是整块屏幕），就是转屏还在路上，别读，等调用方复查。
            guard sceneIsPortrait, abs(screen.width - size.width) <= 1 else {
                return .fallback(.orientationSettling)
            }
        } else {
            guard sceneIsPortrait else { return .fallback(.landscape) }
        }

        let reading = ExclusionAreaReader.read(on: scene.screen)
        guard let rect = reading.rect else {
            return .fallback(.unreadable(reading.failure ?? "原因不明"))
        }

        if let problem = check(rect, screenSize: screen) {
            return .fallback(.notIslandShaped(problem))
        }
        return .available(
            IslandRingLayout(pill: IslandEstimate.visiblePill(exclusionRect: rect, screenWidth: screen.width))
        )
    }

    /// 读到的避让区像不像一颗灵动岛。不像就返回哪一条没过（给实验室报告看），像就返回 nil。
    ///
    /// 设计思路是"几条彼此独立的粗条件同时成立"，每条都放得很宽，只拦明显不对的：
    /// - **离顶边有距离**：灵动岛悬在屏幕里（实测 14pt），刘海的避让区贴着顶边（y≈0）。
    ///   这是最硬的一条，刘海机靠它就刷掉了。
    /// - **尺寸和宽高比在胶囊范围内**：刘海宽 200 多、宽高比 6 以上；私有 API 哪天变成
    ///   返回整条状态栏或者一个 0 高的东西，也会在这儿被拦下。
    /// - **水平居中**：岛都在屏幕正中。读出来的 x 只差半个设备像素，给 2pt 足够。
    /// - **整个在屏幕里**：坐标系不对（比如横屏的数混进来）时通常会越界。
    ///
    /// 范围都以 16 Pro 的实测值为中心放宽了一大截，而不是卡死在那一组数上——
    /// 其他带岛机型的尺寸没实测过，只知道公开资料上相差不到 1pt。
    static func check(_ rect: CGRect, screenSize: CGSize) -> String? {
        typealias P = IslandRing.Plausible
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              !rect.isEmpty
        else { return "矩形为空或不是有限值" }

        guard P.top.contains(rect.minY) else {
            return String(format: "离屏幕顶 %.2f，不在 %.0f…%.0f 之间（贴顶的是刘海）",
                          Double(rect.minY), Double(P.top.lowerBound), Double(P.top.upperBound))
        }
        guard P.height.contains(rect.height) else {
            return String(format: "高 %.2f，不像胶囊", Double(rect.height))
        }
        guard P.width.contains(rect.width) else {
            return String(format: "宽 %.2f，不像胶囊", Double(rect.width))
        }
        guard P.aspect.contains(rect.width / rect.height) else {
            return String(format: "宽高比 %.2f，不像胶囊", Double(rect.width / rect.height))
        }
        guard abs(rect.midX - screenSize.width / 2) <= P.centerDrift else {
            return String(format: "中心 x=%.2f，没有水平居中（屏宽 %.0f）",
                          Double(rect.midX), Double(screenSize.width))
        }
        guard CGRect(origin: .zero, size: screenSize).contains(rect) else {
            return "矩形超出了屏幕范围"
        }
        return nil
    }
}
