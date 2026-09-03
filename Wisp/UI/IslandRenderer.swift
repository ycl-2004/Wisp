import AppKit
import SwiftUI

/// 把药丸的三种状态渲染成一张图，用于在没有屏幕录制权限时检查排版。
/// 只在带 --render-island 参数启动时用到，正常运行不会碰。
@MainActor
enum IslandRenderer {

    /// 把模型设置页的三种接法各渲染一张，用于在没有录屏权限时检查排版。
    static func renderSettings(to path: String) {
        let settings = AppSettings.shared
        let original = settings.providerKind
        let size = CGSize(width: 580, height: 400)
        var images: [(String, NSImage)] = []

        for kind in ProviderKind.allCases {
            settings.providerKind = kind.rawValue
            let view = ModelSettingsView(flat: true)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage { images.append((kind.title, image)) }
        }
        settings.providerKind = original

        guard !images.isEmpty else {
            FileHandle.standardError.write(Data("渲染失败\n".utf8))
            return
        }
        let labelHeight: CGFloat = 20
        let rowHeight = size.height + labelHeight
        let total = NSSize(width: size.width, height: rowHeight * CGFloat(images.count))
        let output = NSImage(size: total)
        output.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: total).fill()
        for (index, entry) in images.enumerated() {
            let y = total.height - CGFloat(index + 1) * rowHeight
            entry.1.draw(at: NSPoint(x: 0, y: y + labelHeight), from: .zero,
                         operation: .sourceOver, fraction: 1)
            NSString(string: entry.0).draw(at: NSPoint(x: 8, y: y + 3), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        }
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardOutput.write(Data("已写入 \(path)\n".utf8))
    }

    /// 渲染头部两行，用来检查窄面板里会不会挤爆。
    static func renderHeader(to path: String) {
        var packet = ContextPacket(appName: "Google Chrome", bundleID: "com.google.Chrome")
        packet.url = "https://openrouter.ai/models?q=free-models"
        packet.pageTitle = "Free models"
        packet.pageText = String(repeating: "字", count: 13229)
        packet.pageTextTotalChars = 13229
        packet.screenshotJPEG = ScreenCapturer.tinyTestJPEG()
        packet.notes = [.info("页面含 5 个跨域嵌入框架，其内部文字读不到，只能靠截图判断。")]
        AssistantModel.shared.packet = packet

        let view = ContextHeaderView()
            .environmentObject(AssistantModel.shared)
            .environmentObject(ConversationStore.shared)
            .frame(width: PanelController.width)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("渲染失败\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardOutput.write(Data("已写入 \(path)\n".utf8))
    }

    /// 渲染聊天面板的空状态，用来检查文案、建议胶囊和整体排版。
    ///
    /// 这里只画内容层：ChatView 的底子是 VisualEffectView，而 ImageRenderer
    /// 画不了 NSViewRepresentable，整块会变成一张黄底红杠的占位图。
    static func renderChat(to path: String) {
        var packet = ContextPacket(appName: "Google Chrome", bundleID: "com.google.Chrome")
        packet.url = "https://github.com/features/actions"
        packet.pageTitle = "GitHub Actions"
        packet.pageText = "Automate your workflow from idea to production"
        packet.pageTextTotalChars = 46
        packet.screenshotJPEG = ScreenCapturer.tinyTestJPEG()
        AssistantModel.shared.packet = packet
        AssistantModel.shared.setCollapsedSilently(false)

        let view = VStack(alignment: .leading, spacing: 14) {
            ChatEmptyStateView()
                .environmentObject(AssistantModel.shared)
                .environmentObject(ConversationStore.shared)
        }
        .padding(.horizontal, DS.gutter)
        .frame(width: 620, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))

        write(view, to: path)
    }

    /// 渲染 Markdown 代码块与表格样本
    static func renderMarkdownSample(to path: String) {
        let sample = """
### 代码优化示例

以下是为您提取的代码片段：

```swift
func greet(user: String) -> String {
    return "Hello, \\(user)! Welcome to Wisp."
}
```

### 性能参数比对

| 模型 | 响应延迟 | 上下文窗口 |
| --- | --- | --- |
| GLM-5.3-Flash | 240ms | 128k |
| Claude 3.5 Sonnet | 450ms | 200k |
| GPT-4o-Mini | 310ms | 128k |

> 提示：以上数据为局域网实测均值。
"""

        let view = VStack(alignment: .leading, spacing: 10) {
            MarkdownText(raw: sample, flat: true)
        }
        .padding(16)
        .frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))

        write(view, to: path)
    }

    private static func write(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("渲染失败\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardOutput.write(Data("已写入 \(path)\n".utf8))
    }

    static func render(to path: String) {
        let model = IslandModel.shared
        let cases: [(String, Bool, Bool)] = [
            ("闲置 idle", false, false),
            ("悬停 hover", true, false),
            ("生成中 generating", false, true),
        ]

        var images: [(String, NSImage)] = []
        for (name, hovered, generating) in cases {
            model.isHovered = hovered
            model.isGenerating = generating
            let view = IslandView(notchWidth: 185, hasNotch: true, position: .bottom)
                .environmentObject(model)
                .frame(width: IslandLayout.bottomWindowSize.width,
                       height: IslandLayout.bottomWindowSize.height)
                .background(Color(white: 0.86))
            if let image = rasterize(view,
                                     size: IslandLayout.bottomWindowSize) {
                images.append((name, image))
            }
        }
        model.isHovered = false
        model.isGenerating = false

        guard !images.isEmpty else {
            FileHandle.standardError.write(Data("渲染失败\n".utf8))
            return
        }

        let labelHeight: CGFloat = 18
        let width = IslandLayout.bottomWindowSize.width
        let rowHeight = IslandLayout.bottomWindowSize.height + labelHeight
        let total = NSSize(width: width, height: rowHeight * CGFloat(images.count))

        let output = NSImage(size: total)
        output.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: total).fill()
        for (index, entry) in images.enumerated() {
            let y = total.height - CGFloat(index + 1) * rowHeight
            entry.1.draw(at: NSPoint(x: 0, y: y + labelHeight), from: .zero,
                         operation: .sourceOver, fraction: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black,
            ]
            NSString(string: entry.0).draw(at: NSPoint(x: 8, y: y + 2), withAttributes: attributes)
        }
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardOutput.write(Data("已写入 \(path)\n".utf8))
    }

    private static func rasterize<V: View>(_ view: V, size: CGSize) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }
}
