import PhotosUI
import SwiftUI

/// 单个站点的设置。新建和编辑共用。
struct SiteEditorView: View {
    enum Mode { case create, edit }

    @Environment(\.dismiss) private var dismiss
    @Environment(SiteStore.self) private var store
    @Environment(IconStore.self) private var icons

    @State private var draft: Site
    @State private var urlText: String
    @State private var uaSelection: UserAgentPreset?
    @State private var customUA: String
    @State private var sharesProfile: Bool
    @State private var profileText: String
    @State private var photoItem: PhotosPickerItem?
    @State private var webClipFile: ExportedFile?
    @State private var storageNotice: String?

    let mode: Mode
    let onSave: (Site) -> Void

    init(site: Site, mode: Mode, onSave: @escaping (Site) -> Void) {
        _draft = State(initialValue: site)
        _urlText = State(initialValue: mode == .create ? "" : site.url.absoluteString)
        let preset = UserAgentPreset.matching(site.userAgent)
        _uaSelection = State(initialValue: preset)
        _customUA = State(initialValue: preset == nil ? (site.userAgent ?? "") : "")
        _sharesProfile = State(initialValue: site.profile != site.id.uuidString)
        _profileText = State(initialValue: site.profile != site.id.uuidString ? site.profile : "")
        self.mode = mode
        self.onSave = onSave
    }

    var body: some View {
        Form {
            basicsSection
            iconSection
            zoomSection
            userAgentSection
            linkSection
            profileSection
            if mode == .edit { maintenanceSection }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(mode == .create ? "新建站点" : "站点设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }.disabled(!isValid)
            }
        }
        .sheet(item: $webClipFile) { file in ShareSheet(items: [file.url]) }
        .onChange(of: photoItem) { _, item in loadPickedImage(item) }
    }

    private var isValid: Bool { Site.normalizeInput(urlText) != nil }

    // MARK: - 基本

    private var basicsSection: some View {
        Section("基本") {
            TextField("名称", text: $draft.name)
            TextField("地址", text: $urlText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !urlText.isEmpty, !isValid {
                Label("地址看着不对，需要是 http(s) 的网址", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 图标

    private var iconSection: some View {
        Section("图标") {
            HStack(spacing: 14) {
                Image(uiImage: icons.image(for: draft))
                    .resizable()
                    .frame(width: 58, height: 58)
                    .clipShape(Theme.tileShape(15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(iconSourceTitle).font(.subheadline)
                    Text("抓不到就用首字母生成，缓存在 Application Support")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if icons.fetching.contains(draft.id) { ProgressView() }
            }

            Button {
                draft.iconSource = .automatic
                icons.invalidate(draft.id)
                icons.refresh(draft, settings: store.settings)
            } label: {
                Label("重新抓取", systemImage: "arrow.triangle.2.circlepath")
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("从相册选一张", systemImage: "photo")
            }

            Button {
                draft.iconSource = .monogram
                icons.invalidate(draft.id)
            } label: {
                Label("用首字母", systemImage: "textformat")
            }
        }
    }

    private var iconSourceTitle: String {
        switch draft.iconSource {
        case .automatic: "自动抓取"
        case .custom: "自选图片"
        case .monogram: "首字母"
        }
    }

    private func loadPickedImage(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else { return }
            if icons.setCustomImage(image, for: draft) {
                draft.iconSource = .custom
            }
        }
    }

    // MARK: - 缩放 / UA / 外链 / profile

    private var zoomSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("缩放")
                    Spacer()
                    Text("\(Int((draft.zoom * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
                Slider(value: $draft.zoom, in: Site.zoomRange, step: 0.05)
            }
        } footer: {
            Text("走 WKWebView 的 pageZoom，等价于给整页加 CSS zoom，不是改 viewport。")
        }
    }

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
    }

    private var linkSection: some View {
        Section {
            Picker("外链", selection: $draft.externalLinkPolicy) {
                ForEach(ExternalLinkPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Text(draft.externalLinkPolicy.subtitle)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        } header: {
            Text("外链行为")
        } footer: {
            Text("只对你点出来的主框架链接生效，iframe、重定向、资源请求一律不拦。")
        }
    }

    private var profileSection: some View {
        Section {
            Toggle("和其他站点共享存储", isOn: $sharesProfile)
            if sharesProfile {
                TextField("profile 名（相同即共享）", text: $profileText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("存储")
        } footer: {
            Text(sharesProfile
                 ? "填同一个名字的站点共用 cookie 和本地存储，适合同一家的几个域名。"
                 : "默认每个站点一份独立存储，登录状态互不可见。")
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button {
                exportWebClip()
            } label: {
                Label("导出 Web Clip", systemImage: "square.and.arrow.down")
            }
            Button(role: .destructive) {
                clearStorage()
            } label: {
                Label("清除本站存储", systemImage: "trash")
            }
            if let storageNotice {
                Text(storageNotice).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        } header: {
            Text("维护")
        }
    }

    // MARK: - 动作

    private func save() {
        guard let url = Site.normalizeInput(urlText) else { return }
        draft.url = url
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = Site.normalizedHost(of: url) ?? "站点"
        }
        draft.userAgent = uaSelection.map(\.value) ?? (customUA.isEmpty ? nil : customUA)
        let trimmedProfile = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.profile = (sharesProfile && !trimmedProfile.isEmpty) ? trimmedProfile : draft.id.uuidString
        onSave(draft)
        dismiss()
    }

    private func exportWebClip() {
        guard let url = try? WebClipBuilder.writeProfile(
            for: [draft],
            iconProvider: { icons.pngData(for: $0) },
            fileName: "\(WebClipBuilder.safeFileName(draft.name)).mobileconfig"
        ) else { return }
        webClipFile = ExportedFile(url: url)
    }

    private func clearStorage() {
        let profile = draft.profile
        storageNotice = "正在清除…"
        Task {
            do {
                try await WebsiteDataStoreManager.shared.removeProfile(profile)
                storageNotice = "已清除。下次打开这个站点会是全新状态。"
            } catch {
                // 站点页面还开着的时候会走到这里：store 还被 WebView 抓着
                storageNotice = "清除失败：这个站点可能还开着，回到列表再试。"
            }
        }
    }
}
