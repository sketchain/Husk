import SwiftUI

/// 沿灵动岛轮廓画的一圈加载进度。
///
/// **从胶囊底边正中起笔，两边对称往上长，在顶边正中合拢。** 为什么这样：
/// - 岛是屏幕正中一个左右对称的东西，单向绕圈的话进度走到一半时整颗岛看上去是
///   歪的，而且很像系统的"转圈等待"；对称长法在任何时刻都是平衡的。
/// - 底边朝着网页内容，是眼睛最容易看到的那一侧；顶边离屏幕上沿只有十来个 pt，
///   又挨着屏幕圆角。WebKit 的进度经常在前 10%–30% 停好一会儿，这一段应该落在
///   最显眼的地方；最后合拢的那一下发生在不起眼的顶边，紧接着就淡出了。
///
/// 位置是屏幕坐标（`IslandRingLayout`），这里只负责换算到自己的坐标系里。
/// 自己必须铺满整个窗口（调用方加 `.ignoresSafeArea()`）。
struct IslandProgressRing: View {
    let layout: IslandRingLayout
    let progress: Double
    let isLoading: Bool

    var body: some View {
        GeometryReader { proxy in
            // `.global` 在 SwiftUI 里就是窗口坐标。iPhone 上窗口和屏幕重合，
            // 这里减一下只是为了不假设自己一定从 (0,0) 开始。
            let origin = proxy.frame(in: .global).origin
            let rect = layout.strokeRect.offsetBy(dx: -origin.x, dy: -origin.y)
            let half = min(max(progress, 0), 1) / 2

            ZStack {
                // 同一条路径剪两段：前半段是从底边中点往左绕到顶边中点，
                // 后半段是从顶边中点经右侧回到底边中点。两段各取靠近起点的那 half，
                // 看上去就是从底边中点往两边对称生长。
                PillOutline()
                    .trim(from: 0, to: half)
                    .stroke(Theme.accent, style: Self.stroke)
                PillOutline()
                    .trim(from: 1 - half, to: 1)
                    .stroke(Theme.accent, style: Self.stroke)
            }
            .shadow(color: Theme.accent.opacity(0.6), radius: 4, y: 0)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
        .loadingProgressFade(progress: progress, isLoading: isLoading)
    }

    private static let stroke = StrokeStyle(lineWidth: IslandRing.lineWidth, lineCap: .round)
}

/// 胶囊轮廓，**起点固定在底边正中**，先往左、绕过左端、沿顶边、绕过右端、回到起点。
///
/// 不直接用 `Capsule().path(in:)`：它的起点在哪、往哪个方向走都没有文档保证，
/// 而 trim 的 0 和 1 就落在起点上，起点不受控，对称生长就无从谈起。
///
/// 圆弧用 `addArc(tangent1End:tangent2End:radius:)`（两条切线夹出来的圆角），
/// 它由几何关系唯一确定，不像按角度画的那几个重载要操心 y 轴朝下时"顺时针"指哪边。
/// 每个半圆拆成两个四分之一圆。路径左右镜像对称，所以顶边正中正好在全长的一半处，
/// trim 的 0.5 就是合拢点。
private struct PillOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.height, rect.width) / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        // 左半圆：底 → 左 → 顶
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.midY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: r)
        // 右半圆：顶 → 右 → 底
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.midY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.midX, y: rect.maxY), radius: r)
        path.closeSubpath()
        return path
    }
}
