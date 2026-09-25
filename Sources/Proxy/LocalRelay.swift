import Foundation
import Network
import Security

/// 一个 profile 的本地中继：只在回环接口上监听的明文 HTTP CONNECT 代理。
///
/// **每个开了「本地中继」的 profile 各一个监听**，而不是全 app 共用一个：
/// - 端口本身就标识了 profile，中继不用靠凭据去反查"这条连接是哪个 profile 的"；
/// - 于是本地凭据只承担"防蹭"一件事。万一 WKWebView 的代理认证在某个系统版本上坏了，
///   实验室里关掉凭据校验照样能用（有风险，见 README），不用改架构；
/// - 监听是几个文件描述符的事，十几个 profile 也不值一提。
///
/// 本机其他 app 能连 127.0.0.1（iOS 的回环接口是全设备共用的，只是被挂起的 app 连不了），
/// 所以这一跳默认要求 `Proxy-Authorization`：用户名固定，密码每次启动随机生成、只在内存里。
final class LocalRelay: @unchecked Sendable {
    struct Stats: Sendable {
        var tunnelsOpened = 0
        var authRejections = 0
        var nonLoopbackRejections = 0
        var failures = 0
        var lastFailure: ProxyFailure?
        var lastFailureAt: Date?
    }

    let profile: String
    let username = "husk"
    let password: String
    private let queue: DispatchQueue
    private let onFailure: @Sendable (ProxyFailure) -> Void

    // 锁保护：主线程要读
    private let lock = NSLock()
    private var upstreamValue: UpstreamSettings
    private var requireAuthValue: Bool
    private var portValue: UInt16?
    private var statsValue = Stats()

    // 只在 `queue` 上读写
    private var listener: NWListener?
    private var generation = 0
    private var pendingStart: (@Sendable (Result<UInt16, ProxyFailure>) -> Void)?
    /// 活着的连接。配置变了要全部断开，见 `dropAllConnections`
    private var active: [ObjectIdentifier: RelayConnection] = [:]

    init(
        profile: String,
        upstream: UpstreamSettings,
        requireAuth: Bool,
        onFailure: @escaping @Sendable (ProxyFailure) -> Void
    ) {
        self.profile = profile
        self.upstreamValue = upstream
        self.requireAuthValue = requireAuth
        self.onFailure = onFailure
        self.password = Self.randomSecret()
        self.queue = DispatchQueue(label: "husk.relay")
    }

    var port: UInt16? { lock.withLock { portValue } }
    var stats: Stats { lock.withLock { statsValue } }
    var upstream: UpstreamSettings { lock.withLock { upstreamValue } }
    var requiresAuth: Bool { lock.withLock { requireAuthValue } }

    /// 换上游配置：只影响之后的新连接。已经建好的隧道要靠 `dropAllConnections` 断掉。
    func update(upstream: UpstreamSettings, requireAuth: Bool) {
        lock.withLock {
            upstreamValue = upstream
            requireAuthValue = requireAuth
        }
    }

    /// 断开所有已经建立的隧道。
    ///
    /// 代理配置变了（换了指纹、换了密码、换了上游）时必须做：WebKit 网络进程会复用它到
    /// 中继的长连接，而那些隧道是按**旧**配置验证过的上游建的。比如用户因为旧密钥泄露而删掉
    /// 一个指纹，不断开的话旧隧道还会继续跑。
    func dropAllConnections() {
        queue.async {
            let connections = Array(self.active.values)
            self.active.removeAll()
            connections.forEach { $0.terminate() }
        }
    }

    // MARK: - 监听

    /// 开始监听。`preferredPort` 用于回前台重建：尽量拿回原来的端口，
    /// 这样 `proxyConfigurations` 不用改，也就不会打断 WebView 里正在进行的请求。
    ///
    /// `completion` 保证恰好调用一次：被后来的 start / stop 顶掉时也会以失败返回，
    /// 调用方（`ProxyManager` 里的 continuation）不会永远挂着。
    func start(preferredPort: UInt16?, completion: @escaping @Sendable (Result<UInt16, ProxyFailure>) -> Void) {
        queue.async {
            self.tearDownListener()
            self.generation += 1
            let generation = self.generation
            self.pendingStart = completion

            let parameters = NWParameters.tcp
            // 只绑回环接口：别的网卡上来的连接内核直接不给
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            let port = preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any

            let listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: port)
            } catch {
                self.finishStart(.failure(.relayUnavailable("建监听失败：\(error.localizedDescription)")))
                return
            }
            self.listener = listener

            listener.newConnectionHandler = { connection in
                self.accept(ConnectionIO(connection))
            }
            listener.stateUpdateHandler = { state in
                // 被新的一次 start / stop 顶掉的旧监听，它的状态变化一概不理
                guard generation == self.generation else { return }
                switch state {
                case .ready:
                    let actual = self.listener?.port?.rawValue
                    self.lock.withLock { self.portValue = actual }
                    if let actual {
                        self.finishStart(.success(actual))
                    } else {
                        self.finishStart(.failure(.relayUnavailable("监听起来了但拿不到端口号")))
                    }
                case .waiting(let error), .failed(let error):
                    // 端口被占（回前台想拿回原端口时常见）也走这里，调用方会换个端口重试
                    let reason = error.localizedDescription
                    if self.pendingStart != nil {
                        self.finishStart(.failure(.relayUnavailable("监听失败：\(reason)")))
                    } else {
                        self.onFailure(.relayUnavailable("监听意外停止：\(reason)"))
                    }
                    self.tearDownListener()
                case .cancelled:
                    self.lock.withLock { self.portValue = nil }
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    /// 停止监听。已经建立的隧道不动（它们是数据连接，TN2277 允许留着，被系统回收了自己会报错断开）。
    func stop() {
        queue.async {
            self.generation += 1
            self.tearDownListener()
        }
    }

    private func finishStart(_ result: Result<UInt16, ProxyFailure>) {
        guard let completion = pendingStart else { return }
        pendingStart = nil
        completion(result)
    }

    private func tearDownListener() {
        finishStart(.failure(.relayUnavailable("监听在启动过程中被停掉了")))
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        lock.withLock { portValue = nil }
    }

    // MARK: - 接连接

    private func accept(_ client: ConnectionIO) {
        // 监听已经限定在回环接口，这是第二道闸
        guard client.isFromLoopback else {
            lock.withLock { statsValue.nonLoopbackRejections += 1 }
            client.cancel()
            return
        }
        let (upstream, requireAuth) = lock.withLock { (upstreamValue, requireAuthValue) }
        let expected = requireAuth ? HTTPHead.basicAuthorization(username: username, password: password) : nil
        let context = RelayContext(upstream: upstream, expectedAuthorization: expected) { event in
            self.record(event)
        }
        let connection = RelayConnection(client: client, context: context, queue: queue)
        let key = ObjectIdentifier(connection)
        active[key] = connection
        connection.onClose = {
            // close() 总是在 queue 上跑（所有回调都派在这个队列），这里直接改是安全的
            self.active[key] = nil
        }
        connection.start()
    }

    private func record(_ event: RelayEvent) {
        switch event {
        case .authRejected:
            lock.withLock { statsValue.authRejections += 1 }
        case .tunnelOpened:
            lock.withLock { statsValue.tunnelsOpened += 1 }
        case .failure(let failure):
            lock.withLock {
                statsValue.failures += 1
                statsValue.lastFailure = failure
                statsValue.lastFailureAt = Date()
            }
            onFailure(failure)
        }
    }

    /// 本地一跳的密码：每次启动随机，只在内存里
    private static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // 系统随机源失败几乎不可能；真失败了也不能用可预测的值
            bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
    }
}
