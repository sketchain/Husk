import SwiftUI
import UIKit

/// `UIActivityViewController` 的 SwiftUI 包装。
///
/// 为什么不全用 `ShareLink`：导出配置 JSON 时要在分享完成后删临时文件，
/// 而且 iPad 上要自己给 popover 一个锚点，这两件事 ShareLink 没给口子。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
