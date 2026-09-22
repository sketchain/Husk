import Foundation

/// 一个"站点"——在 Husk 里等价于一个独立 app。
///
/// 持久化选择 Codable + JSON 而不是 SwiftData，理由见 README：
/// 数据量是十几条，导入导出是核心功能（JSON 直接就是交换格式），
/// 而 SwiftData 的 @Model 类在 Swift 6 严格并发下跨 actor 传递很别扭。
struct Site: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var url: URL
    /// WKWebView.pageZoom，范围见 `Site.zoomRange`
    var zoom: Double
    /// nil = 系统默认 UA
    var userAgent: String?
    var externalLinkPolicy: ExternalLinkPolicy
    /// `.sameDomain` 策略下"站内"的判定档位
    var linkScope: LinkScopeStrictness
    /// 手动例外：命中就算站内，优先于档位。支持 `*.example.com`
    var inAppDomains: [String]
    /// 手动例外：命中就强制交给 Safari，优先级最高
    var safariDomains: [String]
    /// 存储隔离标识。默认等于 id.uuidString（完全隔离）；两个站点填同一个字符串即共享 cookie/localStorage。
    var profile: String
    var iconSource: IconSource
    var createdAt: Date

    /// 下限 10%：给"整页塞进一屏看个大概"留出余地。
    /// `WKWebView.pageZoom` 自己**不做任何钳位**（setter 一路直通
    /// `WebPageProxy::setPageZoomFactor` → `LocalFrame::setPageAndTextZoomFactors`，
    /// 中间没有 clamp），所以范围完全由我们说了算；不设下限的话 0 会把
    /// 缩放换算里的除法搞炸，该有的保护还是得留在这边。
    static let zoomRange: ClosedRange<Double> = 0.1...2.0

    init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        zoom: Double = 1.0,
        userAgent: String? = nil,
        externalLinkPolicy: ExternalLinkPolicy = .sameDomain,
        linkScope: LinkScopeStrictness = .registrableDomain,
        inAppDomains: [String] = [],
        safariDomains: [String] = [],
        profile: String? = nil,
        iconSource: IconSource = .automatic,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.zoom = zoom.clamped(to: Site.zoomRange)
        self.userAgent = userAgent
        self.externalLinkPolicy = externalLinkPolicy
        self.linkScope = linkScope
        self.inAppDomains = inAppDomains
        self.safariDomains = safariDomains
        self.profile = profile ?? id.uuidString
        self.iconSource = iconSource
        self.createdAt = createdAt
    }

    /// 站点主域（去掉 www.），用于站内判断和图标抓取
    var host: String { Site.normalizedHost(of: url) ?? "" }

    var displayHost: String { url.host() ?? url.absoluteString }

    /// 首字母占位图用的字符
    var monogram: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    static func normalizedHost(of url: URL) -> String? {
        guard var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    // MARK: - 站内 / 外链

    /// 判断 `candidate` 算不算"站内"，按本站选的档位。
    ///
    /// 三档的差别只在这一个函数里，手动例外不在这儿处理——
    /// 例外要压过档位，所以放在 `externalLinkDecision(for:)` 的最前面。
    func isSameSite(_ candidate: URL) -> Bool {
        guard let base = Site.normalizedHost(of: url),
              let other = Site.normalizedHost(of: candidate) else { return false }

        switch linkScope {
        case .host:
            // normalizedHost 已经削掉了 www.，所以 www.example.com 和 example.com 在这儿是同一个
            return other == base
        case .hostAndSubdomains:
            return other == base || other.hasSuffix("." + base)
        case .registrableDomain:
            if other == base { return true }
            // 两边都归约到 eTLD+1 再比。站点地址填的是 m.youtube.com 时，
            // 点到 youtube.com / www.youtube.com 不该被当成外站。
            guard let baseDomain = PublicSuffixList.registrableDomain(of: base),
                  let otherDomain = PublicSuffixList.registrableDomain(of: other)
            else { return false }
            return baseDomain == otherDomain
        }
    }

    /// 一次导航该往哪儿去
    enum LinkDestination: Equatable, Sendable {
        case inApp
        case safari
    }

    /// 外链决策的唯一入口。顺序是刻意的：
    /// 1. **强制 Safari 名单**——用户写死的，压过一切，包括 `.inApp` 策略
    /// 2. **也算站内名单**——自家短链（`b23.tv`、`youtu.be`）、CDN、登录中心
    /// 3. 站点策略；`.sameDomain` 下再看档位和登录流放行
    func destination(for url: URL) -> LinkDestination {
        guard url.scheme == "http" || url.scheme == "https" else { return .inApp }
        let host = Site.normalizedHost(of: url) ?? ""

        if DomainPattern.matchesAny(host, patterns: safariDomains) { return .safari }
        if DomainPattern.matchesAny(host, patterns: inAppDomains) { return .inApp }

        switch externalLinkPolicy {
        case .inApp:
            return .inApp
        case .safari:
            // 字面意义的"全都甩出去"，用户既然选了这个就不替他耍小聪明
            return .safari
        case .sameDomain:
            if isSameSite(url) { return .inApp }
            // 登录 / 授权流留在站内：甩进 Safari 的话回调落在 Safari，这边永远等不到
            if Site.looksLikeAuthFlow(url) { return .inApp }
            return .safari
        }
    }

    // MARK: - Decoding

    /// 手写 decode，给所有新增字段兜底：从旧版本导出的 JSON 导进来不该整条失败。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        url = try c.decode(URL.self, forKey: .url)
        zoom = (try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0).clamped(to: Site.zoomRange)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        externalLinkPolicy = try c.decodeIfPresent(ExternalLinkPolicy.self, forKey: .externalLinkPolicy) ?? .sameDomain
        linkScope = try c.decodeIfPresent(LinkScopeStrictness.self, forKey: .linkScope) ?? .registrableDomain
        inAppDomains = try c.decodeIfPresent([String].self, forKey: .inAppDomains) ?? []
        safariDomains = try c.decodeIfPresent([String].self, forKey: .safariDomains) ?? []
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? id.uuidString
        iconSource = try c.decodeIfPresent(IconSource.self, forKey: .iconSource) ?? .automatic
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// 图标来源
enum IconSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// 自动抓取：apple-touch-icon → /favicon.ico → Google favicon 服务
    case automatic
    /// 用户自选图片（存在 Application Support/Husk/Icons/<id>-custom.png）
    case custom
    /// 强制用首字母渐变占位图
    case monogram
}

/// 外链行为。只作用于用户点击产生的主框架导航，不碰 iframe / 重定向 / 资源请求。
enum ExternalLinkPolicy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// 一切都在站内加载
    case inApp
    /// 一切外链都交给 Safari
    case safari
    /// 按 `Site.linkScope` 的档位判断（默认）。rawValue 留着历史拼写，老配置才导得进来。
    case sameDomain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inApp: "站内加载"
        case .safari: "交给 Safari"
        case .sameDomain: "按域名判断"
        }
    }

    var subtitle: String {
        switch self {
        case .inApp: "所有链接都留在这个窗口里"
        case .safari: "任何链接都甩给 Safari"
        case .sameDomain: "按下面的档位决定什么算站内，其余交给 Safari"
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Site {
    /// `husk://open?url=...` 打开的临时站点共用这一个 profile。
    /// 不用默认 store，这样"清除临时站点数据"能单独做，也不会和将来可能用到的默认 store 混在一起。
    static let adHocProfile = "__husk_adhoc__"

    /// 关掉"每个新站点独立存储"时，新建的站点共用这一个 profile
    static let sharedProfile = "shared"

    /// 从一个裸 URL 造临时站点（不入列表）
    static func adHoc(url: URL, defaults: SiteDefaults) -> Site {
        Site(
            name: Site.normalizedHost(of: url) ?? url.absoluteString,
            url: url,
            zoom: defaults.zoom,
            userAgent: defaults.userAgent,
            externalLinkPolicy: defaults.externalLinkPolicy,
            linkScope: defaults.linkScope,
            profile: Site.adHocProfile,
            iconSource: .monogram
        )
    }

    /// 这次导航看着像不像在走登录 / 授权流程。
    ///
    /// 为什么需要这个判断：`.sameDomain` 策略下，点"用 Google 登录"跳到 `accounts.google.com`
    /// 会被判成外站甩进 Safari，用户在 Safari 里登完，回调也落在 Safari 里——Husk 这边
    /// 永远等不到，表现就是"点了登录，然后什么都没发生"。这是默认策略，不能这么坑。
    ///
    /// 所以 `.sameDomain` 对这类导航放行，留在站内走完。进了授权页之后的跳转都不是
    /// `.linkActivated`（是表单提交和重定向），本来就不会被拦，最后回调回自己域名时又是站内了。
    ///
    /// 宁可放过不可错杀：判宽一点最多是某个外站的登录页留在了站内，用户还能从工具箱丢去 Safari；
    /// 判窄了就是登不上。真要精确控制，站点设置里的「强制 Safari」名单压得过它。
    static func looksLikeAuthFlow(_ url: URL) -> Bool {
        guard let host = normalizedHost(of: url) else { return false }
        if authHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }

        let path = url.path().lowercased()
        if authPathHints.contains(where: { path.contains($0) }) { return true }

        // OAuth authorize 端点的特征参数组合
        let names = Set(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { $0.name.lowercased() }
        )
        return names.contains("client_id")
            && (names.contains("redirect_uri") || names.contains("redirect_url"))
    }

    /// 专门用来做登录的域名
    private static let authHosts: Set<String> = [
        "accounts.google.com", "appleid.apple.com",
        "login.microsoftonline.com", "login.live.com", "login.yahoo.com",
        "auth0.com", "okta.com", "oauth.telegram.org", "id.twitch.tv",
        "open.weixin.qq.com", "openauth.alipay.com", "openapi.alipay.com",
    ]

    /// 路径里出现这些就当是登录流
    private static let authPathHints: [String] = [
        "/oauth", "/authorize", "/sso", "/saml", "/auth/",
        "/login", "/signin", "/sign_in", "/session/new",
    ]

    /// 用户输入的地址规范化：光打 "example.com" 也要能用
    static func normalizeInput(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false
        else { return nil }
        return url
    }
}
