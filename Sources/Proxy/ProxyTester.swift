import Foundation

/// 代理设置页的「测试连接」：在 app 里连一次上游代理，握手、验证、再发一个 CONNECT。
///
/// 走的是和本地中继**完全相同**的代码（`UpstreamLink`），所以本地中继模式下它的结论就是真实结论。
/// 直连模式下 WebView 走的是 WebKit 自己的实现，这里只能说明"代理本身是好的"，
/// WebKit 那条路能不能跑通要去实验室里用真 WebView 测。
enum ProxyTester {
    /// 拿来试 CONNECT 的目标。只建隧道不发数据，对方看到的只是一次 TCP 握手。
    static let probeTarget = "www.apple.com:443"

    struct Result: Sendable {
        var failure: ProxyFailure?
        /// 代理对 CONNECT 的回答（起始行）；没走到那一步是 nil
        var tunnelStatus: String?
        var inspection: TLSInspection.Snapshot
        var elapsed: Duration

        var succeeded: Bool { failure == nil }
    }

    static func run(settings: UpstreamSettings) async -> Result {
        let clock = ContinuousClock()
        let started = clock.now
        let queue = DispatchQueue(label: "husk.proxy-test")
        let link = UpstreamLink(settings: settings, queue: queue)

        let (failure, status) = await withCheckedContinuation { (continuation: CheckedContinuation<(ProxyFailure?, String?), Never>) in
            link.open { opened in
                if case .failure(let failure) = opened {
                    continuation.resume(returning: (failure, nil))
                    return
                }
                link.requestTunnel(to: probeTarget) { tunnel in
                    link.cancel()
                    switch tunnel {
                    case .success:
                        continuation.resume(returning: (nil, "2xx，隧道建立成功"))
                    case .failure(let failure):
                        var status: String?
                        if case .upstreamRefused(let line) = failure { status = line }
                        if failure == .upstreamAuthRejected { status = "407 Proxy Authentication Required" }
                        continuation.resume(returning: (failure, status))
                    }
                }
            }
        }
        return Result(
            failure: failure,
            tunnelStatus: status,
            inspection: link.inspection.snapshot,
            elapsed: clock.now - started
        )
    }
}
