import Foundation

/// HTTP/1.x 报文头（请求或响应）。中继只需要看起始行和少数几个头，别的原样转发。
struct HTTPHead: Sendable {
    /// 头部上限。正常浏览器请求头几 KB；超过这个多半不是 HTTP，直接断开。
    static let maxLength = 32 * 1024

    var startLine: String
    var headers: [(name: String, value: String)]

    /// `\r\n\r\n` 之后第一个字节的下标；还没收全返回 nil
    static func endIndex(in data: Data) -> Int? {
        // 返回的是相对偏移：传进来的可能是个切片，startIndex 不一定是 0
        guard let range = data.range(of: Data([13, 10, 13, 10])) else { return nil }
        return range.upperBound - data.startIndex
    }

    /// 解析到 `\r\n\r\n` 为止的那一段。头部按 ISO-8859-1 读（RFC 9110 允许的最宽读法），
    /// 不会因为某个头里有奇怪字节就整条解析失败。
    static func parse(_ data: Data) -> HTTPHead? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let first = lines.first, !first.isEmpty else { return nil }
        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers.append((name, value))
        }
        return HTTPHead(startLine: first, headers: headers)
    }

    func value(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// 请求行拆成 (method, target, version)
    var requestLine: (method: String, target: String, version: String)? {
        let parts = startLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }

    /// 响应状态码
    var statusCode: Int? {
        let parts = startLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }

    func removingHeaders(_ names: Set<String>) -> HTTPHead {
        var copy = self
        copy.headers.removeAll { names.contains($0.name.lowercased()) }
        return copy
    }

    func adding(_ name: String, _ value: String) -> HTTPHead {
        var copy = self
        copy.headers.append((name, value))
        return copy
    }

    var serialized: Data {
        var text = startLine + "\r\n"
        for header in headers {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "\r\n"
        return text.data(using: .isoLatin1) ?? Data(text.utf8)
    }

    // MARK: - 小工具

    /// `Basic base64(user:pass)`
    static func basicAuthorization(username: String, password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// CONNECT 目标 / Host 里不能有能拆行或拆字段的字符，防止拼请求时被注入
    static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 1024
            && !value.contains(where: { $0 == "\r" || $0 == "\n" || $0 == " " || $0 == "\t" })
    }

    /// 固定的错误响应。`Connection: close` 让 WebKit 别复用这条连接。
    static func errorResponse(status: String, failure: ProxyFailure?, extraHeaders: [String] = []) -> Data {
        let body: String
        if let failure {
            body = """
            <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
            <title>\(failure.title)</title>
            <body style="font:16px -apple-system;padding:24px;background:#0a0b0e;color:#eee">
            <h3>\(failure.title)</h3><p>\(escapeHTML(failure.detail))</p>
            <p style="color:#888">Husk 本地代理中继 · \(failure.code)</p>
            """
        } else {
            body = ""
        }
        let bodyData = Data(body.utf8)
        var lines = ["HTTP/1.1 \(status)"]
        lines += extraHeaders
        if let failure { lines.append("X-Husk-Proxy-Error: \(failure.code)") }
        lines.append("Content-Type: text/html; charset=utf-8")
        lines.append("Content-Length: \(bodyData.count)")
        lines.append("Connection: close")
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(bodyData)
        return data
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
