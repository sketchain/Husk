import SwiftUI

/// tab bar 上方那条"继续上次"。玻璃胶囊底是系统给的，这里只管往里填内容。
///
/// `tabViewBottomAccessoryPlacement` 在 tab bar 收起时变成 `.inline`，
/// 留给内容的高度只剩一行，所以那种摆法只显示一行名字。
/// 两个分支**都必须是非空的**——accessory 的内容在"有"和"没有"之间跳会踩
/// `_bottomAccessory.displayStyle` 的断言（FB18479195）；
/// "没有上次记录"那种情况是连 modifier 一起不加的，见 `HomeTabs` 的注释。
struct ContinueAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(IconStore.self) private var icons

    let site: Site
    let action: () -> Void

    private var isInline: Bool { placement == .inline }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(uiImage: icons.image(for: site))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: isInline ? 22 : 28, height: isInline ? 22 : 28)
                    .clipShape(Theme.tileShape(isInline ? 6 : 8))

                if isInline {
                    Text(site.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("继续上次")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(site.name)
                            .font(.subheadline.weight(.medium))
                    }
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
