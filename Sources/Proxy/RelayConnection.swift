import Foundation
import Network

/// 中继一条连接要知道的全部东西。每接一条新连接拍一次快照，改配置不影响已经建好的隧道。
struct RelayContext: Sendable {
    var upstream: UpstreamSettings
    /// WKWebView 这一跳必须带的 `Proxy-Authorization`；nil = 不校验（只有实验室开关会走到）
    var expectedAuthorization: String?
    var report: @Sendable (RelayEvent) -> Void
}

enum RelayEvent: Sendable {
    case authRejected
    case tunnelOpened
    case failure(ProxyFailure)
}

/// 本地中继上的一条客户端连接（来自 WebKit 网络进程或 app 自己的 URLSession）。
///
/// 两种请求都要接：
/// - **`CONNECT host:port`**：HTTPS（以及大多数 ws/wss）走这个。向上游代理发同样的 CONNECT，
///   2xx 之后两边对接成一条透明隧道。
/// - **绝对形式的 `GET http://host/path`**：有的客户端对明文 http:// 不开隧道，
///   直接把整条请求交给代理。原样转给上游（上游本来就是 HTTP 代理，这是它的本职），
///   换掉 `Proxy-Authorization`，并强制 `Connection: close`——一条连接只跑一个请求，
///   中继就不用去理解 keep-alive 的分帧。
///
/// 不管哪种，**上游连不上、握手失败、证书不对，都回 502 并关掉**。这里根本没有直连的代码路径，
/// 所以不存在"回落成直连"这回事。
final class RelayConnection: @unchecked Sendable {
    private let client: ConnectionIO
    private let context: RelayContext
    private let queue: DispatchQueue

    // 以下只在 `queue` 上读写（两条连接的回调都派在这个队列上）
    private var upstream: UpstreamLink?
    private var closed = false
    private var endedDirections = 0

    init(client: ConnectionIO, context: RelayContext, queue: DispatchQueue) {
        self.client = client
        self.context = context
        self.queue = queue
    }

    func start() {
        client.connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        client.connection.start(queue: queue)
        client.readHead { result in
            switch result {
            case .success(let request): self.handle(request.0, leftover: request.1)
            case .failure: self.close()
            }
        }
    }

    // MARK: - 分派

    private func handle(_ head: HTTPHead, leftover: Data) {
        guard let line = head.requestLine, line.version.hasPrefix("HTTP/1.") else {
            reject("400 Bad Request")
            return
        }
        let method = line.method
        let target = line.target

        if let expected = context.expectedAuthorization {
            guard let presented = head.value("Proxy-Authorization"),
                  Self.constantTimeEquals(presented, expected)
            else {
                // 本机任何 app 都能连 127.0.0.1，这一步就是防蹭用的。
                // 带上 Proxy-Authenticate，WebKit 收到 407 才知道该出示凭据。
                context.report(.authRejected)
                client.sendAndClose(HTTPHead.errorResponse(
                    status: "407 Proxy Authentication Required",
                    failure: nil,
                    extraHeaders: ["Proxy-Authenticate: Basic realm=\"Husk\""]
                ))
                return
            }
        }

        guard HTTPHead.isSafeToken(target) else {
            reject("400 Bad Request")
            return
        }
        if method.uppercased() == "CONNECT" {
            tunnel(to: target, leftover: leftover)
        } else if target.lowercased().hasPrefix("http://") {
            forward(head, leftover: leftover)
        } else {
            // 源形式的请求（`GET /path`）说明对方把我们当成了普通服务器，不是代理
            reject("400 Bad Request")
        }
    }

    // MARK: - CONNECT

    private func tunnel(to target: String, leftover: Data) {
        guard target.contains(":") else {
            reject("400 Bad Request")
            return
        }
        let link = UpstreamLink(settings: context.upstream, queue: queue)
        upstream = link
        link.open { result in
            if case .failure(let failure) = result { return self.fail(failure) }
            link.requestTunnel(to: target) { result in
                switch result {
                case .failure(let failure):
                    self.fail(failure)
                case .success(let early):
                    let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                    self.client.send(established + early) { error in
                        if error != nil { return self.close() }
                        if !leftover.isEmpty { link.io.send(leftover) { _ in } }
                        self.context.report(.tunnelOpened)
                        self.splice(with: link)
                    }
                }
            }
        }
    }

    // MARK: - 绝对形式

    private func forward(_ head: HTTPHead, leftover: Data) {
        var outgoing = head
            .removingHeaders(["proxy-authorization", "proxy-connection", "connection", "keep-alive"])
            .adding("Connection", "close")
        if let authorization = context.upstream.proxyAuthorization {
            outgoing = outgoing.adding("Proxy-Authorization", authorization)
        }
        let link = UpstreamLink(settings: context.upstream, queue: queue)
        upstream = link
        link.open { result in
            if case .failure(let failure) = result { return self.fail(failure) }
            link.io.send(outgoing.serialized + leftover) { error in
                if let error {
                    return self.fail(.upstreamProtocolError("转发请求失败：\(error.localizedDescription)"))
                }
                // 请求体（如果有）继续往上游送
                self.client.pump(to: link.io) { ok in self.directionEnded(ok) }
                link.readResponseHead { result in
                    switch result {
                    case .failure(let failure):
                        self.fail(failure)
                    case .success(let response):
                        let (responseHead, rest) = response
                        // 上游的 407 不能原样丢给 WebKit：那会让系统弹一个"代理需要认证"的框，
                        // 用户在里面填什么都没用（凭据在 Husk 的代理设置里）
                        if responseHead.statusCode == 407 {
                            return self.fail(.upstreamAuthRejected)
                        }
                        self.context.report(.tunnelOpened)
                        self.client.send(responseHead.serialized + rest) { error in
                            if error != nil { return self.close() }
                            link.io.pump(to: self.client) { ok in self.directionEnded(ok) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 收尾

    private func splice(with link: UpstreamLink) {
        client.pump(to: link.io) { ok in self.directionEnded(ok) }
        link.io.pump(to: client) { ok in self.directionEnded(ok) }
    }

    /// 两个方向都正常结束才关；任何一边出错立刻整条关掉
    private func directionEnded(_ ok: Bool) {
        guard ok else { return close() }
        endedDirections += 1
        if endedDirections >= 2 { close() }
    }

    private func fail(_ failure: ProxyFailure) {
        context.report(.failure(failure))
        upstream?.cancel()
        guard !closed else { return }
        client.sendAndClose(HTTPHead.errorResponse(status: "502 Bad Gateway", failure: failure))
    }

    private func reject(_ status: String) {
        client.sendAndClose(HTTPHead.errorResponse(status: status, failure: nil))
    }

    private func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
    }

    /// 比较凭据时不因为前缀对上了就早退，免得本机别的 app 靠计时一位一位猜
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
