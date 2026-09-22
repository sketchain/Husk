import Foundation

/// 打包进 app 的 Public Suffix List（`Resources/public_suffix_list.dat`）。
///
/// 以前这里是一张手写的常见多段后缀表（`co.uk`、`com.cn` 之类），代价是
/// `github.io`、`vercel.app` 这种"托管型"公共后缀没覆盖——`a.github.io` 和
/// `b.github.io` 会被算成同一站。外链策略要按"同一可注册域"判，就得用真表。
///
/// 打包的文件是官方列表去掉注释和空行之后的版本（约 10000 条 / 145KB），
/// ICANN 段和 PRIVATE 段都留着：`github.io` 正在 PRIVATE 段里，丢掉它就白换了。
enum PublicSuffixList {
    /// 列表分三类规则，按 publicsuffix.org 的算法匹配：
    /// - `rules`      普通规则，如 `com`、`co.uk`
    /// - `wildcards`  `*.ck` 这类，存的是 `*.` 后面那截
    /// - `exceptions` `!www.ck` 这类，存的是 `!` 后面那截；例外优先级最高
    private struct Rules: Sendable {
        var plain: Set<String> = []
        var wildcards: Set<String> = []
        var exceptions: Set<String> = []
    }

    /// `static let` 本身就是惰性 + 线程安全的，不用自己加锁。
    /// 解析一次约 10000 行，只在第一次判外链时发生。
    private static let rules: Rules = load()

    private static func load() -> Rules {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            // 资源没打进包里的话不能让外链判断整个失灵，退回"最后一段是公共后缀"
            return Rules()
        }
        var result = Rules()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let rule = line.trimmingCharacters(in: .whitespaces)
            if rule.isEmpty || rule.hasPrefix("#") || rule.hasPrefix("//") { continue }
            if rule.hasPrefix("!") {
                result.exceptions.insert(String(rule.dropFirst()).lowercased())
            } else if rule.hasPrefix("*.") {
                result.wildcards.insert(String(rule.dropFirst(2)).lowercased())
            } else {
                result.plain.insert(rule.lowercased())
            }
        }
        return result
    }

    /// 取公共后缀。`m.youtube.com` → `com`，`a.github.io` → `github.io`
    static func publicSuffix(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard !labels.isEmpty else { return host }
        let table = rules

        // 例外规则压过一切，所以单独先扫一遍。
        // `!city.kawasaki.jp` 的含义是"city.kawasaki.jp 是可注册域"，
        // 于是公共后缀取它去掉最左一段之后的部分。
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            if table.exceptions.contains(candidate) {
                return labels[(i + 1)...].joined(separator: ".")
            }
        }

        // i 从 0 递增 = 候选从最长到最短，第一个命中的就是最长匹配
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            if table.plain.contains(candidate) { return candidate }
            if i + 1 < labels.count {
                let rest = labels[(i + 1)...].joined(separator: ".")
                if table.wildcards.contains(rest) { return candidate }
            }
        }

        // 一条都没命中，按规范里的隐含规则 `*` 处理：最后一段就是公共后缀
        return labels[labels.count - 1]
    }

    /// 取可注册域（eTLD+1）。`m.youtube.com` → `youtube.com`，`a.github.io` → `a.github.io`。
    ///
    /// 传进来的本身就是裸公共后缀（`com`、`github.io`）时返回 nil——
    /// 这种地址没有"可注册域"可言，调用方应当判成两个不同的站。
    static func registrableDomain(of host: String) -> String? {
        let lower = host.lowercased()
        let suffix = publicSuffix(of: lower)
        let labels = lower.split(separator: ".")
        let suffixLabels = suffix.split(separator: ".").count
        guard labels.count > suffixLabels else { return nil }
        return labels[(labels.count - suffixLabels - 1)...].joined(separator: ".")
    }
}
