import Foundation

/// `.mobileconfig` 的结构体定义。
///
/// 用 `PropertyListEncoder` 生成，不手拼 XML——手拼的转义、data 的 base64 折行、
/// 键序，错一个 iOS 就整份拒绝安装，而且报错信息毫无用处。
struct WebClipProfile: Encodable {
    var payloadContent: [WebClipEntry]
    var payloadDisplayName: String
    var payloadIdentifier: String
    var payloadUUID: String
    var payloadDescription: String
    var payloadOrganization: String = "Husk"
    var payloadType: String = "Configuration"
    var payloadVersion: Int = 1
    var payloadRemovalDisallowed: Bool = false

    enum CodingKeys: String, CodingKey {
        case payloadContent = "PayloadContent"
        case payloadDisplayName = "PayloadDisplayName"
        case payloadIdentifier = "PayloadIdentifier"
        case payloadUUID = "PayloadUUID"
        case payloadDescription = "PayloadDescription"
        case payloadOrganization = "PayloadOrganization"
        case payloadType = "PayloadType"
        case payloadVersion = "PayloadVersion"
        case payloadRemovalDisallowed = "PayloadRemovalDisallowed"
    }
}

/// 单个 Web Clip payload。
struct WebClipEntry: Encodable {
    /// 主屏图标的名字
    var label: String
    /// 点开去哪儿。本项目填 `husk://open?id=<UUID>`，让它回到 Husk 而不是 Safari。
    var url: String
    /// PNG 图标数据。PropertyListEncoder 会把 Data 编成 <data> base64，不用自己转。
    var icon: Data?
    /// 让用户能自己删掉这个图标。设 false 的话只能连整个描述文件一起删。
    var isRemovable: Bool = true
    /// 全屏模式。指向 husk:// 时没意义（打开的是 app 不是网页），保留给 https 版本用。
    var fullScreen: Bool = true
    /// 别让网站的 manifest scope 把导航限制住
    var ignoreManifestScope: Bool = true
    var precomposed: Bool = true

    var payloadType: String = "com.apple.webClip.managed"
    var payloadIdentifier: String
    var payloadUUID: String
    var payloadVersion: Int = 1
    var payloadDisplayName: String

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case url = "URL"
        case icon = "Icon"
        case isRemovable = "IsRemovable"
        case fullScreen = "FullScreen"
        case ignoreManifestScope = "IgnoreManifestScope"
        case precomposed = "Precomposed"
        case payloadType = "PayloadType"
        case payloadIdentifier = "PayloadIdentifier"
        case payloadUUID = "PayloadUUID"
        case payloadVersion = "PayloadVersion"
        case payloadDisplayName = "PayloadDisplayName"
    }
}
