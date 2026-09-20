import SwiftUI

/// 手势唤出的工具箱。半透明浮层，用 sheet 的 detent 实现——
/// 这样下拉关闭、跟手拖动这些都是系统给的，不用自己写。
struct ToolboxSheet: View {
    let session: WebSession
    /// 临时站点（husk://open?url=）不写回配置，所以要知道能不能持久化
    let canPersist: Bool
    let onCommitZoom: (Double) -> Void
    let onOpenSiteSettings: () -> Void
    let onExitToLibrary: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 22) {
            header
            zoomSection
            actionRow
            urlRow
            footerRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .presentationDetents([.height(408)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(28)
        .tint(Theme.accent)
    }

    private var header: some View {
        VStack(spacing: 3) {
            Text(session.pageTitle?.isEmpty == false ? session.pageTitle! : session.site.name)
                .font(.headline)
                .lineLimit(1)
            Text(session.site.displayHost)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 缩放

    private var zoomSection: some View {
        VStack(spacing: 8) {
            HStack {
                Label("缩放", systemImage: "textformat.size")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((session.site.zoom * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 12) {
                Text("50%").font(.caption2).foregroundStyle(Theme.secondaryText)
                Slider(
                    value: Binding(
                        get: { session.site.zoom },
                        // 拖动时实时生效：直接写 pageZoom，不等松手
                        set: { session.applyZoom($0) }
                    ),
                    in: Site.zoomRange,
                    step: 0.05,
                    onEditingChanged: { editing in
                        // 松手才写回配置，免得拖一次滑块写几十遍盘
                        if !editing { onCommitZoom(session.site.zoom) }
                    }
                )
                Text("200%").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: 动作

    private var actionRow: some View {
        HStack(spacing: 10) {
            toolButton("刷新", "arrow.clockwise") { session.reload(); dismiss() }
            toolButton("站点首页", "house") { session.goHome(); dismiss() }
            shareButton
            toolButton("Safari", "safari") { session.openInSafari(); dismiss() }
        }
    }

    private func toolButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 50, height: 50)
                    .background(Color.white.opacity(0.09), in: Circle())
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SpringyPressStyle())
        .foregroundStyle(Theme.primaryText)
    }

    private var shareButton: some View {
        ShareLink(item: session.shareURL) {
            VStack(spacing: 7) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 50, height: 50)
                    .background(Color.white.opacity(0.09), in: Circle())
                Text("分享").font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Theme.primaryText)
    }

    // MARK: 当前地址

    private var urlRow: some View {
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
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var footerRow: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
                onExitToLibrary()
            } label: {
                Label("返回列表", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
                onOpenSiteSettings()
            } label: {
                Label("本站设置", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canPersist)
            .opacity(canPersist ? 1 : 0.4)
        }
        .foregroundStyle(Theme.primaryText)
    }
}
