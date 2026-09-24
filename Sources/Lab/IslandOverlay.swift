import Observation
import SwiftUI
import UIKit

/// 描边的可调参数。做成一个整体而不是六个散落的属性，是为了能一次
/// `onChange` 就落盘，不用给每个属性挂 `didSet`——`@Observable` 宏会把
/// 存储属性重写成计算属性，属性观察器在那之后是不成立的。
struct IslandAdjustments: Equatable, Codable, Sendable {
    var cornerRadius: CGFloat
    /// 描边相对基准矩形向外扩的距离，负数就是往里收
    var outset: CGFloat = 0
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    /// 圆角用正圆弧还是连续曲率（超椭圆）。系统那颗胶囊是正圆弧，
    /// 但避让区矩形未必，两个都给，眼睛选一个更贴的。
    var usesCircularCorners = true
    /// 在岛周围铺一小块白底。黑胶囊衬在白底上边缘最清楚，比在深色 UI 上好判断得多。
    var showsWhiteBacking = false

    init(cornerRadius: CGFloat = IslandEstimate.size.height / 2) {
        self.cornerRadius = cornerRadius
    }
}

/// 灵动岛描边叠加层的开关和参数。
///
/// **为什么是独立的 `UIWindow` 而不是 SwiftUI 的 `.overlay`**：这层描边要在离开
/// 实验室页之后还看得见——页面自己的导航栏、tab bar 都会挡住灵动岛附近，
/// 站在页面里根本没法判断贴不贴合。挂在自己的窗口上之后，它盖在 app 的一切之上，
/// 切 tab、进站点浏览、回首页全程都在，直到手动关掉。
///
/// 窗口做了两件事保证它只是"一层贴纸"：
/// - `hitTest` 永远返回 nil，触摸全部穿透下去，UI 照常能用；
/// - 不 `makeKeyAndVisible`，key window 仍然是 SwiftUI 那个，
///   状态栏的显示/隐藏还是由它说了算（浏览页的「隐藏状态栏」不受影响）。
///
/// 参数存 `UserDefaults` 而不是进 `AppSettings`：这是调试用的临时值，
/// 不该混进导出的配置 JSON 里。
@MainActor
@Observable
final class IslandOverlayController {
    static let shared = IslandOverlayController()

    /// 描边线宽固定 1pt：再粗就看不出零点几个 point 的偏差了
    static let lineWidth: CGFloat = 1

    // MARK: - 状态

    /// 描边参照的基准矩形。探测成功时是 `_exclusionArea` 的 rect，
    /// 否则是上面那组估计值。
    private(set) var baseRect: CGRect = .zero

    /// true = `baseRect` 是估计值，不是读出来的
    private(set) var baseIsEstimate = true

    /// 只由 `setVisible(_:)` 改。用方法而不是属性观察器，理由见 `IslandAdjustments`。
    private(set) var isVisible = false

    var adjustments: IslandAdjustments

    /// 不参与观察：它只是个实现细节，没人需要因为它变了而重画
    @ObservationIgnored private var window: UIWindow?

    // MARK: - 计算

    /// 真正画出来的那个矩形
    var outlinedRect: CGRect {
        baseRect
            .insetBy(dx: -adjustments.outset, dy: -adjustments.outset)
            .offsetBy(dx: adjustments.offsetX, dy: adjustments.offsetY)
    }

    var cornerStyle: RoundedCornerStyle {
        adjustments.usesCircularCorners ? .circular : .continuous
    }

    /// 圆角半径超过描边矩形高度的一半时，`RoundedRectangle` 会把它夹成胶囊，
    /// 再往上调没有任何视觉区别。页面上要标出来，不然会以为是自己看错了。
    var cornerRadiusIsClamped: Bool {
        adjustments.cornerRadius >= outlinedRect.height / 2
    }

    /// 按 iPhone 16 Pro 上实测出来的那条公式推算的可见胶囊。
    ///
    /// 换机型、换系统版本时不用再从零拖一遍滑块：先看它和手调出来的「描边矩形」
    /// 对不对得上，一致就说明公式还成立；对不上再调，然后把新的一组记下来。
    var formulaPillRect: CGRect {
        IslandEstimate.visiblePill(exclusionRect: baseRect, screenWidth: Self.currentScreenWidth)
    }

    /// 公式推算的胶囊和手调出来的描边矩形是否吻合。
    /// 容差半个设备像素——比这更细的差别肉眼本来也分不出来。
    var formulaMatchesOutline: Bool {
        let tolerance = 0.5 / (DynamicIslandProbe.activeScene?.screen.scale ?? 3)
        let a = formulaPillRect
        let b = outlinedRect
        return abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    // MARK: - 生命周期

    private init() {
        adjustments = Self.loadAdjustments() ?? IslandAdjustments()
        baseRect = IslandEstimate.rect(screenWidth: Self.currentScreenWidth)
    }

    private static var currentScreenWidth: CGFloat {
        DynamicIslandProbe.activeScene?.screen.bounds.width ?? IslandEstimate.fallbackScreenWidth
    }

    /// 把一次探测结果喂进来。读到了就用真值，没读到就退回估计值。
    func adopt(_ diagnostics: IslandDiagnostics) {
        if let rect = diagnostics.exclusionRect, !rect.isEmpty {
            baseRect = rect
            baseIsEstimate = false
        } else {
            baseRect = IslandEstimate.rect(screenWidth: Self.currentScreenWidth)
            baseIsEstimate = true
        }
    }

    func setVisible(_ on: Bool) {
        guard on != isVisible else { return }
        isVisible = on
        on ? attachWindow() : detachWindow()
    }

    func resetAdjustments() {
        adjustments = IslandAdjustments(cornerRadius: baseRect.height / 2)
        persistAdjustments()
    }

    /// 复制回报告里的那一段，和诊断信息拼在一起贴回来
    var calibrationSummary: String {
        """
        基准矩形（\(baseIsEstimate ? "估计值" : "_exclusionArea 读取值")）：\
        \(DynamicIslandProbe.format(baseRect))
        圆角半径：\(DynamicIslandProbe.fmt(adjustments.cornerRadius))\
        （\(adjustments.usesCircularCorners ? "正圆弧" : "连续曲率")）
        向外扩：\(DynamicIslandProbe.fmt(adjustments.outset))
        X 偏移：\(DynamicIslandProbe.fmt(adjustments.offsetX))
        Y 偏移：\(DynamicIslandProbe.fmt(adjustments.offsetY))
        描边线宽：\(DynamicIslandProbe.fmt(Self.lineWidth))（画在矩形内侧）
        描边矩形（基准 + 外扩 + 偏移）：\(DynamicIslandProbe.format(outlinedRect))
        实测公式推算：\(DynamicIslandProbe.format(formulaPillRect))\
        \(formulaMatchesOutline ? "（和描边矩形一致，公式成立）" : "（和描边矩形对不上，这台设备要单独记一组）")
        """
    }

    // MARK: - 窗口

    private func attachWindow() {
        // scene 换过（比如 app 被杀过又回来）时旧窗口是死的，重建
        if let window, window.windowScene != nil {
            window.isHidden = false
            return
        }
        detachWindow()
        guard let scene = DynamicIslandProbe.activeScene else { return }

        let host = OverlayHostingController(rootView: IslandOutlineView(overlay: self))
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.isUserInteractionEnabled = false

        let new = PassthroughWindow(windowScene: scene)
        new.rootViewController = host
        new.backgroundColor = .clear
        new.isOpaque = false
        new.isUserInteractionEnabled = false
        // 压在 app 自己的窗口之上、系统状态栏之下。不用 .alert 那种高层级：
        // 越靠上越容易被 UIKit 当成"该由它决定状态栏样式"的那一个。
        new.windowLevel = .normal + 1
        new.isHidden = false          // 刻意不是 makeKeyAndVisible，见类型注释

        window = new
    }

    private func detachWindow() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    // MARK: - 持久化

    private static let storageKey = "lab.island.adjustments"

    private static func loadAdjustments() -> IslandAdjustments? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(IslandAdjustments.self, from: data)
    }

    func persistAdjustments() {
        guard let data = try? JSONEncoder().encode(adjustments) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - 窗口与容器

/// 什么都不接，触摸一律穿透到下面的窗口
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// 明确放弃对状态栏和 home indicator 的发言权，别影响浏览页的「隐藏状态栏」
private final class OverlayHostingController<Content: View>: UIHostingController<Content> {
    override var childForStatusBarStyle: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
}

// MARK: - 描边本体

/// 整屏铺开、忽略安全区，在绝对坐标上画一圈细描边。
///
/// 用 `strokeBorder` 而不是 `stroke`：前者把线画在矩形**内侧**，
/// 矩形的外边缘就正好是 `outlinedRect` 的边界，校准时不用再脑补半个线宽。
///
/// 白底只铺岛周围一圈而不是整屏——整屏白了就看不见下面的开关，关不掉了。
private struct IslandOutlineView: View {
    /// 直接持有 `@Observable` 单例，读它的属性就会订阅变化，滑块拖动时实时重画
    var overlay: IslandOverlayController

    var body: some View {
        let rect = overlay.outlinedRect

        ZStack(alignment: .topLeading) {
            Color.clear

            if overlay.adjustments.showsWhiteBacking {
                Rectangle()
                    .fill(.white)
                    .frame(width: rect.width + 96, height: rect.height + 64)
                    .offset(x: rect.minX - 48, y: rect.minY - 32)
            }

            RoundedRectangle(cornerRadius: overlay.adjustments.cornerRadius, style: overlay.cornerStyle)
                .strokeBorder(
                    Color(red: 1, green: 0.16, blue: 0.22),
                    lineWidth: IslandOverlayController.lineWidth
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
