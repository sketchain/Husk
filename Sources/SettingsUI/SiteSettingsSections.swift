import SwiftUI

/// 单个站点的「缩放 / UA / 外链 / 存储」四组设置。
///
/// 抽出来是因为它现在有两个宿主：站点编辑页，以及工具箱 sheet 拖到大档位之后
/// 露出来的下半截。两边各写一份的话，加一个字段就得改两处，迟早走样。
///
/// 约定：`site` 的写入是**即时**的（调用方可能正拿它驱动当前页面），
/// 写盘则集中在 `commit`。缩放滑块拖动时只写 `site`，松手才 `commit`，
/// 不然拖一次滑块要落几十次盘。
struct SiteSettingsSections: View {
    @Binding var site: Site
    /// 该把改动写进磁盘了
    let commit: () -> Void

    @State private var uaSelection: UserAgentPreset?
    @State private var customUA: String
    @State private var sharesProfile: Bool
    @State private var profileText: String
    @State private var inAppText: String
    @State private var safariText: String

    init(site: Binding<Site>, commit: @escaping () -> Void) {
        _site = site
        self.commit = commit
        let value = site.wrappedValue
        let preset = UserAgentPreset.matching(value.userAgent)
        _uaSelection = State(initialValue: preset)
        _customUA = State(initialValue: preset == nil ? (value.userAgent ?? "") : "")
        _sharesProfile = State(initialValue: value.profile != value.id.uuidString)
        _profileText = State(initialValue: value.profile != value.id.uuidString ? value.profile : "")
        _inAppText = State(initialValue: value.inAppDomains.joined(separator: ", "))
        _safariText = State(initialValue: value.safariDomains.joined(separator: ", "))
    }

    var body: some View {
        Group {
            zoomSection
                // 只挂在其中一个 section 上：`Group` 会把 modifier 分发给每个子视图，
                // 挂在 Group 上等于同一次改动写五遍盘。
                .onChange(of: site) { old, new in
                    // 缩放单独走 onEditingChanged（拖动时不写盘），别的改动一律立刻落盘
                    if old.zoom == new.zoom { commit() }
                }
            userAgentSection
            linkSection
            exceptionSection
            profileSection
        }
    }

    // MARK: - 缩放

    private var zoomSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("缩放", systemImage: "textformat.size")
                    Spacer()
                    Text(ZoomScale.percentText(site.zoom))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                    Button("重置") { setZoom(1.0); commit() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(abs(site.zoom - 1.0) < 0.001)
                }
                HStack(spacing: 10) {
                    Text("10%").font(.caption2).foregroundStyle(Theme.secondaryText)
                    Slider(
                        value: Binding(
                            get: { ZoomScale.index(for: site.zoom) },
                            set: { setZoom(ZoomScale.zoom(atIndex: $0)) }
                        ),
                        in: ZoomScale.indexRange,
                        step: 1,
                        onEditingChanged: { editing in if !editing { commit() } }
                    )
                    Text("200%").font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }
        } footer: {
            Text("走 WKWebView 的 pageZoom，等价于给整页加 CSS zoom，不是改 viewport。滑块走的是档位表，所以一定停得到 100%。")
        }
    }

    private func setZoom(_ value: Double) {
        site.zoom = value.clamped(to: Site.zoomRange)
    }

    // MARK: - UA

    private var userAgentSection: some View {
        Section {
            Picker("UA", selection: $uaSelection) {
                Text("自定义").tag(UserAgentPreset?.none)
                ForEach(UserAgentPreset.allCases) { preset in
                    Text(preset.title).tag(UserAgentPreset?.some(preset))
                }
            }
            if uaSelection == nil {
                TextField("粘贴 UA 串", text: $customUA, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else if let note = uaSelection?.note {
                Text(note).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text("User-Agent")
        } footer: {
            Text("改完会重新加载当前页——customUserAgent 只影响之后发出的请求。")
        }
        .onChange(of: uaSelection) { _, _ in applyUserAgent() }
        .onChange(of: customUA) { _, _ in applyUserAgent() }
    }

    private func applyUserAgent() {
        let value = uaSelection.map(\.value) ?? (customUA.isEmpty ? nil : customUA)
        guard site.userAgent != value else { return }
        site.userAgent = value
    }

    // MARK: - 外链

    private var linkSection: some View {
        Section {
            Picker("外链", selection: $site.externalLinkPolicy) {
                ForEach(ExternalLinkPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Text(site.externalLinkPolicy.subtitle)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)

            if site.externalLinkPolicy == .sameDomain {
                Picker("什么算站内", selection: $site.linkScope) {
                    ForEach(LinkScopeStrictness.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Text(site.linkScope.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text("外链行为")
        } footer: {
            Text("只对你点出来的主框架链接生效，iframe、重定向、资源请求一律不拦。")
        }
    }

    private var exceptionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("也算站内", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.subheadline)
                TextField("b23.tv, *.ytimg.com", text: $inAppText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("强制 Safari", systemImage: "safari")
                    .font(.subheadline)
                TextField("ads.example.com", text: $safariText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("手动例外")
        } footer: {
            Text("逗号或空格分隔。`example.com` 只匹配这一个主机（www. 视为同一个），`*.example.com` 连同它的所有子域一起。例外优先于上面的档位，「强制 Safari」又优先于「也算站内」。")
        }
        .onChange(of: inAppText) { _, value in
            site.inAppDomains = DomainPattern.parseList(value)
        }
        .onChange(of: safariText) { _, value in
            site.safariDomains = DomainPattern.parseList(value)
        }
    }

    // MARK: - 存储

    private var profileSection: some View {
        Section {
            Toggle("和其他站点共享存储", isOn: $sharesProfile)
            if sharesProfile {
                TextField("profile 名（相同即共享）", text: $profileText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            // 代理挂在 profile 上，所以放在存储这一组里，紧跟着 profile 的选择
            ProfileProxyRow(profile: site.profile)
        } header: {
            Text("存储与网络")
        } footer: {
            Text((sharesProfile
                 ? "填同一个名字的站点共用 cookie 和本地存储，适合同一家的几个域名。"
                 : "默认每个站点一份独立存储，登录状态互不可见。")
                 + "\n网络代理跟着 profile 走：共用 profile 的站点也共用同一个代理。")
        }
        .onChange(of: sharesProfile) { _, _ in applyProfile() }
        .onChange(of: profileText) { _, _ in applyProfile() }
    }

    private func applyProfile() {
        let trimmed = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (sharesProfile && !trimmed.isEmpty) ? trimmed : site.id.uuidString
        guard site.profile != value else { return }
        site.profile = value
    }
}
