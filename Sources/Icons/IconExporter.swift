import SwiftUI
import UIKit

/// 生成"存到相册"用的主屏图标 PNG。
///
/// 为什么是这个形状：快捷指令的「添加到主屏幕」让你从相册里挑一张自定义图标，
/// 系统会自己切超椭圆圆角、自己缩放。所以这边要给的是
/// **1024×1024、方形、不带圆角、不透明**的原图——自己先切圆角的话会被切两遍，
/// 边上留一圈怪东西。
@MainActor
enum IconExporter {
    /// 主屏图标的标准边长。iOS 的 app 图标原图就是这个尺寸。
    static let size: CGFloat = 1024

    /// 源图小于这个像素数就不往上放了。
    ///
    /// 门槛该定在哪儿，要按**最终显示尺寸**算而不是按 1024 算：主屏图标显示出来
    /// 大约 180pt，3x 屏上是 540 像素。所以 180 的 apple-touch-icon（最常见的一种）
    /// 实际是 180 → 540 的 3 倍放大，偏软但认得出，用它比给人一个字母强；
    /// 而 32 / 64 的 favicon 是 8 倍以上，那就真是一团糊了。
    ///
    /// 128 是这两者之间的界线。注意这条门槛只有在图标缓存"只缩不放"时才有意义
    /// （见 `IconFetcher.targetSize`）——缓存要是统一放大到固定尺寸，
    /// 这里读到的像素数就和源图的真实清晰度没关系了。
    static let minimumSourcePixels: CGFloat = 128

    /// 生成 PNG。`source` 是磁盘上真存在的那张图标，没有就传 nil。
    static func makeIcon(for site: Site, source: UIImage?) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1        // 固定 1x：产出的是 PNG 文件，不跟屏幕 scale 走
        format.opaque = true    // 主屏图标不该有透明通道
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size),
            format: format
        )

        let seed = site.name + site.displayHost
        let usable = usableSource(site: site, source: source)

        let image = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            // 底色一律铺占位图那套渐变：源图是透明 PNG 的话（很多 favicon 都是）
            // 直接落在渐变上，看着像是故意设计的，而不是一块黑。
            MonogramRenderer.drawGradient(in: rect, seed: seed, context: context.cgContext)

            if let usable {
                drawAspectFill(usable, in: rect)
            } else {
                MonogramRenderer.drawMonogram(site.monogram, in: rect)
            }
        }
        return image.pngData()
    }

    /// 源图够不够大、该不该用。
    /// `source` 传 nil 表示压根没有真图标（调用方负责判断，见 `IconStore.homeScreenIconPNG`）。
    private static func usableSource(site: Site, source: UIImage?) -> UIImage? {
        guard site.iconSource != .monogram, let source else { return nil }
        let pixels = max(source.size.width * source.scale, source.size.height * source.scale)
        return pixels >= minimumSourcePixels ? source : nil
    }

    /// 等比铺满（超出的部分裁掉），保证方形图里不留空边
    private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: rect.midX - drawn.width / 2,
            y: rect.midY - drawn.height / 2
        )
        image.draw(in: CGRect(origin: origin, size: drawn))
    }
}
