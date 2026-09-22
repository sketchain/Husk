import SwiftUI

/// 实验室：在真机上验证能不能读到灵动岛的几何信息，并用一圈描边做可视化校准。
///
/// 它是「加载进度环绕灵动岛」的前期验证，本身不画进度环。要确认两件事：
/// 1. `UIScreen._exclusionArea` 在这台设备这个系统版本上读不读得到；
/// 2. 读到的矩形离系统画的黑胶囊有多远——差多少圆角、差多少外扩、差多少偏移。
///
/// 第 2 件事没法在代码里算，只能把描边画出来用眼睛对。所以页面下半部分全是滑块，
/// 描边挂在一个独立窗口上（`IslandOverlayController`），离开这一页也还在。
struct LabView: View {
    private var overlay: IslandOverlayController { .shared }

    @State private var diagnostics: IslandDiagnostics?
    @State private var notice: String?

    var body: some View {
        @Bindable var bindable = overlay

        Form {
            resultSection
            diagnosticsSection
            overlaySection($bindable)
            howToSection
        }
        .navigationTitle("实验室")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let notice { GlassToast(text: notice).padding(.bottom, 24) }
        }
        // 每次进页面重新探一次：探测没有副作用，而且方向变了结果就不一样
        .onAppear { probe() }
        // 滑块是连续变化的，统一在这儿落盘，省得给每个参数挂观察器
        .onChange(of: overlay.adjustments) { overlay.persistAdjustments() }
    }

    // MARK: - 结论

    @ViewBuilder
    private var resultSection: some View {
        Section {
            if let diagnostics {
                if let rect = diagnostics.exclusionRect {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("读到了")
                            Text(DynamicIslandProbe.format(rect))
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("没读到")
                            Text(diagnostics.failure ?? "原因不明")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            } else {
                Text("正在探测…").foregroundStyle(Theme.secondaryText)
            }

            Button {
                probe()
                show("已重新探测")
            } label: {
                Label("重新探测", systemImage: "arrow.clockwise")
            }

            Button {
                UIPasteboard.general.string = fullReport
                Haptics.success()
                show("整份报告已复制")
            } label: {
                Label("复制全部诊断信息", systemImage: "doc.on.doc")
            }
        } header: {
            Text("UIScreen._exclusionArea")
        } footer: {
            Text("公开 API 拿不到灵动岛的位置和尺寸，这个私有属性是已知唯一的来源。读出来的是**传感器避让区的外接矩形**，不保证和系统画的黑胶囊边缘完全重合，也不带圆角——差多少靠下面的描边对。")
        }
    }

    // MARK: - 原始信息

    @ViewBuilder
    private var diagnosticsSection: some View {
        if let diagnostics, !diagnostics.fields.isEmpty {
            Section {
                ForEach(diagnostics.fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                        Text(field.value)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("原始诊断信息")
            } footer: {
                Text("长按任一行可以单独选中复制；要整份贴回去用上面的「复制全部」。")
            }
        }
    }

    // MARK: - 可视化叠加

    private func overlaySection(_ bindable: Bindable<IslandOverlayController>) -> some View {
        Section {
            Toggle(
                "显示描边",
                isOn: Binding(get: { overlay.isVisible }, set: { overlay.setVisible($0) })
            )

            if overlay.baseIsEstimate {
                Label(
                    "基准矩形是**估计值**（126 × 37.33，距顶 11，水平居中），不是从 _exclusionArea 读出来的",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            LabeledContent("基准矩形") {
                Text(DynamicIslandProbe.format(overlay.baseRect))
                    .font(.caption.monospaced())
            }
            LabeledContent("描边矩形") {
                Text(DynamicIslandProbe.format(overlay.outlinedRect))
                    .font(.caption.monospaced())
            }

            // 包一层 Group 纯粹是为了别把 Section 的直接子视图顶过 ViewBuilder 的 10 个上限
            Group {
                slider("圆角半径", value: bindable.adjustments.cornerRadius, in: 0...40)
                slider("向外扩", value: bindable.adjustments.outset, in: -8...16)
                slider("X 偏移", value: bindable.adjustments.offsetX, in: -24...24)
                slider("Y 偏移", value: bindable.adjustments.offsetY, in: -24...24)
            }

            Toggle("圆角用正圆弧（关 = 连续曲率）", isOn: bindable.adjustments.usesCircularCorners)
            Toggle("岛周围铺白底", isOn: bindable.adjustments.showsWhiteBacking)

            Button(role: .destructive) {
                overlay.resetAdjustments()
                show("已复位")
            } label: {
                Label("参数复位", systemImage: "arrow.uturn.backward")
            }
        } header: {
            Text("可视化叠加")
        } footer: {
            Text("描边挂在自己的窗口上，盖在一切之上且触摸全部穿透——**离开这一页、切 tab、进站点浏览都还看得见**，不会被导航栏挡住。描边画在矩形内侧，所以线的外边缘就是矩形边界。\n铺白底是为了把黑胶囊衬出来，只铺岛周围一圈，免得整屏白了找不到开关。")
        }
    }

    private func slider(
        _ title: String,
        value: Binding<CGFloat>,
        in range: ClosedRange<CGFloat>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(DynamicIslandProbe.fmt(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
            Slider(value: value, in: range, step: 0.25)
        }
    }

    private var howToSection: some View {
        Section {
            Text("在真机上打开描边，调到和灵动岛严丝合缝为止，然后点「复制全部诊断信息」——校准参数会和诊断信息一起进剪贴板。")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        } header: {
            Text("怎么用")
        } footer: {
            Text("这一页只做验证，不画进度环。")
        }
    }

    // MARK: - 动作

    private func probe() {
        let result = DynamicIslandProbe.run()
        diagnostics = result
        overlay.adopt(result)
    }

    /// 贴回来的那一整份
    private var fullReport: String {
        var lines = ["# Husk 灵动岛几何探测"]
        if let diagnostics {
            lines.append("探测时间：\(diagnostics.takenAt.formatted(date: .numeric, time: .standard))")
            lines.append("结论：\(diagnostics.succeeded ? "读到了 _exclusionArea" : "没读到")")
            if let failure = diagnostics.failure {
                lines.append("失败点：\(failure)")
            }
            lines.append("")
            lines.append("## 原始信息")
            lines.append(contentsOf: diagnostics.fields.map { "\($0.label)：\($0.value)" })
        } else {
            lines.append("（还没探测）")
        }
        lines.append("")
        lines.append("## 叠加层校准参数")
        lines.append(overlay.calibrationSummary)
        return lines.joined(separator: "\n")
    }

    private func show(_ message: String) {
        withAnimation { notice = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { notice = nil }
        }
    }
}
