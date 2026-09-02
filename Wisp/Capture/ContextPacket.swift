import Foundation

/// 一次「按快捷键」采集到的屏幕上下文。截图只存在内存，不落盘。
struct ContextPacket: Identifiable {
    let id = UUID()

    var appName: String
    var bundleID: String?
    var windowTitle: String?

    var url: String?
    var pageTitle: String?
    /// 已按上限截断的页面正文。
    var pageText: String?
    /// 截断前的总字数，UI 用来显示「N 字 / 已截断」。
    var pageTextTotalChars: Int?
    var selectedText: String?
    /// 页面内 iframe 的 src。跨域 iframe 的正文读不到，只能靠截图。
    var iframeURLs: [String] = []

    /// JPEG 数据，仅内存。
    var screenshotJPEG: Data?
    var screenshotPixelSize: CGSize?

    var capturedAt: Date = Date()
    /// 采集过程中的说明与失败原因，会显示在浮窗头部。
    var notes: [String] = []
    /// 该应用被用户排除，本次不采集任何内容。
    var isExcluded: Bool = false

    var isTruncated: Bool {
        guard let total = pageTextTotalChars, let text = pageText else { return false }
        return total > text.count
    }

    var hasPageText: Bool {
        !(pageText ?? "").isEmpty
    }

    var hasScreenshot: Bool {
        (screenshotJPEG?.isEmpty == false)
    }

    static func excluded(appName: String, bundleID: String?) -> ContextPacket {
        var p = ContextPacket(appName: appName, bundleID: bundleID)
        p.isExcluded = true
        p.notes = [String(localized: "「\(appName)」在排除列表中，本次不读取截图与页面文字。")]
        return p
    }

    /// 存入对话记录的文字快照（不含图片）。
    func snapshot() -> ContextSnapshot {
        ContextSnapshot(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            url: url,
            pageTitle: pageTitle,
            pageText: pageText,
            pageTextTotalChars: pageTextTotalChars,
            selectedText: selectedText,
            iframeURLs: iframeURLs,
            hadScreenshot: hasScreenshot,
            capturedAt: capturedAt
        )
    }
}

/// 页面提取脚本的返回结构。
struct PageExtraction: Decodable {
    var title: String?
    var href: String?
    var text: String?
    var selection: String?
    var iframes: [String]?
    var error: String?
}
