import Foundation
import ObjectiveC
import UIKit

/// 一次 `_exclusionArea` 读取的结果
struct ExclusionAreaReading: Sendable {
    /// 读取过程中看到的东西，按顺序。成功失败都有——失败时它记录的是
    /// "走到哪一步、看见了什么"，实验室页会原样拼进诊断报告。
    struct TraceLine: Sendable {
        let label: String
        let value: String
    }

    var trace: [TraceLine] = []
    /// 传感器避让区（screen points）。nil = 没读到。
    var rect: CGRect?
    /// 卡在哪一步。成功时是 nil。
    var failure: String?
}

/// 安全读取私有属性 `UIScreen._exclusionArea`。
///
/// 从实验室的 `DynamicIslandProbe` 里拆出来的：浏览页的进度环也要读它，
/// 读取逻辑只能有一份。实验室继续在外面拼机型、系统、安全区那些诊断信息。
///
/// 公开 API 拿不到灵动岛的位置和尺寸：`safeAreaInsets.top` 只给一个高度，
/// 横向范围完全没有，圆角更没有。已知唯一的来源是这个私有属性——按逆向资料它返回
/// 一个 `UISDisplaySingleRectShape`，其 `rect` 是**传感器避让区的外接矩形**
/// （单位 screen points），iOS 16 到 26 都有实际使用证据。
///
/// **为什么每一跳都先 `responds(to:)`**：对不存在的 key 调 `value(forKey:)`
/// 抛的是 ObjC 的 `NSUnknownKeyException`，Swift 的 `do-catch` 根本接不住，
/// 结果是直接闪退。私有 API 随时可能改名、换类型或者整个消失，所以这里
/// 每一步都先确认选择器在，不在就带着"卡在哪一步"原地返回——
/// 一个进度条样式绝不能把 app 搞崩。
@MainActor
enum ExclusionAreaReader {
    /// `UIScreen` 上那个私有属性的名字
    private static let exclusionKey = "_exclusionArea"

    /// shape 对象上可能装着矩形的属性名，按可能性从高到低试。
    /// `rect` 是 `UISDisplaySingleRectShape` 的；`rects` 是多矩形形状的；
    /// `bounds` 纯属兜底，万一哪天换了个类型。
    private static let rectKeys = ["rect", "rects", "bounds"]

    static func read(on screen: UIScreen) -> ExclusionAreaReading {
        var reading = ExclusionAreaReading()

        // 第 1 步：UIScreen 上有没有这个选择器
        guard screen.responds(to: NSSelectorFromString(exclusionKey)) else {
            reading.trace.append(.init(label: "_exclusionArea", value: "选择器不存在"))
            reading.failure = "第 1 步：UIScreen 上没有 -_exclusionArea。可能是这个版本的 iOS 改了私有 API，"
                + "也可能这台设备本来就没有传感器避让区（无刘海/无灵动岛的机型）。"
            return reading
        }

        // 第 2 步：读出来。选择器已经确认存在，KVC 到这一步不会抛 NSUnknownKeyException。
        guard let raw = screen.value(forKey: exclusionKey) else {
            reading.trace.append(.init(label: "_exclusionArea", value: "选择器在，但返回 nil"))
            reading.failure = "第 2 步：-_exclusionArea 返回了 nil。这台设备大概率没有传感器避让区。"
            return reading
        }

        // 第 3 步：拿到对象，先把身份信息记下来。哪怕后面取 rect 失败，
        // 这两行也足够判断私有 API 变成了什么样子。
        let shapeClass = object_getClass(raw).map { NSStringFromClass($0) } ?? "取不到类名"
        reading.trace.append(.init(label: "_exclusionArea 类名", value: shapeClass))
        reading.trace.append(.init(label: "_exclusionArea description", value: String(describing: raw)))

        guard let shape = raw as? NSObject else {
            reading.failure = "第 3 步：返回的东西不是 NSObject（类名 \(shapeClass)），没法继续用 KVC 往里取。"
            return reading
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
                reading.trace.append(
                    .init(
                        label: "\(shapeClass).\(key)",
                        value: "有这个属性，但取出来不是 CGRect：\(String(describing: value))"
                    )
                )
                continue
            }
            reading.trace.append(.init(label: "取到的 rect（来自 .\(key)）", value: describe(rect)))
            reading.rect = rect
            return reading
        }

        reading.trace.append(.init(label: "试过的 key", value: triedKeys.joined(separator: " ")))
        reading.failure = "第 4 步：\(shapeClass) 上没有任何一个候选 key（\(rectKeys.joined(separator: " / "))）"
            + "能取出 CGRect。把上面那行 description 贴回来，就能看出矩形藏在哪个属性里。"
        return reading
    }

    // MARK: - 解包

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

    private static func describe(_ rect: CGRect) -> String {
        func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
        return "x=\(f(rect.minX)) y=\(f(rect.minY)) w=\(f(rect.width)) h=\(f(rect.height))"
    }

    // MARK: - 环境

    /// 前台活跃的那个 window scene。iPhone 上只会有一个。
    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
