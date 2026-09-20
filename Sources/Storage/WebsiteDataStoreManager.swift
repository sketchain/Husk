import CryptoKit
import Foundation
import WebKit

/// 每个站点的存储隔离（cookie / localStorage / IndexedDB / 缓存）都靠这里。
///
/// 这个文件里的每一条约束都是踩过的坑，改之前先读注释：
///
/// 1. `WKWebsiteDataStore(forIdentifier:)` 收的是 `UUID`，不是随便一个字符串。
///    用户填的 profile 名要稳定映射成 UUID（这里用 SHA256 取前 16 字节），
///    保证同一个名字在任何时候、任何设备上都算出同一个 UUID。
///
/// 2. **每次调用 `init(forIdentifier:)` 都会返回一个全新对象。** 同一个 UUID 调两次会拿到
///    两个实例指向同一份磁盘数据，WebKit 把它们当成两个不同的 store，于是静默失去
///    网络进程 / 存储进程共享——表现就是两个 WebView 明明"同一个 profile"却不共享登录态。
///    所以必须做缓存：一个标识**只发一个实例**。
///
/// 3. `WKProcessPool` 已经废弃，也不再影响进程共享。别拿它来"修"共享问题。
///
/// 4. `remove(forIdentifier:)` 在还有实例存活时会抛 `Data store is in use`，
///    干重试没用。必须先从缓存里移除、把引用放掉，再重试几次覆盖 dealloc 的延迟。
///
/// 5. 默认 store（`.default()`）删不掉，只能 `removeData(ofTypes:modifiedSince:)`。
///    "清除全部"得同时走这两条路。
@MainActor
final class WebsiteDataStoreManager {
    static let shared = WebsiteDataStoreManager()

    /// 坑 2 的解法：标识 → 唯一实例
    private var cache: [UUID: WKWebsiteDataStore] = [:]

    private init() {}

    // MARK: - 标识映射

    /// profile 名 → 稳定 UUID。
    ///
    /// 用 SHA256 而不是 `String.hashValue`：后者带每次启动随机化的 seed，
    /// 换一次进程就换一个值，存储会整个"丢失"。
    nonisolated static func identifier(forProfile profile: String) -> UUID {
        let digest = SHA256.hash(data: Data(profile.utf8))
        var bytes = Array(digest.prefix(16))
        // 按 RFC 9562 把版本位打成 8（自定义），变体位打成 RFC 变体。
        // 顺带保证结果永远不是全零 UUID —— WebKit 对空 UUID 会直接抛异常。
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: tuple)
    }

    // MARK: - 取用

    /// 拿到某个 profile 的 data store。同一个 profile 永远返回同一个实例（坑 2）。
    func dataStore(forProfile profile: String) -> WKWebsiteDataStore {
        let id = Self.identifier(forProfile: profile)
        if let existing = cache[id] { return existing }
        // 注意：`init(forIdentifier:)` 对不存在的标识会直接创建，不能拿它做存在性检查（见 `existingIdentifiers`）。
        let store = WKWebsiteDataStore(forIdentifier: id)
        cache[id] = store
        return store
    }

    /// 磁盘上真实存在的 store 标识。做孤儿清理用。
    func existingIdentifiers() async -> [UUID] {
        await WKWebsiteDataStore.fetchAllDataStoreIdentifiers()
    }

    // MARK: - 清除

    /// 清掉某个 profile 的全部数据，并把这个 store 从磁盘上删掉。
    func removeProfile(_ profile: String) async throws {
        try await removeIdentifier(Self.identifier(forProfile: profile))
    }

    /// 坑 4：先断引用，再重试。
    func removeIdentifier(_ id: UUID) async throws {
        // 先把缓存里的实例放掉，否则 WebKit 认为这个 store "in use"，重试多少次都一样。
        cache.removeValue(forKey: id)

        var lastError: (any Error)?
        // 5 次 × 250ms：覆盖 WebView 释放后 store 对象真正 dealloc 的那点延迟。
        for attempt in 0..<5 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
    }

    /// 清掉默认 store 的所有数据。
    ///
    /// 坑 5：默认 store 没法删除，只能清空内容。临时站点用的就是它，
    /// 所以"清除全部"必须带上这一步。
    func clearDefaultStore() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    /// 清除全部：磁盘上每一个具名 store + 默认 store。
    /// - Returns: 成功删掉的具名 store 个数
    @discardableResult
    func clearEverything() async -> Int {
        let ids = await existingIdentifiers()
        var removed = 0
        for id in ids {
            if (try? await removeIdentifier(id)) != nil { removed += 1 }
        }
        await clearDefaultStore()
        return removed
    }

    /// 找出磁盘上存在、但已经没有任何站点在用的 store（删过站点但没清存储就会留下这些）。
    func orphanIdentifiers(knownProfiles: [String]) async -> [UUID] {
        let known = Set(knownProfiles.map(Self.identifier(forProfile:)))
        return await existingIdentifiers().filter { !known.contains($0) }
    }

    /// 清理孤儿 store。
    /// - Returns: (成功, 失败)
    func removeOrphans(knownProfiles: [String]) async -> (removed: Int, failed: Int) {
        let orphans = await orphanIdentifiers(knownProfiles: knownProfiles)
        var removed = 0
        var failed = 0
        for id in orphans {
            if (try? await removeIdentifier(id)) != nil { removed += 1 } else { failed += 1 }
        }
        return (removed, failed)
    }

    /// 某个 profile 名下有多少条网站数据记录。
    ///
    /// 刻意不报字节数：`WKWebsiteDataRecord` 根本不提供大小，只按域名分条，
    /// 真想要精确占用得自己去翻沙盒目录，不值当。拿"几个域名留了数据"当指示够用了。
    func recordCount(forProfile profile: String) async -> Int {
        let store = dataStore(forProfile: profile)
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return records.count
    }
}
