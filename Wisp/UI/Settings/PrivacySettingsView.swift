import KeyboardShortcuts
import SwiftUI

// MARK: - 隐私

/// 会议共享输出与本地窗口、光标及菜单栏的隐私设置。
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
                Toggle(isOn: Binding(
                    get: { settings.hideFromScreenCapture },
                    set: {
                        // Restore the pointer before making its host capture-visible.
                        if !$0 { LocalCursorController.shared.setEnabled(false) }
                        presentation.setHiding($0)
                    }
                )) {
                    HStack(spacing: 5) {
                        Text("在共享和录屏中隐藏 Wisp")
                        InfoButton(message: String(localized: "要共享整个屏幕，请启动专用演示屏，并在会议中选择 Wisp Presentation。直接共享主屏时，窗口隐藏效果取决于录屏工具。"))
                    }
                }
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
                Toggle(isOn: Binding(
                    get: { settings.localCursorEnabled },
                    set: {
                        settings.localCursorEnabled = $0
                        ScreenPrivacy.applyToAllWindows()
                        LocalCursorController.shared.setEnabled($0)
                    }
                )) {
                    HStack(spacing: 5) {
                        Text("隐私光标锁定（实验）")
                        InfoButton(message: String(localized: "开启后，本机使用一个移动箭头并关闭按钮按压特效；兼容录屏中隐藏鼠标，不再补画会残留的静止箭头。后台悬停保留系统指针，点击激活 Wisp 后生效；离开、关闭窗口或关闭选项后恢复。录屏工具另加的鼠标与点击提示需在该工具中关闭。开启时会同时开启窗口隐藏；关闭窗口隐藏也会关闭此选项。请检查实际接收端。"))
                    }
                }
                .accessibilityLabel(Text("隐私光标锁定（实验）"))
                if !settings.hideFromScreenCapture {
                    Text("开启光标锁定时，会同时开启窗口隐藏。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(
                    get: { settings.showsMenuBarIcon },
                    // 关掉之前先问一句：这是没有 Dock 图标的应用唯一看得见的入口。
                    set: { if $0 { settings.showsMenuBarIcon = true } else { confirmHidingMenuBarIcon = true } }
                )) {
                    HStack(spacing: 5) {
                        Text("在菜单栏显示图标")
                        InfoButton(message: String(localized: "菜单栏图标可能出现在共享和录屏中。关闭后 Wisp 在菜单栏不留痕迹，仍可用全局快捷键唤起，或在访达里再打开一次 Wisp；面板上的齿轮是进入设置的入口。"))
                    }
                }
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
}
