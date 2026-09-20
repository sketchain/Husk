import Foundation

/// 沙盒里的目录布局，集中一处免得到处拼路径。
///
/// 全部放在 Application Support 而不是 Documents：这些是 app 的内部状态，
/// 不该出现在"文件" app 里给用户看。
enum AppPaths {
    static var support: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        let dir = base.appending(path: "Husk", directoryHint: .isDirectory)
        ensureDirectory(dir)
        return dir
    }

    static var iconsDirectory: URL {
        let dir = support.appending(path: "Icons", directoryHint: .isDirectory)
        ensureDirectory(dir)
        return dir
    }

    static var libraryFile: URL {
        support.appending(path: "library.json", directoryHint: .notDirectory)
    }

    /// 自动抓取来的图标缓存
    static func cachedIcon(for id: UUID) -> URL {
        iconsDirectory.appending(path: "\(id.uuidString)-auto.png", directoryHint: .notDirectory)
    }

    /// 用户自选的图片
    static func customIcon(for id: UUID) -> URL {
        iconsDirectory.appending(path: "\(id.uuidString)-custom.png", directoryHint: .notDirectory)
    }

    /// 首字母占位图缓存
    static func monogramIcon(for id: UUID) -> URL {
        iconsDirectory.appending(path: "\(id.uuidString)-mono.png", directoryHint: .notDirectory)
    }

    static func removeIcons(for id: UUID) {
        for url in [cachedIcon(for: id), customIcon(for: id), monogramIcon(for: id)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func ensureDirectory(_ url: URL) {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
