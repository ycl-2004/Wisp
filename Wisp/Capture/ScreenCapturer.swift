import AppKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 用 ScreenCaptureKit 截取指定进程的前台窗口，或它所在的整块屏幕。
/// Wisp 自己的窗口一律不入镜：按窗口编号挖一次，再按 bundle id 挖一次。
enum ScreenCapturer {

    struct Shot {
        var jpeg: Data
        var pixelSize: CGSize
        /// 焦点应用最前面那个窗口的标题。整屏截图也照填，告诉模型焦点在哪。
        var windowTitle: String?
        /// 这张图实际覆盖的范围。找不到窗口时会退回整屏，所以不一定等于设置里选的。
        var scope: CaptureScope
    }

    enum CaptureError: Error {
        case noPermission
        case noWindow
        case failed(String)
    }

    private nonisolated(unsafe) static var hasRequestedOnce = false

    static let jpegQuality: CGFloat = 0.8

    /// 输出图的长边上限（像素）。截图按每点一像素出图，超过上限才等比缩小。
    /// 整屏里装着好几个窗口，多给一些像素，代价是图更大、图片 token 更多。
    static func maxLongEdge(for scope: CaptureScope) -> CGFloat {
        switch scope {
        case .window: return 1600
        case .screen: return 2048
        }
    }

    /// 截取 pid 对应应用最前面的那个窗口；`scope` 为 `.screen` 时截那个窗口所在的整块屏幕。
    /// `titleHint` 是浏览器 AppleScript 返回的当前分页标题：多窗口、多配置文件时用它锁定同一个窗口，
    /// 否则截图和整页文字可能来自两个不同的窗口。
    /// `hiddenBundleIDs` 只在截整屏时生效：这些应用的窗口会从画面里挖掉。
    static func capture(pid: pid_t,
                        excludingWindowIDs: [CGWindowID],
                        titleHint: String? = nil,
                        scope: CaptureScope = .window,
                        hiddenBundleIDs: Set<String> = []) async -> Result<Shot, CaptureError> {
        if !Permissions.hasScreenRecording {
            // 第一次没权限时主动弹一次系统授权框；之后只能去系统设置里勾。
            if !hasRequestedOnce {
                hasRequestedOnce = true
                _ = Permissions.requestScreenRecording()
            }
            guard Permissions.hasScreenRecording else { return .failure(.noPermission) }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        // SCShareableContent 返回的窗口按从前到后排列，第一个就是该应用最前面的窗口。
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid
                && window.windowLayer == 0
                && window.isOnScreen
                && window.frame.width > 120
                && window.frame.height > 120
                && !excludingWindowIDs.contains(window.windowID)
        }

        var target = candidates.first
        if let hint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            // 浏览器窗口标题通常就是当前分页标题，可能再带上配置文件名后缀。
            if let matched = candidates.first(where: { window in
                guard let title = window.title, !title.isEmpty else { return false }
                return title == hint || title.hasPrefix(hint) || title.contains(hint)
            }) {
                target = matched
            }
        }

        let filter: SCContentFilter
        let sourceSize: CGSize
        let shotScope: CaptureScope

        if scope == .window, let target {
            filter = SCContentFilter(desktopIndependentWindow: target)
            sourceSize = target.frame.size
            shotScope = .window
        } else if let index = displayIndex(for: target?.frame,
                                           cursor: CGEvent(source: nil)?.location,
                                           displays: content.displays.map(\.frame)) {
            // 选了整屏，或者找不到窗口只能退回整屏。两种情况都要把不该入镜的挖掉。
            // 这个过滤只作用于 Wisp 自己这次截图，不影响浏览器或其他录屏进程的捕获流。
            let display = content.displays[index]
            let ownBundleID = Bundle.main.bundleIdentifier
            let excluded = content.windows.filter { window in
                if excludingWindowIDs.contains(window.windowID) { return true }
                guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
                return bundleID == ownBundleID || hiddenBundleIDs.contains(bundleID)
            }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            sourceSize = CGSize(width: display.width, height: display.height)
            shotScope = .screen
        } else {
            return .failure(.noWindow)
        }

        let scale = min(1.0, maxLongEdge(for: shotScope) / max(sourceSize.width, sourceSize.height))
        let config = SCStreamConfiguration()
        config.width = max(1, Int((sourceSize.width * scale).rounded()))
        config.height = max(1, Int((sourceSize.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = true

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let jpeg = encodeJPEG(image) else {
                return .failure(.failed(String(localized: "JPEG 编码失败")))
            }
            return .success(Shot(jpeg: jpeg,
                                 pixelSize: CGSize(width: image.width, height: image.height),
                                 windowTitle: target?.title,
                                 scope: shotScope))
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// 截整屏时截哪一块：焦点窗口占得最多的那块；没有窗口就看指针在哪块；都不行用第一块。
    /// 参数全是 CG 全局坐标（左上角为原点），`SCWindow.frame` 和 `SCDisplay.frame` 用的都是这一套。
    static func displayIndex(for windowFrame: CGRect?, cursor: CGPoint?, displays: [CGRect]) -> Int? {
        guard !displays.isEmpty else { return nil }
        if let windowFrame {
            let areas = displays.map { display -> CGFloat in
                let overlap = display.intersection(windowFrame)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
                return best
            }
        }
        if let cursor, let index = displays.firstIndex(where: { $0.contains(cursor) }) {
            return index
        }
        return 0
    }

    static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 用于「测试连接」的一张 64×64 纯色小图。
    static func tinyTestJPEG() -> Data? {
        let size = 64
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = ctx.makeImage() else { return nil }
        return encodeJPEG(image)
    }
}
