import Foundation
import UIKit

/// 生成 `.mobileconfig`，把站点做成主屏图标。
///
/// ⚠️ 一个必须知道的限制：Apple 官方文档写明 Web Clip 的 `URL` **必须以 http/https 开头**。
/// 我们这里填的是 `husk://open?id=...`，属于文档不支持的用法。实测在不少 iOS 版本上
/// 是可以装、可以跳的，但这是没有保证的行为，哪天被收紧也不奇怪。
/// 所以 `linkTarget` 给了两个选择，安装被拒的话换 `.siteURL`（代价是用 Safari 打开）。
@MainActor
enum WebClipBuilder {
    enum LinkTarget {
        /// husk://open?id=<UUID> —— 点图标回到 Husk（默认，也是这个 app 存在的意义）
        case huskDeepLink
        /// 站点原始 https 地址 —— 规范内的用法，但点了会进 Safari
        case siteURL

        func url(for site: Site) -> String {
            switch self {
            case .huskDeepLink: DeepLink.share(site: site).absoluteString
            case .siteURL: site.url.absoluteString
            }
        }
    }

    static func makeProfile(
        for sites: [Site],
        iconProvider: (Site) -> Data?,
        linkTarget: LinkTarget = .huskDeepLink
    ) -> WebClipProfile {
        let entries = sites.map { site in
            WebClipEntry(
                label: site.name,
                url: linkTarget.url(for: site),
                icon: iconProvider(site),
                payloadIdentifier: "org.example.husk.webclip.\(site.id.uuidString)",
                payloadUUID: site.id.uuidString.uppercased(),
                payloadDisplayName: site.name
            )
        }

        let isBundle = sites.count > 1
        let name = isBundle ? "Husk 站点（\(sites.count) 个）" : (sites.first?.name ?? "Husk")
        // 整份描述文件的标识每次导出都换一个，这样重复导出不会互相覆盖；
        // 想让新导出替换旧的，把这里改成按站点 id 派生的固定值即可。
        let profileUUID = UUID().uuidString.uppercased()

        return WebClipProfile(
            payloadContent: entries,
            payloadDisplayName: name,
            payloadIdentifier: "org.example.husk.profile.\(profileUUID)",
            payloadUUID: profileUUID,
            payloadDescription: isBundle
                ? "把 \(sites.count) 个 Husk 站点装到主屏上。"
                : "把「\(sites.first?.name ?? "")」装到主屏上，点开直接进 Husk。"
        )
    }

    static func encode(_ profile: WebClipProfile) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml   // .mobileconfig 必须是 XML plist，二进制的装不上
        return try encoder.encode(profile)
    }

    /// 生成文件，返回临时目录里的 URL（分享面板要文件）
    @discardableResult
    static func writeProfile(
        for sites: [Site],
        iconProvider: (Site) -> Data?,
        linkTarget: LinkTarget = .huskDeepLink,
        fileName: String
    ) throws -> URL {
        let data = try encode(makeProfile(for: sites, iconProvider: iconProvider, linkTarget: linkTarget))
        let url = URL.temporaryDirectory.appending(path: fileName, directoryHint: .notDirectory)
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// 文件名里不能出现 / : 之类的东西
    static func safeFileName(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Husk" : String(cleaned.prefix(40))
    }
}
