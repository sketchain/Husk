import AppIntents
import Foundation
import Observation

/// 站点列表 + 全局设置的单一真相来源。
///
/// 存一个 JSON 文件，原子写。数据量是十几条，没必要上数据库；
/// 更重要的是导入导出本来就要 JSON，用同一套 Codable 省掉一层转换。
@MainActor
@Observable
final class SiteStore {
    /// 单例。`AppDelegate` 要在第一帧之前按 id 解析 deep link，那会儿还没有任何
    /// SwiftUI 视图可以挂 `@State`，所以真相来源得是进程级的。
    static let shared = SiteStore()

    private(set) var sites: [Site] = []
    var settings: AppSettings = AppSettings() {
        didSet { if settings != oldValue && !isLoading { save() } }
    }

    /// 启动时 load() 给 settings 赋值会触发 didSet，不拦一下会白写一次盘
    private var isLoading = false

    /// 最近一次写盘失败的原因，UI 里提示用
    private(set) var lastError: String?

    private init() {
        load()
    }

    // MARK: - 读写

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: AppPaths.libraryFile) else { return }
        do {
            let library = try Self.decoder.decode(HuskLibrary.self, from: data)
            sites = library.sites
            settings = library.settings
        } catch {
            lastError = "配置读取失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        let library = HuskLibrary(sites: sites, settings: settings)
        do {
            let data = try Self.encoder.encode(library)
            // .atomic：写临时文件再 rename，中途被杀不会留下半截 JSON
            try data.write(to: AppPaths.libraryFile, options: [.atomic])
            lastError = nil
        } catch {
            lastError = "配置保存失败：\(error.localizedDescription)"
        }
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - 增删改

    func site(id: UUID) -> Site? {
        sites.first { $0.id == id }
    }

    func add(_ site: Site) {
        sites.append(site)
        save()
        refreshShortcuts()
    }

    /// 站点列表变了就把 App Shortcut 的参数快照刷一遍。
    ///
    /// 参数化的 App Shortcut（"打开〈站点〉"）会按 `SiteEntityQuery.suggestedEntities()`
    /// 在「快捷指令」app 的 Husk 分组里逐个展开。不调这一下的话，那份列表会停在
    /// 上一次刷新时的样子——新加的站点不出现，删掉的还赖着。
    private func refreshShortcuts() {
        HuskShortcuts.updateAppShortcutParameters()
    }

    func update(_ site: Site) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites[index] = site
        save()
        refreshShortcuts()
    }

    func delete(id: UUID) {
        sites.removeAll { $0.id == id }
        AppPaths.removeIcons(for: id)
        if settings.lastOpenedSiteID == id { settings.lastOpenedSiteID = nil }
        save()
        refreshShortcuts()
    }

    func moveToFront(id: UUID) {
        guard let index = sites.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let site = sites.remove(at: index)
        sites.insert(site, at: 0)
        save()
    }

    /// 记下"上次打开的站点"，首页底部的"继续上次"读它。
    /// 值没变就不写盘——同一个站点连开几次不该反复落盘。
    func rememberLastOpened(_ id: UUID) {
        guard settings.lastOpenedSiteID != id else { return }
        settings.lastOpenedSiteID = id   // didSet 会负责写盘
    }

    /// "继续上次"要显示的那个站点。站点被删掉之后这里自然就是 nil。
    var lastOpenedSite: Site? {
        guard let id = settings.lastOpenedSiteID else { return nil }
        return site(id: id)
    }

    /// 当前所有在用的 profile 名，孤儿清理要拿它当白名单。
    /// 带上临时站点用的那个，免得把它当孤儿删了。
    var knownProfiles: [String] {
        Array(Set(sites.map(\.profile) + [Site.adHocProfile]))
    }

    // MARK: - 导入导出

    func exportData() throws -> Data {
        try Self.encoder.encode(HuskLibrary(sites: sites, settings: settings))
    }

    /// 写一份导出 JSON 到临时目录，返回文件 URL（分享面板要的是文件）
    func exportFile() throws -> URL {
        let data = try exportData()
        let name = "Husk-\(Self.fileStamp()).json"
        let url = URL.temporaryDirectory.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url, options: [.atomic])
        return url
    }

    static func fileStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    func parseImport(_ data: Data) throws -> HuskLibrary {
        try Self.decoder.decode(HuskLibrary.self, from: data)
    }

    /// 按 id 去重的处理方式
    enum ImportStrategy {
        /// 同 id 的覆盖已有站点
        case overwrite
        /// 同 id 的另发一个新 id，两份都留着
        case duplicate
        /// 同 id 的跳过
        case skip
    }

    struct ImportResult: Sendable {
        var added: Int = 0
        var overwritten: Int = 0
        var duplicated: Int = 0
        var skipped: Int = 0
    }

    /// 导入会和已有 id 撞车的站点
    func conflicts(in library: HuskLibrary) -> [Site] {
        let existing = Set(sites.map(\.id))
        return library.sites.filter { existing.contains($0.id) }
    }

    @discardableResult
    func importLibrary(_ library: HuskLibrary, strategy: ImportStrategy, includeSettings: Bool) -> ImportResult {
        var result = ImportResult()
        for incoming in library.sites {
            if let index = sites.firstIndex(where: { $0.id == incoming.id }) {
                switch strategy {
                case .overwrite:
                    sites[index] = incoming
                    // 图标缓存跟着作废，下次显示会重新抓
                    AppPaths.removeIcons(for: incoming.id)
                    result.overwritten += 1
                case .duplicate:
                    var copy = incoming
                    let newID = UUID()
                    // profile 原本等于旧 id 的话，跟着换成新 id，否则副本会和原站共享存储
                    if copy.profile == copy.id.uuidString { copy.profile = newID.uuidString }
                    copy.id = newID
                    copy.name = incoming.name + " 副本"
                    sites.append(copy)
                    result.duplicated += 1
                case .skip:
                    result.skipped += 1
                }
            } else {
                sites.append(incoming)
                result.added += 1
            }
        }
        if includeSettings { settings = library.settings }
        save()
        refreshShortcuts()
        return result
    }
}
