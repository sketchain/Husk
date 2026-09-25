import Foundation
import Network
import Security

/// 上游代理的连接参数快照（含密码）。只在 app 进程内存里，跨队列传。
struct UpstreamSettings: Sendable, Hashable {
    var host: String
    var port: UInt16
    var username: String?
    var password: String?
    var verification: ProxyTLSVerification
    /// 叶子 SPKI SHA-256，32 字节
    var pins: Set<Data>

    var proxyAuthorization: String? {
        guard let username, !username.isEmpty else { return nil }
        return HTTPHead.basicAuthorization(username: username, password: password ?? "")
    }
}

/// 一次 TLS 握手里看到的证书情况。verify block 在连接的队列上写，握手结束后别处读。
final class TLSInspection: @unchecked Sendable {
    struct Snapshot: Sendable {
        var subject: String?
        var chainLength = 0
        var spkiSHA256: Data?
        var certificateSHA256: Data?
        /// 系统信任链 + 主机名的结果。三种模式都会算一遍，给「测试连接」展示用
        var systemTrustPassed: Bool?
        var systemTrustError: String?
        /// 按所选验证方式的最终裁决；nil = 还没走到验证
        var accepted: Bool?
        var rejectionReason: String?
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot { lock.withLock { value } }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.withLock { body(&value) }
    }
}

/// 到上游 HTTPS 代理的一条 TLS 连接。中继每条隧道用一个，「测试连接」也用它。
final class UpstreamLink: @unchecked Sendable {
    let settings: UpstreamSettings
    let inspection = TLSInspection()
    let io: ConnectionIO
    private let queue: DispatchQueue
    /// 只在 `queue` 上读写
    private var openCompletion: (@Sendable (Result<Void, ProxyFailure>) -> Void)?

    init(settings: UpstreamSettings, queue: DispatchQueue) {
        self.settings = settings
        self.queue = queue
        let parameters = NWParameters(tls: Self.tlsOptions(settings: settings, inspection: inspection, queue: queue))
        // 明确不许走系统代理之类的旁路：这条连接本身就是去代理的
        parameters.preferNoProxies = true
        let port = NWEndpoint.Port(rawValue: settings.port) ?? .https
        io = ConnectionIO(NWConnection(host: NWEndpoint.Host(settings.host), port: port, using: parameters))
    }

    // MARK: - 建连

    /// TCP + TLS（含证书验证）。`timeout` 秒内没到 ready 就算连不上。
    func open(timeout: TimeInterval = 12, completion: @escaping @Sendable (Result<Void, ProxyFailure>) -> Void) {
        queue.async {
            self.openCompletion = completion
            self.io.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.finishOpen(.success(()))
                case .waiting(let error), .failed(let error):
                    // .waiting 表示 Network 打算等网络变好了自己重试。对代理来说这就是"现在连不上"，
                    // 让页面立刻报错，别让用户对着转圈干等。
                    let failure = self.classify(error)
                    self.io.cancel()
                    self.finishOpen(.failure(failure))
                default:
                    break
                }
            }
            self.io.connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + timeout) {
                guard self.openCompletion != nil else { return }
                self.io.cancel()
                self.finishOpen(.failure(.upstreamUnreachable("连代理超时（\(Int(timeout)) 秒没握完手）")))
            }
        }
    }

    private func finishOpen(_ result: Result<Void, ProxyFailure>) {
        guard let completion = openCompletion else { return }
        openCompletion = nil
        completion(result)
    }

    /// 发 CONNECT，等代理回 2xx。成功时返回响应头后面多读到的字节（隧道里的首包，一般是空的）。
    func requestTunnel(to target: String, completion: @escaping @Sendable (Result<Data, ProxyFailure>) -> Void) {
        var lines = ["CONNECT \(target) HTTP/1.1", "Host: \(target)"]
        if let authorization = settings.proxyAuthorization {
            lines.append("Proxy-Authorization: \(authorization)")
        }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        io.send(request) { error in
            if let error {
                completion(.failure(.upstreamProtocolError("发 CONNECT 失败：\(error.localizedDescription)")))
                return
            }
            self.readResponseHead { result in
                completion(result.flatMap { response in
                    let (head, rest) = response
                    guard let status = head.statusCode else {
                        return .failure(.upstreamProtocolError("代理回的不像 HTTP：\(head.startLine)"))
                    }
                    if (200..<300).contains(status) { return .success(rest) }
                    return .failure(Self.failure(forStatus: status, line: head.startLine))
                })
            }
        }
    }

    /// 读上游响应头，读失败统一换成 `ProxyFailure`
    func readResponseHead(
        initial: Data = Data(),
        completion: @escaping @Sendable (Result<(HTTPHead, Data), ProxyFailure>) -> Void
    ) {
        io.readHead(initial: initial) { result in
            completion(result.mapError { error in
                switch error {
                case .closed: .upstreamProtocolError("代理没回任何东西就断开了")
                case .tooLarge, .malformed: .upstreamProtocolError("代理回的不像 HTTP")
                case .failed(let reason): .upstreamProtocolError("读代理响应失败：\(reason)")
                }
            })
        }
    }

    static func failure(forStatus status: Int, line: String) -> ProxyFailure {
        status == 407 ? .upstreamAuthRejected : .upstreamRefused(line)
    }

    func cancel() { io.cancel() }

    // MARK: - TLS

    private static func tlsOptions(
        settings: UpstreamSettings,
        inspection: TLSInspection,
        queue: DispatchQueue
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        // 代理协议是 HTTP/1.1 的 CONNECT。显式说出来，免得有的代理按 ALPN 分流时猜错
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        // 三种模式都走自己的 verify block：系统验证也在这里做，
        // 这样才拿得到证书指纹给「测试连接」展示，也才分得清"证书不对"和"握手失败"。
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            complete(evaluate(secTrust, settings: settings, inspection: inspection))
        }, queue)
        return options
    }

    /// 证书验证本体
    static func evaluate(_ trust: SecTrust, settings: UpstreamSettings, inspection: TLSInspection) -> Bool {
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        guard let leaf = chain.first else {
            inspection.update {
                $0.accepted = false
                $0.rejectionReason = "代理没出示证书"
            }
            return false
        }
        let spki = CertificateFingerprint.spkiSHA256(of: leaf)

        // 系统验证总是跑一遍（给测试连接看），但只有 .system 模式拿它当裁决
        _ = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, settings.host as CFString))
        var cfError: CFError?
        let systemPassed = SecTrustEvaluateWithError(trust, &cfError)
        let systemError = systemPassed ? nil : (cfError.map { CFErrorCopyDescription($0) as String } ?? "原因不明")

        let accepted: Bool
        let reason: String?
        switch settings.verification {
        case .system:
            accepted = systemPassed
            reason = "证书没通过系统验证：\(systemError ?? "")。自签证书请改用「公钥指纹」。"
        case .pinnedKey:
            // 只比叶子证书。不能"链上任意一张命中就放行"：指纹模式不验签名链，
            // 攻击者把公开的中间证书塞进自己出示的链里就能骗过去。
            accepted = spki.map { settings.pins.contains($0) } ?? false
            let shown = spki?.base64EncodedString() ?? "（算不出来）"
            reason = "公钥指纹不匹配。代理出示的是 sha256/\(shown)，不在你填的列表里——要么证书换了密钥，要么有人在冒充代理。"
        case .none:
            accepted = true
            reason = nil
        }

        inspection.update {
            $0.subject = SecCertificateCopySubjectSummary(leaf) as String?
            $0.chainLength = chain.count
            $0.spkiSHA256 = spki
            $0.certificateSHA256 = CertificateFingerprint.certificateSHA256(of: leaf)
            $0.systemTrustPassed = systemPassed
            $0.systemTrustError = systemError
            $0.accepted = accepted
            $0.rejectionReason = accepted ? nil : reason
        }
        return accepted
    }

    /// Network 报的错 → 用户看得懂的分类
    private func classify(_ error: NWError) -> ProxyFailure {
        let seen = inspection.snapshot
        if seen.accepted == false {
            return .certificateRejected(seen.rejectionReason ?? "证书没通过验证")
        }
        switch error {
        case .dns(let code):
            return .upstreamUnreachable("解析不了代理的主机名 \(settings.host)（DNS 错误 \(code)）")
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .upstreamUnreachable("代理拒绝连接：\(settings.host):\(settings.port) 上没有服务在听")
            case .ETIMEDOUT: return .upstreamUnreachable("连代理超时")
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN: return .upstreamUnreachable("网络不通，到不了代理")
            case .ECONNRESET: return .upstreamUnreachable("代理把连接重置了")
            default: return .upstreamUnreachable("连代理失败：\(error.localizedDescription)")
            }
        case .tls(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return .tlsHandshakeFailed(message)
        default:
            return .upstreamUnreachable(error.localizedDescription)
        }
    }
}
