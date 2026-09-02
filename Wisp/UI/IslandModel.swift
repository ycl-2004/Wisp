import AppKit
import SwiftUI

/// 灵动岛只跟踪「当前是哪个应用」，不截图、不跑浏览器脚本。
/// 保持「按需抓取」的原则：闲置时不产生任何屏幕内容。
@MainActor
final class IslandModel: ObservableObject {
    static let shared = IslandModel()

    @Published private(set) var appName: String = ""
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var bundleID: String?
    @Published var isHovered = false
    /// 主面板开着的时候整条药丸让位，避免同一份信息出现两次。
    @Published var isDimmed = false
    /// 正在生成回答。药丸会变宽、亮起流光并给出停止键。
    @Published var isGenerating = false
    /// 正在被拖动。此时收成小圆，免得展开态贴边放不下。
    @Published var isDragging = false
    /// 小圆中心在窗口内的 x。由 IslandController 在布局时算好写进来。
    @Published var dotCenterX: CGFloat = IslandLayout.anchorInWindow.x

    private init() {
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.update(app) }
        }
    }

    private func update(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        appName = app.localizedName ?? ""
        bundleID = app.bundleIdentifier
        appIcon = app.icon
    }

    private var hoverExitWork: DispatchWorkItem?

    /// 悬停要留一点余量：光标掠过边缘时不要立刻收，否则看起来像在抖。
    func setHovered(_ hovering: Bool) {
        hoverExitWork?.cancel()
        if hovering {
            guard !isHovered else { return }
            isHovered = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.isHovered = false }
        }
        hoverExitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    var isExcluded: Bool { AppSettings.shared.isExcluded(bundleID: bundleID) }

    var canReadPageText: Bool {
        BrowserTextExtractor.family(for: bundleID) != nil
    }

    /// 右侧那一小行提示。
    var hint: String {
        if isExcluded { return String(localized: "已排除") }
        return canReadPageText ? String(localized: "可读整页") : String(localized: "仅截图")
    }
}
