import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: "rectangle.and.text.magnifyingglass")
        }

        Settings {
            SettingsView()
                .environmentObject(AssistantModel.shared)
                .environmentObject(ConversationStore.shared)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var updateNotice = UpdateNotice.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if settings.shortcutTrigger == .standard {
            Button("唤起助手") {
                PanelController.shared.toggle()
            }
            .globalKeyboardShortcut(.toggleAssistant)
        } else {
            Button {
                PanelController.shared.toggle()
            } label: {
                HStack(spacing: 12) {
                    Text("唤起助手")
                    Spacer(minLength: 20)
                    Text(advancedShortcutLabel)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let version = updateNotice.availableVersion {
            Divider()
            Button("有新版本 \(version)，去下载…") {
                NSWorkspace.shared.open(UpdateChecker.releasesPage)
            }
        }

        Divider()

        Text("\(store.conversations.count)/\(store.maxConversations) 个对话")

        SettingsLink {
            Text("设置…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("退出 Wisp") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var advancedShortcutLabel: String {
        guard let shortcut = settings.advancedShortcut else {
            return String(localized: "未设置")
        }

        let name = shortcut.displayName
        switch settings.shortcutTrigger {
        case .enhancedSingle:
            return name
        case .doubleTap:
            return String(localized: "双击 \(name)")
        case .tripleTap:
            return String(localized: "三击 \(name)")
        case .standard:
            return ""
        }
    }
}
