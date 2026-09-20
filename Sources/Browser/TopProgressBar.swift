import SwiftUI

/// 顶部那条极细的进度条。加载完淡出，不占布局。
struct TopProgressBar: View {
    let progress: Double
    let isLoading: Bool

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Theme.accent)
                .frame(width: max(0, geometry.size.width * progress), height: 2)
                .shadow(color: Theme.accent.opacity(0.6), radius: 4, y: 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        // 加载完之后淡出，而不是"啪"一下消失
        .opacity(isLoading && progress < 1 ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: progress)
        .animation(.easeInOut(duration: 0.4), value: isLoading)
        .allowsHitTesting(false)
    }
}
