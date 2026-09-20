import Foundation

/// 全局设置。同样走 Codable，和站点列表存在同一个 JSON 里。
struct AppSettings: Codable, Hashable, Sendable {
    var gestures: GestureSettings
    var newSiteDefaults: SiteDefaults
    /// 抓不到站点自己的图标时，是否允许回退到 Google 的 favicon 服务（会把域名发给 Google）
    var allowGoogleFaviconFallback: Bool

    init(
        gestures: GestureSettings = GestureSettings(),
        newSiteDefaults: SiteDefaults = SiteDefaults(),
        allowGoogleFaviconFallback: Bool = true
    ) {
        self.gestures = gestures
        self.newSiteDefaults = newSiteDefaults
        self.allowGoogleFaviconFallback = allowGoogleFaviconFallback
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gestures = try c.decodeIfPresent(GestureSettings.self, forKey: .gestures) ?? GestureSettings()
        newSiteDefaults = try c.decodeIfPresent(SiteDefaults.self, forKey: .newSiteDefaults) ?? SiteDefaults()
        allowGoogleFaviconFallback = try c.decodeIfPresent(Bool.self, forKey: .allowGoogleFaviconFallback) ?? true
    }
}

/// 四种唤出工具箱的手势，逐个可关。默认只开前两个。
///
/// 刻意避开的手势：
/// - 单指边缘滑 → 撞 `allowsBackForwardNavigationGestures` 的前进后退
/// - 单指长按   → 撞选中文字、链接预览（Peek）
struct GestureSettings: Codable, Hashable, Sendable {
    var twoFingerSwipeDown: Bool
    var bottomEdgeSwipeUp: Bool
    var threeFingerTap: Bool
    var twoFingerLongPress: Bool

    init(
        twoFingerSwipeDown: Bool = true,
        bottomEdgeSwipeUp: Bool = true,
        threeFingerTap: Bool = false,
        twoFingerLongPress: Bool = false
    ) {
        self.twoFingerSwipeDown = twoFingerSwipeDown
        self.bottomEdgeSwipeUp = bottomEdgeSwipeUp
        self.threeFingerTap = threeFingerTap
        self.twoFingerLongPress = twoFingerLongPress
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        twoFingerSwipeDown = try c.decodeIfPresent(Bool.self, forKey: .twoFingerSwipeDown) ?? true
        bottomEdgeSwipeUp = try c.decodeIfPresent(Bool.self, forKey: .bottomEdgeSwipeUp) ?? true
        threeFingerTap = try c.decodeIfPresent(Bool.self, forKey: .threeFingerTap) ?? false
        twoFingerLongPress = try c.decodeIfPresent(Bool.self, forKey: .twoFingerLongPress) ?? false
    }

    var anyEnabled: Bool {
        twoFingerSwipeDown || bottomEdgeSwipeUp || threeFingerTap || twoFingerLongPress
    }
}

/// 新建站点时的默认值
struct SiteDefaults: Codable, Hashable, Sendable {
    var zoom: Double
    var userAgent: String?
    var externalLinkPolicy: ExternalLinkPolicy
    /// true = 每个新站用自己的 id 当 profile（完全隔离）
    var isolateStoragePerSite: Bool

    init(
        zoom: Double = 1.0,
        userAgent: String? = nil,
        externalLinkPolicy: ExternalLinkPolicy = .sameDomain,
        isolateStoragePerSite: Bool = true
    ) {
        self.zoom = zoom
        self.userAgent = userAgent
        self.externalLinkPolicy = externalLinkPolicy
        self.isolateStoragePerSite = isolateStoragePerSite
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zoom = (try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0).clamped(to: Site.zoomRange)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        externalLinkPolicy = try c.decodeIfPresent(ExternalLinkPolicy.self, forKey: .externalLinkPolicy) ?? .sameDomain
        isolateStoragePerSite = try c.decodeIfPresent(Bool.self, forKey: .isolateStoragePerSite) ?? true
    }
}

/// 导入导出的信封格式
struct HuskLibrary: Codable, Sendable {
    /// 格式版本，将来结构变了靠它判断
    var formatVersion: Int
    var exportedAt: Date
    var sites: [Site]
    var settings: AppSettings

    static let currentFormatVersion = 1

    init(sites: [Site], settings: AppSettings, exportedAt: Date = Date()) {
        self.formatVersion = HuskLibrary.currentFormatVersion
        self.exportedAt = exportedAt
        self.sites = sites
        self.settings = settings
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        // 单个站点解码失败不应该让整个导入失败
        sites = (try c.decodeIfPresent([FailableSite].self, forKey: .sites) ?? []).compactMap(\.value)
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}

/// 让数组里坏掉的一条被跳过，而不是整条导入失败
private struct FailableSite: Decodable {
    let value: Site?
    init(from decoder: any Decoder) throws {
        value = try? Site(from: decoder)
    }
}
