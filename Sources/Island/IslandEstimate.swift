import CoreGraphics

/// 灵动岛那颗可见胶囊的实测几何：兜底估计值 + "避让区 → 可见胶囊"的换算公式。
///
/// 从 Lab/ 挪出来的：浏览页的进度环（`IslandRingResolver`）和实验室页都靠它，
/// 实验室不再是唯一的使用方。
///
/// ## 兜底估计值
///
/// 这组数来自真机实测（见下面的"已测得"），不是设计资料上的约数：
/// **125 × 36.6667 pt、距屏幕顶 14 pt、水平居中**。
///
/// 这仍然是**估计值，不是读出来的**。实验室页用它占位时会明确标出来；
/// **进度环绝不用它**——它只是 16 Pro 一台机器上的实测值，拿去给读不到
/// `_exclusionArea` 的未知设备画环，画出来大概率是错位的。
///
/// ## 已测得（iPhone 16 Pro / iPhone17,1 / iOS 26.6.2，402 × 874 @3x）
///
/// - `_exclusionArea` → `UISDisplaySingleRectShape`，`rect = {138.333, 14, 125, 36.6667}`
/// - `safeAreaInsets.top = 62`、`_displayCornerRadius = 62`
/// - 人眼校准出来的贴合参数：**向外扩 1、圆角夹成胶囊、X 偏移 +0.15**、Y 不用偏。
///
/// 两条结论（**只在这一台机器上验证过**，其他带岛机型待验证）：
///
/// 1. **避让区比眼睛看到的边缘小一圈 1pt。** 进度环要贴的是扩完之后
///    那颗胶囊，不是原始 rect。
/// 2. **那个 +0.15 不是玄学，是半个设备像素。** 把这台机器的数换算成像素：
///    屏宽 1206px、岛宽 375px，真正居中的 x 应该是 (1206-375)/2 = **415.5px**，
///    而 `_exclusionArea` 报的 138.3333pt = **415.0px**——正好被向下取整了半像素，
///    @3x 下就是 0.1667pt。y=42px、w=375px、h=110px 全是整像素，只有 x 落在半像素上。
///
///    所以**可见的岛是水平居中的**，横向别直接用读出来的 x，按屏幕居中算。
///    见 `visiblePill(exclusionRect:screenWidth:)`。
///
/// 是个不带隔离的 enum：非 MainActor 的 `IslandAdjustments` 要拿它当默认参数。
enum IslandEstimate {
    static let size = CGSize(width: 125, height: 36.6667)
    static let topInset: CGFloat = 14

    /// 实测出来的"避让区 → 可见胶囊"的外扩量
    static let visibleOutset: CGFloat = 1

    static func rect(screenWidth: CGFloat) -> CGRect {
        CGRect(
            x: (screenWidth - size.width) / 2,
            y: topInset,
            width: size.width,
            height: size.height
        )
    }

    /// 探不到 scene 时拿来占位的屏幕宽度（iPhone 16 Pro 的竖屏宽度）
    static let fallbackScreenWidth: CGFloat = 402

    /// 从 `_exclusionArea` 读到的 rect 推出**眼睛看到的那颗黑胶囊**。
    ///
    /// 这就是上面那两条实测结论的可执行版本：四边各扩 `visibleOutset`，
    /// 然后横向按屏幕重新居中（丢掉读出来的 x，它被向下取整到整设备像素了）。
    ///
    /// 进度环就是调的这个。别再自己拿 rect 硬算——不然又会踩回半像素那个坑。
    static func visiblePill(exclusionRect: CGRect, screenWidth: CGFloat) -> CGRect {
        let pill = exclusionRect.insetBy(dx: -visibleOutset, dy: -visibleOutset)
        return CGRect(
            x: (screenWidth - pill.width) / 2,
            y: pill.minY,
            width: pill.width,
            height: pill.height
        )
    }
}
