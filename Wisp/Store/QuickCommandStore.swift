import Foundation
import KeyboardShortcuts

/// A saved question run with one click or one shortcut, sent like a typed question with the
/// current screen context. Replaces the fixed suggestions the empty chat used to show.
struct QuickCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var prompt: String
    /// nil runs in whichever mode the toggle shows. A command that needs the whole page picks Deep,
    /// one that should answer at once picks Quick.
    var mode: ResponseMode?

    /// No dot: KeyboardShortcuts 3 reserves it, because the name doubles as an observation key path.
    var shortcutName: KeyboardShortcuts.Name { .init("quickCommand-" + id.uuidString) }

    /// The name shortcuts were recorded under before KeyboardShortcuts 3, read once at launch by
    /// `QuickCommandStore.migrateLegacyShortcutNames()`.
    var legacyShortcutName: KeyboardShortcuts.Name { .init(rawValue: "quickCommand." + id.uuidString)! }

    /// The mode's own symbol, so the list already says how the command will answer.
    var symbol: String { mode?.symbol ?? "sparkles" }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "未命名") : trimmed
    }

    /// A command with nothing to ask is kept in Settings but not offered in the panel.
    var isRunnable: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Text already in the input box is the material the command works on, so "paste a paragraph,
    /// then click Translate" does what it says.
    func question(withDraft draft: String) -> String {
        let material = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return material.isEmpty ? prompt : prompt + "\n\n" + material
    }

    /// Seeded on first launch and by "Restore Defaults", in the interface language of that moment.
    static var defaults: [QuickCommand] {
        [
            QuickCommand(title: String(localized: "总结这一页"),
                         prompt: String(localized: "请提炼当前网页的核心要点和关键结论，分条列出。"), mode: .deep),
            QuickCommand(title: String(localized: "翻译选中内容"),
                         prompt: String(localized: "把我选中的文字翻译成中文；本来就是中文的话就翻译成英文。只给译文，不用解释。"),
                         mode: .quick),
            QuickCommand(title: String(localized: "解释代码或报错"),
                         prompt: String(localized: "请分析当前窗口中的代码或报错信息，指出其核心原因。"), mode: .deep),
            QuickCommand(title: String(localized: "提取要点与待办"),
                         prompt: String(localized: "从当前屏幕中提取重要信息，整理成清晰的要点与待办事项。")),
        ]
    }
}

@MainActor
final class QuickCommandStore: ObservableObject {
    static let shared = QuickCommandStore()
    static let key = "quickCommands"

    @Published var commands: [QuickCommand] {
        didSet {
            save()
            registerShortcuts()
        }
    }

    /// 存着的数据解不开时为真（#48）。以前 init 用 try? 解码、失败就当
    /// 第一次启动装默认指令，用户会以为指令被「重置」了，而随后任何一次
    /// 编辑都会把原始数据覆盖掉。现在：内存里照样给默认指令用，但保存
    /// 被压住，界面上明说，只有用户显式「恢复默认」才清掉这个状态。
    @Published private(set) var loadFailed = false

    private let defaults: UserDefaults
    /// Names that already have a library handler installed. Handlers
    /// dispatch by name through the CURRENT command list, so each name is
    /// hooked exactly once for the life of the process; a deleted
    /// command's name simply stops resolving (and `delete` /
    /// `restoreDefaults` reset its recorded shortcut, which is what
    /// unregisters the system hotkey), so no handler ever needs removing.
    private var hookedNames: Set<KeyboardShortcuts.Name> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            if let saved = try? JSONDecoder().decode([QuickCommand].self, from: data) {
                commands = saved
            } else {
                commands = QuickCommand.defaults
                loadFailed = true
            }
        } else {
            commands = QuickCommand.defaults
        }
        migrateLegacyShortcutNames()
    }

    /// A shortcut recorded under a pre-KeyboardShortcuts-3 dotted name moves to the current name
    /// once, unless the current name already has one; the old entry is removed either way.
    private func migrateLegacyShortcutNames() {
        for command in commands {
            let legacy = command.legacyShortcutName
            guard let shortcut = KeyboardShortcuts.getShortcut(for: legacy) else { continue }
            if KeyboardShortcuts.getShortcut(for: command.shortcutName) == nil {
                KeyboardShortcuts.setShortcut(shortcut, for: command.shortcutName)
            }
            KeyboardShortcuts.setShortcut(nil, for: legacy)
        }
    }

    @discardableResult
    func add() -> QuickCommand {
        let command = QuickCommand(title: String(localized: "新指令"), prompt: "")
        commands.append(command)
        return command
    }

    func delete(_ id: UUID) {
        guard let command = commands.first(where: { $0.id == id }) else { return }
        // The recorder stores the shortcut on its own; a deleted command must not keep a hot key.
        KeyboardShortcuts.reset(command.shortcutName)
        commands.removeAll { $0.id == id }
    }

    func restoreDefaults() {
        // 显式恢复是解开 loadFailed 的唯一出口：先清状态，didSet 的保存才会落盘。
        loadFailed = false
        KeyboardShortcuts.reset(commands.map(\.shortcutName))
        commands = QuickCommand.defaults
    }

    /// Each command's shortcut runs it from any app. A name's handler is
    /// installed once and resolves its command at press time, so edits
    /// and deletions need no re-registration.
    func registerShortcuts() {
        for command in commands where !hookedNames.contains(command.shortcutName) {
            hookedNames.insert(command.shortcutName)
            let name = command.shortcutName
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                Task { @MainActor in self?.triggerShortcut(named: name) }
            }
        }
    }

    private func triggerShortcut(named name: KeyboardShortcuts.Name) {
        guard let command = commands.first(where: { $0.shortcutName == name }) else { return }
        trigger(command.id)
    }

    /// From a shortcut the panel may be hidden: show it first, so the command reads the app the
    /// user is looking at, then run it once that capture has finished.
    func trigger(_ id: UUID) {
        guard let command = commands.first(where: { $0.id == id }) else { return }
        let panel = PanelController.shared
        if panel.isVisible { AssistantModel.shared.run(command) }
        else { panel.show { AssistantModel.shared.run(command) } }
    }

    private func save() {
        // 解码失败后存着的原始数据还在，不能被默认指令默默覆盖（#48）。
        guard !loadFailed else { return }
        if let data = try? JSONEncoder().encode(commands) { defaults.set(data, forKey: Self.key) }
    }
}
