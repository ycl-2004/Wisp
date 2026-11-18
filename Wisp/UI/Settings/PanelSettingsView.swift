import KeyboardShortcuts
import SwiftUI

// MARK: - 面板

private struct AdvancedShortcutRecorderView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var recorder = AdvancedShortcutRecorderModel()

    private var tapCount: Int { settings.shortcutTrigger.tapCount ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text("唤起助手：")
                    InfoButton(message: instruction)
                }
                Spacer()
                if let shortcut = settings.advancedShortcut, !recorder.isRecording {
                    Text(shortcut.displayName)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                }
                Button {
                    if recorder.isRecording {
                        recorder.cancel()
                    } else {
                        recorder.begin(tapCount: tapCount) { shortcut in
                            settings.advancedShortcut = shortcut
                        }
                    }
                } label: {
                    Text(buttonTitle)
                }
                .controlSize(.small)
            }

            if recorder.isRecording {
                Text(instruction)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: settings.shortcutTrigger) { _, _ in
            recorder.cancel()
        }
        .onDisappear { recorder.cancel() }
    }

    private var buttonTitle: String {
        if recorder.isRecording {
            return String(localized: "请按 \(tapCount) 次（\(recorder.progress)/\(tapCount)）")
        }
        return settings.advancedShortcut == nil
            ? String(localized: "开始录制")
            : String(localized: "重新录制")
    }

    private var instruction: String {
        switch settings.shortcutTrigger {
        case .enhancedSingle:
            return String(localized: "点击录制后按一次组合键，例如 Globe/Fn + Space 或 Shift + Space。")
        case .doubleTap:
            return String(localized: "点击录制后快速按两次同一个键，例如 Control、Globe/Fn 或 Space。")
        case .tripleTap:
            return String(localized: "点击录制后快速按三次同一个键。")
        case .standard:
            return ""
        }
    }
}

/// 悬浮面板本身：怎么叫出来、透到什么程度、什么时候自己消失。
/// 药丸虽然是另一个窗口，但它是面板的入口，放一起找起来最顺。
struct PanelSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hasAccessibility = Permissions.hasAccessibility
    /// 关掉自动收起时把秒数存在这，再打开时不用重新调。
    @State private var idleSecondsDraft = 10

    var body: some View {
        Form {
            Section {
                Picker("触发方式", selection: Binding(
                    get: { settings.shortcutTrigger },
                    set: {
                        settings.shortcutTrigger = $0
                        AppDelegate.applyShortcutTrigger()
                        AdvancedShortcutMonitor.shared.cancelRecording()
                    }
                )) {
                    ForEach(ShortcutTriggerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if settings.shortcutTrigger == .standard {
                    KeyboardShortcuts.Recorder("唤起助手：", name: .toggleAssistant)
                } else {
                    AdvancedShortcutRecorderView()

                    if !hasAccessibility {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("增强快捷键需要辅助功能权限，才能在其他 App 中生效。")
                                .font(.system(size: 10))
                            Spacer()
                            Button("去授权") { Permissions.openAccessibilitySettings() }
                                .controlSize(.small)
                        }
                    }
                }

                KeyboardShortcuts.Recorder("录制笔记：", name: .toggleNotes)
            } header: {
                SettingsSectionHeader("快捷键", info: String(localized: "标准组合保持兼容；增强模式支持 Shift、Globe/Fn、单独修饰键和双击/三击。"))
            }

            Section {
                HStack(spacing: 12) {
                    Slider(value: Binding(
                        get: { settings.panelBackgroundOpacity },
                        set: { settings.panelBackgroundOpacity = $0 }
                    ), in: AppSettings.minimumPanelBackgroundOpacity...1, step: 0.05)
                    Text(verbatim: "\(Int((settings.panelBackgroundOpacity * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("面板不透明度"))

                PanelOpacityPreview(opacity: settings.panelBackgroundOpacity)

                Toggle("悬停或输入时恢复不透明", isOn: Binding(
                    get: { settings.panelOpaqueWhenActive },
                    set: { settings.panelOpaqueWhenActive = $0 }
                ))
                .disabled(settings.panelBackgroundOpacity >= 1)
            } header: {
                SettingsSectionHeader("面板不透明度", info: String(localized: "调低后能看穿到底下的窗口，方便对照着提问。只有面板底会变透，文字和按钮始终清晰。"))
            }

            Section {
                Toggle("显示", isOn: Binding(
                    get: { settings.showIsland },
                    set: { settings.showIsland = $0; IslandController.shared.setEnabled($0) }
                ))
                Picker("位置", selection: Binding(
                    get: { settings.islandPosition },
                    set: { settings.islandPosition = $0; IslandController.shared.applyPositionChange() }
                )) {
                    Text("桌面上（可拖动）").tag("bottom")
                    Text("贴住刘海").tag("notch")
                }
                .pickerStyle(.radioGroup)
                .disabled(!settings.showIsland)

                if settings.islandPosition == "bottom" {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Spacer()
                        InfoButton(message: String(localized: "底部位置可拖动，Wisp 会记住位置；面板仍从底部中央打开。"))
                        Button("重置位置") { IslandController.shared.resetPosition() }
                            .disabled(!settings.hasCustomIslandAnchor || !settings.showIsland)
                    }
                }
            } header: {
                SettingsSectionHeader("常驻小药丸", info: String(localized: "空闲时只显示图标；悬停展开，点击打开。回答生成时可停止。"))
            }

            Section {
                Toggle("离开面板后自动收起", isOn: Binding(
                    get: { settings.idleDismissSeconds > 0 },
                    set: { on in
                        if on {
                            settings.idleDismissSeconds = Double(max(1, idleSecondsDraft))
                        } else {
                            // 关掉之前先把秒数记下来，下次打开还是这个值。
                            idleSecondsDraft = max(1, Int(settings.idleDismissSeconds))
                            settings.idleDismissSeconds = 0
                        }
                        PanelController.shared.refreshIdleTimer()
                    }
                ))
                CompactStepper("等待 \(Int(settings.idleDismissSeconds)) 秒",
                               value: Binding(
                                   get: { max(1, Int(settings.idleDismissSeconds)) },
                                   set: { seconds in
                                       idleSecondsDraft = seconds
                                       settings.idleDismissSeconds = Double(seconds)
                                       PanelController.shared.refreshIdleTimer()
                                   }
                               ),
                               in: 1...300)
                    .disabled(settings.idleDismissSeconds <= 0)
            } header: {
                SettingsSectionHeader("自动收起", info: String(localized: "离开面板后开始倒计时；输入、悬停、生成或采集时不会收起。"))
            }
        }
        .formStyle(.grouped)
        .onAppear { hasAccessibility = Permissions.hasAccessibility }
    }
}

/// 滑块旁边的实时预览。
///
/// 真正的面板多半已经被自动收起了（点齿轮进设置就等于让它失焦），所以调滑块时
/// 得在这儿看得见效果。假的「底下窗口」用几条彩带代替，不透明度一低就该透出来。
private struct PanelOpacityPreview: View {
    var opacity: Double

    var body: some View {
        ZStack {
            underlyingWindow
            panel
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    /// 假装底下开着一个文档窗口：横条越明显，说明面板越透。
    private var underlyingWindow: some View {
        ZStack {
            LinearGradient(colors: [Color.teal.opacity(0.55), Color.purple.opacity(0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 7) {
                ForEach([0.85, 0.62, 0.74, 0.45], id: \.self) { fraction in
                    Capsule()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 240 * fraction, height: 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
        }
    }

    /// 面板本身。预览窗口是不透明的，behindWindow 在这里透不出东西，
    /// 所以用 withinWindow 混合上面那层彩带——观感和真面板一致。
    private var panel: some View {
        ZStack {
            VisualEffect(material: .hudWindow, blending: .withinWindow)
                .opacity(opacity)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: "Wisp")
                    .font(.system(size: 11, weight: .semibold))
                Text("文字和按钮不受影响，始终是实心的。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DS.specularRim, lineWidth: 0.75)
        )
        .animation(.easeOut(duration: 0.12), value: opacity)
    }
}
