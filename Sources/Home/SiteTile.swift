import SwiftUI

/// 首页上的一个站点。大圆角图标 + 名字，按下去有回弹。
struct SiteTile: View {
    let site: Site
    let image: UIImage
    let action: () -> Void

    private var glow: Color {
        let hue = MonogramRenderer.hue(for: site.name + site.displayHost)
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 74, height: 74)
                    .clipShape(Theme.tileShape(20))
                    .overlay(
                        // 深色底上如果图标本身也是深色，没这道边就糊成一团
                        Theme.tileShape(20).strokeBorder(.separator, lineWidth: 0.5)
                    )
                    // 图标自己的颜色透出来一点，整屏就不会死黑
                    .shadow(color: glow.opacity(0.28), radius: 14, y: 7)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)

                Text(site.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 32, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TilePressStyle())
    }
}

/// 整个 app 里仅剩的一处自绘按钮样式。
///
/// 站点图标是一张铺满的图片，系统的 `.glass` / `.borderless` 都会在它周围
/// 画自己的背景，看着就不是"主屏图标"了。这里只保留按压回弹，别的什么都不加。
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
