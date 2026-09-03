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

    var body: some View {
        Button(String(localized: "唤起助手")) {
            PanelController.shared.toggle()
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

}
