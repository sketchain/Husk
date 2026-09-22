import Foundation

/// 缩放滑块的刻度表。
///
/// 范围拉到 10%–200% 之后，线性滑块就不好用了：10%–100% 占掉滑轨的 47%，
/// 而日常真正会调的 90%–125% 挤在中间几个像素里，想停在 100% 基本靠运气。
///
/// 所以滑块不直接绑 zoom，而是绑这张表的下标——每一格都是一个能说出口的档位，
/// 低段跨度大、常用段跨度小，且一定能精准停在 100%。
enum ZoomScale {
    static let stops: [Double] = [
        0.10, 0.15, 0.20, 0.25, 0.33, 0.40, 0.50, 0.60, 0.67, 0.75, 0.80, 0.90,
        1.00,
        1.10, 1.25, 1.40, 1.50, 1.75, 2.00,
    ]

    static var indexRange: ClosedRange<Double> { 0...Double(stops.count - 1) }

    /// 任意 zoom → 最近的一格。老配置里 0.85 这种表外的值也能落到滑块上。
    static func index(for zoom: Double) -> Double {
        let value = zoom.clamped(to: Site.zoomRange)
        var best = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (i, stop) in stops.enumerated() {
            let delta = abs(stop - value)
            if delta < bestDelta {
                bestDelta = delta
                best = i
            }
        }
        return Double(best)
    }

    static func zoom(atIndex index: Double) -> Double {
        let i = Int(index.rounded()).clamped(to: 0...(stops.count - 1))
        return stops[i]
    }

    static func percentText(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }
}
