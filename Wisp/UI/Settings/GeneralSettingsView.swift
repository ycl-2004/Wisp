import AppKit
import SwiftUI

// MARK: - 通用

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var store: ConversationStore

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var updateState: UpdateChecker.Outcome?
    @State private var checking = false
    @State private var showsNotices = false
    @State private var archivedName: String?
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (build \(build))"
    }

    var body: some View {
        Form {
            Section {
                Picker("界面语言", selection: Binding(
                    get: { language },
                    set: { newValue in
                        language = newValue
                        AppLanguage.apply(newValue)
                        languageChanged = true
                    }
                )) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                if languageChanged {
                    HStack(spacing: 10) {
                        Text("重开之后生效。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button("立即重启") { AppRelaunch.now() }
                        Spacer()
                    }
                }
            } header: {
                SettingsSectionHeader("语言", info: String(localized: "留空跟随系统；只影响 Wisp，不改系统语言。"))
            }

            Section {
                Button("重新运行首次设置") {
                    PanelController.shared.show {
                        AssistantModel.shared.showsOnboarding = true
                    }
                }
            } header: {
                SettingsSectionHeader("帮助", info: String(localized: "重新打开首次设置向导：连接模型、录屏权限和呼出快捷键都可以在里面完成。"))
            }

            Section {
                Toggle("登录时启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                HStack(spacing: 5) {
                    Text("登录项")
                    // 出问题时警告挤在这一行里，不另起一行——它讲的就是登录项的事，
                    // 单独占一行只会把这个两行的区段撑成三行。
                    if let note = LaunchAtLogin.statusNote {
                        Label("需要设置", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        InfoButton(message: note)
                    } else {
                        InfoButton(message: String(localized: "在系统设置中管理 Wisp 的登录权限。"))
                    }
                    Spacer()
                    Button("管理…") { LaunchAtLogin.openLoginItemsSettings() }
                }
                if let launchError {
                    Text(launchError).font(.system(size: 10)).foregroundStyle(.red)
                }
            } header: {
                SettingsSectionHeader("启动")
            }

            Section {
                Toggle("自动检查更新", isOn: Binding(
                    get: { settings.checkForUpdates },
                    set: { settings.checkForUpdates = $0 }
                ))
                HStack(spacing: 10) {
                    Button(checking ? "检查中…" : "现在检查") { runCheck() }
                        .disabled(checking)
                    updateLine
                    Spacer()
                }
            } header: {
                SettingsSectionHeader("更新", info: String(localized: "仅请求 GitHub 的版本号，不发送使用信息，也不会自动下载。"))
            }

            if store.isReadOnly || archivedName != nil {
                Section("对话记录被锁为只读") {
                    if store.isReadOnly {
                        Text(store.loadIssue?.message ?? "")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("备份并重置", role: .destructive) {
                            archivedName = store.archiveBlockingFileAndReset()
                        }
                    }
                    if let archivedName {
                        Text("已备份为 \(archivedName)，现在可以正常保存了。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("版本", value: version)
                HStack(spacing: 10) {
                    Button("项目主页") { NSWorkspace.shared.open(UpdateChecker.releasesPage) }
                    Button("报告问题") { NSWorkspace.shared.open(UpdateChecker.issuesPage) }
                    Button("开源许可") { showsNotices = true }
                    Spacer()
                }
            } header: {
                SettingsSectionHeader("关于", info: String(localized: "崩溃日志由 macOS 控制台保存；Wisp 不包含统计或崩溃上报。"))
            }

            // 菜单栏图标和药丸都能关掉，两者都关时这里是唯一看得见的退出入口。
            Section {
                QuitWispButton()
            } header: {
                SettingsSectionHeader("退出", info: String(localized: "退出后全局快捷键、字幕和小药丸都会停止。要再用，从访达或聚焦打开 Wisp。"))
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsNotices) {
            NoticesSheet().background(ScreenPrivacyWindow())
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            language = AppLanguage.current
        }
        .onChange(of: settings.dataWipeCount) { _, _ in
            language = AppLanguage.current
            languageChanged = false
            updateState = nil
            archivedName = nil
        }
    }

    @ViewBuilder
    private var updateLine: some View {
        switch updateState {
        case .upToDate(let current):
            Label("已经是最新的（\(current)）", systemImage: "checkmark.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .available(let latest):
            HStack(spacing: 6) {
                Label("有新版本 \(latest)", systemImage: "arrow.down.circle")
                    .font(.system(size: 11))
                Button("去下载") { NSWorkspace.shared.open(UpdateChecker.releasesPage) }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        case nil:
            EmptyView()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchError = nil
        } catch {
            launchError = String(localized: "改不了登录项：\(error.localizedDescription)")
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func runCheck() {
        checking = true
        Task {
            let outcome = await UpdateChecker.check()
            await MainActor.run {
                updateState = outcome
                checking = false
            }
        }
    }
}

/// 第三方许可全文。随 App 一起分发，MIT 要求保留版权声明。
private struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var text: String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "找不到许可文件。")
        }
        return content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开源许可").font(.system(size: 14, weight: .semibold))
            ScrollView {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
    }
}
