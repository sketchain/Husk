import Foundation

/// UA 预设。
///
/// 版本号是 2026-09 查证的真实串，不是编的：
/// - iOS 26 起 Safari 把系统版本号冻结在 `18_7`（隐私措施），真实版本只在 `Version/` token 里，
///   所以 iPhone/iPad 串里出现 "OS 18_7" 是对的，不要"修正"成 26_x。
/// - Chrome 从 153 开始改两周一个大版本，跑得很快，这里的 152 早晚会过时——
///   过时了直接在站点设置里手填即可，UA 预设本来就只是省打字。
enum UserAgentPreset: String, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case iPhoneSafari
    case iPadSafari
    case macSafari
    case macChrome
    case androidChrome
    case googlebot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemDefault: "系统默认"
        case .iPhoneSafari: "iOS Safari"
        case .iPadSafari: "iPadOS Safari"
        case .macSafari: "macOS Safari"
        case .macChrome: "Chrome on macOS"
        case .androidChrome: "Chrome on Android"
        case .googlebot: "Googlebot"
        }
    }

    var note: String? {
        switch self {
        case .systemDefault: "WKWebView 自带的 UA"
        case .iPadSafari: "移动版串；iPadOS 默认其实发的是 macOS 串"
        case .googlebot: "拿来绕付费墙的老办法，成功率看站点"
        default: nil
        }
    }

    /// nil 表示交回系统默认
    var value: String? {
        switch self {
        case .systemDefault:
            nil
        case .iPhoneSafari:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1"
        case .iPadSafari:
            "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1"
        case .macSafari:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"
        case .macChrome:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
        case .androidChrome:
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Mobile Safari/537.36"
        case .googlebot:
            "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        }
    }

    /// 反查：给定 UA 串落在哪个预设上，落不上就是"自定义"
    static func matching(_ userAgent: String?) -> UserAgentPreset? {
        allCases.first { $0.value == userAgent }
    }
}
