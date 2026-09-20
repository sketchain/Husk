import SwiftUI
import UniformTypeIdentifiers

/// 全局设置。
struct GlobalSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SiteStore.self) private var store
    @Environment(IconStore.self) private var icons

    @State private var exportFile: ExportedFile?
    @State private var importing = false
    @State private var pendingImport: HuskLibrary?
    @State private var importConflicts: [Site] = []
    @State private var importSettings = false
    @State private var notice: String?

    var body: some View {
        // @Environment 拿到的 Observable 要绑到 Toggle/Slider 上，得先过一道 @Bindable。
        // 刻意换个名字而不是 shadow 掉 store，免得读代码时分不清哪个是哪个。
        @Bindable var bindable = store

        Form {
            // 传 $bindable（也就是 Bindable<SiteStore> 本身），不是它包着的值
            gestureSection($bindable)
            defaultsSection($bindable)
            iconSection($bindable)
            transferSection
            storageSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            handleImportPick(result)
        }
        .alert("有 \(importConflicts.count) 个站点 id 已经存在", isPresented: conflictBinding) {
            Button("覆盖已有") { finishImport(strategy: .overwrite) }
            Button("都留着（新建副本）") { finishImport(strategy: .duplicate) }
            Button("跳过重复的") { finishImport(strategy: .skip) }
            Button("取消", role: .cancel) { pendingImport = nil; importConflicts = [] }
        } message: {
            Text(importConflicts.prefix(5).map(\.name).joined(separator: "、"))
        }
        .overlay(alignment: .bottom) { noticeToast }
    }

    // MARK: - 手势

    private func gestureSection(_ bindable: Bindable<SiteStore>) -> some View {
        Section {
            Toggle("双指下滑", isOn: bindable.settings.gestures.twoFingerSwipeDown)
            Toggle("底边上滑", isOn: bindable.settings.gestures.bottomEdgeSwipeUp)
            Toggle("三指点按", isOn: bindable.settings.gestures.threeFingerTap)
            Toggle("双指长按", isOn: bindable.settings.gestures.twoFingerLongPress)
            if !store.settings.gestures.anyEnabled {
                Label("全关了的话，浏览页右下角会出现一个小按钮兜底", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("唤出工具箱")
        } footer: {
            Text("刻意没有单指边缘滑（撞前进后退）和单指长按（撞选中文字、链接预览）。")
        }
    }

    // MARK: - 新建默认值

    private func defaultsSection(_ bindable: Bindable<SiteStore>) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("缩放")
                    Spacer()
                    Text("\(Int((store.settings.newSiteDefaults.zoom * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
                Slider(value: bindable.settings.newSiteDefaults.zoom, in: Site.zoomRange, step: 0.05)
            }
            Picker("外链", selection: bindable.settings.newSiteDefaults.externalLinkPolicy) {
                ForEach(ExternalLinkPolicy.allCases) { Text($0.title).tag($0) }
            }
            Picker("UA", selection: bindable.settings.newSiteDefaults.userAgent) {
                ForEach(UserAgentPreset.allCases) { preset in
                    Text(preset.title).tag(preset.value)
                }
            }
            Toggle("每个新站点独立存储", isOn: bindable.settings.newSiteDefaults.isolateStoragePerSite)
        } header: {
            Text("新建站点的默认值")
        } footer: {
            Text("只影响之后新建的站点，已有的不动。")
        }
    }

    private func iconSection(_ bindable: Bindable<SiteStore>) -> some View {
        Section {
            Toggle("允许回退到 Google favicon 服务", isOn: bindable.settings.allowGoogleFaviconFallback)
        } header: {
            Text("图标")
        } footer: {
            Text("站点自己没提供图标时才会用到，会把域名发给 Google。关掉就只用首字母占位图。")
        }
    }

    // MARK: - 导入导出

    private var transferSection: some View {
        Section {
            Button {
                exportConfig()
            } label: {
                Label("导出配置（JSON）", systemImage: "square.and.arrow.up")
            }
            Button {
                importing = true
            } label: {
                Label("从文件导入", systemImage: "square.and.arrow.down")
            }
            Toggle("导入时一并覆盖全局设置", isOn: $importSettings)
            Button {
                exportAllWebClips()
            } label: {
                Label("导出全部站点的 Web Clip", systemImage: "square.grid.2x2")
            }
            .disabled(store.sites.isEmpty)
        } header: {
            Text("配置")
        } footer: {
            Text("profile 里的登录状态在沙盒里，删 app 就没了，配置本身导出来至少能留住。")
        }
    }

    private var storageSection: some View {
        Section {
            NavigationLink {
                StorageMaintenanceView()
            } label: {
                Label("存储管理", systemImage: "internaldrive")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("站点数", value: "\(store.sites.count)")
            LabeledContent("URL Scheme", value: "husk://open?id=…")
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("Husk · 明确不做多标签、书签、历史、广告拦截、下载管理、阅读模式。")
        }
    }

    // MARK: - 动作

    private var conflictBinding: Binding<Bool> {
        Binding(get: { !importConflicts.isEmpty }, set: { if !$0 { importConflicts = [] } })
    }

    private func exportConfig() {
        guard let url = try? store.exportFile() else {
            showNotice("导出失败")
            return
        }
        exportFile = ExportedFile(url: url)
    }

    private func exportAllWebClips() {
        guard let url = try? WebClipBuilder.writeProfile(
            for: store.sites,
            iconProvider: { icons.pngData(for: $0) },
            fileName: "Husk-\(SiteStore.fileStamp()).mobileconfig"
        ) else {
            showNotice("Web Clip 生成失败")
            return
        }
        exportFile = ExportedFile(url: url)
    }

    private func handleImportPick(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        // 文件在 app 沙盒外，必须开安全作用域才读得到
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let library = try? store.parseImport(data)
        else {
            showNotice("这个文件读不出来")
            return
        }

        let conflicts = store.conflicts(in: library)
        pendingImport = library
        if conflicts.isEmpty {
            finishImport(strategy: .skip)
        } else {
            importConflicts = conflicts
        }
    }

    private func finishImport(strategy: SiteStore.ImportStrategy) {
        guard let library = pendingImport else { return }
        let result = store.importLibrary(library, strategy: strategy, includeSettings: importSettings)
        pendingImport = nil
        importConflicts = []
        var parts: [String] = []
        if result.added > 0 { parts.append("新增 \(result.added)") }
        if result.overwritten > 0 { parts.append("覆盖 \(result.overwritten)") }
        if result.duplicated > 0 { parts.append("副本 \(result.duplicated)") }
        if result.skipped > 0 { parts.append("跳过 \(result.skipped)") }
        showNotice(parts.isEmpty ? "没有可导入的站点" : parts.joined(separator: "，"))
    }

    private func showNotice(_ message: String) {
        withAnimation { notice = message }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { notice = nil }
        }
    }

    @ViewBuilder
    private var noticeToast: some View {
        if let notice {
            Text(notice)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
    }
}
