import Foundation
import UIKit

/// 站点图标抓取。顺序：页面里的 apple-touch-icon → 根目录约定路径 → /favicon.ico → Google favicon 服务。
///
/// 整个类型标成 `@MainActor` 是有意的：UIImage / CGImage 都不是 Sendable，
/// 让它们跨 actor 走只会换来一堆 `@unchecked` 或者把图搬进 Data 再搬出来。
/// 图标就 180 像素见方，解码开销可以忽略，而网络等待期间 `await` 本来就把主线程让出去了。
@MainActor
enum IconFetcher {
    /// 目标边长：iOS 主屏图标最大用到 180pt，超过没意义
    static let targetSize: CGFloat = 180

    struct Outcome: Sendable {
        let pngData: Data
        let source: String
    }

    static func fetch(for site: Site, allowGoogleFallback: Bool) async -> Outcome? {
        var tried = Set<URL>()

        for candidate in await htmlDeclaredIcons(for: site.url) {
            guard tried.insert(candidate).inserted else { continue }
            if let png = await loadPNG(from: candidate) {
                return Outcome(pngData: png, source: "apple-touch-icon")
            }
        }

        guard let root = rootURL(of: site.url) else { return nil }
        let conventional = [
            root.appending(path: "apple-touch-icon.png"),
            root.appending(path: "apple-touch-icon-precomposed.png"),
            root.appending(path: "favicon.ico"),
        ]
        for candidate in conventional {
            guard tried.insert(candidate).inserted else { continue }
            if let png = await loadPNG(from: candidate) {
                return Outcome(pngData: png, source: candidate.lastPathComponent)
            }
        }

        // 最后才走 Google：这一步会把域名告诉 Google，所以做成可关
        if allowGoogleFallback, let host = Site.normalizedHost(of: site.url),
           let google = URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(host)"),
           let png = await loadPNG(from: google) {
            return Outcome(pngData: png, source: "Google favicon")
        }

        return nil
    }

    // MARK: - HTML

    /// 抓首页 HTML，翻出 `<link rel="apple-touch-icon">`，按 sizes 从大到小排。
    private static func htmlDeclaredIcons(for url: URL) async -> [URL] {
        guard let html = await fetchHTMLPrefix(url) else { return [] }
        let pattern = "<link[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var found: [(size: Int, url: URL)] = []

        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            guard rel.contains("apple-touch-icon") || rel == "icon" || rel == "shortcut icon" else { continue }
            guard let href = attribute("href", in: tag),
                  let resolved = URL(string: href, relativeTo: url)?.absoluteURL
            else { continue }

            // "180x180" → 180；没写 sizes 的排在后面，但 apple-touch-icon 整体优先于普通 icon
            let sizeText = attribute("sizes", in: tag) ?? ""
            let parsed = Int(sizeText.lowercased().split(separator: "x").first.map(String.init) ?? "") ?? 0
            let bonus = rel.contains("apple-touch-icon") ? 1000 : 0
            found.append((parsed + bonus, resolved))
        }

        return found.sorted { $0.size > $1.size }.map(\.url)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只读前 256KB：图标声明都在 <head> 里，整页拉下来纯属浪费
    private static func fetchHTMLPrefix(_ url: URL, limit: Int = 256 * 1024) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(UserAgentPreset.iPhoneSafari.value, forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        guard (response as? HTTPURLResponse).map({ (200..<400).contains($0.statusCode) }) ?? false else { return nil }

        var data = Data()
        data.reserveCapacity(limit)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            guard !data.isEmpty else { return nil }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - 图片

    private static func loadPNG(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(UserAgentPreset.iPhoneSafari.value, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return normalize(data)
    }

    /// 统一转成 targetSize 的方形 PNG
    static func normalize(_ data: Data) -> Data? {
        // .ico 要先拆：UIImage 不认这个格式
        let decodable = ICOUnpacker.extractLargestPNG(from: data) ?? data
        guard let image = UIImage(data: decodable), image.size.width > 8, image.size.height > 8 else { return nil }

        let side = targetSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let rendered = renderer.image { _ in
            // 等比缩放居中，不拉伸
            let scale = min(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2)
            image.draw(in: CGRect(origin: origin, size: size))
        }
        return rendered.pngData()
    }

    private static func rootURL(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
