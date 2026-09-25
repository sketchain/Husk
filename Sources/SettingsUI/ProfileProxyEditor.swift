import SwiftUI

/// 一个 profile 的代理设置。从「设置 → 网络代理」push 进来，或者从站点设置里以 sheet 打开。
///
/// 草稿制：改完点「保存」才生效。保存时 `SiteStore.setProxy` 会通知 `ProxyManager`，
/// 已经开着的、属于这个 profile 的页面会被**拆掉重建并重新加载**（理由见 README）。
struct ProfileProxyEditor: View {
    let profile: String

    @Environment(\.dismiss) private var dismiss
    @Environment(SiteStore.self) private var store

    @State private var draft: ProfileProxy
    @State private var portText: String
    @State private var pinsText: String
    /// 新输入的密码；空 = 不改 Keychain 里现有的
    @State private var password = ""
    @State private var hasStoredPassword: Bool
    @State private var testing = false
    @State private var testResult: ProxyTester.Result?
    @State private var saveError: String?
    @State private var confirmingDelete = false
    private let existed: Bool

    init(profile: String) {
        self.profile = profile
        let existing = SiteStore.shared.profileProxies[profile]
        existed = existing != nil
        let value = existing ?? ProfileProxy(isEnabled: false)
        _draft = State(initialValue: value)
        _portText = State(initialValue: String(value.port))
        _pinsText = State(initialValue: value.pins.map { "sha256/" + $0 }.joined(separator: "\n"))
        _hasStoredPassword = State(initialValue: ProxyKeychain.hasPassword(forProfile: profile))
    }

    var body: some View {
        Form {
            scopeSection
            Section {
                Toggle("走代理", isOn: $draft.isEnabled)
            } footer: {
                Text(draft.isEnabled
                     ? "开着时，代理连不上、握手失败或证书不对都会直接报错，不会改用直连。"
                     : "关掉就是直连。已经填好的地址和验证设置会留着，下次打开不用重填。")
            }
            if draft.isEnabled {
                modeSection
                endpointSection
                verificationSection
                ProxyTestSection(
                    mode: draft.mode,
                    testing: testing,
                    result: testResult,
                    onTest: runTest,
                    onUseFingerprint: adoptFingerprint
                )
            }
            if existed {
                Section {
                    Button("删除这个 profile 的代理配置", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle("代理")
        .navigationBarTitleDisplayMode(.inline)
        // 草稿制：push 进来时也只留「取消 / 保存」，免得返回键让人以为改动已经生效
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
            }
        }
        .alert("保存不了", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog("删除代理配置？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.removeProxy(for: profile)
                dismiss()
            }
        } message: {
            Text("连同 Keychain 里存的密码一起删。用这个 profile 的站点会改回直连。")
        }
    }

    // MARK: - 影响范围

    private var scopeSection: some View {
        let descriptor = ProfileDescriptor(profile: profile, sites: store.sites(usingProfile: profile))
        return Section {
            LabeledContent("profile", value: descriptor.title)
            if descriptor.sites.count > 1 {
                Text(descriptor.subtitle ?? "")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        } footer: {
            Text(scopeFooter(descriptor))
        }
    }

    private func scopeFooter(_ descriptor: ProfileDescriptor) -> String {
        let reload = "保存后，已经打开的这些页面会自动重新加载。"
        if descriptor.isAdHoc { return "改这里会影响所有临时站点（husk://open?url= 打开的地址）。" + reload }
        switch descriptor.sites.count {
        case 0: return "现在没有站点在用这个 profile。"
        case 1: return "只有这一个站点在用。" + reload
        default: return "⚠︎ 这 \(descriptor.sites.count) 个站点共用这个 profile，改了代理它们全都跟着变。" + reload
        }
    }

    // MARK: - 连接方式

    private var modeSection: some View {
        Section {
            Picker("连接方式", selection: $draft.mode) {
                ForEach(ProxyConnectionMode.allCases) { Text($0.title).tag($0) }
            }
        } footer: {
            Text(draft.mode.subtitle)
        }
    }

    // MARK: - 地址与认证

    private var endpointSection: some View {
        Section {
            TextField("代理主机名或 IP", text: $draft.host)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("端口", text: $portText)
                .keyboardType(.numberPad)
            TextField("用户名（不需要认证就留空）", text: $draft.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textContentType(.username)
            if !draft.username.isEmpty {
                SecureField(hasStoredPassword ? "已存密码，留空不改" : "密码", text: $password)
                    .textContentType(.password)
            }
        } header: {
            Text("HTTPS 代理")
        } footer: {
            Text("app 和代理之间走 TLS，隧道用 HTTP CONNECT。两种连接方式共用这组地址和认证，切换方式不用重填。\n密码只存在本机 Keychain，不进配置文件，也不随导出带走。")
        }
    }

    // MARK: - 证书验证

    private var verificationSection: some View {
        Section {
            Picker("证书验证", selection: $draft.verification) {
                ForEach(ProxyTLSVerification.allCases) { option in
                    Text(draft.mode.supports(option) ? option.title : "\(option.title)（直连不支持）")
                        .tag(option)
                }
            }
            if !draft.mode.supports(draft.verification) {
                Label("「直连代理」下 WebKit 不会调用自定义验证回调，只能用系统验证。换成「本地中继」，或者改回系统验证才能保存。", systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if draft.verification == .pinnedKey {
                TextField("每行一个指纹", text: $pinsText, axis: .vertical)
                    .lineLimit(2...6)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                let invalid = CertificateFingerprint.parsePinList(pinsText).invalid
                if !invalid.isEmpty {
                    Label("认不出：\(invalid.joined(separator: "、"))", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if draft.verification == .none {
                Label("不验证证书时，路上任何人都能冒充这个代理，看到你经它访问的一切（HTTPS 站点的内容除外）。", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("代理证书")
        } footer: {
            Text(draft.verification.subtitle + (draft.verification == .pinnedKey
                ? "\n写法：sha256/ 开头的 base64（curl --pinnedpubkey 那种），或 64 位十六进制（冒号可有可无）。填多个用来平滑换密钥：新旧两个都填上，换完再删旧的。"
                : ""))
        }
    }

    // MARK: - 动作

    /// 草稿 → 待保存的配置。把端口文本和指纹文本并进去。
    private var candidate: ProfileProxy {
        var value = draft
        value.host = value.trimmedHost
        value.username = value.username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        value.pins = CertificateFingerprint.parsePinList(pinsText).pins
        return value
    }

    private func save() {
        let value = candidate
        if let problem = saveProblem(value) {
            saveError = problem
            return
        }
        if !value.needsPassword {
            ProxyKeychain.removePassword(forProfile: profile)
        } else if !password.isEmpty, !ProxyKeychain.setPassword(password, forProfile: profile) {
            saveError = "密码存不进 Keychain，配置没有保存。"
            return
        }
        // 从没配过、也没打开的，就别在库里留一条空配置
        if !existed, !value.isEnabled, value.trimmedHost.isEmpty {
            dismiss()
            return
        }
        store.setProxy(value, for: profile)
        dismiss()
    }

    /// 关着的配置随便存（下次打开再补）；开着的必须能用
    private func saveProblem(_ value: ProfileProxy) -> String? {
        guard value.isEnabled else { return nil }
        if let problem = value.configurationProblem { return problem }
        if value.verification == .pinnedKey, !CertificateFingerprint.parsePinList(pinsText).invalid.isEmpty {
            return "有指纹认不出来，改好或删掉再保存。"
        }
        if value.needsPassword, password.isEmpty, !hasStoredPassword {
            return "填了用户名就要填密码。"
        }
        return nil
    }

    private func runTest() {
        let value = candidate
        // 指纹模式下还没填指纹时照样让测：测的目的之一就是把指纹拿到手
        let collectingFingerprint = value.verification == .pinnedKey && value.pins.isEmpty
        let blocking = collectingFingerprint
            ? (value.trimmedHost.isEmpty || !(1...65535).contains(value.port) ? "先填代理地址和端口" : nil)
            : value.configurationProblem
        if let problem = blocking {
            testResult = ProxyTester.Result(failure: .invalidConfiguration(problem), inspection: .init(), elapsed: .zero)
            return
        }
        let stored = ProxyKeychain.password(forProfile: profile)
        let settings = UpstreamSettings(
            host: value.trimmedHost,
            port: UInt16(clamping: value.port),
            username: value.needsPassword ? value.username : nil,
            password: password.isEmpty ? stored : password,
            verification: value.verification,
            pins: Set(value.pins.compactMap(CertificateFingerprint.parsePin))
        )
        testing = true
        testResult = nil
        Task {
            let result = await ProxyTester.run(settings: settings)
            testResult = result
            testing = false
        }
    }

    /// 把测到的指纹加进列表，并切到指纹验证
    private func adoptFingerprint(_ base64: String) {
        var pins = CertificateFingerprint.parsePinList(pinsText).pins
        if !pins.contains(base64) { pins.append(base64) }
        pinsText = pins.map { "sha256/" + $0 }.joined(separator: "\n")
        draft.verification = .pinnedKey
        if !draft.mode.supports(.pinnedKey) { draft.mode = .localRelay }
    }
}
