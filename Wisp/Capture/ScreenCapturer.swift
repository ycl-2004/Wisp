import AppKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 用 ScreenCaptureKit 截取指定进程的前台窗口。浮窗尚未显示时调用，因此不会把自己截进去。
enum ScreenCapturer {

    struct Shot {
        var jpeg: Data
        var pixelSize: CGSize
        var windowTitle: String?
    }

    enum CaptureError: Error {
        case noPermission
        case noWindow
        case failed(String)
    }

    private nonisolated(unsafe) static var hasRequestedOnce = false

    static let maxLongEdge: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.8

    /// 截取 pid 对应应用最前面的那个窗口。
    /// `titleHint` 是浏览器 AppleScript 返回的当前分页标题：多窗口、多配置文件时用它锁定同一个窗口，
    /// 否则截图和整页文字可能来自两个不同的窗口。
    static func capture(pid: pid_t,
                        excludingWindowIDs: [CGWindowID],
                        titleHint: String? = nil) async -> Result<Shot, CaptureError> {
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
        let title: String?
        let sourceSize: CGSize

        if let target {
            filter = SCContentFilter(desktopIndependentWindow: target)
            title = target.title
            sourceSize = target.frame.size
        } else if let display = content.displays.first {
            let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            title = nil
            sourceSize = CGSize(width: display.width, height: display.height)
        } else {
            return .failure(.noWindow)
        }

        let scale = min(1.0, maxLongEdge / max(sourceSize.width, sourceSize.height))
        let config = SCStreamConfiguration()
        config.width = max(1, Int((sourceSize.width * scale).rounded()))
        config.height = max(1, Int((sourceSize.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = true

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let jpeg = encodeJPEG(image) else {
                return .failure(.failed("JPEG 编码失败"))
            }
            return .success(Shot(jpeg: jpeg,
                                 pixelSize: CGSize(width: image.width, height: image.height),
                                 windowTitle: title))
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
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
