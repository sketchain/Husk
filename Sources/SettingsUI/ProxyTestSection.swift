import SwiftUI

/// 代理设置页的「测试连接」分区：一个按钮 + 结果。
///
/// 结果里最有用的是**公钥指纹**：自签证书的代理，点一次测试、再点「用这个指纹」，
/// 指纹验证就配好了，不用去服务器上跑 openssl。
struct ProxyTestSection: View {
    let mode: ProxyConnectionMode
    let testing: Bool
    let result: ProxyTester.Result?
    let onTest: () -> Void
    let onUseFingerprint: (String) -> Void

    @State private var copied: String?

    var body: some View {
        Section {
            Button {
                Haptics.tap()
                onTest()
            } label: {
                HStack {
                    Label("测试连接", systemImage: "bolt.horizontal.circle")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing)

            if let result { resultRows(result) }
        } header: {
            Text("测试")
        } footer: {
            Text(mode == .direct
                 ? "测的是 app 自己连一次代理（握手 + 一次 CONNECT 到 \(ProxyTester.probeTarget)）。「直连代理」模式下网页走的是 WebKit 自己的实现，那条路能不能通要去 设置 → 实验室 → 代理诊断 里用真 WebView 测。"
                 : "和本地中继走的是同一套代码：握手、按所选方式验证证书，再发一次 CONNECT 到 \(ProxyTester.probeTarget)（只建隧道不发数据）。")
        }
    }

    @ViewBuilder
    private func resultRows(_ result: ProxyTester.Result) -> some View {
        if let failure = result.failure {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title)
                    Text(failure.detail).font(.caption).foregroundStyle(Theme.secondaryText)
                }
            } icon: {
                Image(systemName: failure.symbol).foregroundStyle(.red)
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("连通了")
                    Text("握手、证书验证、CONNECT 全部通过 · \(Self.milliseconds(result.elapsed)) ms")
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }

        let tls = result.inspection
        if let subject = tls.subject {
            LabeledContent("证书主体", value: subject)
            LabeledContent("证书链", value: "\(tls.chainLength) 张")
        }
        if let passed = tls.systemTrustPassed {
            LabeledContent("系统信任链 + 主机名") {
                Text(passed ? "通过" : "不通过")
                    .foregroundStyle(passed ? .green : .orange)
            }
            if let error = tls.systemTrustError {
                Text(error).font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
        if let spki = tls.spkiSHA256 {
            fingerprintRow(
                title: "公钥指纹（SPKI SHA-256）",
                value: "sha256/" + spki.base64EncodedString(),
                note: "指纹验证比对的就是这个"
            )
            Button {
                onUseFingerprint(spki.base64EncodedString())
            } label: {
                Label("用这个指纹", systemImage: "pin")
            }
        }
        if let certificate = tls.certificateSHA256 {
            fingerprintRow(
                title: "整张证书 SHA-256",
                value: CertificateFingerprint.hexString(certificate),
                note: "只供核对（浏览器、openssl 显示的通常是这个），续签就会变，不拿来比对"
            )
        }
        if let status = result.tunnelStatus {
            LabeledContent("CONNECT", value: status)
        }
    }

    private func fingerprintRow(title: String, value: String, note: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.success()
            copied = value
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.caption)
                    Spacer()
                    Text(copied == value ? "已复制" : "点按复制")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
                Text(value)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                Text(note).font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        }
        .tint(.primary)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
