import UIKit
// touchesBegan / reset() 这些"给子类用"的方法声明在 UIGestureRecognizerSubclass.h 里，
// Swift 侧必须显式 import 这个子模块才看得见，不然子类里的 override 会报"没有可覆盖的方法"。
import UIKit.UIGestureRecognizerSubclass

/// 工具箱的四种唤出手势。
///
/// 刻意避开的两种：
/// - **单指边缘滑**：撞 `allowsBackForwardNavigationGestures`，前进后退比工具箱重要
/// - **单指长按**：撞选中文字、链接预览（Peek），是页面自己的基本交互
///
/// 剩下这四种都要么多指、要么限定在底边很窄的一条，和页面内手势基本不打架；
/// 打架的那点靠 `shouldRecognizeSimultaneouslyWith` 返回 true 让两边都能识别。
@MainActor
final class ToolboxGestureInstaller: NSObject, UIGestureRecognizerDelegate {
    var onTrigger: (() -> Void)?

    private weak var host: UIView?
    private var recognizers: [UIGestureRecognizer] = []
    /// 底边上滑那个要单独认出来做起手位置判断
    private weak var bottomSwipe: BottomEdgeSwipeGestureRecognizer?

    /// 底边判定区高度。太大就会在页面下半部乱触发。
    private let bottomEdgeHeight: CGFloat = 48

    func install(on view: UIView, settings: GestureSettings) {
        removeAll()
        host = view

        if settings.twoFingerSwipeDown {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handle(_:)))
            swipe.direction = .down
            swipe.numberOfTouchesRequired = 2
            add(swipe, to: view)
        }

        if settings.bottomEdgeSwipeUp {
            // 用 UISwipeGestureRecognizer 而不是 UIScreenEdgePanGestureRecognizer(.bottom)：
            // 屏幕底边被系统的主屏指示器 / 控制中心占着，边缘 pan 要靠
            // preferredScreenEdgesDeferringSystemGestures 争抢，体验是"要划两次"。
            // swipe 判定快、失败得也快，不会把页面滚动卡住。
            //
            // 用的是子类，因为要拿**起手位置**——见 BottomEdgeSwipeGestureRecognizer 的注释。
            let swipe = BottomEdgeSwipeGestureRecognizer(target: self, action: #selector(handle(_:)))
            swipe.direction = .up
            swipe.numberOfTouchesRequired = 1
            bottomSwipe = swipe
            add(swipe, to: view)
        }

        if settings.threeFingerTap {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handle(_:)))
            tap.numberOfTouchesRequired = 3
            tap.numberOfTapsRequired = 1
            add(tap, to: view)
        }

        if settings.twoFingerLongPress {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            press.numberOfTouchesRequired = 2
            press.minimumPressDuration = 0.35
            // 两指按住时手指会有轻微移动，放宽一点否则很难触发
            press.allowableMovement = 24
            add(press, to: view)
        }
    }

    func removeAll() {
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        recognizers.removeAll()
        bottomSwipe = nil
    }

    private func add(_ recognizer: UIGestureRecognizer, to view: UIView) {
        recognizer.delegate = self
        // 页面里的链接点击、滚动都不该被这些手势吃掉
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        view.addGestureRecognizer(recognizer)
        recognizers.append(recognizer)
    }

    @objc private func handle(_ recognizer: UIGestureRecognizer) {
        switch recognizer {
        case is UILongPressGestureRecognizer:
            // 长按会连续回调，只认起始那一下
            guard recognizer.state == .began else { return }
        default:
            guard recognizer.state == .recognized || recognizer.state == .ended else { return }
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onTrigger?()
    }

    // MARK: - UIGestureRecognizerDelegate

    /// 和 WebView 内部那一大堆手势（滚动、缩放、选中、链接预览）共存，
    /// 不这么做的话多指手势会被 scroll view 的 pan 抢先，基本触发不了。
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// 底边上滑限定**起手位置**：只有从底部那一条开始的上滑才算数，
    /// 否则页面里任何一次向上滑（也就是正常往下读）都会弹工具箱。
    ///
    /// 这里用的是记录下来的起手点，不是 `gestureRecognizer.location(in:)`。
    /// 后者返回的是**当前**位置，而 UIKit 调到这个回调时 swipe 已经判定成立了
    /// ——手指早就滑出去几十点，必然落在判定区之外，于是这个手势永远触发不了。
    ///
    /// 判定区还刻意**避开底部安全区**（主屏指示器那一条）：从那里往上滑会被系统
    /// 当成回桌面，要抢过来就得 `preferredScreenEdgesDeferringSystemGestures`，
    /// 代价是用户真想回桌面得划两次。把判定区挪到指示器上方 48pt，两边都不打架。
    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            guard let swipe = gestureRecognizer as? BottomEdgeSwipeGestureRecognizer,
                  swipe === bottomSwipe,
                  let host
            else { return true }
            guard let start = swipe.initialLocation else { return false }

            let systemZone = host.safeAreaInsets.bottom   // 主屏指示器占着的那一条
            let upper = host.bounds.height - systemZone - bottomEdgeHeight
            let lower = host.bounds.height - systemZone
            return start.y >= upper && start.y <= lower
        }
    }
}

/// 只为拿到起手位置而存在的子类。
///
/// `UISwipeGestureRecognizer` 不保留起始点，而 `gestureRecognizerShouldBegin` 又是在
/// 滑动判定成立之后才被调用的，那时 `location(in:)` 早已不在起手处。
/// 在 `touchesBegan` 里存一份是唯一干净的拿法。
final class BottomEdgeSwipeGestureRecognizer: UISwipeGestureRecognizer {
    private(set) var initialLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if initialLocation == nil {
            initialLocation = touches.first?.location(in: view)
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        initialLocation = nil
    }
}
