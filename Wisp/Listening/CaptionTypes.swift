import Foundation

struct ListeningPreferences: Codable, Equatable {
    static let key = AppSettings.listeningPreferencesKey
    static let locales = ["en-US", "zh-CN", "zh-TW", "ja-JP"]
    var locale = "zh-CN"
    var recognitionEngine: ListeningEngine?
    /// Caption questions go to the configured API connection (the default) instead of the
    /// connection the panel uses: a CLI starts a process for every question.
    var asksThroughAPI: Bool?
    /// Experimental: when the other side's words end in a question, ask Quick Ask by itself.
    var autoAnswer: Bool?

    init() {}

    /// Each field is read on its own: a value saved by an older Wisp (an engine that no longer
    /// exists, keys of removed features) costs only that field, not the whole set.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locale = (try? container.decode(String.self, forKey: .locale)) ?? Self().locale
        recognitionEngine = try? container.decode(ListeningEngine.self, forKey: .recognitionEngine)
        asksThroughAPI = try? container.decode(Bool.self, forKey: .asksThroughAPI)
        autoAnswer = try? container.decode(Bool.self, forKey: .autoAnswer)
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if !locales.contains(value.locale) { value.locale = Self().locale }
        return value
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Who turns speech into captions.
enum ListeningEngine: String, Codable, CaseIterable {
    /// Apple's on-device recognizer: free, and the audio never leaves the Mac.
    case appleSpeech
    /// Soniox's real-time service: the audio goes to Soniox, billed by the minute.
    case soniox
}

/// Recognized words with the span of session audio they cover, in seconds from the session start.
struct CaptionPiece: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// What a recognizer reports: words it will not revise, or its current guess at the words after
/// them. A new guess replaces the previous one; committed words replace the guess they settle.
enum CaptionUpdate: Equatable {
    case committed([CaptionPiece])
    case volatile(CaptionPiece?)
}

/// The last half minute of the other side's speech, in memory only.
///
/// Nothing older than `retention` is kept: it is what the longest question window can ask for,
/// and nothing about a meeting is written to disk. Committed words carry their own audio times,
/// so a window cuts at a word. The volatile guess covers whatever has not settled yet, so it
/// always counts as recent.
struct CaptionBuffer: Equatable {
    /// The longest transcript window a command can attach.
    static let retention: TimeInterval = 30

    /// Push-to-talk keeps a whole question instead, bounded by its own 60-second hold limit.
    let retention: TimeInterval
    private(set) var committed: [CaptionPiece] = []
    private(set) var volatile: CaptionPiece?

    init(retention: TimeInterval = CaptionBuffer.retention) {
        self.retention = retention
    }

    var isEmpty: Bool { committed.isEmpty && (volatile?.text.isEmpty ?? true) }

    /// The latest audio time any recognized word reaches.
    var latestEnd: TimeInterval { max(committed.last?.end ?? 0, volatile?.end ?? 0) }

    mutating func apply(_ update: CaptionUpdate) {
        switch update {
        case .committed(let pieces):
            committed.append(contentsOf: pieces.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
            volatile = nil
        case .volatile(let piece):
            volatile = piece?.text.trimmingCharacters(in: .whitespaces).isEmpty == false ? piece : nil
        }
        let cutoff = latestEnd - retention
        committed.removeAll { $0.end < cutoff }
    }

    /// Everything said in the last `seconds`, counted back from the latest recognized word rather
    /// than the clock: after a silence, "what did they just ask" is still the last thing said.
    func text(lastSeconds seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        let cutoff = latestEnd - seconds
        let recent = committed.filter { $0.end > cutoff } + (volatile.map { [$0] } ?? [])
        return Self.join(recent.map(\.text))
    }

    /// The whole buffer, for the caption bar, which shows its tail.
    var text: String { Self.join(committed.map(\.text) + (volatile.map { [$0.text] } ?? [])) }

    /// Both recognizers put the space before an English word into the word itself, and Chinese
    /// takes no spaces, so the pieces are simply joined.
    static func join(_ parts: [String]) -> String {
        parts.joined().trimmingCharacters(in: .whitespaces)
    }

    /// Whether these words end in a question: a question mark, which both recognizers add.
    static func endsWithQuestion(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "？" || last == "?"
    }
}

struct ListeningFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static var microphoneDenied: Self { .init(message: String(localized: "请在系统设置 → 隐私与安全性 → 麦克风中允许 Wisp。")) }
}
