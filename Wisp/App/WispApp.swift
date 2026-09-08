import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // 必须是 @AppStorage：App 里的 @ObservedObject 不驱动 Scene 更新，用它包出来的
    // Binding 会让 MenuBarExtra 一直读到插入前的旧值，图标根本不出现。
    @AppStorage(AppSettings.showsMenuBarIconKey) private var showsMenuBarIcon = true

    var body: some Scene {
        // 图标关掉后菜单栏上不留任何痕迹；入口退回全局快捷键和面板头部的齿轮。
        MenuBarExtra(isInserted: $showsMenuBarIcon) {
            MenuContent()
        } label: {
            Image(systemName: "rectangle.and.text.magnifyingglass")
        }

        Settings {
            SettingsView()
                .background(ScreenPrivacyWindow())
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
        Button(String(localized: "唤起助手")) {
            PanelController.shared.toggle()
        }

        // 录演示视频时要临时露出来，藏在设置里第四层太远了。
        Toggle("共享时隐藏", isOn: Binding(
            get: { settings.hideFromScreenCapture },
            set: { ScreenPrivacy.setEnabled($0) }
        ))

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
