import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct WispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // 必须是 @AppStorage：App 里的 @ObservedObject 不驱动 Scene 更新，用它包出来的
    // Binding 会让 MenuBarExtra 一直读到插入前的旧值，图标根本不出现。
    @AppStorage(AppSettings.showsMenuBarIconKey) private var showsMenuBarIcon = true

    @State private var menuPresence = MenuBarPresence(
        isInserted: UserDefaults.standard.object(forKey: AppSettings.showsMenuBarIconKey) as? Bool ?? true)

    var body: some Scene {
        // 图标关掉后菜单栏上不留任何痕迹；入口退回全局快捷键和面板头部的齿轮。
        MenuBarExtra(isInserted: $menuPresence.isInserted) {
            MenuContent()
        } label: {
            Image(systemName: "rectangle.and.text.magnifyingglass")
        }
        .onChange(of: showsMenuBarIcon, initial: true) {
            menuPresence.setPreference(showsMenuBarIcon)
        }
        .onChange(of: menuPresence.isInserted) {
            guard showsMenuBarIcon, !menuPresence.isInserted else { return }
            // System removal must not persist as the user's preference. Retry only once,
            // then leave a usable panel instead of fighting macOS in an insertion loop.
            if !menuPresence.recoverIfNeeded(wantsVisible: showsMenuBarIcon) {
                PanelController.shared.show()
            }
        }

        Settings {
            SettingsView()
                .background(SettingsWindowConfigurator())
                .environmentObject(AssistantModel.shared)
                .environmentObject(ConversationStore.shared)
        }
        // 设置窗口可缩放，下限就是内容给出的最小尺寸（620×520 起）。
        // 以前根视图钉死宽高，窗口大小完全不可调（round-3 UI 审查）。
        .windowResizability(.contentMinSize)
    }
}

private struct MenuContent: View {
    @ObservedObject private var captions = LiveCaptions.shared
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var updateNotice = UpdateNotice.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var presentation = PresentationDisplay.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(String(localized: "唤起助手")) {
            PanelController.shared.toggle()
        }

        if captions.isEnabled {
            Button(captions.isActive ? String(localized: "关闭字幕") : String(localized: "打开字幕")) {
                captions.toggleFromUser()
            }
        }

        // 录演示视频时要临时露出来，藏在设置里第四层太远了。
        Toggle("共享时隐藏", isOn: Binding(
            get: { settings.hideFromScreenCapture },
            set: { presentation.setHiding($0) }
        ))

        if settings.hideFromScreenCapture {
            Button(presentation.isOpen ? String(localized: "关闭演示屏") : String(localized: "启动专用演示屏")) {
                if presentation.isOpen { presentation.stop() } else { presentation.start() }
            }
        }

        if let version = updateNotice.availableVersion {
            Divider()
            Button("有新版本 \(version)，去下载…") {
                NSWorkspace.shared.open(UpdateChecker.releasesPage)
            }
        }

        Divider()

        Text("\(store.savedCount)/\(store.maxConversations) 个对话")

        Button("设置…") {
            SettingsWindowPresenter.open(using: openSettings)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        QuitWispButton()
            .keyboardShortcut("q", modifiers: .command)
    }

}

/// 菜单栏、药丸右键菜单和设置「通用」页共用的退出入口。
/// 菜单栏图标可以被关掉，药丸也可以被关掉，所以退出不能只放在其中一处。
struct QuitWispButton: View {
    var body: some View {
        Button("退出 Wisp") {
            NSApplication.shared.terminate(nil)
        }
    }
}

/// Insertion is runtime state, not the persisted opt-out. Apple writes false on removal:
/// https://developer.apple.com/documentation/swiftui/menubarextra
struct MenuBarPresence {
    var isInserted: Bool
    private(set) var attemptedRecovery = false

    mutating func setPreference(_ visible: Bool) {
        attemptedRecovery = false
        isInserted = visible
    }

    @discardableResult
    mutating func recoverIfNeeded(wantsVisible: Bool) -> Bool {
        guard wantsVisible, !isInserted, !attemptedRecovery else { return false }
        attemptedRecovery = true
        isInserted = true
        return true
    }
}
