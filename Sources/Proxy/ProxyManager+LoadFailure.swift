import Foundation

extension ProxyManager {
    /// 浏览页加载失败时显示什么。
    ///
    /// 没开代理：和以前一样，就是系统给的那句描述。
    /// 开了代理：要让人看出是**代理不通**、**代理证书不对**，还是**站点自己的问题**。
    /// - 本地中继模式下，中继自己知道上游出了什么事（`recentFailure`），直接用它的说法；
    ///   中继没报错而页面挂了，那就是站点的问题（比如站点证书过期），明确这么说。
    /// - 直连模式下 WebKit 只给一个错误码，分不清是代理的证书还是站点的证书，两种都点出来。
    func describeLoadFailure(_ error: any Error, profile: String) -> LoadFailure {
        let nsError = error as NSError
        let code = "（\(nsError.domain) \(nsError.code)）"
        guard let config = config(for: profile), config.isEnabled else {
            return LoadFailure(message: nsError.localizedDescription)
        }

        switch config.mode {
        case .localRelay:
            if let failure = recentFailure(for: profile) {
                var result = LoadFailure(failure)
                result.message += "\n\n页面没有改用直连。" + code
                return result
            }
            if nsError.domain == NSURLErrorDomain,
               [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(nsError.code) {
                return LoadFailure(ProxyFailure.relayUnavailable("WebView 连不上本机的中继端口。回到列表再进一次试试。"))
            }
            if Self.isCertificateError(nsError) {
                return LoadFailure(
                    title: "站点的证书没通过验证",
                    message: "代理本身是通的（它的证书也验过了），是站点出示的证书没通过验证：\(nsError.localizedDescription)\n\n可能是站点证书过期，也可能是代理在中间替换了证书。" + code,
                    symbol: "lock.trianglebadge.exclamationmark"
                )
            }
            return LoadFailure(
                title: "打不开这个页面",
                message: "\(nsError.localizedDescription)\n\n代理 \(config.trimmedHost) 没报错，问题多半在站点那边。" + code
            )

        case .direct:
            if Self.isCertificateError(nsError) {
                return LoadFailure(
                    title: "证书没通过验证",
                    message: "代理或站点的证书有问题——「直连代理」模式下 WebKit 不告诉 app 是哪一个。\n\(nsError.localizedDescription)\n\n如果代理用的是自签证书，换成「本地中继」+「公钥指纹」。" + code,
                    symbol: "lock.trianglebadge.exclamationmark"
                )
            }
            if Self.isProxyConnectionError(nsError) {
                return LoadFailure(
                    ProxyFailure.upstreamUnreachable("WebKit 连不上代理 \(config.trimmedHost):\(config.port)：\(nsError.localizedDescription)\n\n页面没有改用直连。" + code)
                )
            }
            return LoadFailure(
                title: "打不开这个页面",
                message: "\(nsError.localizedDescription)\n\n经代理 \(config.trimmedHost) 加载失败。「直连代理」模式下分不清是代理还是站点的问题，想看清楚可以在代理设置里点「测试连接」。" + code
            )
        }
    }

    static func isCertificateError(_ error: NSError) -> Bool {
        let certificateCodes = [
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
        ]
        return error.domain == NSURLErrorDomain && certificateCodes.contains(error.code)
    }

    /// CFNetwork 的代理类错误码：306 连不上 HTTP 代理、307 代理凭据不对、
    /// 310 连不上 HTTPS 代理、311 CONNECT 收到了意外响应。WebKit 有时把它们包在 underlying 里。
    static func isProxyConnectionError(_ error: NSError) -> Bool {
        let proxyCodes = [306, 307, 310, 311]
        // 字面量就是 kCFErrorDomainCFNetwork 的值，省得为一个常量去 import CFNetwork
        if error.domain == "kCFErrorDomainCFNetwork", proxyCodes.contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isProxyConnectionError(underlying)
        }
        return error.domain == NSURLErrorDomain
            && [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorCannotFindHost].contains(error.code)
    }
}
