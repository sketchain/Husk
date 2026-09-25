import Foundation
import Network

/// 包一条 `NWConnection`，提供中继要用的几个读写动作。
///
/// 为什么要包一层：`NWConnection` 在 Swift 接口上是不是 `Sendable`，随 SDK 版本变过。
/// 中继到处要在 `@Sendable` 回调里用连接，直接捕获的话 SDK 标注一变就编译不过。
/// 这里统一让回调只捕获这个 `@unchecked Sendable` 的壳——Network 框架的对象本身是线程安全的，
/// 而且本项目里每条连接的回调都派在同一个串行队列上。
final class ConnectionIO: @unchecked Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    enum HeadError: Error {
        case closed
        case tooLarge
        case malformed
        /// 带的是描述文本不是 `NWError` 本身：`Error` 要求 `Sendable`，同样别押 SDK 的标注
        case failed(String)
    }

    /// 一直读到 `\r\n\r\n`。返回解析好的头，以及头后面多读到的字节（请求体、隧道里的首包）。
    func readHead(
        initial: Data = Data(),
        completion: @escaping @Sendable (Result<(HTTPHead, Data), HeadError>) -> Void
    ) {
        if let end = HTTPHead.endIndex(in: initial) {
            let buffer = Data(initial)
            guard let head = HTTPHead.parse(Data(buffer.prefix(end))) else {
                completion(.failure(.malformed))
                return
            }
            completion(.success((head, Data(buffer.dropFirst(end)))))
            return
        }
        guard initial.count < HTTPHead.maxLength else {
            completion(.failure(.tooLarge))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var buffer = initial
            if let data { buffer.append(data) }
            if HTTPHead.endIndex(in: buffer) != nil {
                self.readHead(initial: buffer, completion: completion)
            } else if let error {
                completion(.failure(.failed(error.localizedDescription)))
            } else if isComplete {
                completion(.failure(.closed))
            } else {
                self.readHead(initial: buffer, completion: completion)
            }
        }
    }

    /// 发一段数据；失败时回调带错误
    func send(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in completion(error) })
    }

    /// 发完就关：错误响应用
    func sendAndClose(_ data: Data) {
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }

    /// 把 `self` 读到的数据原样写到 `destination`，直到对端关闭或出错。
    ///
    /// 等上一段写完再读下一段，天然就是背压：哪边慢，另一边就停下来等，
    /// 不会在内存里攒一大堆没发出去的数据。
    /// - Parameter onEnd: `true` = 正常读到 EOF（已经向对面半关闭），`false` = 出错
    func pump(to destination: ConnectionIO, onEnd: @escaping @Sendable (Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            let receiveFailed = error != nil
            if let data, !data.isEmpty {
                destination.connection.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        onEnd(false)
                    } else if isComplete {
                        destination.finishWriting()
                        onEnd(true)
                    } else if receiveFailed {
                        onEnd(false)
                    } else {
                        self.pump(to: destination, onEnd: onEnd)
                    }
                })
            } else if isComplete {
                destination.finishWriting()
                onEnd(true)
            } else if receiveFailed {
                onEnd(false)
            } else {
                self.pump(to: destination, onEnd: onEnd)
            }
        }
    }

    /// 半关闭：告诉对面"我这边不会再写了"，但还能继续读
    func finishWriting() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    func cancel() {
        connection.cancel()
    }

    /// 对端是不是本机回环地址。监听已经限定在回环接口上了，这里是第二道闸。
    var isFromLoopback: Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default: return false
        }
    }
}
