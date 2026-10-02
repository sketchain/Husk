import SwiftUI

/// 只能停在整格上的滑块，替代系统 `Slider` 用在缩放档位表上。
///
/// 系统滑块放进 sheet 里的 Form 之后很难拖，毛病有三：
/// 1. 只认按在拇指上的触摸，按偏一点就变成了列表滚动或者 sheet 拖动；
/// 2. 起手稍微带点竖直分量，外面的滚动视图就把手势抢走了；
/// 3. 点轨道不会跳过去，只能去找那个拇指。
///
/// 这里整条 44pt 高的轨道都是热区，`minimumDistance: 0` 让手指一按下就归滑块。
/// 按在拇指附近是相对拖动（拇指不会先跳一下），按在别处则先跳到那一格再接着拖。
/// 每过一格给一下 selection 触感，停在哪一格手上就有数。
struct StopSlider: View {
    @Binding var index: Int
    let count: Int
    /// 在轨道上标一个小点（比如 100% 那一格），拇指压上去时隐藏
    var marker: Int? = nil
    /// 开始 / 结束拖动。调用方在结束时写盘
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    /// 按下时手指相对拇指中心的偏移；按在拇指外就是 0（直接跳过去）
    @State private var grabOffset: CGFloat = 0
    /// 手势被系统取消（比如 sheet 被收走）时 onEnded 不会来，靠它复位
    @GestureState private var isPressed = false

    private let thumbSize: CGFloat = 26
    private let trackHeight: CGFloat = 6
    private let hitHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = position(of: index, width: width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: thumbX, height: trackHeight)
                if let marker, marker != index {
                    Circle()
                        .fill(marker < index ? Color.white.opacity(0.85) : Color.primary.opacity(0.45))
                        .frame(width: 5, height: 5)
                        .offset(x: position(of: marker, width: width) - 2.5)
                }
                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .scaleEffect(isDragging ? 1.15 : 1)
                    .offset(x: thumbX - thumbSize / 2)
            }
            .frame(width: width, height: hitHeight)
            .contentShape(Rectangle())
            .gesture(drag(width: width, thumbX: thumbX))
        }
        .frame(height: hitHeight)
        .animation(.snappy(duration: 0.12), value: index)
        .animation(.snappy(duration: 0.15), value: isDragging)
        .sensoryFeedback(.selection, trigger: index)
        .onChange(of: isPressed) { _, pressed in
            guard !pressed, isDragging else { return }
            isDragging = false
            onEditingChanged(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(index + 1, count - 1)
            case .decrement: index = max(index - 1, 0)
            @unknown default: return
            }
            onEditingChanged(false)
        }
    }

    private func drag(width: CGFloat, thumbX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isPressed) { _, state, _ in state = true }
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    let delta = value.startLocation.x - thumbX
                    // 拇指周围一圈都算"抓住拇指"，手指不必精确压在圆上
                    grabOffset = abs(delta) <= thumbSize ? delta : 0
                    onEditingChanged(true)
                }
                let target = nearestIndex(to: value.location.x - grabOffset, width: width)
                if target != index { index = target }
            }
    }

    // MARK: - 几何

    /// 拇指中心能到的范围是 [thumbSize/2, width - thumbSize/2]，两端不会探出轨道
    private func position(of i: Int, width: CGFloat) -> CGFloat {
        let inset = thumbSize / 2
        let usable = max(width - thumbSize, 1)
        return inset + usable * CGFloat(i) / CGFloat(max(count - 1, 1))
    }

    private func nearestIndex(to x: CGFloat, width: CGFloat) -> Int {
        let usable = max(width - thumbSize, 1)
        let fraction = (x - thumbSize / 2) / usable
        return Int((fraction * CGFloat(count - 1)).rounded()).clamped(to: 0...(count - 1))
    }
}
