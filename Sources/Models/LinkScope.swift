import Foundation

/// "站内"的判定档位。只在外链策略是 `.sameDomain` 时起作用。
///
/// 分三档是因为"同一个站"这件事本来就没有唯一答案：
/// 自建博客可能只想把 `blog.example.com` 算站内，而 `youtube.com` 这种
/// 主域子域来回跳的，卡得太死就寸步难行。
enum LinkScopeStrictness: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// 仅本主机。`www.` 视为同一个主机。
    case host
    /// 本主机及其子域
    case hostAndSubdomains
    /// 同一可注册域（eTLD+1，走 Public Suffix List）——默认，也是历史行为
    case registrableDomain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host: "仅本主机"
        case .hostAndSubdomains: "本主机及子域"
        case .registrableDomain: "同一可注册域"
        }
    }

    var subtitle: String {
        switch self {
        case .host: "只有 example.com 自己算站内（www. 视为同一个）"
        case .hostAndSubdomains: "example.com 和 a.example.com 算站内"
        case .registrableDomain: "按 Public Suffix List 归约到 eTLD+1 再比"
        }
    }
}

/// 一条手动例外。用户在站点设置里填的域名列表就是它的数组。
///
/// 两种写法，含义**刻意不同**：
/// - `example.com`    只匹配这一个主机（`www.` 视为同一个）
/// - `*.example.com`  匹配 `example.com` 本身以及它的任意层级子域
///
/// 不把裸域名也当成"连子域一起"，是为了让通配符这个写法有意义；
/// 大多数人想要的是后者，所以 UI 的占位文案里直接写了 `*.` 的例子。
enum DomainPattern {
    /// `candidate` 是否命中 `pattern`。两边都会先做 `www.` 归一化。
    static func matches(_ candidate: String, pattern rawPattern: String) -> Bool {
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty else { return false }
        let host = normalize(candidate)

        if pattern.hasPrefix("*.") {
            let base = normalize(String(pattern.dropFirst(2)))
            guard !base.isEmpty else { return false }
            return host == base || host.hasSuffix("." + base)
        }
        // 用户直接写 ".example.com" 的也按通配处理，这是个常见手误
        if pattern.hasPrefix(".") {
            let base = normalize(String(pattern.dropFirst()))
            return !base.isEmpty && (host == base || host.hasSuffix("." + base))
        }
        return host == normalize(pattern)
    }

    static func matchesAny(_ candidate: String, patterns: [String]) -> Bool {
        patterns.contains { matches(candidate, pattern: $0) }
    }

    /// 去掉首尾空白、协议头、路径，再削掉 `www.`——用户从地址栏复制粘贴的多半带这些
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value
    }

    /// 把用户输入的一整行（逗号 / 空格 / 换行分隔）拆成若干条
    static func parseList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
