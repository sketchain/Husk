import CryptoKit
import Foundation
import Network
import Observation
import UIKit
import WebKit

/// 把 profile 的代理配置落到它的 `WKWebsiteDataStore` 上，并管理本地中继的生命周期。
///
/// 核心约束（README「按 profile 配 HTTPS 代理」有展开）：
/// 1. **开了代理的 profile 在代理就绪之前一个请求都不许发。** 浏览页先问 `readiness`，
///    不是 `.ready` 就不建 WebView；`allowFailover` 显式设 false（文档说默认就是 false，照样写明）。
/// 2. **`proxyConfigurations` 只在真变了的时候才赋值**：Apple 文档说改它会打断进行中的请求。
///    用签名比对，同一份配置重复准备是空操作。
/// 3. **没开代理的 profile 一律不碰 `proxyConfigurations`**，除非这次启动里给它设过、现在要撤掉。
@MainActor
@Observable
final class ProxyManager {
    static let shared = ProxyManager()

    /// profile → 改动计数。浏览页观察它：一变就拆掉 WebView、重新准备、重建。
    private(set) var revisions: [String: Int] = [:]

    // 下面几个不是 private：ProxyManager+Relay.swift 要用（Swift 的 private 是按文件的）
    @ObservationIgnored var relays: [String: LocalRelay] = [:]
    /// 进后台时记下的端口，回前台优先拿回它
    @ObservationIgnored var lastRelayPorts: [String: UInt16] = [:]
    /// 这次启动里给哪些 store 设过什么（签名），以及设的具体值（URLSession 要照抄一份）
    @ObservationIgnored var applied: [String: (signature: String, configurations: [ProxyConfiguration])] = [:]
    @ObservationIgnored private var failures: [String: (failure: ProxyFailure, at: Date)] = [:]
    @ObservationIgnored var relayStarts: [String: Task<Result<UInt16, ProxyFailure>, Never>] = [:]
    @ObservationIgnored var urlSessions: [String: (signature: String, session: URLSession)] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    @ObservationIgnored private(set) var dnsPrefetchRuleList: WKContentRuleList?
    @ObservationIgnored private(set) var ruleListError: String?
    @ObservationIgnored private var ruleListState = RuleListState.idle
    private enum RuleListState { case idle, compiling, done }

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ProxyManager.shared.enterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ProxyManager.shared.enterForeground() }
        })
    }

    // MARK: - 查询

    func config(for profile: String) -> ProfileProxy? {
        SiteStore.shared.profileProxies[profile]
    }

    func isProxied(_ profile: String) -> Bool {
        config(for: profile)?.isEnabled == true
    }

    func revision(for profile: String) -> Int {
        revisions[profile, default: 0]
    }

    func relay(for profile: String) -> LocalRelay? { relays[profile] }

    /// 实验室开关：本地一跳不校验凭据。只为排查"WKWebView 的代理认证在这个系统上坏了"时用，
    /// 存 UserDefaults、不进导出。打开时本机别的 app 能借用这个中继（见 README）。
    var relayAuthDisabled: Bool {
        get { access(keyPath: \.relayAuthDisabled); return UserDefaults.standard.bool(forKey: Self.authDisabledKey) }
        set {
            withMutation(keyPath: \.relayAuthDisabled) {
                UserDefaults.standard.set(newValue, forKey: Self.authDisabledKey)
            }
            for (profile, relay) in relays { relay.update(upstream: relay.upstream, requireAuth: !newValue); bump(profile) }
        }
    }
    private static let authDisabledKey = "lab.proxy.relayAuthDisabled"

    // MARK: - 准备

    enum Readiness: Equatable {
        case ready
        /// 要等一下（中继还没起来 / 规则还在编译），走 `prepare`
        case pending
        case failed(ProxyFailure)
    }

    /// 不等待的版本：能立刻判定的就立刻判定。浏览页进来第一帧用它，
    /// 没开代理的站点因此和以前一样第一帧就有 WebView，不多闪一下。
    func readiness(for profile: String) -> Readiness {
        guard let config = config(for: profile), config.isEnabled else {
            withdraw(profile)
            return .ready
        }
        guard ruleListState == .done else { return .pending }
        let settings: UpstreamSettings
        switch upstreamSettings(for: profile, config: config) {
        case .failure(let failure): return .failed(failure)
        case .success(let value): settings = value
        }
        switch config.mode {
        case .direct:
            retireRelay(profile)
            applyDirect(profile, settings: settings)
            return .ready
        case .localRelay:
            guard let relay = relays[profile], let port = relay.port else { return .pending }
            relay.update(upstream: settings, requireAuth: !relayAuthDisabled)
            applyRelay(profile, relay: relay, port: port)
            return .ready
        }
    }

    /// 等待版本：把中继起起来、规则编译完，再给结论。
    func prepare(profile: String) async -> Result<Void, ProxyFailure> {
        if isProxied(profile) { await ensureRuleList() }
        switch readiness(for: profile) {
        case .ready: return .success(())
        case .failed(let failure): return .failure(failure)
        case .pending: break
        }
        guard let config = config(for: profile), config.isEnabled, config.mode == .localRelay,
              case .success(let settings) = upstreamSettings(for: profile, config: config)
        else { return readinessResult(profile) }

        let relay = relays[profile] ?? makeRelay(profile, settings: settings)
        relay.update(upstream: settings, requireAuth: !relayAuthDisabled)
        if relay.port == nil {
            if case .failure(let failure) = await start(relay, profile: profile) {
                record(failure, for: profile)
                return .failure(failure)
            }
        }
        // 等待期间配置可能又变了，以最新的判定为准
        return readinessResult(profile)
    }

    private func readinessResult(_ profile: String) -> Result<Void, ProxyFailure> {
        switch readiness(for: profile) {
        case .ready: .success(())
        case .failed(let failure): .failure(failure)
        case .pending: .failure(.relayUnavailable("中继还没准备好"))
        }
    }

    /// 配置 + Keychain 密码 → 连接参数。任何一样缺了都是失败，不是"那就不走代理"。
    func upstreamSettings(for profile: String, config: ProfileProxy) -> Result<UpstreamSettings, ProxyFailure> {
        if let problem = config.configurationProblem { return .failure(.invalidConfiguration(problem)) }
        var password: String?
        if config.needsPassword {
            guard let stored = ProxyKeychain.password(forProfile: profile) else { return .failure(.missingPassword) }
            password = stored
        }
        let pins = Set(config.pins.compactMap(CertificateFingerprint.parsePin))
        return .success(UpstreamSettings(
            host: config.trimmedHost,
            port: UInt16(config.port),
            username: config.needsPassword ? config.username : nil,
            password: password,
            verification: config.verification,
            pins: pins
        ))
    }

    // MARK: - 落到 data store 上

    private func applyDirect(_ profile: String, settings: UpstreamSettings) {
        let signature = "direct|\(settings.host)|\(settings.port)|\(settings.username ?? "")|\(Self.digest(settings.password))"
        guard applied[profile]?.signature != signature else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(settings.host),
            port: NWEndpoint.Port(rawValue: settings.port) ?? .https
        )
        // TLS 选项故意给一个全默认的：WebKit bug 264307 说带 TLS 选项的配置跨进程序列化会出问题，
        // 能少带一样定制就少带一样。验证就是系统默认的信任链 + 主机名。
        var configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        configuration.allowFailover = false
        if let username = settings.username {
            configuration.applyCredential(username: username, password: settings.password ?? "")
        }
        set([configuration], signature: signature, for: profile)
    }

    func applyRelay(_ profile: String, relay: LocalRelay, port: UInt16) {
        let signature = "relay|\(port)|\(Self.digest(relay.password))|\(relay.requiresAuth)"
        guard applied[profile]?.signature != signature else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port) ?? .any)
        // 本地这一跳是明文（只在回环接口上），tlsOptions 必须是 nil
        var configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        configuration.allowFailover = false
        configuration.applyCredential(username: relay.username, password: relay.password)
        set([configuration], signature: signature, for: profile)
    }

    private func set(_ configurations: [ProxyConfiguration], signature: String, for profile: String) {
        WebsiteDataStoreManager.shared.dataStore(forProfile: profile).proxyConfigurations = configurations
        applied[profile] = (signature, configurations)
        urlSessions[profile] = nil
    }

    /// 撤掉代理：只有这次启动里设过才动 store
    private func withdraw(_ profile: String) {
        retireRelay(profile)
        guard applied[profile] != nil else { return }
        WebsiteDataStoreManager.shared.dataStore(forProfile: profile).proxyConfigurations = []
        applied[profile] = nil
        urlSessions[profile] = nil
    }

    /// 这个 profile 不再用本地中继了：停监听，已有隧道也断掉
    private func retireRelay(_ profile: String) {
        guard let relay = relays.removeValue(forKey: profile) else { return }
        relay.dropAllConnections()
        relay.stop()
    }

    // MARK: - 配置变了

    /// 代理设置保存 / 删除之后调。先 bump 版本号，让开着的浏览页立刻拆掉旧 WebView，
    /// 再落新配置——顺序反过来的话，旧页面会在新旧配置交替的那一下按错误的路发请求。
    func configurationDidChange(profile: String) {
        bump(profile)
        failures[profile] = nil
        urlSessions[profile] = nil
        if config(for: profile)?.mode != .localRelay {
            retireRelay(profile)
        }
        // 按旧配置建好的隧道一律断开，别让 WebKit 复用它们
        relays[profile]?.dropAllConnections()
        if case .pending = readiness(for: profile) {
            Task { _ = await prepare(profile: profile) }
        }
    }

    func bump(_ profile: String) {
        revisions[profile, default: 0] += 1
    }

    // MARK: - 失败记录

    func record(_ failure: ProxyFailure, for profile: String) {
        failures[profile] = (failure, Date())
    }

    /// 最近一段时间内中继报过的错。浏览页失败时拿它来判断"是代理的锅还是站点的锅"。
    func recentFailure(for profile: String, within seconds: TimeInterval = 20) -> ProxyFailure? {
        guard let entry = failures[profile], Date().timeIntervalSince(entry.at) <= seconds else { return nil }
        return entry.failure
    }

    // MARK: - 规则

    func ensureRuleList() async {
        switch ruleListState {
        case .done:
            return
        case .compiling:
            // 另一处正在编，等它（一般几十毫秒）
            for _ in 0..<100 where ruleListState == .compiling {
                try? await Task.sleep(for: .milliseconds(30))
            }
        case .idle:
            ruleListState = .compiling
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                ProxyHardening.compileRuleList { list, error in
                    ProxyManager.shared.dnsPrefetchRuleList = list
                    ProxyManager.shared.ruleListError = error
                    ProxyManager.shared.ruleListState = .done
                    continuation.resume()
                }
            }
        }
    }

    private static func digest(_ secret: String?) -> String {
        guard let secret else { return "-" }
        return SHA256.hash(data: Data(secret.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
