import SwiftUI

/// 站点网格本体。站点 tab 和搜索 tab 共用，区别只是传进来的 `sites` 不同。
///
/// 长按菜单、编辑面板、删除确认、"存图标到相册"这些都归它管——
/// 两个 tab 各写一份的话迟早走样。
struct SiteGridView: View {
    @Environment(SiteStore.self) private var store
    @Environment(IconStore.self) private var icons

    let sites: [Site]
    /// 搜索结果为空时的文案；nil 表示用站点 tab 的空状态
    var emptyQuery: String? = nil
    @Binding var creating: Bool
    let onOpen: (Site) -> Void

    @State private var editingSite: Site?
    @State private var pendingDeletion: Site?
    @State private var notice: String?

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 14)]

    var body: some View {
        ScrollView {
            if sites.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(sites) { site in
                        SiteTile(site: site, image: icons.image(for: site)) {
                            Haptics.tap()
                            onOpen(site)
                        }
                        .contextMenu { menu(for: site) }
                        .onAppear { icons.prepare(for: site, settings: store.settings) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .background(backdrop)
        .sheet(isPresented: $creating) { editorSheet(site: nil) }
        .sheet(item: $editingSite) { site in editorSheet(site: site) }
        .alert("删除「\(pendingDeletion?.name ?? "")」？", isPresented: deletionBinding) {
            Button("删除站点", role: .destructive) { confirmDeletion(clearStorage: false) }
            Button("删除并清除存储", role: .destructive) { confirmDeletion(clearStorage: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「删除站点」只是从列表移除，这个 profile 的 cookie 和本地存储还留在设备上，之后可以在设置里做孤儿清理。")
        }
        .overlay(alignment: .bottom) {
            if let notice { GlassToast(text: notice).padding(.bottom, 16) }
        }
    }

    // MARK: - 背景

    private var backdrop: some View {
        ZStack {
            Theme.background
            // 顶部一层很淡的辉光，纯黑底看着太"终端"了
            RadialGradient(
                colors: [Theme.accent.opacity(0.20), .clear],
                center: .init(x: 0.5, y: -0.05),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 长按菜单

    @ViewBuilder
    private func menu(for site: Site) -> some View {
        Button { editingSite = site } label: { Label("编辑", systemImage: "pencil") }
        Button { store.moveToFront(id: site.id) } label: { Label("移到最前", systemImage: "arrow.up.to.line") }
        Button {
            UIPasteboard.general.string = DeepLink.share(site: site).absoluteString
            showNotice("husk:// 链接已复制")
        } label: {
            Label("复制 husk:// 链接", systemImage: "link")
        }
        Button { saveIconToPhotos(site) } label: {
            Label("存储图标到相册", systemImage: "square.and.arrow.down")
        }
        Divider()
        Button(role: .destructive) { pendingDeletion = site } label: { Label("删除", systemImage: "trash") }
    }

    // MARK: - 空状态

    @ViewBuilder
    private var emptyState: some View {
        if let emptyQuery {
            ContentUnavailableView.search(text: emptyQuery)
                .padding(.top, 40)
        } else {
            ContentUnavailableView {
                Label("还没有站点", systemImage: "square.grid.2x2")
            } description: {
                Text("每个站点有自己的缩放、UA 和存储空间，互不打扰。")
            } actions: {
                Button("添加第一个站点") { creating = true }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
            }
            .padding(.top, 40)
        }
    }

    // MARK: - 动作

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    @ViewBuilder
    private func editorSheet(site: Site?) -> some View {
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
            linkScope: defaults.linkScope,
            // 关掉"每个新站点独立存储"的话，新站默认落到同一个共享 profile 上
            profile: defaults.isolateStoragePerSite ? nil : Site.sharedProfile
        )
    }

    @MainActor
    private func confirmDeletion(clearStorage: Bool) {
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

    @MainActor
    private func saveIconToPhotos(_ site: Site) {
        guard let png = icons.homeScreenIconPNG(for: site) else {
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
    private func showNotice(_ message: String) {
        Haptics.success()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { notice = message }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { notice = nil }
        }
    }
}
