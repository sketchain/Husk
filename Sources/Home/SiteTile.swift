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
                        Theme.tileShape(20).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                    // 图标自己的颜色透出来一点，整屏就不会死黑
                    .shadow(color: glow.opacity(0.28), radius: 14, y: 7)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)

                Text(site.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.primaryText.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 32, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpringyPressStyle(scale: 0.9))
    }
}

/// 末尾那块"加站点"，和站点图标同样大小，虚线框。
struct AddSiteTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Theme.tileShape(20)
                    .strokeBorder(
                        Color.white.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1.4, dash: [6, 5])
                    )
                    .frame(width: 74, height: 74)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Theme.secondaryText)
                    )
                Text("加站点")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(height: 32, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpringyPressStyle(scale: 0.9))
    }
}
