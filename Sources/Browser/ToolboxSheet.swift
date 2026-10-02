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
    @State private var addressText = ""
    @State private var addressError: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        Form {
            actionSection
            navigationSection
            if canPersist {
                SiteSettingsSections(site: siteBinding, commit: { store.update(session.site) })
            } else {
                adHocSection
            }
        }
        // 段间距收紧、顶部留白去掉：半屏档要一直露出完整的缩放滑块，
        // 不然它只露半截，想拖还得先把 sheet 往上拉
        .listSectionSpacing(.compact)
        .contentMargins(.top, 14, for: .scrollContent)
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

    // MARK: - 头部 + 动作

    /// 标题和四个按钮放进同一个 section：原来各占一组，光是组间距和标题行就吃掉了
    /// 小半个半屏档。
    private var actionSection: some View {
        Section {
            VStack(spacing: 10) {
                VStack(spacing: 1) {
                    Text(session.pageTitle?.isEmpty == false ? session.pageTitle! : session.site.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(session.site.displayHost)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
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
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
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
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
            Text(title)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - 地址栏 + 返回列表

    /// 地址栏和"返回列表"同组两行，省一份组间距。
    private var navigationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(Theme.secondaryText)
                    TextField("地址，或以 / 开头的站内路径", text: $addressText)
                        .font(.footnote)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit(submitAddress)
                    if addressFocused {
                        if !addressText.isEmpty {
                            Button {
                                addressText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("清空")
                        }
                    } else {
                        copyButton
                    }
                }
                if let addressError {
                    Text(addressError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .onAppear { addressText = session.shareURL.absoluteString }
            // 页面自己跳转了就跟上；正在编辑时不抢用户的输入
            .onChange(of: session.shareURL) { _, url in
                if !addressFocused { addressText = url.absoluteString }
            }
            .onChange(of: addressFocused) { _, focused in
                // 没提交就退出编辑：还原成当前地址，别留一个看起来像已生效的半截地址。
                // 提交失败时例外——留着那串字和报错，方便接着改
                if !focused, addressError == nil { addressText = session.shareURL.absoluteString }
            }
            .onChange(of: addressText) { _, _ in addressError = nil }

            Button {
                dismiss()
                onExitToLibrary()
            } label: {
                Label("返回列表", systemImage: "square.grid.2x2")
            }
        } footer: {
            if addressFocused {
                Text("外站地址按本站的外链规则判定，该交给 Safari 的照样交给 Safari。")
            }
        }
    }

    private var copyButton: some View {
        Button {
            session.copyCurrentURL()
            Haptics.success()
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .foregroundStyle(copied ? .green : Theme.secondaryText)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(copied ? "已复制" : "复制地址")
    }

    private func submitAddress() {
        switch session.navigate(to: addressText) {
        case .loading, .handedOff:
            Haptics.tap()
            addressFocused = false
            dismiss()
        case .invalid:
            Haptics.warning()
            addressError = "不像是个地址"
            // onSubmit 会收起键盘，留在输入框里方便直接改
            addressFocused = true
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
