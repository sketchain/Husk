import Foundation
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

/// 实验室页的诊断探针：把机型、系统、屏幕、安全区和 `_exclusionArea` 的读取结果
/// 拼成一份能贴回来的报告。
///
/// `_exclusionArea` 本身的安全读取（每一跳先 `responds(to:)`）在
/// `ExclusionAreaReader` 里，浏览页的进度环和这里共用那一份。这里只负责
/// "读到什么如实报出来"，贴不贴得上要靠 `LabView` 的可视化叠加在真机上人眼校准。
@MainActor
enum DynamicIslandProbe {
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
        // iOS 26 起 scene.interfaceOrientation 废弃，改从 effectiveGeometry 读
        report.fields.append(
            LabField(
                label: "界面方向",
                value: orientationText(scene.effectiveGeometry.interfaceOrientation)
            )
        )

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

        let reading = ExclusionAreaReader.read(on: screen)
        report.fields.append(contentsOf: reading.trace.map { LabField(label: $0.label, value: $0.value) })
        report.exclusionRect = reading.rect
        report.failure = reading.failure

        // 浏览页进度环会不会用上这组数——和设置里「环绕灵动岛」的判定是同一个函数
        let verdict = IslandRingResolver.resolve(in: scene)
        report.fields.append(LabField(label: "进度环判定", value: verdict.labDescription))

        return report
    }

    private static func displayCornerRadius(of screen: UIScreen) -> CGFloat? {
        guard screen.responds(to: NSSelectorFromString(cornerRadiusKey)) else { return nil }
        return (screen.value(forKey: cornerRadiusKey) as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    // MARK: - 环境

    static var activeScene: UIWindowScene? { ExclusionAreaReader.activeScene }

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
