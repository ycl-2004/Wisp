import KeyboardShortcuts
import SwiftUI

// MARK: - 隐私

/// 会议共享输出与本地窗口、菜单栏的隐私设置。
struct PrivacySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var presentation = PresentationDisplay.shared
    @State private var confirmHidingMenuBarIcon = false

    /// 关掉菜单栏图标之后，用户还剩什么办法把 Wisp 叫出来。
    private var fallbackEntry: String {
        // 增强模式下标准快捷键已经注销，能用的是录下来的那个。
        let summon = settings.shortcutTrigger == .standard
            ? KeyboardShortcuts.getShortcut(for: .toggleAssistant)?.description
            : settings.advancedShortcut?.symbolicName(tapCount: settings.shortcutTrigger.tapCount ?? 1)
        if let summon {
            return String(localized: "快捷键 \(summon)，或者在访达里再打开一次 Wisp")
        }
        return String(localized: "在访达里再打开一次 Wisp")
    }

    var body: some View {
        Form {
            Section {
                privacyToggle("在共享和录屏中隐藏 Wisp", isOn: Binding(
                    get: { settings.hideFromScreenCapture },
                    set: { presentation.setHiding($0) }
                ), info: String(localized: "要共享整个屏幕，请启动专用演示屏，并在会议中选择 Wisp Presentation。直接共享主屏时，窗口隐藏效果取决于录屏工具。"))
                if settings.hideFromScreenCapture {
                    if presentation.isOpen {
                        Button("关闭演示屏") { presentation.stop() }
                        if presentation.message == nil {
                            Text(presentation.isReady
                                 ? String(localized: "在会议中选“整个屏幕”，然后选 Wisp Presentation。结束会议共享后再关闭演示屏。")
                                 : String(localized: "正在准备演示屏…"))
                                .font(.caption)
                        }
                    } else {
                        Button("启动专用演示屏") { presentation.start() }
                    }
                    if let message = presentation.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                privacyToggle("在菜单栏显示图标", isOn: Binding(
                    get: { settings.showsMenuBarIcon },
                    // 关掉之前先问一句：这是没有 Dock 图标的应用唯一看得见的入口。
                    set: { if $0 { settings.showsMenuBarIcon = true } else { confirmHidingMenuBarIcon = true } }
                ), info: String(localized: "菜单栏图标可能出现在共享和录屏中。关闭后 Wisp 在菜单栏不留痕迹，仍可用全局快捷键唤起，或在访达里再打开一次 Wisp；面板上的齿轮是进入设置的入口。"))
            } header: {
                SettingsSectionHeader("屏幕共享")
            }
        }
        .formStyle(.grouped)
        .alert("关掉菜单栏图标？", isPresented: $confirmHidingMenuBarIcon) {
            Button("关掉", role: .destructive) { settings.showsMenuBarIcon = false }
            Button("保留", role: .cancel) { }
        } message: {
            Text("关掉之后菜单栏上不会再有 Wisp。要再打开它，用\(fallbackEntry)。")
        }
    }

    /// Keep the Info button independent so it cannot become the switch's accessible name.
    private func privacyToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>, info: String) -> some View {
        HStack(spacing: 5) {
            Text(title).accessibilityHidden(true)
            InfoButton(message: info)
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(Text(title))
        }
    }
}
