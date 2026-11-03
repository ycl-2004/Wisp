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

    /// 本会话是否已经请求过录屏权限（进程内共享，只有内存，不落盘）。
    ///
    /// macOS 不区分「未请求 / 已拒绝」（CGPreflight 只回布尔），而首次
    /// 之后再调 CGRequestScreenCaptureAccess 就是无声 no-op——「请求过
    /// 没有」是各处决定「按钮该弹窗还是该跳系统设置」的唯一信号。这份
    /// 标记以前采集路径（ScreenCapturer）与向导步 2 各记一份、互不知
    /// 情：用户先经首次采集弹框被拒，之后进向导点「去授权」，仍会白点
    /// 一下死的。现在收口到这里，由 `requestScreenRecording()` 统一
    /// 写入，任一路径请求过、两处都认。
    ///
    /// 不落盘是有意的：Wisp 是 ad-hoc 签名（没有付费开发者账号做公证
    /// 身份），每次更新后二进制身份变化，TCC 记录随之失效、系统会重新
    /// 允许询问；落盘标记会把更新后本可正常弹的框误判成已拒绝。设置页
    /// 的权限行常驻「请求」+「系统设置…」双按钮作兜底，会话标记的判断
    /// 即使偶尔不合时宜，用户也不会被困住。
    nonisolated(unsafe) static var sessionRequestedScreenRecording = false

    /// 请求录屏权限（首次会弹窗；已拒绝则无效果，需去系统设置）。
    @discardableResult
    static func requestScreenRecording() -> Bool {
        sessionRequestedScreenRecording = true
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

    static func openSpeechSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    static func openSoundSettings() {
        open("x-apple.systempreferences:com.apple.preference.sound")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
