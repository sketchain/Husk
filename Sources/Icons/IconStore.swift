import Observation
import SwiftUI
import UIKit

/// 图标的内存缓存 + 抓取调度。
///
/// 解析顺序：用户自选图片 → 抓取缓存 → 首字母占位图。
/// 磁盘缓存在 Application Support/Husk/Icons，删站点时一起清掉。
@MainActor
@Observable
final class IconStore {
    /// 单例。App Intents 的实体查询要在没有任何 SwiftUI 视图的情况下取图标。
    static let shared = IconStore()

    private init() {}

    /// **故意不被观察**：`image(for:)` 会在 SwiftUI 的 body 求值过程中被调用，
    /// 顺手把解析结果写回缓存。要是这个字典参与观察，就成了"渲染中读又写同一份状态"，
    /// 轻则运行时警告，重则无限重渲染。
    @ObservationIgnored private var cache: [UUID: UIImage] = [:]

    /// 真正用来通知视图刷新的东西。抓到新图标时 +1，body 里读过它的视图就会重画。
    private(set) var generation: Int = 0
    private(set) var fetching: Set<UUID> = []

    /// 同步拿图，可以在 body 里直接调
    func image(for site: Site) -> UIImage {
        _ = generation   // 建立观察依赖：generation 变了，调用方要重新取图
        if let cached = cache[site.id] { return cached }
        let image = loadFromDisk(site) ?? makeMonogram(site)
        cache[site.id] = image
        return image
    }

    /// 首页出现时调一次：设成自动抓取、且磁盘上还没有缓存的，去抓
    func prepare(for site: Site, settings: AppSettings) {
        guard site.iconSource == .automatic else { return }
        let cached = AppPaths.cachedIcon(for: site.id).path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: cached) else { return }
        refresh(site, settings: settings)
    }

    /// 强制重新抓取
    func refresh(_ site: Site, settings: AppSettings) {
        guard !fetching.contains(site.id) else { return }
        fetching.insert(site.id)
        Task { [weak self] in
            // 开了代理但代理没就绪时拿到的是 nil：这次就不抓，绝不拿 URLSession.shared 直连凑合
            let session = await ProxyManager.shared.urlSession(forProfile: site.profile)
            var outcome: IconFetcher.Outcome?
            if let session {
                outcome = await IconFetcher.fetch(
                    for: site,
                    allowGoogleFallback: settings.allowGoogleFaviconFallback,
                    session: session
                )
            }
            guard let self else { return }
            if let outcome {
                try? outcome.pngData.write(to: AppPaths.cachedIcon(for: site.id), options: [.atomic])
                if site.iconSource == .automatic, let image = UIImage(data: outcome.pngData) {
                    self.cache[site.id] = image
                    self.generation &+= 1
                }
            }
            self.fetching.remove(site.id)
        }
    }

    /// 用户选了张图片
    @discardableResult
    func setCustomImage(_ image: UIImage, for site: Site) -> Bool {
        guard let data = image.pngData(), let png = IconFetcher.normalize(data) else { return false }
        try? png.write(to: AppPaths.customIcon(for: site.id), options: [.atomic])
        cache[site.id] = UIImage(data: png)
        generation &+= 1
        return true
    }

    /// 站点改了名字或地址之后把内存缓存作废，下次取重新解析
    func invalidate(_ id: UUID) {
        cache.removeValue(forKey: id)
        generation &+= 1
    }

    func forget(_ id: UUID) {
        cache.removeValue(forKey: id)
        AppPaths.removeIcons(for: id)
        generation &+= 1
    }

    /// 原样的 PNG data
    func pngData(for site: Site) -> Data? {
        image(for: site).pngData()
    }

    /// 存到相册用的 1024×1024 主屏图标。
    ///
    /// 这里**刻意不用 `image(for:)`**：它抓不到图标时会返回一张 180 像素的占位图，
    /// 而占位图和真图标在那个返回值上分不出来——导出那边会把它当成"一张 180 的源图"
    /// 放大到 1024，结果是一个糊掉的字母。走 `loadFromDisk` 就只有真存在的
    /// 抓取缓存或自选图片才返回，抓不到就是 nil，交给导出那边按占位图风格**重画**一张。
    func homeScreenIconPNG(for site: Site) -> Data? {
        IconExporter.makeIcon(for: site, source: loadFromDisk(site))
    }

    /// 快捷指令列表里那张小图。太大的话会让整个实体列表变得很重，缩到 128 足够。
    func thumbnailPNG(for site: Site, side: CGFloat = 128) -> Data? {
        let source = image(for: site)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()
    }

    // MARK: - 私有

    private func loadFromDisk(_ site: Site) -> UIImage? {
        switch site.iconSource {
        case .custom:
            UIImage(contentsOfFile: AppPaths.customIcon(for: site.id).path(percentEncoded: false))
        case .automatic:
            UIImage(contentsOfFile: AppPaths.cachedIcon(for: site.id).path(percentEncoded: false))
        case .monogram:
            nil
        }
    }

    private func makeMonogram(_ site: Site) -> UIImage {
        let image = MonogramRenderer.render(text: site.monogram, seed: site.name + site.displayHost)
        try? image.pngData()?.write(to: AppPaths.monogramIcon(for: site.id), options: [.atomic])
        return image
    }
}
