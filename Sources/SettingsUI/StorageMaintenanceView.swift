import SwiftUI

/// 存储管理：按站点清、全部清、孤儿清理。
struct StorageMaintenanceView: View {
    @Environment(SiteStore.self) private var store

    @State private var orphans: [UUID] = []
    @State private var scanning = false
    @State private var busy = false
    @State private var notice: String?
    @State private var confirmClearAll = false

    /// profile 名 → 用这个 profile 的站点。共享存储的站点要一起显示，
    /// 不然用户会以为清了 A 站，结果 B 站也跟着退登录了。
    ///
    /// 用结构体而不是元组：KeyPath 取不了元组成员，`ForEach(..., id: \.profile)` 编不过。
    private struct ProfileGroup: Identifiable {
        let profile: String
        let sites: [Site]
        var id: String { profile }
    }

    private var profileGroups: [ProfileGroup] {
        Dictionary(grouping: store.sites, by: \.profile)
            .map { ProfileGroup(profile: $0.key, sites: $0.value.sorted { $0.name < $1.name }) }
            .sorted { ($0.sites.first?.name ?? "") < ($1.sites.first?.name ?? "") }
    }

    var body: some View {
        Form {
            Section {
                ForEach(profileGroups) { group in
                    Button(role: .destructive) {
                        clear(profile: group.profile)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.sites.map(\.name).joined(separator: "、"))
                                .foregroundStyle(.primary)
                            Text(group.sites.count > 1 ? "共享存储的 \(group.sites.count) 个站点" : "独立存储")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                if store.sites.isEmpty {
                    Text("还没有站点").foregroundStyle(Theme.secondaryText)
                }
            } header: {
                Text("按站点清除")
            } footer: {
                Text("点一下就清掉那份 cookie / localStorage / 缓存。站点页面开着的时候清不掉，先回列表。")
            }

            Section {
                Button {
                    Task { await scanOrphans() }
                } label: {
                    HStack {
                        Label("扫描孤儿存储", systemImage: "magnifyingglass")
                        Spacer()
                        if scanning { ProgressView() }
                    }
                }
                if !orphans.isEmpty {
                    Text("发现 \(orphans.count) 份没有站点在用的数据")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(role: .destructive) {
                        Task { await cleanOrphans() }
                    } label: {
                        Label("清掉这 \(orphans.count) 份", systemImage: "trash")
                    }
                }
            } header: {
                Text("孤儿清理")
            } footer: {
                Text("删站点时选了「只删列表」，数据就会留在磁盘上变成孤儿。这里查的是 WebKit 实际存在的 store 标识，不是靠猜。")
            }

            Section {
                Button(role: .destructive) {
                    confirmClearAll = true
                } label: {
                    Label("清除全部存储", systemImage: "trash.fill")
                }
            } footer: {
                Text("每一份具名存储都会删掉，默认存储（临时站点用的）会被清空——它按设计就是删不掉的，只能清内容。")
            }
        }
        .navigationTitle("存储管理")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .alert("清除全部存储？", isPresented: $confirmClearAll) {
            Button("全部清除", role: .destructive) { Task { await clearAll() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有站点的登录状态都会没。站点配置本身不受影响。")
        }
        .overlay(alignment: .bottom) { noticeToast }
        .task { await scanOrphans() }
    }

    // MARK: - 动作

    private func clear(profile: String) {
        busy = true
        Task {
            do {
                try await WebsiteDataStoreManager.shared.removeProfile(profile)
                show("已清除")
            } catch {
                show("清不掉：这个站点可能还开着")
            }
            busy = false
            await scanOrphans()
        }
    }

    private func scanOrphans() async {
        scanning = true
        orphans = await WebsiteDataStoreManager.shared.orphanIdentifiers(knownProfiles: store.knownProfiles)
        scanning = false
    }

    private func cleanOrphans() async {
        busy = true
        let result = await WebsiteDataStoreManager.shared.removeOrphans(knownProfiles: store.knownProfiles)
        busy = false
        show(result.failed == 0 ? "清掉了 \(result.removed) 份" : "清掉 \(result.removed) 份，\(result.failed) 份还被占用")
        await scanOrphans()
    }

    private func clearAll() async {
        busy = true
        let removed = await WebsiteDataStoreManager.shared.clearEverything()
        busy = false
        show("清掉了 \(removed) 份具名存储，默认存储已清空")
        await scanOrphans()
    }

    private func show(_ message: String) {
        Haptics.success()
        withAnimation { notice = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { notice = nil }
        }
    }

    @ViewBuilder
    private var noticeToast: some View {
        if let notice {
            GlassToast(text: notice).padding(.bottom, 24)
        }
    }
}
