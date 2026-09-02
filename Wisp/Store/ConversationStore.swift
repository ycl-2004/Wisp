import Foundation

/// 本地 JSON 对话存储。固定上限、手动删除、不做时间淘汰。
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    /// 磁盘格式版本，定义在 ConversationFile 上。
    static var schemaVersion: Int { ConversationFile.currentVersion }
    /// 最多保留几份损坏备份，多的按时间从旧到新删掉。
    static let maxCorruptBackups = 3

    /// 读盘时发生过的、需要让用户知道的事。不静默吞掉。
    enum LoadIssue: Equatable {
        /// 文件解不开，已改名备份，当前列表是空的。
        case recovered(backup: String)
        /// 文件来自更新版本的 Wisp。为了不覆盖它，本次运行禁止写盘。
        case newerVersion(found: Int, supported: Int)

        var message: String {
            switch self {
            case .recovered(let backup):
                return String(localized: "上次的对话记录读不出来了，已经原样备份成 \(backup)，当前列表是空的。备份文件在 Wisp 的应用支持目录里，没有被删除。")
            case .newerVersion(let found, let supported):
                return String(localized: "这份对话记录来自更新版本的 Wisp（格式 v\(found)，本版本只认到 v\(supported)）。为了不覆盖它，本次运行不会保存任何改动。请升级 Wisp，或在设置里把它备份后重新开始。")
            }
        }
    }

    @Published private(set) var conversations: [Conversation] = []
    @Published var activeID: UUID?
    /// 有值时界面上要显示提示条。
    @Published private(set) var loadIssue: LoadIssue?

    /// 读到了更新版本的文件时置位。置位期间一律不写盘，否则会把用户的数据覆盖掉。
    private var persistenceBlocked = false

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

        // 先只看版本号。比本版本新的文件绝不能碰——读不动，就更不能覆盖。
        if let probe = try? decoder.decode(ConversationFileVersionProbe.self, from: data),
           let version = probe.version, version > Self.schemaVersion {
            loadIssue = .newerVersion(found: version, supported: Self.schemaVersion)
            persistenceBlocked = true
            return
        }

        // 模型层是容错解码的：个别消息坏掉只会丢那一条，不会带走整个文件。
        if let file = try? decoder.decode(ConversationFile.self, from: data) {
            conversations = file.conversations
            return
        }

        // 走到这里说明整份 JSON 都不成形了。备份改名，并且明确告诉用户。
        let backup = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
        if (try? FileManager.default.moveItem(at: fileURL, to: backup)) != nil {
            loadIssue = .recovered(backup: backup.lastPathComponent)
            pruneCorruptBackups()
        }
    }

    /// 损坏备份只留最新几份，否则每坏一次留一个几十 MB 的文件，无上限地涨。
    private func pruneCorruptBackups() {
        let directory = fileURL.deletingLastPathComponent()
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let backups = all
            .filter { $0.hasPrefix("conversations.corrupt-") && $0.hasSuffix(".json") }
            .sorted()
        guard backups.count > Self.maxCorruptBackups else { return }
        for name in backups.prefix(backups.count - Self.maxCorruptBackups) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func persist() {
        // 文件比本版本新时只读不写，宁可这次改动不落盘，也不能覆盖用户的数据。
        guard !persistenceBlocked else { return }

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

    // MARK: - 提示条

    func dismissLoadIssue() {
        loadIssue = nil
    }

    /// 「更新版本的文件」这种情况下的逃生口：把它另存一份，然后从空白开始。
    /// 只有用户在设置里显式点了才会走到这里。
    @discardableResult
    func archiveBlockingFileAndReset() -> String? {
        guard persistenceBlocked else { return nil }
        let backup = fileURL.deletingPathExtension()
            .appendingPathExtension("from-newer-version-\(Int(Date().timeIntervalSince1970)).json")
        guard (try? FileManager.default.moveItem(at: fileURL, to: backup)) != nil else { return nil }
        persistenceBlocked = false
        loadIssue = nil
        conversations = []
        activeID = nil
        AppSettings.shared.lastActiveConversationID = nil
        persist()
        return backup.lastPathComponent
    }

    var isReadOnly: Bool { persistenceBlocked }

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

    /// 满额时会被顶掉的那一个：最久没更新的。UI 拿它来问用户「删这个可以吗」。
    var evictionCandidate: Conversation? {
        guard !canCreateNew else { return nil }
        return conversations.min { $0.updatedAt < $1.updatedAt }
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

    /// 满额时腾位置再新建：删掉最久没更新的那个。
    /// 会真的删数据，所以只在用户点了确认之后调用。
    @discardableResult
    func createNewEvictingOldest() -> Conversation? {
        if let victim = evictionCandidate {
            conversations.removeAll { $0.id == victim.id }
            if activeID == victim.id { activeID = nil }
        }
        return createNew()
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
