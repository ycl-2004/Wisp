import Foundation

/// 采集过程中的一条说明。是不是「要用户自己去动手」由采集方直接标出来，
/// 不能靠在界面上匹配文案关键词——那样每加一种语言都会悄悄失灵。
struct CaptureNote: Hashable {
    var text: String
    /// 权限没给、浏览器开关没开这类，用户不动手就一直读不到，界面要显眼提示。
    var needsUserAction: Bool = false

    static func info(_ text: String) -> CaptureNote { CaptureNote(text: text) }
    static func blocking(_ text: String) -> CaptureNote { CaptureNote(text: text, needsUserAction: true) }
}

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
    /// 正文已知不完整：虚拟滚动没采到底，或滚动采集中途失败。
    /// 和 `isTruncated`（按字数上限砍）是两件事，两者可能同时成立。
    var pageTextIsPartial: Bool = false
    /// 这次正文是靠滚动采集拿到的，而不是单次 innerText。
    var usedScrollCollection: Bool = false
    var selectedText: String?
    /// 页面内 iframe 的 src。跨域 iframe 的正文读不到，只能靠截图。
    var iframeURLs: [String] = []

    /// JPEG 数据，仅内存。
    var screenshotJPEG: Data?
    var screenshotPixelSize: CGSize?

    var capturedAt: Date = Date()
    /// 采集过程中的说明与失败原因，会显示在浮窗头部。
    var notes: [CaptureNote] = []
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
        p.notes = [.info(String(localized: "「\(appName)」在排除列表中，本次不读取截图与页面文字。"))]
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
            pageTextIsPartial: pageTextIsPartial,
            selectedText: selectedText,
            iframeURLs: iframeURLs,
            hadScreenshot: hasScreenshot,
            capturedAt: capturedAt
        )
    }
}

/// 页面提取脚本 `beginJS` 的返回结构。
struct PageExtraction: Decodable {
    var title: String?
    var href: String?
    var text: String?
    var selection: String?
    var iframes: [String]?
    var error: String?
    /// 滚动容器的尺寸，用来判断这一页是不是虚拟滚动、要不要继续往下采。
    var scrollHeight: Double?
    var clientHeight: Double?
    var scrollTop: Double?
    var docScroller: Bool?
}

/// `stepJS` 的返回结构。
struct PageScrollStep: Decodable {
    var added: Int?
    /// 本次采集累计新增的行数，用来识别「滚到底了却一个字没多」。
    var gained: Int?
    var atBottom: Bool?
    var chars: Int?
    var steps: Int?
    var error: String?
}

/// `finishJS` 的返回结构。
struct PageScrollFinish: Decodable {
    var text: String?
    var gained: Int?
    var reachedBottom: Bool?
    var steps: Int?
    var error: String?
}
