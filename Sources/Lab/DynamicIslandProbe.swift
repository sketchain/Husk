import Foundation
import ObjectiveC
import UIKit

/// 诊断页上的一行"名字：值"
struct LabField: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let value: String
}

/// 一次探测的完整结果
struct IslandDiagnostics: Sendable {
    var fields: [LabField] = []
    /// 从 `_exclusionArea` 真读到的传感器避让区（screen points）。nil = 没读到。
    var exclusionRect: CGRect?
    /// 读取卡在哪一步。成功时是 nil。
    var failure: String?
    /// 探测时机，复制出来的报告里带上
    var takenAt = Date()

    var succeeded: Bool { exclusionRect != nil }
}

/// 读取灵动岛几何信息的探针。
///
/// 公开 API 拿不到灵动岛的位置和尺寸：`safeAreaInsets.top` 只给一个高度，
/// 横向范围完全没有，圆角更没有。已知唯一的来源是私有属性
/// `UIScreen._exclusionArea`——按逆向资料它返回一个 `UISDisplaySingleRectShape`，
/// 其 `rect` 是**传感器避让区的外接矩形**（单位 screen points），
/// iOS 16 到 26 都有实际使用证据。
///
/// 注意它给的是避让区，不保证和系统画的那颗黑色胶囊边缘严丝合缝，也不给圆角。
/// 所以这个探针只负责"读到什么如实报出来"，贴不贴得上要靠 `LabView` 的
/// 可视化叠加在真机上人眼校准。
///
/// **为什么每一跳都先 `responds(to:)`**：对不存在的 key 调 `value(forKey:)`
/// 抛的是 ObjC 的 `NSUnknownKeyException`，Swift 的 `do-catch` 根本接不住，
/// 结果是直接闪退。私有 API 随时可能改名、换类型或者整个消失，所以这里
/// 每一步都先确认选择器在，不在就带着"卡在哪一步"原地返回——
/// 绝不能因为一个测试页把 app 搞崩。
@MainActor
enum DynamicIslandProbe {
    /// `UIScreen` 上那个私有属性的名字
    private static let exclusionKey = "_exclusionArea"

    /// shape 对象上可能装着矩形的属性名，按可能性从高到低试。
    /// `rect` 是 `UISDisplaySingleRectShape` 的；`rects` 是多矩形形状的；
    /// `bounds` 纯属兜底，万一哪天换了个类型。
    private static let rectKeys = ["rect", "rects", "bounds"]

    /// 屏幕圆角，同样是私有属性。和灵动岛无关，但校准时想知道这台设备的
    /// 屏幕圆角有多大——顺手读了一起报出来。
    private static let cornerRadiusKey = "_displayCornerRadius"

    // MARK: - 入口

    static func run() -> IslandDiagnostics {
        var report = IslandDiagnostics()

        report.fields.append(LabField(label: "机型标识", value: machine))
        report.fields.append(
            LabField(
                label: "系统",
                value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            )
        )
        report.fields.append(
            LabField(
                label: "系统（完整）",
                value: ProcessInfo.processInfo.operatingSystemVersionString
            )
        )

        guard let scene = activeScene else {
            report.failure = "拿不到 UIWindowScene——app 可能正在后台。回前台再试一次。"
            return report
        }

        let screen = scene.screen
        report.fields.append(LabField(label: "UIScreen.bounds", value: format(screen.bounds)))
        report.fields.append(LabField(label: "UIScreen.nativeBounds", value: format(screen.nativeBounds)))
        report.fields.append(LabField(label: "scale / nativeScale", value: "\(fmt(screen.scale)) / \(fmt(screen.nativeScale))"))
        report.fields.append(LabField(label: "界面方向", value: orientationText(scene.interfaceOrientation)))

        // 屏幕圆角：读不到就写"读不到"，它不影响主流程
        report.fields.append(
            LabField(
                label: "_displayCornerRadius",
                value: displayCornerRadius(of: screen).map { fmt($0) } ?? "读不到（选择器不存在）"
            )
        )

        if let window = scene.keyWindow ?? scene.windows.first {
            report.fields.append(LabField(label: "窗口 bounds", value: format(window.bounds)))
            report.fields.append(LabField(label: "窗口 safeAreaInsets", value: format(window.safeAreaInsets)))
        } else {
            report.fields.append(LabField(label: "窗口 safeAreaInsets", value: "这个 scene 下没有窗口"))
        }

        let probe = probeExclusionArea(on: screen)
        report.fields.append(contentsOf: probe.fields)
        report.exclusionRect = probe.rect
        report.failure = probe.failure

        return report
    }

    // MARK: - `_exclusionArea`

    /// 返回值里的 `fields` 无论成功失败都要拼进报告——失败时它记录的是
    /// "走到哪一步、看见了什么"，恰恰是最该贴回来的部分。
    private static func probeExclusionArea(
        on screen: UIScreen
    ) -> (fields: [LabField], rect: CGRect?, failure: String?) {
        var fields: [LabField] = []

        // 第 1 步：UIScreen 上有没有这个选择器
        guard screen.responds(to: NSSelectorFromString(exclusionKey)) else {
            fields.append(LabField(label: "_exclusionArea", value: "选择器不存在"))
            return (
                fields, nil,
                "第 1 步：UIScreen 上没有 -_exclusionArea。可能是这个版本的 iOS 改了私有 API，"
                    + "也可能这台设备本来就没有传感器避让区（无刘海/无灵动岛的机型）。"
            )
        }

        // 第 2 步：读出来。选择器已经确认存在，KVC 到这一步不会抛 NSUnknownKeyException。
        guard let raw = screen.value(forKey: exclusionKey) else {
            fields.append(LabField(label: "_exclusionArea", value: "选择器在，但返回 nil"))
            return (
                fields, nil,
                "第 2 步：-_exclusionArea 返回了 nil。这台设备大概率没有传感器避让区。"
            )
        }

        // 第 3 步：拿到对象，先把身份信息记下来。哪怕后面取 rect 失败，
        // 这两行也足够判断私有 API 变成了什么样子。
        let shapeClass = object_getClass(raw).map { NSStringFromClass($0) } ?? "取不到类名"
        fields.append(LabField(label: "_exclusionArea 类名", value: shapeClass))
        fields.append(LabField(label: "_exclusionArea description", value: String(describing: raw)))

        guard let shape = raw as? NSObject else {
            return (
                fields, nil,
                "第 3 步：返回的东西不是 NSObject（类名 \(shapeClass)），没法继续用 KVC 往里取。"
            )
        }

        // 第 4 步：逐个试候选 key，同样每次先 responds(to:)
        var triedKeys: [String] = []
        for key in rectKeys {
            guard shape.responds(to: NSSelectorFromString(key)) else {
                triedKeys.append("\(key)✗")
                continue
            }
            triedKeys.append("\(key)✓")
            let value = shape.value(forKey: key)
            guard let rect = cgRect(from: value) else {
                fields.append(
                    LabField(
                        label: "\(shapeClass).\(key)",
                        value: "有这个属性，但取出来不是 CGRect：\(String(describing: value))"
                    )
                )
                continue
            }
            fields.append(LabField(label: "取到的 rect（来自 .\(key)）", value: format(rect)))
            return (fields, rect, nil)
        }

        fields.append(LabField(label: "试过的 key", value: triedKeys.joined(separator: " ")))
        return (
            fields, nil,
            "第 4 步：\(shapeClass) 上没有任何一个候选 key（\(rectKeys.joined(separator: " / "))）"
                + "能取出 CGRect。把上面那行 description 贴回来，就能看出矩形藏在哪个属性里。"
        )
    }

    private static func displayCornerRadius(of screen: UIScreen) -> CGFloat? {
        guard screen.responds(to: NSSelectorFromString(cornerRadiusKey)) else { return nil }
        return (screen.value(forKey: cornerRadiusKey) as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    /// CGRect 装进 NSValue 之后的 ObjC 类型编码。算一次存成 String：
    /// 直接留着 `objCType` 那个指针，会随着产生它的临时 NSValue 一起失效。
    private static let cgRectEncoding = String(cString: NSValue(cgRect: .zero).objCType)

    /// KVC 把结构体返回值装箱成 NSValue，但**不保证**装的就是 CGRect。
    /// 类型对不上时 `cgRectValue` 不是返回 nil 而是直接崩，所以先比一遍 objCType。
    private static func cgRect(from any: Any?) -> CGRect? {
        if let value = any as? NSValue {
            guard String(cString: value.objCType) == cgRectEncoding else { return nil }
            return value.cgRectValue
        }
        // 多矩形形状（`rects`）：把所有矩形并起来当外接矩形用
        if let values = any as? [NSValue] {
            let rects = values.compactMap { cgRect(from: $0) }
            guard let first = rects.first else { return nil }
            return rects.dropFirst().reduce(first) { $0.union($1) }
        }
        return nil
    }

    // MARK: - 环境

    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// `utsname.machine`，例如 `iPhone18,1`。模拟器上拿到的是宿主机架构，
    /// 真机标识在 `SIMULATOR_MODEL_IDENTIFIER` 环境变量里。
    static var machine: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated)（模拟器）"
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "uname 失败" }
        // machine 是定长 C 数组，在 Swift 里是个大元组。走 Mirror 逐字节读到 \0 为止，
        // 而不是 withUnsafePointer(to: &info.machine)——后者在闭包里再碰 info
        // 就是一次重叠的独占访问，Swift 6 下会直接报错。
        var bytes: [UInt8] = []
        for child in Mirror(reflecting: info.machine).children {
            guard let byte = child.value as? CChar, byte != 0 else { break }
            bytes.append(UInt8(bitPattern: byte))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - 格式化

    static func fmt(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    static func format(_ rect: CGRect) -> String {
        "x=\(fmt(rect.origin.x)) y=\(fmt(rect.origin.y)) w=\(fmt(rect.width)) h=\(fmt(rect.height))"
    }

    static func format(_ insets: UIEdgeInsets) -> String {
        "top=\(fmt(insets.top)) left=\(fmt(insets.left)) bottom=\(fmt(insets.bottom)) right=\(fmt(insets.right))"
    }

    private static func orientationText(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "竖屏"
        case .portraitUpsideDown: "竖屏倒置"
        case .landscapeLeft: "横屏（左）"
        case .landscapeRight: "横屏（右）"
        default: "未知"
        }
    }
}
