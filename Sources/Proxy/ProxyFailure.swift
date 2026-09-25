import Foundation

/// 代理这条路上能出的错。每一种都要能让用户看出是"代理不通"还是"证书不对"。
enum ProxyFailure: Error, Hashable, Sendable {
    /// 配置本身不完整（没地址、端口不对、指纹模式没填指纹……）
    case invalidConfiguration(String)
    /// 配了用户名，但 Keychain 里没有密码（典型场景：刚从别的设备导入）
    case missingPassword
    /// 本地中继起不来 / 没在监听
    case relayUnavailable(String)
    /// 连不上代理：DNS、拒绝连接、超时
    case upstreamUnreachable(String)
    /// TLS 握手失败，但不是证书验证的锅（协议版本、密码套件……）
    case tlsHandshakeFailed(String)
    /// 代理的证书没通过验证
    case certificateRejected(String)
    /// 代理回了 407：用户名或密码不对
    case upstreamAuthRejected
    /// 代理回了别的非 2xx，比如 403（代理不许连这个目标）、502
    case upstreamRefused(String)
    /// 握手完了代理那边直接断开，或者回的东西不像 HTTP
    case upstreamProtocolError(String)

    enum Category {
        case configuration
        case proxyUnreachable
        case certificate
        case authentication
    }

    var category: Category {
        switch self {
        case .invalidConfiguration, .missingPassword: .configuration
        case .relayUnavailable, .upstreamUnreachable, .tlsHandshakeFailed,
             .upstreamRefused, .upstreamProtocolError: .proxyUnreachable
        case .certificateRejected: .certificate
        case .upstreamAuthRejected: .authentication
        }
    }

    var title: String {
        switch category {
        case .configuration: "代理配置不完整"
        case .proxyUnreachable: "代理连不上"
        case .certificate: "代理的证书没通过验证"
        case .authentication: "代理拒绝了用户名或密码"
        }
    }

    var detail: String {
        switch self {
        case .invalidConfiguration(let reason): reason
        case .missingPassword: "这个代理要用户名密码，但本机没存密码。导入的配置不带密码，去代理设置里补上。"
        case .relayUnavailable(let reason): "本地中继没在工作：\(reason)"
        case .upstreamUnreachable(let reason): reason
        case .tlsHandshakeFailed(let reason): "和代理的 TLS 握手失败：\(reason)"
        case .certificateRejected(let reason): reason
        case .upstreamAuthRejected: "代理回了 407。检查代理设置里的用户名和密码。"
        case .upstreamRefused(let status): "代理不肯建立隧道：\(status)"
        case .upstreamProtocolError(let reason): reason
        }
    }

    var symbol: String {
        switch category {
        case .configuration: "gearshape.fill"
        case .proxyUnreachable: "network.slash"
        case .certificate: "lock.trianglebadge.exclamationmark"
        case .authentication: "person.badge.key"
        }
    }

    /// 中继回给 WKWebView 的 502 响应里带的短标识，排查时在抓包里一眼能认出来
    var code: String {
        switch self {
        case .invalidConfiguration: "config"
        case .missingPassword: "missing-password"
        case .relayUnavailable: "relay"
        case .upstreamUnreachable: "unreachable"
        case .tlsHandshakeFailed: "tls"
        case .certificateRejected: "certificate"
        case .upstreamAuthRejected: "auth"
        case .upstreamRefused: "refused"
        case .upstreamProtocolError: "protocol"
        }
    }
}

/// 浏览页失败界面要显示的东西。原来只有一句 `localizedDescription`，
/// 现在开了代理的 profile 要能说清楚是代理的问题还是站点的问题。
struct LoadFailure: Hashable, Sendable {
    var title: String
    var message: String
    var symbol: String

    init(title: String = "打不开这个页面", message: String, symbol: String = "wifi.exclamationmark") {
        self.title = title
        self.message = message
        self.symbol = symbol
    }

    init(_ failure: ProxyFailure) {
        self.init(title: failure.title, message: failure.detail, symbol: failure.symbol)
    }
}
