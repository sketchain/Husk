import SwiftUI

/// 首页：站点网格。
///
/// 刻意不是 `List`，也不是呆板的九宫格——深色底、大圆角图标、按压回弹，
/// 滚动时大标题收成一条窄栏，搜索靠下拉唤出、不常驻。
struct HomeScreen: View {
    @Environment(SiteStore.self) var store
    @Environment(IconStore.self) var icons

    let onOpen: (Site) -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    @State private var editingSite: Site?
    @State private var creatingSite = false
    @State private var showSettings = false
    @State var pendingDeletion: Site?
    @State var webClipExport: ExportedFile?
    @State var copiedNotice: String?

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 14)]

    private var filtered: [Site] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.sites }
        return store.sites.filter {
            $0.name.lowercased().contains(query) || $0.displayHost.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            content
            compactBar
            toast
        }
        .background(Theme.background)
        .sheet(isPresented: $creatingSite) { editorSheet(site: nil) }
        .sheet(item: $editingSite) { site in editorSheet(site: site) }
        .sheet(isPresented: $showSettings) {
            NavigationStack { GlobalSettingsView() }
        }
        .sheet(item: $webClipExport) { file in
            ShareSheet(items: [file.url])
        }
        .alert("删除「\(pendingDeletion?.name ?? "")」？", isPresented: deletionBinding) {
            Button("删除站点", role: .destructive) { confirmDeletion(clearStorage: false) }
            Button("删除并清除存储", role: .destructive) { confirmDeletion(clearStorage: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「删除站点」只是从列表移除，这个 profile 的 cookie 和本地存储还留在设备上，之后可以在设置里做孤儿清理。")
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

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isSearching {
                    PullDownSearchField(text: $searchText, focused: $searchFocused) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isSearching = false }
                    }
                }

                largeTitle

                if store.sites.isEmpty {
                    emptyState
                } else if filtered.isEmpty {
                    noMatches
                } else {
                    grid
                }
            }
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        // iOS 18 的 onScrollGeometryChange：拿滚动偏移不用再套 GeometryReader + PreferenceKey
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scrollOffset = offset
            // 往下拽过头就把搜索框拉出来，松手也留着
            if offset < -58, !isSearching {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isSearching = true }
                searchFocused = true
                Haptics.tap()
            }
        }
    }

    private var largeTitle: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Husk")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(store.sites.isEmpty ? "还没有站点" : "\(store.sites.count) 个站点")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            headerButtons
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 18)
        // 往上滚的时候大标题缩小淡出，交给顶部那条窄栏
        .opacity(1 - collapse)
        .scaleEffect(1 - collapse * 0.12, anchor: .topLeading)
        // opacity 为 0 的视图在 SwiftUI 里照样能点，不关掉的话会和窄栏上的按钮重叠
        .allowsHitTesting(collapse < 0.5)
    }

    /// 大标题的收起进度，0 = 完全展开，1 = 收完
    private var collapse: CGFloat {
        min(max(scrollOffset, 0) / 44, 1)
    }

    private var headerButtons: some View {
        HStack(spacing: 14) {
            iconButton("magnifyingglass") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isSearching = true }
                searchFocused = true
            }
            iconButton("gearshape") { showSettings = true }
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(SpringyPressStyle())
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(filtered) { site in
                SiteTile(site: site, image: icons.image(for: site)) {
                    Haptics.tap()
                    onOpen(site)
                }
                .contextMenu { menu(for: site) }
                .onAppear { icons.prepare(for: site, settings: store.settings) }
            }
            if searchText.isEmpty {
                AddSiteTile { creatingSite = true }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func menu(for site: Site) -> some View {
        Button { editingSite = site } label: { Label("编辑", systemImage: "pencil") }
        Button { store.moveToFront(id: site.id) } label: { Label("移到最前", systemImage: "arrow.up.to.line") }
        Button {
            UIPasteboard.general.string = DeepLink.share(site: site).absoluteString
            showToast("husk:// 链接已复制")
        } label: {
            Label("复制 husk:// 链接", systemImage: "link")
        }
        Button { exportWebClip(for: site) } label: { Label("导出 Web Clip", systemImage: "square.and.arrow.down") }
        Divider()
        Button(role: .destructive) { pendingDeletion = site } label: { Label("删除", systemImage: "trash") }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.secondaryText)
            Text("把常用网站加进来")
                .font(.headline)
            Text("每个站点有自己的缩放、UA 和存储空间，互不打扰。")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("添加第一个站点") { creatingSite = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 60)
    }

    private var noMatches: some View {
        Text("没有匹配「\(searchText)」的站点")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
    }

    // MARK: - 顶栏与提示

    private var compactBar: some View {
        let progress = min(max(scrollOffset - 26, 0) / 34, 1)
        return HStack {
            Text("Husk").font(.headline)
            Spacer()
            headerButtons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // 只让毛玻璃底铺到状态栏上去，文字本身留在安全区内。
        // 直接给整个 HStack 加 .ignoresSafeArea 的话，标题会跑到灵动岛底下。
        .background {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .opacity(progress)
        .allowsHitTesting(progress > 0.9)
    }

    @ViewBuilder
    private var toast: some View {
        if let copiedNotice {
            Text(copiedNotice)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 34)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
