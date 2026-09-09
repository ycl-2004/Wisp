import Foundation

struct ListeningPreferences: Codable, Equatable {
    static let key = "listeningPreferences"
    static let locales = ["en-US", "zh-CN", "zh-TW", "ja-JP"]
    var mode: ListeningMode = .application
    var locale = "en-US"
    var savesAudio = false
    // Optional keys preserve preferences saved before alternative engines existed.
    var recognitionEngine: ListeningRecognitionEngine?
    var senseVoiceLanguage: String?

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if !locales.contains(value.locale) { value.locale = "en-US" }
        if let language = value.senseVoiceLanguage, !SenseVoiceRecognition.languages.contains(language) {
            value.senseVoiceLanguage = "auto"
        }
        return value
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

enum ListeningSource: String, Codable, CaseIterable {
    case microphone, application

    var title: String {
        switch self {
        case .microphone: return String(localized: "我方麦克风")
        case .application: return String(localized: "远端音频")
        }
    }
}

enum ListeningMode: String, Codable, CaseIterable, Identifiable {
    case microphone, application, both
    var id: String { rawValue }
    var sources: [ListeningSource] {
        switch self {
        case .microphone: return [.microphone]
        case .application: return [.application]
        case .both: return [.microphone, .application]
        }
    }
    var title: String {
        switch self {
        case .microphone: return String(localized: "只听我说")
        case .application: return String(localized: "只听对方")
        case .both: return String(localized: "双方对话")
        }
    }
}

struct ListeningSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let source: ListeningSource
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var isFinal: Bool

    var line: String {
        "[\(Self.timestamp(start))–\(Self.timestamp(end))] \(source.title): \(text)"
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }

    /// 界面上的时间。一小时以内只写分秒，窄面板里才排得下；
    /// 存到文件和发给模型的仍然是上面那个完整时间戳。
    static func clock(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

struct ListeningTranscript: Codable {
    static let maximumCharacters = 200_000
    static let maximumUTF8Bytes = 2_000_000
    static let maximumSegments = 7_200
    static let draftLimit = 12_000
    let id: UUID
    let startedAt: Date
    let locale: String
    let applicationName: String?
    let savesAudio: Bool
    var segments: [ListeningSegment] = []
    var stoppedAt: Date?
    var stopReason: String?

    /// Reject before mutation, including trailing callbacks after Stop.
    @discardableResult
    mutating func upsert(_ segment: ListeningSegment) -> Bool {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let previous = segments.first { $0.id == segment.id }
        if previous?.isFinal == true, !segment.isFinal { return true }
        guard segments.count < Self.maximumSegments || previous != nil,
              segments.reduce(0, { $0 + $1.text.count }) - (previous?.text.count ?? 0) + segment.text.count <= Self.maximumCharacters,
              segments.reduce(0, { $0 + $1.text.utf8.count }) - (previous?.text.utf8.count ?? 0) + segment.text.utf8.count <= Self.maximumUTF8Bytes else { return false }
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            // Late provisional callbacks must never undo a finalized result.
            segments[index] = segment
        } else {
            segments.append(segment)
        }
        segments.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        return true
    }

    static func appendingToDraft(_ text: String, existing: String) -> String? {
        let combined = existing.isEmpty ? text : existing + "\n\n" + text
        return combined.count <= draftLimit ? combined : nil
    }

    /// 还没交出去的话——从上一次放进草稿／发出去之后算起，一直到现在。
    ///
    /// 这里**不设时间窗口**：会议里每隔几分钟按一次分析，中间那几分钟正是要给模型的东西。
    /// 早先按「最近 90 秒」取，间隔一旦超过 90 秒，中间说的话就再也不会进入任何一次发送，
    /// 只剩本地记录里有。唯一的闸是草稿字数，超了从最旧的一端整段丢。
    func unstagedText(excluding ids: Set<UUID>) -> String {
        var pending = self
        pending.segments.removeAll { ids.contains($0.id) }
        return pending.spokenText()
    }

    /// 和 `unstagedText` 同一个判断，只是不拼字符串：语音条每秒都要问一次还能不能分析。
    /// 窗口是相对剩下那些段落的最新时间算的，所以只要还有没交出去的段落，取到的文字就非空。
    func hasUnstagedText(excluding ids: Set<UUID>) -> Bool {
        segments.contains { !ids.contains($0.id) }
    }

    var text: String { segments.map { $0.line + ($0.isFinal ? "" : " [\(String(localized: "临时文字"))]") }.joined(separator: "\n\n") }

    /// 放进输入框、发给模型的文字。
    ///
    /// 这里不带时间戳，也不按识别批次换行：识别是两三秒吐一批的，原样贴进输入框
    /// 就是一堆 `[00:00:01–00:00:02] 我方麦克风:` 开头的碎行，用户第一眼看到的全是噪音。
    /// 同一个人的连续几批并成一段；只有真的听了两个音源时才在换人处标一次，
    /// 否则模型分不清是谁答应了什么。完整时间戳留在 `transcript.txt` 和转写原文页里。
    ///
    /// 超出预算时从最旧的一端整批丢弃：一场长会议给不完，也要给完整的句子，而不是半句话。
    ///
    /// 裁剪必须在合并**之前**做。一个人连说半小时会并成一整段，那时候再裁就只能从中间
    /// 切字；按识别批次裁，丢掉的边界总是某一句的开头。
    func spokenText(characterLimit: Int = draftLimit) -> String {
        guard characterLimit > 0 else { return "" }
        var kept: [ListeningSegment] = []
        var budget = characterLimit
        for segment in segments.reversed() {
            let cost = segment.text.count + 1
            guard cost <= budget else { break }
            kept.insert(segment, at: 0)
            budget -= cost
        }
        // 合并之后还要加说话人和「临时文字」标记，可能再次越界；从最旧的一批开始让位。
        while !kept.isEmpty {
            let text = Self.spoken(kept).joined(separator: "\n")
            if text.count <= characterLimit { return text }
            kept.removeFirst()
        }
        // 一批就已经超预算的极端情况：至少把最近说的那几个字留下。
        guard let last = segments.last else { return "" }
        return String(Self.spoken([last]).joined().suffix(characterLimit))
    }

    /// 把按批次切开的识别结果还原成「谁说了什么」。
    static func spoken(_ segments: [ListeningSegment]) -> [String] {
        let labelled = Set(segments.map(\.source)).count > 1
        var groups: [(source: ListeningSource, text: String, provisional: Bool)] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = groups.last, last.source == segment.source {
                groups[groups.count - 1] = (last.source, last.text + " " + text,
                                            last.provisional || !segment.isFinal)
            } else {
                groups.append((segment.source, text, !segment.isFinal))
            }
        }
        return groups.map { group in
            (labelled ? "\(group.source.title): " : "")
                + group.text
                + (group.provisional ? " " + String(localized: "（末尾是临时文字，可能还会修正）") : "")
        }
    }

    func save(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        try text.write(to: directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    }
}

/// Admission control reserves an entire bounded session. Never removes user records.
enum ListeningStorageBudget {
    static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumSessions = 100
    static let textReservation: Int64 = 32 * 1024 * 1024
    static let audioReservation: Int64 = 544 * 1024 * 1024

    /// Only this feature's directory is removed; siblings (chats/keys/settings) are untouched.
    static func clearRecords(in supportDirectory: URL) throws {
        let root = supportDirectory.appendingPathComponent("Listening", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    static func validate(root: URL, savesAudio: Bool) throws {
        let manager = FileManager.default
        // Check the root itself, including dangling links, before following any path.
        if let attributes = try? manager.attributesOfItem(atPath: root.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw full() }
        guard manager.fileExists(atPath: root.path) else { return }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))
        var sessions = 0
        var bytes: Int64 = 0
        var entries = 0
        func count(_ url: URL) throws {
            entries += 1
            let values = try url.resourceValues(forKeys: keys)
            // Fail closed on unexpected links/huge trees instead of following them.
            guard entries <= 30_000, values.isSymbolicLink != true else { throw full() }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            guard bytes <= maximumBytes else { throw full() }
        }
        for child in children {
            try count(child)
            if try child.resourceValues(forKeys: keys).isDirectory == true {
                sessions += 1
                guard sessions < maximumSessions else { throw full() }
                // Our sessions are flat; unknown nested folders require user review.
                for file in try manager.contentsOfDirectory(at: child, includingPropertiesForKeys: Array(keys)) {
                    try count(file)
                    if try file.resourceValues(forKeys: keys).isDirectory == true { throw full() }
                }
            }
        }
        let reservation = savesAudio ? audioReservation : textReservation
        guard bytes <= maximumBytes - reservation else { throw full() }
    }

    private static func full() -> ListeningFailure {
        ListeningFailure(message: String(localized: "本地转写记录空间不足或记录过多（最多 2 GiB / 100 次）。请打开记录文件夹，手动整理后再开始；旧记录不会自动删除。"))
    }
}

struct ListeningFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
