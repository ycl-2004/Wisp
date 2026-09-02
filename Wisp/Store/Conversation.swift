import Foundation

/// 存入对话记录的上下文文字快照。刻意不含图片。
struct ContextSnapshot: Codable, Hashable {
    var appName: String
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var pageTitle: String?
    var pageText: String?
    var pageTextTotalChars: Int?
    var selectedText: String?
    var iframeURLs: [String]
    var hadScreenshot: Bool
    var capturedAt: Date

    var summaryLine: String {
        var parts: [String] = [appName]
        if let t = pageTitle ?? windowTitle, !t.isEmpty { parts.append(t) }
        if let u = url, !u.isEmpty { parts.append(u) }
        return parts.joined(separator: " · ")
    }
}

struct Message: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var context: ContextSnapshot?
    var createdAt: Date = Date()
    /// 该回合是否随消息发了截图（仅用于 UI 显示，图片本身不保存）。
    var sentScreenshot: Bool = false
}

struct Conversation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String = "新对话"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [Message] = []

    var userTurnCount: Int {
        messages.filter { $0.role == .user }.count
    }

    var isEmpty: Bool { messages.isEmpty }

    mutating func retitleFromFirstUserMessage() {
        guard title == "新对话" || title.isEmpty,
              let first = messages.first(where: { $0.role == .user }) else { return }
        let trimmed = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        title = trimmed.isEmpty ? "新对话" : String(trimmed.prefix(40))
    }
}

/// 磁盘上的顶层结构。
struct ConversationFile: Codable {
    var version: Int = 1
    var conversations: [Conversation] = []
}
