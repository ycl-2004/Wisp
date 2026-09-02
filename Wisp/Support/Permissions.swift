import AppKit
import CoreGraphics

enum Permissions {
    /// 录屏权限是否已授予（不弹窗）。
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Whether macOS allows Wisp to observe raw keyboard events outside its own window.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// 请求录屏权限（首次会弹窗；已拒绝则无效果，需去系统设置）。
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
