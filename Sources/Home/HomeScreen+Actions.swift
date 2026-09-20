import SwiftUI

extension HomeScreen {
    var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    @ViewBuilder
    func editorSheet(site: Site?) -> some View {
        NavigationStack {
            SiteEditorView(
                site: site ?? makeDraft(),
                mode: site == nil ? .create : .edit
            ) { updated in
                if site == nil {
                    store.add(updated)
                    icons.prepare(for: updated, settings: store.settings)
                } else {
                    store.update(updated)
                    // 名字或地址变了，图标要重新解析
                    icons.invalidate(updated.id)
                }
            }
        }
    }

    /// 新建站点时套用全局默认值
    private func makeDraft() -> Site {
        let defaults = store.settings.newSiteDefaults
        return Site(
            name: "",
            url: URL(string: "https://example.com")!,
            zoom: defaults.zoom,
            userAgent: defaults.userAgent,
            externalLinkPolicy: defaults.externalLinkPolicy,
            // 关掉"每个新站点独立存储"的话，新站默认落到同一个共享 profile 上
            profile: defaults.isolateStoragePerSite ? nil : Site.sharedProfile
        )
    }

    func confirmDeletion(clearStorage: Bool) {
        guard let site = pendingDeletion else { return }
        pendingDeletion = nil
        let profile = site.profile
        let stillUsed = store.sites.contains { $0.id != site.id && $0.profile == profile }

        store.delete(id: site.id)
        icons.forget(site.id)

        guard clearStorage, !stillUsed else { return }
        Task {
            // 先删站点再删 store：WebView 那边的引用已经随着页面关闭放掉了，
            // 这里 removeProfile 内部还会重试几次覆盖 dealloc 的延迟
            try? await WebsiteDataStoreManager.shared.removeProfile(profile)
        }
    }

    func exportWebClip(for site: Site) {
        do {
            let url = try WebClipBuilder.writeProfile(
                for: [site],
                iconProvider: { icons.pngData(for: $0) },
                fileName: "\(WebClipBuilder.safeFileName(site.name)).mobileconfig"
            )
            webClipExport = ExportedFile(url: url)
        } catch {
            showToast("Web Clip 生成失败")
        }
    }

    func showToast(_ message: String) {
        Haptics.success()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { copiedNotice = message }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation { copiedNotice = nil }
        }
    }
}

/// 用 `.sheet(item:)` 分享文件时的包装
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}
