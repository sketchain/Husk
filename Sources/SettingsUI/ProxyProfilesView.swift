import SwiftUI

/// 「设置 → 网络代理」：按 profile 列出来，每行点进去改那个 profile 的代理。
///
/// profile 在界面上本来只是站点里的一个字符串，没有自己的页面。这里第一次把它当成
/// 一个"东西"列出来，所以每一行都要说清楚**它是谁**：只有一个站点在用的，直接叫那个站点的名字；
/// 几个站点共用的，叫 profile 名并把站点列出来。
struct ProxyProfilesView: View {
    @Environment(SiteStore.self) private var store

    var body: some View {
        let descriptors = ProfileDescriptor.all(in: store)
        Form {
            Section {
                ForEach(descriptors.filter { !$0.sites.isEmpty || $0.isAdHoc }) { descriptor in
                    row(descriptor)
                }
            } header: {
                Text("存储 profile")
            } footer: {
                Text("代理挂在 profile 上，不挂在单个站点上：同一个 profile 的站点共用 cookie，也共用同一条网络出口。想让某个站点单独走代理，先在站点设置里给它一个独立的 profile。")
            }

            let orphans = descriptors.filter { $0.sites.isEmpty && !$0.isAdHoc }
            if !orphans.isEmpty {
                Section {
                    ForEach(orphans) { row($0) }
                        .onDelete { offsets in
                            for index in offsets { store.removeProxy(for: orphans[index].profile) }
                        }
                } header: {
                    Text("没有站点在用的配置")
                } footer: {
                    Text("站点删掉了或者换了 profile，代理配置还留着。左滑删除（连同 Keychain 里的密码）。")
                }
            }
        }
        .navigationTitle("网络代理")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ descriptor: ProfileDescriptor) -> some View {
        NavigationLink {
            ProfileProxyEditor(profile: descriptor.profile)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(descriptor.title)
                    Spacer()
                    Text(store.profileProxies[descriptor.profile]?.summary ?? "关闭")
                        .font(.caption)
                        .foregroundStyle(store.profileProxies[descriptor.profile]?.isEnabled == true ? Theme.accent : Theme.secondaryText)
                }
                if let subtitle = descriptor.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
    }
}

/// 全局设置里通往上面那页的一行
struct ProxySettingsEntry: View {
    @Environment(SiteStore.self) private var store

    var body: some View {
        Section {
            NavigationLink {
                ProxyProfilesView()
            } label: {
                LabeledContent {
                    Text(summary)
                } label: {
                    Label("网络代理", systemImage: "network.badge.shield.half.filled")
                }
            }
        } footer: {
            Text("代理按存储 profile 设置：共用同一个 profile 的站点走同一个代理。")
        }
    }

    private var summary: String {
        let count = store.profileProxies.values.filter(\.isEnabled).count
        return count == 0 ? "未启用" : "\(count) 个 profile"
    }
}

/// 站点设置「存储」分区里的一行：显示这个站点所在 profile 的代理状态，点开就地编辑。
///
/// 用 sheet 而不是 NavigationLink：这组设置也挂在工具箱 sheet 里，而工具箱刻意没有
/// NavigationStack（见 `ToolboxSheet`），push 不了。
struct ProfileProxyRow: View {
    let profile: String
    @Environment(SiteStore.self) private var store
    @State private var editing = false

    var body: some View {
        Button {
            editing = true
        } label: {
            LabeledContent {
                Text(store.profileProxies[profile]?.summary ?? "关闭")
                    .foregroundStyle(store.profileProxies[profile]?.isEnabled == true ? Theme.accent : Theme.secondaryText)
            } label: {
                Label("网络代理", systemImage: "network.badge.shield.half.filled")
            }
        }
        .tint(.primary)
        .sheet(isPresented: $editing) {
            NavigationStack {
                ProfileProxyEditor(profile: profile)
            }
            .tint(Theme.accent)
        }
    }
}

/// 一个 profile 在界面上叫什么、有谁在用
struct ProfileDescriptor: Identifiable, Hashable {
    let profile: String
    let sites: [Site]
    var id: String { profile }

    var isAdHoc: Bool { profile == Site.adHocProfile }

    var title: String {
        if isAdHoc { return "临时站点" }
        // 默认的"一站一个 profile"：profile 就是站点自己的 id，直接叫站点名
        if sites.count == 1, let only = sites.first, only.profile == only.id.uuidString { return only.name }
        if sites.isEmpty, UUID(uuidString: profile) != nil { return "已删除站点的 profile" }
        return profile
    }

    var subtitle: String? {
        if isAdHoc { return "所有从 husk://open?url= 打开的地址共用这一个" }
        if sites.count == 1, let only = sites.first, only.profile == only.id.uuidString { return "独立存储 · \(only.displayHost)" }
        if sites.isEmpty { return profile }
        return "\(sites.count) 个站点共用：" + sites.map(\.name).joined(separator: "、")
    }

    /// 在用的 profile + 临时站点那个 + 有代理配置但没人用的
    @MainActor
    static func all(in store: SiteStore) -> [ProfileDescriptor] {
        var grouped: [String: [Site]] = [:]
        for site in store.sites { grouped[site.profile, default: []].append(site) }
        var profiles = Array(grouped.keys)
        for profile in [Site.adHocProfile] + Array(store.profileProxies.keys) where grouped[profile] == nil {
            profiles.append(profile)
            grouped[profile] = []
        }
        // 按站点列表里第一次出现的顺序排，临时站点和孤儿排最后
        let order = Dictionary(store.sites.enumerated().map { ($0.element.profile, $0.offset) }, uniquingKeysWith: { Swift.min($0, $1) })
        return profiles
            .sorted { (order[$0] ?? .max, $0) < (order[$1] ?? .max, $1) }
            .map { ProfileDescriptor(profile: $0, sites: grouped[$0] ?? []) }
    }
}
