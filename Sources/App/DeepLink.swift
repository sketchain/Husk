import Foundation

/// `husk://` 的解析与生成。
///
/// - `husk://open?id=<UUID>`             打开列表里的站点
/// - `husk://open?url=<percent-encoded>` 打开临时站点（不入列表）
enum DeepLink {
    static let scheme = "husk"

    enum Target: Equatable, Sendable {
        case site(UUID)
        case adHoc(URL)
    }

    static func parse(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // husk://open?... 里 "open" 落在 host 上；写成 husk:///open?... 时才落在 path 上，两种都认
        let action = (url.host() ?? url.pathComponents.first { $0 != "/" } ?? "").lowercased()
        guard action == "open" else { return nil }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        if let raw = items.first(where: { $0.name == "id" })?.value, let id = UUID(uuidString: raw) {
            return .site(id)
        }
        // queryItems 已经做过一次百分号解码，这里拿到的就是原始地址
        if let raw = items.first(where: { $0.name == "url" })?.value, let target = Site.normalizeInput(raw) {
            return .adHoc(target)
        }
        return nil
    }

    /// 生成分享用的链接
    static func share(site: Site) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "id", value: site.id.uuidString)]
        return components.url ?? URL(string: "husk://open")!
    }

    static func share(url: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url ?? URL(string: "husk://open")!
    }
}
