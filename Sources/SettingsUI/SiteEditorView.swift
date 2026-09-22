import PhotosUI
import SwiftUI

/// 单个站点的设置。新建和编辑共用。
///
/// 只管"名字 / 地址 / 图标"和维护动作；缩放、UA、外链、存储那四组在
/// `SiteSettingsSections` 里，因为工具箱 sheet 的大档位也要用同一份。
struct SiteEditorView: View {
    enum Mode { case create, edit }

    @Environment(\.dismiss) private var dismiss
    @Environment(SiteStore.self) private var store
    @Environment(IconStore.self) private var icons

    @State private var draft: Site
    @State private var urlText: String
    @State private var photoItem: PhotosPickerItem?
    @State private var notice: String?

    let mode: Mode
    let onSave: (Site) -> Void

    init(site: Site, mode: Mode, onSave: @escaping (Site) -> Void) {
        _draft = State(initialValue: site)
        _urlText = State(initialValue: mode == .create ? "" : site.url.absoluteString)
        self.mode = mode
        self.onSave = onSave
    }

    var body: some View {
        Form {
            basicsSection
            iconSection
            // 草稿在保存时才写盘，所以 commit 是空操作
            SiteSettingsSections(site: $draft, commit: {})
            if mode == .edit { maintenanceSection }
        }
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
        .onChange(of: photoItem) { _, item in loadPickedImage(item) }
        .overlay(alignment: .bottom) {
            if let notice { GlassToast(text: notice).padding(.bottom, 16) }
        }
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

    @MainActor
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

    // MARK: - 维护

    private var maintenanceSection: some View {
        Section("维护") {
            Button {
                saveIconToPhotos()
            } label: {
                Label("存储图标到相册", systemImage: "square.and.arrow.down")
            }
            Button(role: .destructive) {
                clearStorage()
            } label: {
                Label("清除本站存储", systemImage: "trash")
            }
        }
    }

    // MARK: - 动作

    private func save() {
        guard let url = Site.normalizeInput(urlText) else { return }
        draft.url = url
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = Site.normalizedHost(of: url) ?? "站点"
        }
        onSave(draft)
        dismiss()
    }

    @MainActor
    private func saveIconToPhotos() {
        guard let png = icons.homeScreenIconPNG(for: draft) else {
            showNotice("生成图标失败")
            return
        }
        Task {
            do {
                try await PhotoLibrarySaver.save(png: png)
                showNotice("已存进相册，1024×1024")
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func clearStorage() {
        let profile = draft.profile
        showNotice("正在清除…")
        Task {
            do {
                try await WebsiteDataStoreManager.shared.removeProfile(profile)
                showNotice("已清除。下次打开这个站点会是全新状态。")
            } catch {
                // 站点页面还开着的时候会走到这里：store 还被 WebView 抓着
                showNotice("清除失败：这个站点可能还开着，回到列表再试。")
            }
        }
    }

    @MainActor
    private func showNotice(_ message: String) {
        withAnimation { notice = message }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation { notice = nil }
        }
    }
}
