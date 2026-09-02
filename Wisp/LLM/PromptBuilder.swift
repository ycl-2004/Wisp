import Foundation

/// 组装发给模型的 messages。全部规则确定性，不用模型做总结。
enum PromptBuilder {

    /// 最近几轮保留完整上下文块，更早的折叠成一行。
    static let fullContextTurns = 2

    /// 跟着界面语言走：英文用户不该收到一段中文提示词，
    /// 尤其是第 4 条的默认语言会直接影响模型用哪种语言回答。
    static var systemPrompt: String {
        String(localized: """
        你是一个 macOS 桌面助手。用户会按快捷键唤起你，并附上他当前屏幕的上下文。

        上下文可能包含：当前应用名与窗口标题、当前网页的网址与标题、整页正文文字、用户选中的文字，以及一张当前窗口的截图。

        要求：
        1. 优先根据提供的上下文回答，不要凭空猜测页面上没有的内容。
        2. 页面正文可能被截断、可能没采集到文末，也可能有跨域嵌入框架读不到。上下文里会写明正文是「完整」还是残缺以及残缺的原因，以那个标注为准，不要自己假设读到的就是全文。
        3. 如果答案所需的信息不在给到的正文里，直接说明这一点，并指出正文断在哪一句、可以看截图的哪一部分，或需要用户滚动到哪里。
        4. 截图只有当前可视区域，正文文字则是整页。两者冲突时以正文文字为准，并说明差异。
        5. 用用户提问所使用的语言回答，默认简体中文。
        6. 回答简洁直接，先给结论。
        """)
    }

    /// - Parameters:
    ///   - messages: 当前对话的全部消息，最后一条应为本轮用户消息。
    ///   - liveScreenshot: 本轮要发送的截图；nil 表示不发图。
    static func build(messages: [Message], liveScreenshot: Data?) -> [[String: Any]] {
        var payload: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        let userIndexes = messages.enumerated()
            .filter { $0.element.role == .user }
            .map { $0.offset }
        let fullContextIndexes = Set(userIndexes.suffix(fullContextTurns))
        let lastIndex = messages.indices.last

        for (index, message) in messages.enumerated() {
            switch message.role {
            case .assistant:
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                payload.append(["role": "assistant", "content": text])

            case .user:
                var blocks: [[String: Any]] = []

                if let context = message.context {
                    let full = fullContextIndexes.contains(index)
                    blocks.append(["type": "text", "text": contextBlock(context, full: full)])
                }

                if index == lastIndex, let jpeg = liveScreenshot, !jpeg.isEmpty {
                    let base64 = jpeg.base64EncodedString()
                    blocks.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(base64)"],
                    ])
                }

                blocks.append(["type": "text", "text": message.text])
                payload.append(["role": "user", "content": blocks])
            }
        }

        return payload
    }

    static func contextBlock(_ context: ContextSnapshot, full: Bool) -> String {
        guard full else {
            var line = String(localized: "[较早一轮的屏幕上下文，已折叠] \(context.summaryLine)")
            if let total = context.pageTextTotalChars, total > 0 {
                line += String(localized: "（当时读到正文 \(total) 字，此处不再重复）")
            }
            return line
        }

        var lines: [String] = [String(localized: "<屏幕上下文>")]
        lines.append(String(localized: "应用：\(context.appName)"))
        if let title = context.windowTitle, !title.isEmpty { lines.append(String(localized: "窗口标题：\(title)")) }
        if let url = context.url, !url.isEmpty { lines.append(String(localized: "网址：\(url)")) }
        if let pageTitle = context.pageTitle, !pageTitle.isEmpty { lines.append(String(localized: "页面标题：\(pageTitle)")) }
        lines.append(String(localized: "截取时间：\(Self.timeFormatter.string(from: context.capturedAt))"))
        lines.append(String(localized: "截图：\(context.hadScreenshot ? String(localized: "有，只覆盖当前可视区域") : String(localized: "无"))"))

        if !context.iframeURLs.isEmpty {
            lines.append(String(localized: "读不到内容的嵌入框架（\(context.iframeURLs.count) 个）："))
            for url in context.iframeURLs.prefix(8) { lines.append("  - \(url)") }
        }

        if let selection = context.selectedText, !selection.isEmpty {
            lines.append(String(localized: "用户选中的文字："))
            lines.append(selection)
        }

        if let text = context.pageText, !text.isEmpty {
            let total = context.pageTextTotalChars ?? text.count
            // 「按上限截断」和「本来就没读全」是两种不同的残缺，必须分开讲清楚，
            // 否则模型会把读到哪算到哪，当成整篇来回答。
            var flags: [String] = []
            if total > text.count {
                flags.append(String(localized: "已按长度上限截断，原文共 \(total) 字，中间省略部分见正文里的省略标记"))
            }
            if context.pageTextIsPartial {
                flags.append(String(localized: "这一页是虚拟滚动，正文没有采集到文末，后面还有未知数量的内容没读到"))
            }
            let suffix = flags.isEmpty
                ? String(localized: "，完整")
                : "，" + flags.joined(separator: "；")
            lines.append(String(localized: "整页正文（\(text.count) 字\(suffix)）："))
            lines.append("---")
            lines.append(text)
            lines.append("---")
            if context.pageTextIsPartial {
                lines.append(String(localized: "注意：上面的正文不是全文。回答前先判断所需信息是否在其中；不在就直说没读到，不要用「后面还有内容」搪塞，而要指出正文断在哪一句、让用户滚动到该位置再问一次。"))
            }
        } else {
            lines.append(String(localized: "整页正文：未取到，只能依赖截图。"))
        }

        lines.append(String(localized: "</屏幕上下文>"))
        return lines.joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 粗略估算 token，用于 UI 提示。中文按 1.5 字/token，英文按 4 字符/token 折中。
    static func estimateTokens(_ payload: [[String: Any]]) -> Int {
        var characters = 0
        var images = 0
        for message in payload {
            if let text = message["content"] as? String {
                characters += text.count
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    if let text = block["text"] as? String { characters += text.count }
                    if block["type"] as? String == "image_url" { images += 1 }
                }
            }
        }
        return characters / 2 + images * 800
    }
}
