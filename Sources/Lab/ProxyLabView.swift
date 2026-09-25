import Network
import SwiftUI
import WebKit

/// 实验室 → 代理诊断。给真机验证用，四件事：
///
/// 1. **直连模式实测**：不管这个 profile 选的是哪种方式，拿它的地址和认证临时拼一个
///    `ProxyConfiguration(httpCONNECTProxy:tlsOptions:)` 给一个一次性的 data store，
///    用真 WKWebView 加载一次。WebKit bug 264307（带 TLS 选项时网络进程崩溃）在 iOS 26
///    上修没修，就看这一项：成功、报错（错误链原样展开）、还是超时（网络进程崩了的典型表现）。
/// 2. **出口 IP 对比**：app 直连问一次 IP，再用这个 profile 的真 data store 连续加载两次——
///    两次都得是代理的 IP。第二次专门查"第一次走代理、后面的导航走直连"这种报告过的问题。
/// 3. **中继状态**：端口、隧道数、认证拒绝数、最近一次上游错误。认证拒绝数一直涨而页面打不开，
///    就是 WKWebView 没带上本地一跳的凭据（`applyCredential` 在这个系统上坏了）。
/// 4. **加固是否生效**：WebRTC / WebTransport 的私有开关关没关上，DNS 预取拦截规则编没编好。
struct ProxyLabView: View {
    @Environment(SiteStore.self) private var store
    private var manager: ProxyManager { .shared }

    @State private var profile: String?
    @State private var directTestURL = "https://www.apple.com/library/test/success.html"
    @State private var ipEchoURL = "https://api.ipify.org"
    @State private var directResult: String?
    @State private var ipResult: String?
    @State private var running = false
    @State private var hardening: ProxyHardening.Report?
    @State private var notice: String?

    var body: some View {
        @Bindable var bindable = manager
        let profiles = store.profileProxies.keys.sorted()
        Form {
            Section {
                if profiles.isEmpty {
                    Text("还没有任何 profile 配过代理。先去 设置 → 网络代理 配一个。")
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Picker("profile", selection: $profile) {
                        Text("选一个").tag(String?.none)
                        ForEach(profiles, id: \.self) { name in
                            Text(ProfileDescriptor(profile: name, sites: store.sites(usingProfile: name)).title)
                                .tag(String?.some(name))
                        }
                    }
                }
            }
            if let profile, let config = store.profileProxies[profile] {
                statusSection(profile, config: config)
                directSection(profile, config: config)
                ipSection(profile)
                reportSection
            }
            Section {
                Toggle("本地一跳不校验凭据", isOn: $bindable.relayAuthDisabled)
            } header: {
                Text("排查开关")
            } footer: {
                Text("只在确认 WKWebView 不带本地凭据（上面「认证拒绝」一直在涨、页面一直 502/407）时临时打开。打开期间本机其他 app 只要猜到端口，就能借你的代理出网。只存本机，不进导出。")
            }
        }
        .navigationTitle("代理诊断")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice { GlassToast(text: notice).padding(.bottom, 24) }
        }
        .onAppear {
            if profile == nil { profile = profiles.first }
            let configuration = WKWebViewConfiguration()
            hardening = ProxyHardening.apply(to: configuration, ruleList: manager.dnsPrefetchRuleList)
        }
    }

    // MARK: - 状态

    private func statusSection(_ profile: String, config: ProfileProxy) -> some View {
        Section {
            LabeledContent("配置", value: config.summary)
            LabeledContent("证书验证", value: config.verification.title)
            if let relay = manager.relay(for: profile) {
                let stats = relay.stats
                LabeledContent("中继端口", value: relay.port.map { "127.0.0.1:\($0)" } ?? "未监听")
                LabeledContent("隧道 / 认证拒绝 / 失败", value: "\(stats.tunnelsOpened) / \(stats.authRejections) / \(stats.failures)")
                if let failure = stats.lastFailure {
                    Text("最近一次：\(failure.title) — \(failure.detail)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if config.mode == .localRelay {
                LabeledContent("中继", value: "还没启动（打开一个站点就会起）")
            }
            if let hardening {
                LabeledContent("WebRTC 关闭", value: Self.flag(hardening.peerConnectionDisabled))
                LabeledContent("WebTransport 关闭", value: Self.flag(hardening.webTransportDisabled))
                LabeledContent("DNS 预取拦截规则", value: hardening.dnsPrefetchRuleInstalled ? "已编译" : (manager.ruleListError ?? "还没编译（打开一个开了代理的站点就会编）"))
            }
        } header: {
            Text("状态")
        }
    }

    // MARK: - 直连模式实测

    private func directSection(_ profile: String, config: ProfileProxy) -> some View {
        Section {
            TextField("测试地址", text: $directTestURL)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                runDirectTest(profile, config: config)
            } label: {
                Label("用「直连代理」方式加载一次", systemImage: "play.circle")
            }
            .disabled(running)
            if let directResult {
                Text(directResult).font(.caption.monospaced()).textSelection(.enabled)
            }
        } header: {
            Text("直连模式实测")
        } footer: {
            Text("临时 data store（不留数据），配置是 ProxyConfiguration(httpCONNECTProxy:, tlsOptions: 默认)，系统验证。和这个 profile 实际选的方式无关。")
        }
    }

    private func runDirectTest(_ profile: String, config: ProfileProxy) {
        guard let url = URL(string: directTestURL) else { return }
        guard case .success(let settings) = manager.upstreamSettings(for: profile, config: directVariant(config)) else {
            directResult = "配置不完整或缺密码，先在代理设置里补全"
            return
        }
        var configuration = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(settings.host), port: NWEndpoint.Port(rawValue: settings.port) ?? .https),
            tlsOptions: NWProtocolTLS.Options()
        )
        configuration.allowFailover = false
        var credential: URLCredential?
        if let username = settings.username {
            configuration.applyCredential(username: username, password: settings.password ?? "")
            credential = URLCredential(user: username, password: settings.password ?? "", persistence: .forSession)
        }
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [configuration]
        running = true
        directResult = "加载中…"
        Task {
            let probe = WebViewProbe(store: store, proxyCredential: credential)
            let outcome = await probe.load(url)
            probe.tearDown()
            directResult = outcome.summary
            running = false
        }
    }

    /// 直连只支持系统验证。实测时强制按系统验证拼，别因为 profile 选了指纹就拼不出来
    private func directVariant(_ config: ProfileProxy) -> ProfileProxy {
        var copy = config
        copy.mode = .direct
        copy.verification = .system
        return copy
    }

    // MARK: - 出口 IP

    private func ipSection(_ profile: String) -> some View {
        Section {
            TextField("回显 IP 的地址", text: $ipEchoURL)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                runIPCheck(profile)
            } label: {
                Label("对比出口 IP", systemImage: "arrow.triangle.branch")
            }
            .disabled(running)
            if let ipResult {
                Text(ipResult).font(.caption.monospaced()).textSelection(.enabled)
            }
        } header: {
            Text("出口 IP")
        } footer: {
            Text("第一行是 app 直连问到的（会把你的真实 IP 发给这个回显服务，只在你点按钮时发生）。后两行是这个 profile 的真 data store 在同一个 WebView 里连续两次导航问到的，都应该是代理的 IP，且和第一行不同。")
        }
    }

    private func runIPCheck(_ profile: String) {
        guard let url = URL(string: ipEchoURL) else { return }
        running = true
        ipResult = "查询中…"
        Task {
            var lines: [String] = []
            if let response = try? await URLSession.shared.data(from: url) {
                lines.append("直连：\(String(decoding: response.0, as: UTF8.self).prefix(64))")
            } else {
                lines.append("直连：查不到")
            }
            switch await manager.prepare(profile: profile) {
            case .failure(let failure):
                lines.append("代理没准备好：\(failure.title) — \(failure.detail)")
            case .success:
                let probe = WebViewProbe(
                    store: WebsiteDataStoreManager.shared.dataStore(forProfile: profile),
                    proxyCredential: credential(for: profile)
                )
                lines.append("第一次导航：" + (await probe.load(url)).summary)
                lines.append("第二次导航：" + (await probe.load(url)).summary)
                probe.tearDown()
            }
            ipResult = lines.joined(separator: "\n")
            running = false
        }
    }

    /// 和浏览页答 407 时用的是同一份凭据
    private func credential(for profile: String) -> URLCredential? {
        guard let config = store.profileProxies[profile] else { return nil }
        switch config.mode {
        case .localRelay:
            return manager.proxyCredential(for: profile, host: "127.0.0.1", port: Int(manager.relay(for: profile)?.port ?? 0))
        case .direct:
            return manager.proxyCredential(for: profile, host: config.trimmedHost, port: config.port)
        }
    }

    // MARK: - 报告

    private var reportSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = report
                Haptics.success()
                withAnimation { notice = "诊断结果已复制" }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { notice = nil }
                }
            } label: {
                Label("复制诊断结果", systemImage: "doc.on.doc")
            }
        }
    }

    private var report: String {
        var lines = ["# Husk 代理诊断", "系统：iOS \(UIDevice.current.systemVersion)"]
        if let profile, let config = store.profileProxies[profile] {
            lines.append("配置：\(config.summary)，验证：\(config.verification.title)")
            if let relay = manager.relay(for: profile) {
                let stats = relay.stats
                lines.append("中继：端口 \(relay.port.map { String($0) } ?? "无")，隧道 \(stats.tunnelsOpened)，认证拒绝 \(stats.authRejections)，失败 \(stats.failures)")
                if let failure = stats.lastFailure { lines.append("最近失败：\(failure.code) \(failure.detail)") }
            }
        }
        if let hardening {
            lines.append("WebRTC 关闭：\(Self.flag(hardening.peerConnectionDisabled))；WebTransport 关闭：\(Self.flag(hardening.webTransportDisabled))；DNS 预取规则：\(hardening.dnsPrefetchRuleInstalled)")
        }
        lines.append("本地一跳凭据校验：\(manager.relayAuthDisabled ? "关" : "开")")
        if let directResult { lines += ["", "## 直连模式实测", directResult] }
        if let ipResult { lines += ["", "## 出口 IP", ipResult] }
        return lines.joined(separator: "\n")
    }

    private static func flag(_ value: Bool?) -> String {
        switch value {
        case .some(true): "是"
        case .some(false): "设了但没生效"
        case .none: "这个系统上没有该开关"
        }
    }
}
