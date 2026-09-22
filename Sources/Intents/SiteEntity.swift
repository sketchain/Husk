import AppIntents
import Foundation

/// 站点在"快捷指令"里的样子。
///
/// 做成 `AppEntity` 而不是让用户手打一串 UUID，图的就是
/// **在快捷指令的参数里直接从列表选站点**，而且列表里带名字和图标。
struct SiteEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "站点")
    static let defaultQuery = SiteEntityQuery()

    /// 用站点自己的 UUID 当 id。快捷指令会把它存下来，所以**不能换**——
    /// 换了等于用户攒的每一条快捷指令都指向空气。
    var id: UUID
    var name: String
    var host: String
    /// 列表里那张小图。没有就只显示名字。
    var iconData: Data?

    var displayRepresentation: DisplayRepresentation {
        if let iconData {
            DisplayRepresentation(title: "\(name)", subtitle: "\(host)", image: .init(data: iconData))
        } else {
            DisplayRepresentation(title: "\(name)", subtitle: "\(host)")
        }
    }

    @MainActor
    init(site: Site, icons: IconStore) {
        self.id = site.id
        self.name = site.name
        self.host = site.displayHost
        self.iconData = icons.thumbnailPNG(for: site)
    }
}

/// 站点的查询。
///
/// `EnumerableEntityQuery` 这一条是关键：站点总共就十几个，全量给出去之后
/// 系统能自己派生"按名字找""按 id 找""给出候选"这些能力，
/// 也是 `AppShortcutsProvider` 能给**每个站点**自动生成一条快捷指令的前提。
struct SiteEntityQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor
    private func all() -> [SiteEntity] {
        let store = SiteStore.shared
        let icons = IconStore.shared
        return store.sites.map { SiteEntity(site: $0, icons: icons) }
    }

    func allEntities() async throws -> [SiteEntity] {
        await MainActor.run { all() }
    }

    func entities(for identifiers: [UUID]) async throws -> [SiteEntity] {
        let wanted = Set(identifiers)
        return await MainActor.run { all().filter { wanted.contains($0.id) } }
    }

    /// 用户在快捷指令里打字搜站点。名字和域名都认。
    func entities(matching string: String) async throws -> [SiteEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return try await allEntities() }
        return await MainActor.run {
            all().filter {
                $0.name.lowercased().contains(needle) || $0.host.lowercased().contains(needle)
            }
        }
    }

    /// 参数面板默认列出全部站点
    func suggestedEntities() async throws -> [SiteEntity] {
        try await allEntities()
    }
}
