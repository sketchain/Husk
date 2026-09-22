import SwiftUI
import UIKit

/// 抓不到图标时用的首字母渐变占位图。
///
/// 拆成 `drawGradient` / `drawMonogram` 两个原子操作，是因为"存图标到相册"
/// 也要用同一套底色（见 `IconExporter`）——源图是透明 PNG 时落在这层渐变上，
/// 看着像是故意设计的，而不是一块黑。
enum MonogramRenderer {
    /// 色相由站点名稳定推导，**不能用 `hashValue`**：
    /// Swift 的字符串哈希带每次启动随机化的 seed，换一次进程同一个站点就换一个颜色。
    static func hue(for seed: String) -> Double {
        var acc: UInt64 = 5381
        for scalar in seed.unicodeScalars {
            acc = (acc &* 33) &+ UInt64(scalar.value)
        }
        return Double(acc % 360) / 360.0
    }

    static func colors(for seed: String) -> (Color, Color) {
        let h = hue(for: seed)
        let top = Color(hue: h, saturation: 0.62, brightness: 0.78)
        let bottom = Color(hue: (h + 0.08).truncatingRemainder(dividingBy: 1.0), saturation: 0.78, brightness: 0.52)
        return (top, bottom)
    }

    /// 只画底色渐变
    static func drawGradient(in rect: CGRect, seed: String, context cg: CGContext) {
        let (top, bottom) = colors(for: seed)
        let space = CGColorSpaceCreateDeviceRGB()
        let cgColors = [UIColor(top).cgColor, UIColor(bottom).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: [0, 1]) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        } else {
            UIColor(top).setFill()
            cg.fill(rect)
        }
    }

    /// 只画居中的那个字
    static func drawMonogram(_ text: String, in rect: CGRect) {
        let fontSize = min(rect.width, rect.height) * 0.46
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.95),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let origin = CGPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        string.draw(at: origin)
    }

    /// 渲染成 PNG 并缓存到磁盘。要的是真 PNG data，不是 SwiftUI 视图。
    static func render(text: String, seed: String, size: CGFloat = 180) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // 固定 1x：这张图是拿去存 PNG 的，不跟屏幕 scale 走
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)

        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            drawGradient(in: rect, seed: seed, context: context.cgContext)
            drawMonogram(text, in: rect)
        }
    }
}
