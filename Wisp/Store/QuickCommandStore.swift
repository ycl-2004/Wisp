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

    var shortcutName: KeyboardShortcuts.Name { .init("quickCommand." + id.uuidString) }

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

    private let defaults: UserDefaults
    private var registered: [KeyboardShortcuts.Name] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([QuickCommand].self, from: data) {
            commands = saved
        } else {
            commands = QuickCommand.defaults
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
        KeyboardShortcuts.reset(commands.map(\.shortcutName))
        commands = QuickCommand.defaults
    }

    /// Each command's shortcut runs it from any app. Re-registered only when the set of commands
    /// changes, not on every keystroke in the editor.
    func registerShortcuts() {
        let names = commands.map(\.shortcutName)
        guard names != registered else { return }
        registered.forEach { KeyboardShortcuts.removeHandler(for: $0) }
        registered = names
        for command in commands {
            let id = command.id
            KeyboardShortcuts.onKeyUp(for: command.shortcutName) {
                Task { @MainActor in QuickCommandStore.shared.trigger(id) }
            }
        }
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
        if let data = try? JSONEncoder().encode(commands) { defaults.set(data, forKey: Self.key) }
    }
}
