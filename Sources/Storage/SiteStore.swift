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
    /// profile → 代理配置。改它走 `setProxy` / `removeProxy`，那两个会通知 `ProxyManager`
    private(set) var profileProxies: [String: ProfileProxy] = [:]
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
            profileProxies = library.profileProxies
        } catch {
            lastError = "配置读取失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        let library = HuskLibrary(sites: sites, settings: settings, profileProxies: profileProxies)
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
        // 快捷指令那份快照只关心名字和地址（`SiteEntity` 就显示这两样）。
        // 不做这个判断的话，工具箱里拖一次缩放滑块、在例外域名框里敲一个字，
        // 都会顺带去刷一遍 App Shortcut 参数——纯属白干。
        let affectsShortcuts = sites[index].name != site.name || sites[index].url != site.url
        sites[index] = site
        save()
        if affectsShortcuts { refreshShortcuts() }
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

    // MARK: - 代理

    /// 保存某个 profile 的代理配置。密码另外存 Keychain，不经过这里。
    func setProxy(_ proxy: ProfileProxy, for profile: String) {
        profileProxies[profile] = proxy
        save()
        ProxyManager.shared.configurationDidChange(profile: profile)
    }

    /// 删掉某个 profile 的代理配置，连同 Keychain 里的密码
    func removeProxy(for profile: String) {
        profileProxies[profile] = nil
        ProxyKeychain.removePassword(forProfile: profile)
        save()
        ProxyManager.shared.configurationDidChange(profile: profile)
    }

    /// 用某个 profile 的站点。代理设置页用它告诉用户"改这个会影响谁"。
    func sites(usingProfile profile: String) -> [Site] {
        sites.filter { $0.profile == profile }
    }

    // MARK: - 导入导出

    func exportData() throws -> Data {
        // 密码不在这份数据里（它在 Keychain），导出天然不带密码
        try Self.encoder.encode(HuskLibrary(sites: sites, settings: settings, profileProxies: profileProxies))
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
        /// 收下的代理配置里，要密码但本机没存的个数
        var proxiesNeedingPassword: Int = 0
    }

    /// 导入会和已有 id 撞车的站点
    func conflicts(in library: HuskLibrary) -> [Site] {
        let existing = Set(sites.map(\.id))
        return library.sites.filter { existing.contains($0.id) }
    }

    @discardableResult
    func importLibrary(_ library: HuskLibrary, strategy: ImportStrategy, includeSettings: Bool) -> ImportResult {
        var result = ImportResult()
        var importedProxies: [String: ProfileProxy] = [:]
        // 导入前本机已经在用的 profile：非「覆盖」策略下，导入的代理配置不许改它们的走向
        let localProfiles = Set(sites.map(\.profile))
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
                    if copy.profile == copy.id.uuidString {
                        copy.profile = newID.uuidString
                        // 代理配置跟着副本的新 profile 走，不然副本会悄悄变成不走代理
                        if let proxy = library.profileProxies[incoming.profile] {
                            importedProxies[copy.profile] = proxy
                        }
                    }
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
        mergeImportedProxies(
            library.profileProxies,
            extra: importedProxies,
            protecting: strategy == .overwrite ? [] : localProfiles,
            into: &result
        )
        save()
        refreshShortcuts()
        return result
    }

    /// 导入的代理配置怎么合并：
    /// - 本机没人用这个 profile → 直接收下；
    /// - 本机已经有站点在用它 → 跟着站点的冲突策略走：「覆盖」才动，另外两种一律保留本机现状
    ///   （包括"本机没配代理"这个现状——不能因为导入了一个文件，本机的站点就突然改走代理了）。
    ///
    /// 导出文件里没有密码。收下的配置要是需要密码而本机 Keychain 里没有，这个 profile
    /// 的页面会报"代理需要密码"而**不是**直连，`ImportResult.proxiesNeedingPassword` 用来提示用户。
    private func mergeImportedProxies(
        _ incoming: [String: ProfileProxy],
        extra: [String: ProfileProxy],
        protecting localProfiles: Set<String>,
        into result: inout ImportResult
    ) {
        var changed: Set<String> = []
        for (profile, proxy) in incoming.merging(extra, uniquingKeysWith: { _, new in new }) {
            if localProfiles.contains(profile) { continue }
            profileProxies[profile] = proxy
            changed.insert(profile)
            if proxy.needsPassword, !ProxyKeychain.hasPassword(forProfile: profile) {
                result.proxiesNeedingPassword += 1
            }
        }
        for profile in changed {
            ProxyManager.shared.configurationDidChange(profile: profile)
        }
    }
}
