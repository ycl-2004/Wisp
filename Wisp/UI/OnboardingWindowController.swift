import AppKit
import Combine
import SwiftUI

/// 首次设置向导的窗口宿主（UX 改造第 3 项）：向导从面板的 sheet 毕业
/// 成一个独立的普通窗口——有自己的标题栏、关闭按钮和生命周期，不再
/// 被无边框面板的几何（110 高、底部锚定、向上膨胀）和闲置收起牵连。
///
/// 分工：模型只持镜像状态 `showsOnboarding`，谁想开向导就调
/// `AssistantModel.presentOnboarding()`；本控制器在 `start()` 后观察
/// 这个标记开/关窗。窗口消失的两条路（用户点关闭按钮 / 程序置 false）
/// 统一在 `markGone()` 收口，回到模型走 `onboardingWindowClosed()`
/// 记账——与 sheet 时代 onDismiss 的语义逐条对应。写法对齐
/// `NotesPanelController`（懒建窗、isReleasedWhenClosed = false、
/// ScreenPrivacy 同等待遇：窗里有 Key 输入框，隐私姿态不能比 sheet
/// 时代倒退）。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    static let width: CGFloat = 560
    /// 高度按内容拟合、封顶于此。超出的部分由向导里唯一的滚动区
    /// （内嵌的 `ModelSettingsView` 自带 ScrollView）吸收。
    static let maxHeight: CGFloat = 640
    /// 拟合的兜底下限：ScrollView 的拟合高度若报出异常小的值，窗口
    /// 也不至于矮到三步挤不下——矮了只是滚动区变短，不该破窗。
    static let minHeight: CGFloat = 400

    private var window: NSWindow?
    private var observation: AnyCancellable?
    private var isPresented = false
    /// windowWillClose 里置模型标记时抑制观察者：窗口已在关闭流程中，
    /// 不让观察者再去 orderOut 它；记账由 windowWillClose 自己收口。
    private var suppressObservation = false

    /// 供面板截图排除自家窗口用（`PanelController.show()` 汇总
    /// ownWindowIDs 时来取）：向导窗里有 Key 输入框，别进整屏采集。
    var windowID: CGWindowID? {
        guard let window, window.isVisible else { return nil }
        return CGWindowID(window.windowNumber)
    }

    /// AppDelegate 启动时调一次，此后向导的开/关全由模型标记驱动。
    func start() {
        guard observation == nil else { return }
        observation = AssistantModel.shared.$showsOnboarding
            .sink { [weak self] shows in
                guard let self, !self.suppressObservation else { return }
                MainActor.assumeIsolated {
                    if shows { self.present() } else { self.dismiss() }
                }
            }
    }

    private func present() {
        guard !isPresented else {
            // 已经开着（比如设置里又点了一次重跑）：带到前面即可。
            window?.makeKeyAndOrderFront(nil)
            return
        }
        isPresented = true
        // 展示记账在真正呈现的这一刻落盘：任何入口开的窗都算「展示
        // 过」，首启自动开窗此后不再触发（见 AppSettings 的注释）。
        AppSettings.shared.hasShownFirstRunOnboarding = true
        let window = ensureWindow()
        fitHeight(window)
        center(window)
        // 向导是正经的窗口任务（要切去浏览器拿 Key、要打字），不适用
        // 面板的「永不激活」——那条决定只管面板的召唤路径。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        guard isPresented else { return }
        window?.orderOut(nil)
        markGone()
    }

    /// 窗口消失的唯一收口：记账只在这里跑，且只跑一次。
    private func markGone() {
        guard isPresented else { return }
        isPresented = false
        AssistantModel.shared.onboardingWindowClosed()
    }

    func windowWillClose(_ notification: Notification) {
        suppressObservation = true
        AssistantModel.shared.showsOnboarding = false
        suppressObservation = false
        markGone()
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let hosting = NSHostingView(rootView: OnboardingView()
            .environmentObject(AssistantModel.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.maxHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // 标题进标题栏，正文头部因此只剩一行副标题（见 OnboardingView）。
        window.title = String(localized: "欢迎使用 Wisp")
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        ScreenPrivacy.apply(to: window)
        self.window = window
        return window
    }

    /// 高度按内容拟合、封顶 640：拟合值比封顶小就收窄到拟合值（Ollama/
    /// CLI 两种接法的内容明显更矮），超了就停在封顶、余下交给窗内
    /// 唯一的滚动区。宽度恒定 560。定位由随后的 `center()` 统一负责。
    private func fitHeight(_ window: NSWindow) {
        guard let hosting = window.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize.height
        guard fitting > 0 else { return }
        let height = min(max(fitting, Self.minHeight), Self.maxHeight)
        var frame = window.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.size.height = height
        window.setFrame(frame, display: false)
    }

    /// 居中于当前活跃屏幕（鼠标所在屏，跟随既有 ScreenGeometry 口径）。
    private func center(_ window: NSWindow) {
        guard let screen = ScreenGeometry.activeScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin = NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.midY - frame.height / 2)
        window.setFrame(ScreenGeometry.clamp(frame, on: screen), display: false)
    }
}
