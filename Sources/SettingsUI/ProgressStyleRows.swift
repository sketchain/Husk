import SwiftUI

/// 全局设置「浏览」分区里的加载进度样式：一个 Picker，选了「环绕灵动岛」时下面再跟一行
/// 这台设备会不会真的生效。body 是两行，放进 `Section` 会各自成为一行。
///
/// 选项在所有设备上都照常显示、照常可选，只是注明会退回细条：
/// 设置是能导出导入的，在 iPad 上改配置、导到 iPhone 上用是正常的用法，
/// 藏起来或者禁用都会让这个值在不支持的设备上看不见、改不了。
struct ProgressStyleRows: View {
    @Binding var style: ProgressStyle

    /// 这台设备现在画不画得了进度环。出现时算一次（会读一次私有 API），只用来写那行说明。
    @State private var support: IslandRingAvailability?

    var body: some View {
        Picker("加载进度", selection: $style) {
            ForEach(ProgressStyle.allCases) { Text($0.title).tag($0) }
        }
        .onAppear {
            support = IslandRingResolver.resolve(in: ExclusionAreaReader.activeScene)
        }

        if style == .islandRing, let note {
            Label(note.text, systemImage: note.fallsBack ? "info.circle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(note.fallsBack ? .orange : Theme.secondaryText)
        }
    }

    private var note: (text: String, fallsBack: Bool)? {
        switch support {
        case nil:
            return nil
        case .available:
            return ("这台设备支持。横屏时仍用顶部细条。", false)
        case .fallback(.landscape):
            return ("现在是横屏，横屏下用顶部细条（还没在真机上验证过）。竖屏时才会绕着灵动岛画。", true)
        case .fallback(let reason):
            return ("\(reason.summary)，浏览时会用顶部细条。", true)
        }
    }
}
