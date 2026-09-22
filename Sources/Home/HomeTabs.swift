import SwiftUI

enum HomeTab: Hashable {
    case sites
    case settings
    case search
}

/// 首页。iOS 26 的系统 TabView：站点 / 设置两个常规 tab + 一个 search role 的 tab。
///
/// 三件事值得写下来：
/// - **设置从弹窗变成 tab**。原来是 `.sheet` 盖一层，翻两下就得关掉再开；
///   放进 tab 之后它和站点列表是平级的，来回切没有成本。
/// - **搜索用 `role: .search`**。iOS 26 下这个 tab 不跟其他 tab 挤在一起，
///   而是单独一颗圆形按钮落在右边，点下去整条 tab bar 变成搜索框。
///   它**必须排在最后**：排第一的话进 app 就是展开的搜索框。
/// - **"继续上次"是 `tabViewBottomAccessory`**。没有上次记录时**连 modifier 一起不加**，
///   而不是在它的 content 闭包里返回空视图——accessory 的内容在"有"和"没有"之间跳
///   会撞上 `_bottomAccessory.displayStyle` 的断言崩溃（FB18479195）。
struct HomeTabs: View {
    @Environment(SiteStore.self) private var store
    @Environment(Router.self) private var router

    @State private var selection: HomeTab = .sites
    @State private var searchText = ""

    var body: some View {
        if let last = store.lastOpenedSite {
            tabs.tabViewBottomAccessory {
                ContinueAccessory(site: last) { open(last) }
            }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("站点", systemImage: "square.grid.2x2", value: HomeTab.sites) {
                SiteLibraryScreen(onOpen: open)
            }

            Tab("设置", systemImage: "gearshape", value: HomeTab.settings) {
                NavigationStack { GlobalSettingsView() }
            }

            Tab("搜索", systemImage: "magnifyingglass", value: HomeTab.search, role: .search) {
                SiteSearchScreen(searchText: $searchText, onOpen: open)
            }
        }
        // 往下滚的时候 tab bar 收成一条，页面能多露出一点
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Theme.accent)
    }

    private func open(_ site: Site) {
        // 从首页点进去保留过渡动画；deep link / 快捷指令那两条路走 animated: false
        router.open(site, canPersist: true, animated: true)
        store.rememberLastOpened(site.id)
    }
}

/// 站点 tab。`+` 按在导航栏右上角，不再占网格里的一格。
private struct SiteLibraryScreen: View {
    @Environment(SiteStore.self) private var store
    let onOpen: (Site) -> Void

    @State private var creating = false

    var body: some View {
        NavigationStack {
            SiteGridView(sites: store.sites, creating: $creating, onOpen: onOpen)
                .navigationTitle("Husk")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("添加站点", systemImage: "plus") {
                            Haptics.tap()
                            creating = true
                        }
                    }
                }
        }
    }
}

/// 搜索 tab。内容和站点 tab 是同一个网格，只是喂给它过滤后的列表。
private struct SiteSearchScreen: View {
    @Environment(SiteStore.self) private var store
    @Binding var searchText: String
    let onOpen: (Site) -> Void

    @State private var creating = false

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filtered: [Site] {
        guard !query.isEmpty else { return store.sites }
        return store.sites.filter {
            $0.name.lowercased().contains(query) || $0.displayHost.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            SiteGridView(
                sites: filtered,
                emptyQuery: query.isEmpty ? nil : searchText,
                creating: $creating,
                onOpen: onOpen
            )
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索站点")
        }
    }
}
