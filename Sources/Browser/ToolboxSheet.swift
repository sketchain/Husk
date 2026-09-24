import SwiftUI

/// 手势唤出的工具箱。**原生 sheet**，不是自绘浮层。
///
/// 改掉的毛病：原来那版自己画圆角和毛玻璃，圆角半径和屏幕圆角对不齐，
/// 而且只给了一个固定 detent——能往下拖走，往上拖没反应。
///
/// 现在是 `[.medium, .large]` 两档：
/// - 半屏档在 iOS 26 下就是一张悬浮的玻璃卡片，圆角、边距、材质全是系统的；
///   底下的网页还能继续点（`presentationBackgroundInteraction`）。
/// - 内容本身是一个 `Form`，在半屏档滚到顶再往上拖就自然升到大档，
///   下半截直接就是本站设置——不用再点一下"本站设置"跳新页面。
///
/// 刻意**不再**设 `presentationBackground` / `presentationCornerRadius`：
/// 那两个是用来覆盖系统外观的，而现在想要的恰恰是系统外观。
struct ToolboxSheet: View {
    let session: WebSession
    /// 临时站点（husk://open?url=）不写回配置，所以要知道能不能持久化
    let canPersist: Bool
    let onExitToLibrary: () -> Void

    @Environment(SiteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// 由浏览页持有：拉到大档时浏览页要把灵动岛进度环藏起来，见 `BrowserScreen`
    @Binding var detent: PresentationDetent
    @State private var copied = false

    var body: some View {
        Form {
            headerSection
            actionSection
            urlSection
            librarySection
            if canPersist {
                SiteSettingsSections(site: siteBinding, commit: { store.update(session.site) })
            } else {
                adHocSection
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // 半屏档下网页还能继续滚、继续点
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .tint(Theme.accent)
    }

    /// 改动实时落到会话上（当前页面立刻跟着变），写盘交给 `commit`
    private var siteBinding: Binding<Site> {
        Binding(get: { session.site }, set: { session.site = $0 })
    }

    // MARK: - 头部

    private var headerSection: some View {
        Section {
            VStack(spacing: 3) {
                Text(session.pageTitle?.isEmpty == false ? session.pageTitle! : session.site.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.site.displayHost)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 动作

    private var actionSection: some View {
        Section {
            // 几块玻璃挨在一起要装进同一个容器里：玻璃不该去采样玻璃，
            // 容器会把它们当成一整块来算折射。
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 10) {
                    toolButton("刷新", "arrow.clockwise") { session.reload(); dismiss() }
                    toolButton("站点首页", "house") { session.goHome(); dismiss() }
                    shareButton
                    toolButton("Safari", "safari") { session.openInSafari(); dismiss() }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        }
    }

    private func toolButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            toolLabel(title, symbol)
        }
        .buttonStyle(.plain)
    }

    private var shareButton: some View {
        ShareLink(item: session.shareURL) {
            toolLabel("分享", "square.and.arrow.up")
        }
        .buttonStyle(.plain)
    }

    private func toolLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 52, height: 52)
                .glassEffect(.regular.interactive(), in: .circle)
            Text(title)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - 当前地址

    private var urlSection: some View {
        Section {
            Button {
                session.copyCurrentURL()
                Haptics.success()
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation { copied = false }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "link")
                        .foregroundStyle(copied ? .green : Theme.secondaryText)
                    Text(copied ? "已复制" : session.shareURL.absoluteString)
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var librarySection: some View {
        Section {
            Button {
                dismiss()
                onExitToLibrary()
            } label: {
                Label("返回列表", systemImage: "square.grid.2x2")
            }
        }
    }

    private var adHocSection: some View {
        Section {
            Label("临时站点，配置改不了也存不下", systemImage: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            Text("从 husk://open?url= 打开的地址不在站点列表里。想长期用它，先在列表里加一个站点。")
        }
    }
}
