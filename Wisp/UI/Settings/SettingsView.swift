import SwiftUI

struct SettingsView: View {
    enum Tab: String { case model, panel, commands, capture, audio, privacy, data, general }
    /// Remembered, and set by the panel's "Edit Commands…" before it opens Settings.
    @AppStorage(AppSettings.settingsTabKey) private var tab: Tab = .model
    @State private var wipeResult: String?

    var body: some View {
        TabView(selection: $tab) {
            ModelSettingsView().tabItem { Label("模型", systemImage: "cpu") }.tag(Tab.model)
            PanelSettingsView().tabItem { Label("面板", systemImage: "macwindow") }.tag(Tab.panel)
            QuickCommandSettingsView().tabItem { Label("指令", systemImage: "sparkles") }.tag(Tab.commands)
            CaptureSettingsView().tabItem { Label("采集", systemImage: "camera.viewfinder") }.tag(Tab.capture)
            AudioSettingsView().tabItem { Label("音频", systemImage: "waveform") }.tag(Tab.audio)
            PrivacySettingsView().tabItem { Label("隐私", systemImage: "hand.raised") }.tag(Tab.privacy)
            DataSettingsView(wipeResult: $wipeResult)
                .tabItem { Label("数据", systemImage: "internaldrive") }.tag(Tab.data)
            GeneralSettingsView().tabItem { Label("通用", systemImage: "gearshape") }.tag(Tab.general)
        }
        // 只给下限不给死尺寸：窗口能放大，下限 620×520 与原来的固定
        // 尺寸一致（配合 Scene 上的 windowResizability(.contentMinSize)）。
        .frame(minWidth: 620, minHeight: 520)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let wipeResult {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Text(wipeResult)
                            .font(.callout)
                            .textSelection(.enabled)
                        Spacer()
                        Button("完成") { self.wipeResult = nil }
                    }
                    .padding()
                    .background(.regularMaterial)
                }
            }
        }
    }
}

// MARK: - 设置页的小零件

struct SettingsSectionHeader: View {
    let title: LocalizedStringKey
    let info: String?

    init(_ title: LocalizedStringKey, info: String? = nil) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let info {
                InfoButton(message: info)
            }
        }
    }
}

/// 常驻说明收进这里：悬停看 tooltip，点击给键盘用户一个可读的 popover。
struct InfoButton: View {
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(PrivacyPlainButtonStyle())
        .foregroundStyle(.secondary)
        .help(Text(message))
        .accessibilityLabel(Text("信息"))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
                .background(ScreenPrivacyWindow())
        }
    }
}

/// 权限行：状态在前，操作在后。已经授权就不再给「请求」——系统不会再弹第二次窗，
/// 留着那颗按钮等于把同一件事问两遍，还让人以为授权没生效。
struct PermissionRow: View {
    let title: LocalizedStringKey
    let status: String
    let granted: Bool
    var requestDisabled = false
    let request: () -> Void
    let open: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(status).foregroundStyle(granted ? Color.secondary : Color.orange)
            if !granted {
                Button("请求", action: request).disabled(requestDisabled)
            }
            Button("系统设置…", action: open)
        }
    }
}

/// 原生 Stepper 的竖向双箭头在紧凑设置行里太拥挤；改成轻量横向减／加控件。
struct CompactStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>

    init(_ title: LocalizedStringKey, value: Binding<Int>, in range: ClosedRange<Int>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)

            HStack(spacing: 0) {
                stepButton(systemName: "minus", label: "减少", enabled: value > range.lowerBound) {
                    value = max(range.lowerBound, value - 1)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 0.5, height: 12)

                stepButton(systemName: "plus", label: "增加", enabled: value < range.upperBound) {
                    value = min(range.upperBound, value + 1)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(value)")
    }

    private func stepButton(systemName: String,
                            label: LocalizedStringKey,
                            enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8.5, weight: .semibold))
                .frame(width: 23, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(PrivacyPlainButtonStyle())
        .foregroundStyle(enabled ? Color.secondary : Color.primary.opacity(0.24))
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
        .help(label)
    }
}
