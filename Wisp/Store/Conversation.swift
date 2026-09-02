import Foundation

// MARK: - 兼容解码的工具

/// 占位解码器：永远成功，用来在数组里跳过一项。
private struct SkipEntry: Decodable {
    init(from decoder: Decoder) throws {}
}

/// 逐条解码数组，坏掉的那条丢掉，不让它带走整个文件。
/// Swift 合成的 Decodable 不认属性默认值，缺一个 key 就整份炸掉，
/// 所以历史记录这种「丢一条也比全丢好」的数据必须自己兜。
private func decodeLossyArray<Element: Decodable>(_ type: Element.Type,
                                                 from container: inout UnkeyedDecodingContainer) -> [Element] {
    var result: [Element] = []
    while !container.isAtEnd {
        let before = container.currentIndex
        if let element = try? container.decode(Element.self) {
            result.append(element)
        }
        // 解码失败时索引不一定前进，手动跳过，否则会死循环。
        if container.currentIndex == before {
            if (try? container.decode(SkipEntry.self)) == nil { break }
        }
        if container.currentIndex == before { break }
    }
    return result
}

/// 容错读取：key 缺失、类型不对、值本身坏掉，一律退回兜底值而不是抛错。
private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}

// MARK: - 模型

/// 存入对话记录的上下文文字快照。刻意不含图片。
struct ContextSnapshot: Codable, Hashable {
    var appName: String
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var pageTitle: String?
    var pageText: String?
    var pageTextTotalChars: Int?
    /// 正文已知不完整：虚拟滚动没采到底，或页面明说读不全。
    /// 与 `pageTextTotalChars` 表示的「按上限截断」是两回事。
    var pageTextIsPartial: Bool = false
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

    init(appName: String, bundleID: String?, windowTitle: String?, url: String?, pageTitle: String?,
         pageText: String?, pageTextTotalChars: Int?, pageTextIsPartial: Bool = false,
         selectedText: String?, iframeURLs: [String],
         hadScreenshot: Bool, capturedAt: Date) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.pageTitle = pageTitle
        self.pageText = pageText
        self.pageTextTotalChars = pageTextTotalChars
        self.pageTextIsPartial = pageTextIsPartial
        self.selectedText = selectedText
        self.iframeURLs = iframeURLs
        self.hadScreenshot = hadScreenshot
        self.capturedAt = capturedAt
    }

    /// 除了 appName，其余一律「有就读、没有就用兜底」，方便以后加字段。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appName = c.value(.appName, or: "未知应用")
        bundleID = c.optional(String.self, .bundleID)
        windowTitle = c.optional(String.self, .windowTitle)
        url = c.optional(String.self, .url)
        pageTitle = c.optional(String.self, .pageTitle)
        pageText = c.optional(String.self, .pageText)
        pageTextTotalChars = c.optional(Int.self, .pageTextTotalChars)
        pageTextIsPartial = c.value(.pageTextIsPartial, or: false)
        selectedText = c.optional(String.self, .selectedText)
        iframeURLs = c.value(.iframeURLs, or: [])
        hadScreenshot = c.value(.hadScreenshot, or: false)
        capturedAt = c.value(.capturedAt, or: Date())
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

    init(id: UUID = UUID(), role: Role, text: String, context: ContextSnapshot? = nil,
         createdAt: Date = Date(), sentScreenshot: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.context = context
        self.createdAt = createdAt
        self.sentScreenshot = sentScreenshot
    }

    /// role 与 text 是 v1 就有的，缺了这条消息本身就没意义；其余全部容错。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        context = c.optional(ContextSnapshot.self, .context)
        createdAt = c.value(.createdAt, or: Date())
        sentScreenshot = c.value(.sentScreenshot, or: false)
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String = "新对话"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [Message] = []

    /// 未命名对话在磁盘上固定存这个值，**不随界面语言变化**。
    /// 直接存本地化文本的话，中文下建的对话在英文界面里还是中文，反过来也一样。
    static let untitledSentinel = "新对话"

    /// 还没被首条提问改过名。retitleFromFirstUserMessage 只在有用户消息时动手，
    /// 所以「标题还是占位符 + 一条用户消息都没有」就等价于没改过名。
    /// 只比文本的话，用户第一句正好打了「新对话」时会被误判成占位符。
    var isUntitled: Bool {
        if title.isEmpty { return true }
        return title == Self.untitledSentinel && !messages.contains { $0.role == .user }
    }

    /// 界面上该显示的标题。只有还没被首条提问改名时才需要翻译。
    var displayTitle: String {
        isUntitled ? String(localized: "新对话") : title
    }

    var userTurnCount: Int {
        messages.filter { $0.role == .user }.count
    }

    var isEmpty: Bool { messages.isEmpty }

    mutating func retitleFromFirstUserMessage() {
        guard title == Self.untitledSentinel || title.isEmpty,
              let first = messages.first(where: { $0.role == .user }) else { return }
        let trimmed = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        title = trimmed.isEmpty ? Self.untitledSentinel : String(trimmed.prefix(40))
    }

    init(id: UUID = UUID(), title: String = "新对话", createdAt: Date = Date(),
         updatedAt: Date = Date(), messages: [Message] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        title = c.value(.title, or: "新对话")
        createdAt = c.value(.createdAt, or: Date())
        updatedAt = c.value(.updatedAt, or: createdAt)
        if var array = try? c.nestedUnkeyedContainer(forKey: .messages) {
            messages = decodeLossyArray(Message.self, from: &array)
        } else {
            messages = []
        }
    }
}

/// 磁盘上的顶层结构。
/// `version` 是真正会被检查的：见 ConversationStore.load()。
/// 加字段时请一律给可选类型或在自定义 init 里兜底，否则老文件会整份解不开。
struct ConversationFile: Codable {
    /// 当前磁盘格式版本。改结构时才 +1，并在 ConversationStore.load() 里加迁移分支。
    static let currentVersion = 1

    var version: Int = ConversationFile.currentVersion
    var conversations: [Conversation] = []

    init(version: Int = ConversationFile.currentVersion, conversations: [Conversation] = []) {
        self.version = version
        self.conversations = conversations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, or: 1)
        if var array = try? c.nestedUnkeyedContainer(forKey: .conversations) {
            conversations = decodeLossyArray(Conversation.self, from: &array)
        } else {
            conversations = []
        }
    }
}

/// 只读版本号。用来在完整解码之前判断这个文件是不是来自更新的版本。
struct ConversationFileVersionProbe: Decodable {
    var version: Int?
}
