import SwiftUI

/// 视觉常量集中一处。整个 app 走深色（Info.plist 里 UIUserInterfaceStyle = Dark），
/// 所以这里不做明暗两套。
enum Theme {
    static let background = Color(red: 0.039, green: 0.043, blue: 0.055)
    static let elevated = Color(red: 0.086, green: 0.094, blue: 0.118)
    static let accent = Color(red: 0.353, green: 0.541, blue: 0.996)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.55)
    static let hairline = Color.white.opacity(0.08)

    /// 首页图标的圆角。iOS 主屏图标是 continuous 的超椭圆，这里跟着来，
    /// 用 .circular 会一眼看出不对。
    static func tileShape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// 按压回弹。首页图标、工具箱按钮都用它。
struct SpringyPressStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
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
