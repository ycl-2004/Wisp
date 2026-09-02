import Foundation

/// 本地 JSON 对话存储。固定上限、手动删除、不做时间淘汰。
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var conversations: [Conversation] = []
    @Published var activeID: UUID?

    private let fileURL = AppSettings.supportDirectory.appendingPathComponent("conversations.json")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        load()
        if let saved = AppSettings.shared.lastActiveConversationID,
           let uuid = UUID(uuidString: saved),
           conversations.contains(where: { $0.id == uuid }) {
            activeID = uuid
        } else {
            activeID = conversations.first?.id
        }
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let file = try? decoder.decode(ConversationFile.self, from: data) else {
            // 文件损坏时改名备份，不静默丢数据。
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return
        }
        conversations = file.conversations
    }

    private func persist() {
        let file = ConversationFile(conversations: conversations)
        guard let data = try? encoder.encode(file) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // MARK: - 上限

    var maxConversations: Int { AppSettings.shared.maxConversations }
    var maxUserTurns: Int { AppSettings.shared.maxUserTurns }

    var canCreateNew: Bool { conversations.count < maxConversations }

    var active: Conversation? {
        guard let activeID else { return nil }
        return conversations.first { $0.id == activeID }
    }

    func remainingTurns(in conversation: Conversation) -> Int {
        max(0, maxUserTurns - conversation.userTurnCount)
    }

    func isAtTurnLimit(_ conversation: Conversation) -> Bool {
        conversation.userTurnCount >= maxUserTurns
    }

    // MARK: - 变更

    @discardableResult
    func createNew() -> Conversation? {
        guard canCreateNew else { return nil }
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        activeID = conversation.id
        AppSettings.shared.lastActiveConversationID = conversation.id.uuidString
        persist()
        return conversation
    }

    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        activeID = id
        AppSettings.shared.lastActiveConversationID = id.uuidString
    }

    /// 确保有一个可用的当前对话；已满且没有活跃对话时返回 nil。
    @discardableResult
    func ensureActive() -> Conversation? {
        if let active { return active }
        if let first = conversations.first {
            activeID = first.id
            return first
        }
        return createNew()
    }

    func append(_ message: Message, to id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        conversations[index].retitleFromFirstUserMessage()
        persist()
    }

    /// 流式回答过程中就地更新最后一条 assistant 消息。不每次都写盘。
    func updateStreaming(text: String, messageID: UUID, in id: UUID, persistNow: Bool = false) {
        guard let ci = conversations.firstIndex(where: { $0.id == id }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[ci].messages[mi].text = text
        conversations[ci].updatedAt = Date()
        if persistNow { persist() }
    }

    func removeMessage(_ messageID: UUID, from id: UUID) {
        guard let ci = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[ci].messages.removeAll { $0.id == messageID }
        persist()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeID == id {
            activeID = conversations.first?.id
            AppSettings.shared.lastActiveConversationID = activeID?.uuidString
        }
        persist()
    }

    func deleteAll() {
        conversations.removeAll()
        activeID = nil
        AppSettings.shared.lastActiveConversationID = nil
        persist()
    }

    func flush() { persist() }
}
