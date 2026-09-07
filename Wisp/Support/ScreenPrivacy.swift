import AppKit
import SwiftUI

/// 向兼容的捕获路径请求隐藏 Wisp 的窗口，不是全局的防录屏保证。
///
/// `.none` 在部分环境中仍有效，但 Apple 将其列为旧机制，并明确要求不要依赖
/// 它阻止捕获。窗口仍可能被枚举；不同系统、浏览器和录屏路径必须分别实测。
/// https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none
///
/// 只作用于本进程窗口，不覆盖系统菜单栏图标、其他进程的授权弹窗、硬件采集
/// 或摄像机拍屏，也不改变焦点、剪贴板和其他应用的行为记录。实测见
/// docs/screen-privacy-validation.md。
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

        // 兜底处理本进程中晚创建的窗口。刷新通知不能保证在第一帧之前触发，
        // 所以自己创建的面板在构造时应用，SwiftUI 设置窗口在视图挂载时应用。
        // 这个进程内观察者无法修改由其他进程承载的系统授权弹窗。
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

    /// 自有窗口在首次显示前调用；设置成功本身不代表接收端已隐藏内容。
    static func apply(to window: NSWindow) {
        let type = desiredSharingType
        if window.sharingType != type { window.sharingType = type }
    }

    /// 只扫描本进程窗口，不保证覆盖系统绘制的菜单栏图标或授权弹窗。
    static func applyToAllWindows() {
        for window in NSApp.windows { apply(to: window) }
    }
}

/// SwiftUI 创建设置窗口时即应用偏好，不等 didUpdateNotification。
struct ScreenPrivacyWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) {
        if let window = view.window { ScreenPrivacy.apply(to: window) }
    }

    final class WindowView: NSView {
        // Source: https://developer.apple.com/documentation/appkit/nsview/viewdidmovetowindow()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { ScreenPrivacy.apply(to: window) }
        }
    }
}
