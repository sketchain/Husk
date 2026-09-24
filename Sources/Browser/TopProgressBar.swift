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
        .loadingProgressFade(progress: progress, isLoading: isLoading)
    }
}

extension View {
    /// 两种进度样式共用的显隐和动画：进度变化 0.2 秒缓出，加载完淡出而不是"啪"一下消失。
    /// 抽成一处，是为了保证环和细条的淡出行为永远一致。
    func loadingProgressFade(progress: Double, isLoading: Bool) -> some View {
        opacity(isLoading && progress < 1 ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: progress)
            .animation(.easeInOut(duration: 0.4), value: isLoading)
            .allowsHitTesting(false)
    }
}
