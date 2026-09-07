import AppKit

/// 屏幕共享隐身。
///
/// macOS 允许一个窗口声明「别的进程读不到我」（`NSWindow.sharingType = .none`）。
/// 这个标记由 WindowServer 执行：窗口照常合成到你自己的屏幕上，但任何走
/// ScreenCaptureKit / CGWindowList 抓画面的进程都拿不到它 —— Zoom、Google Meet、
/// 腾讯会议、飞书、Teams、QuickTime、系统录屏（⌘⇧5）、OBS 全都走这两条路，
/// 所以一处设置就全都挡住了，不需要逐个 App 适配。
///
/// 挡不住三样：菜单栏那颗图标（系统代为绘制，见 `applyToAllWindows`）、
/// 用手机对着屏幕拍，以及在显示器输出端接硬件采集卡。
@MainActor
enum ScreenPrivacy {

    private static var observer: NSObjectProtocol?

    static var isEnabled: Bool { AppSettings.shared.hideFromScreenCapture }

    /// 关闭时要还原成系统默认值，而不是留在 `.none`。
    private static var desiredSharingType: NSWindow.SharingType {
        isEnabled ? .none : .readOnly
    }

    // MARK: - 生命周期

    /// 启动时调一次。之后新开的窗口由观察者兜底。
    static func start() {
        applyToAllWindows()

        // 设置窗口、菜单、sheet、系统弹出的授权提示都不是我们 new 出来的，
        // 拿不到创建时机，所以挂一个全局观察者：窗口每轮 runloop 刷新时顺手校正一次。
        // 回调只做一次属性比较，命中才写，开销可以忽略。
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { apply(to: window) }
        }
    }

    // MARK: - 开关

    static func setEnabled(_ enabled: Bool) {
        AppSettings.shared.hideFromScreenCapture = enabled
        applyToAllWindows()
    }

    // MARK: - 应用

    /// 窗口创建时立刻调用，别等观察者那一轮 —— 中间那一帧足够被录进去。
    static func apply(to window: NSWindow) {
        let type = desiredSharingType
        if window.sharingType != type { window.sharingType = type }
    }

    /// 兜底扫一遍。菜单栏那颗图标不在这里面：它由系统代为绘制，
    /// 应用侧的 `NSStatusBarWindow` 只是个 35×0 的空壳，改它的 sharingType 无效。
    static func applyToAllWindows() {
        for window in NSApp.windows { apply(to: window) }
    }
}
