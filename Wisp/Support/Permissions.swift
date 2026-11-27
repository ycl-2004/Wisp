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

    /// 请求录屏权限（首次会弹窗；已拒绝则无效果，需去系统设置）。测试宿主只查不问。
    @discardableResult
    static func requestScreenRecording() -> Bool {
        guard !TestHost.isActive else { return hasScreenRecording }
        return CGRequestScreenCaptureAccess()
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

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 当前进程是不是 XCTest 的测试宿主（`xcodebuild test` 拉起的 Debug 版 Wisp）。
///
/// 测试宿主的签名和装在「应用程序」里的 Wisp 不同，系统把它当成另一个 App：录屏要重新授权，
/// 读正式版存进钥匙串的条目也要再问一次。任何一个授权框都会让整轮测试停下来等人点，
/// 所以测试宿主不弹录屏授权框，钥匙串也用自己的一份。
enum TestHost {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
