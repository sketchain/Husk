import SwiftUI

/// 视觉常量。整个 app 走深色（Info.plist 里 UIUserInterfaceStyle = Dark），
/// 所以这里不做明暗两套。
///
/// iOS 26 改版之后这里刻意只剩三个颜色和一个形状：面板、按钮、卡片一律交给
/// 系统组件或 `glassEffect`，不再自己拿 `Color.white.opacity(0.08)` 糊毛玻璃。
enum Theme {
    static let background = Color(red: 0.039, green: 0.043, blue: 0.055)
    static let accent = Color(red: 0.353, green: 0.541, blue: 0.996)
    static let secondaryText = Color.secondary

    /// 首页图标的圆角。iOS 主屏图标是 continuous 的超椭圆，这里跟着来，
    /// 用 .circular 会一眼看出不对。
    static func tileShape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// 一小块玻璃上的提示条。首页和浏览页的"已复制""已在 Safari 打开"都用它。
struct GlassToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

enum Haptics {
    @MainActor
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @MainActor
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
