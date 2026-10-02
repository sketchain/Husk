import Foundation

/// 工具箱地址栏里敲进来的东西 → 一个能加载的 URL。
///
/// 没有搜索引擎：这是个单站容器，不是通用浏览器，敲一串不像地址的字就直接说"不是地址"，
/// 不替用户猜。认的写法：
/// - `https://github.com/xyz`、`http://…`：原样
/// - `github.com/xyz`、`localhost:8080`、`192.168.1.1`：补 `https://`
/// - `/xyz`、`?tab=repos`、`#readme`：相对当前页面
/// - `mailto:`、`tel:`、`weixin://` 这类：原样，交给系统
enum AddressInput {
    static func resolve(_ raw: String, relativeTo base: URL?) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }

        // 站内路径
        if let first = text.first, "/?#".contains(first), !text.hasPrefix("//") {
            guard let base else { return nil }
            return URL(string: text, relativeTo: base)?.absoluteURL
        }
        // 协议相对：//example.com/x
        if text.hasPrefix("//") {
            return webURL("https:" + text)
        }

        if let scheme = explicitScheme(of: text) {
            switch scheme {
            case "http", "https":
                return webURL(text)
            // 在地址栏里跑脚本、读本地文件都不是这个入口该干的事
            case "javascript", "file", "data", "blob", "about":
                return nil
            default:
                return URL(string: text)
            }
        }
        return webURL("https://" + text)
    }

    /// `github.com:443/x` 和 `localhost:8080` 里冒号前面那段不是 scheme：
    /// 含点的、或者冒号后紧跟数字（端口）的，都当成主机。
    private static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[..<colon]
        guard let first = head.first, first.isLetter,
              head.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
              !head.contains(".")
        else { return nil }
        let rest = text[text.index(after: colon)...]
        if let next = rest.first, next.isNumber { return nil }
        return head.lowercased()
    }

    /// 只放行真有主机名的网页地址；`https://abc` 这种单个词只认 localhost
    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let host = url.host(percentEncoded: false), !host.isEmpty else {
            return nil
        }
        let looksLikeHost = host.contains(".") || host.contains(":") || host.lowercased() == "localhost"
        return looksLikeHost ? url : nil
    }
}
