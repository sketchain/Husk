import Foundation
import WebKit

/// 本地中继的生命周期、代理认证兜底、app 自己请求用的 URLSession。
/// 从 ProxyManager.swift 拆出来只是为了单文件不过 300 行。
extension ProxyManager {
    // MARK: - 中继

    func makeRelay(_ profile: String, settings: UpstreamSettings) -> LocalRelay {
        let relay = LocalRelay(profile: profile, upstream: settings, requireAuth: !relayAuthDisabled) { failure in
            Task { @MainActor in ProxyManager.shared.record(failure, for: profile) }
        }
        relays[profile] = relay
        return relay
    }

    /// 起监听。同一个 profile 同时有几处要起（浏览页、保存设置、图标抓取、回前台）时合并成一次：
    /// 各自去 start 的话，后一次会把前一次正在起的监听顶掉，前一次就以失败告终，
    /// 页面会莫名其妙地报"中继起不来"。
    func start(_ relay: LocalRelay, profile: String) async -> Result<UInt16, ProxyFailure> {
        if let running = relayStarts[profile] { return await running.value }
        let task = Task { await self.startUncoalesced(relay, profile: profile) }
        relayStarts[profile] = task
        let result = await task.value
        relayStarts[profile] = nil
        return result
    }

    /// 先试上次的端口，被占了就换一个
    private func startUncoalesced(_ relay: LocalRelay, profile: String) async -> Result<UInt16, ProxyFailure> {
        let preferred = lastRelayPorts[profile]
        var result = await Self.listen(relay, preferredPort: preferred)
        if case .failure = result, preferred != nil {
            result = await Self.listen(relay, preferredPort: nil)
        }
        if case .success(let port) = result { lastRelayPorts[profile] = port }
        return result
    }

    private nonisolated static func listen(_ relay: LocalRelay, preferredPort: UInt16?) async -> Result<UInt16, ProxyFailure> {
        await withCheckedContinuation { continuation in
            relay.start(preferredPort: preferredPort) { continuation.resume(returning: $0) }
        }
    }

    /// TN2277：挂起期间监听套接字可能被系统回收，而且挂起时来的连接没人处理。
    /// 所以进后台就关监听、回前台再开。已经建立的隧道不动。
    func enterBackground() {
        for (profile, relay) in relays {
            if let port = relay.port { lastRelayPorts[profile] = port }
            relay.stop()
        }
    }

    func enterForeground() {
        for (profile, relay) in relays {
            let previous = lastRelayPorts[profile]
            Task {
                switch await start(relay, profile: profile) {
                case .success(let port):
                    // 拿回了原端口：proxyConfigurations 一个字都不用改，页面无感。
                    // 换了端口：得改配置，改配置会打断请求，干脆让浏览页重建。
                    if port != previous, isProxied(profile) {
                        applyRelay(profile, relay: relay, port: port)
                        bump(profile)
                    }
                case .failure(let failure):
                    record(failure, for: profile)
                    bump(profile)
                }
            }
        }
    }

    // MARK: - 认证兜底

    /// WebKit 问代理凭据时答什么。只答"这个 profile 自己的代理"，别的一律 nil。
    func proxyCredential(for profile: String, host: String, port: Int) -> URLCredential? {
        guard let config = config(for: profile), config.isEnabled else { return nil }
        switch config.mode {
        case .localRelay:
            guard let relay = relays[profile], let relayPort = relay.port,
                  ["127.0.0.1", "localhost"].contains(host.lowercased()), port == Int(relayPort)
            else { return nil }
            return URLCredential(user: relay.username, password: relay.password, persistence: .forSession)
        case .direct:
            guard host.caseInsensitiveCompare(config.trimmedHost) == .orderedSame, port == config.port,
                  config.needsPassword, let password = ProxyKeychain.password(forProfile: profile)
            else { return nil }
            return URLCredential(user: config.username, password: password, persistence: .forSession)
        }
    }

    // MARK: - app 自己的请求

    /// 给 app 自己的、和某个站点有关的请求（图标抓取）用的 URLSession。
    /// - 没开代理：`URLSession.shared`
    /// - 开了代理：和 WebView 同一份 `proxyConfigurations`
    /// - 开了代理但没准备好：nil，**调用方必须放弃这次请求**，不能拿 shared 凑合
    func urlSession(forProfile profile: String) async -> URLSession? {
        guard isProxied(profile) else { return .shared }
        guard case .success = await prepare(profile: profile), let entry = applied[profile] else { return nil }
        if let cached = urlSessions[profile], cached.signature == entry.signature { return cached.session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = entry.configurations
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        urlSessions[profile] = (entry.signature, session)
        return session
    }
}
