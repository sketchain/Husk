import Foundation

/// 某个 profile 的 HTTPS 代理配置（客户端到代理这一跳走 TLS，隧道用 HTTP CONNECT）。
///
/// 挂在 profile 上而不是站点上：网络走哪条路是 `WKWebsiteDataStore` 的属性
/// （`proxyConfigurations`），而 data store 是按 profile 一个的，见 `WebsiteDataStoreManager`。
/// 所以共用同一个 profile 的站点必然共用同一个代理，UI 上要把这一点讲清楚。
///
/// **密码不在这里**，在 Keychain（`ProxyKeychain`），按 profile 名存。这个结构体会原样进导出 JSON。
struct ProfileProxy: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var mode: ProxyConnectionMode
    var host: String
    var port: Int
    /// 空串 = 代理不要认证
    var username: String
    var verification: ProxyTLSVerification
    /// `.pinnedKey` 模式下的指纹：叶子证书 SPKI 的 SHA-256，规范化成 base64。命中任意一个即通过。
    var pins: [String]

    init(
        isEnabled: Bool = true,
        mode: ProxyConnectionMode = .localRelay,
        host: String = "",
        port: Int = 443,
        username: String = "",
        verification: ProxyTLSVerification = .system,
        pins: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.host = host
        self.port = port
        self.username = username
        self.verification = verification
        self.pins = pins
    }

    /// 每个字段单独兜底。
    ///
    /// 和别处的 `decodeIfPresent` 不太一样的一点：**条目本身存在、但某个字段坏了**时，
    /// 不能让整条配置消失——那等于这个 profile 静默变成直连。所以 `isEnabled` 缺省是 true
    /// （条目在就说明用户配过），坏掉的地址会让它在加载时报"配置不完整"，而不是悄悄放行。
    /// 整份库里根本没有这个条目，才是"没配代理"。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        // 认不出的连接方式按本地中继：它支持所有验证方式，不会因为方式不支持而把验证降级
        mode = (try? c.decodeIfPresent(ProxyConnectionMode.self, forKey: .mode)) ?? .localRelay
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? 443
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        // 认不出的验证方式按最严格的系统验证处理，绝不往宽了猜
        verification = (try? c.decodeIfPresent(ProxyTLSVerification.self, forKey: .verification)) ?? .system
        pins = (try? c.decodeIfPresent([String].self, forKey: .pins)) ?? []
    }

    var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var needsPassword: Bool { !username.isEmpty }

    /// 列表里显示的一行摘要
    var summary: String {
        guard isEnabled else { return "关闭" }
        let target = trimmedHost.isEmpty ? "（未填地址）" : "\(trimmedHost):\(port)"
        return "\(target) · \(mode.shortTitle)"
    }

    /// 配置本身（不含密码）能不能用。能用返回 nil，不能用返回原因。
    var configurationProblem: String? {
        if trimmedHost.isEmpty { return "没填代理地址" }
        if trimmedHost.contains(where: { $0.isWhitespace || $0 == "/" }) { return "代理地址里不能有空格或斜杠，只填主机名或 IP" }
        if !(1...65535).contains(port) { return "端口要在 1–65535 之间" }
        if verification == .pinnedKey && pins.isEmpty { return "选了指纹验证，但一个指纹都没填" }
        if mode == .direct && verification != .system {
            return "「直连代理」只支持系统验证：WKWebView 不会调用自定义验证回调。换成「本地中继」，或者改回系统验证。"
        }
        return nil
    }
}

/// WKWebView 怎么连到上游代理
enum ProxyConnectionMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// app 进程里起一个只监听 127.0.0.1 的明文 CONNECT 中继，TLS 和证书校验在 app 里做（默认）
    case localRelay
    /// `ProxyConfiguration(httpCONNECTProxy:tlsOptions:)` 直接交给 WebKit 网络进程
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localRelay: "本地中继（推荐）"
        case .direct: "直连代理"
        }
    }

    var shortTitle: String {
        switch self {
        case .localRelay: "本地中继"
        case .direct: "直连"
        }
    }

    var subtitle: String {
        switch self {
        case .localRelay:
            "app 在本机 127.0.0.1 起一个中继，由它和代理握手、校验证书。三种验证方式都支持，失败原因分得清。"
        case .direct:
            "WKWebView 自己连代理，app 不参与转发。只支持系统验证；和代理握 TLS 这条路在 WebKit 里有已知崩溃报告，用前先在实验室里确认。"
        }
    }

    func supports(_ verification: ProxyTLSVerification) -> Bool {
        self == .localRelay || verification == .system
    }
}

/// 代理那一跳 TLS 证书的验证方式
enum ProxyTLSVerification: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// 系统信任链 + 主机名
    case system
    /// 叶子证书 SPKI 的 SHA-256 命中任意一个指纹即通过，不看信任链和主机名
    case pinnedKey
    /// 不验证（只防被动窃听，挡不住中间人）
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "系统验证"
        case .pinnedKey: "公钥指纹"
        case .none: "不验证"
        }
    }

    var subtitle: String {
        switch self {
        case .system: "证书要能链到系统信任的根证书，且和代理地址对得上。代理用的是正经证书时选这个。"
        case .pinnedKey: "只认你填的公钥指纹（SPKI SHA-256），不看签发者和主机名。适合自签证书。续签时密钥不变，指纹就不用改。"
        case .none: "任何证书都接受。流量仍然加密，但路上任何人都能冒充代理——只在排查问题时临时用。"
        }
    }
}
