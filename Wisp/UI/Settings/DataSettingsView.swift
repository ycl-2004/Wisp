import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - 数据

struct DataSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AssistantModel
    @State private var confirmWipe = false
    @Binding var wipeResult: String?
    @State private var confirmListeningWipe = false
    @State private var cleanupResult: String?
    @ObservedObject private var listening = ListeningModel.shared

    var body: some View {
        Form {
            Section {
                CompactStepper("最多保留 \(settings.maxConversations) 个对话",
                               value: Binding(get: { settings.maxConversations },
                                              set: { settings.maxConversations = $0 }),
                               in: 1...50)
                CompactStepper("每个对话最多 \(settings.maxUserTurns) 轮",
                               value: Binding(get: { settings.maxUserTurns },
                                              set: { settings.maxUserTurns = $0 }),
                               in: 5...200)
            } header: {
                SettingsSectionHeader("上限", info: String(localized: "到上限时，新建对话会询问是否移除最久未更新的一项。"))
            }

            Section {
                HStack {
                    Text(AppSettings.supportDirectory.path)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.supportDirectory])
                    }
                }
            } header: {
                SettingsSectionHeader("存储位置", info: String(localized: "对话和页面文字保存在本机。"))
            }

            Section {
                Toggle("保存诊断文件", isOn: Binding(
                    get: { settings.debugDumpEnabled },
                    set: { settings.debugDumpEnabled = $0 }
                ))
            } header: {
                SettingsSectionHeader("调试", info: String(localized: "额外写入 last-context.json 和 last-screenshot.jpg，仅用于排查。"))
            }

            Section {
                HStack {
                    Text("录音与转写")
                    Spacer()
                    Button("打开文件夹") { listening.showFiles() }
                    Button("清理…", role: .destructive) { confirmListeningWipe = true }
                        .disabled(listening.isActive)
                }
                if listening.isActive {
                    Text("请先停止录音，再清理记录。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let cleanupResult {
                    Text(cleanupResult).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                SettingsSectionHeader("录音记录", info: String(localized: "最多 2 GiB / 100 次。手动清理全部录音与转写，不影响对话和 API Key；不会定时自动删除。"))
            }

            Section {
                Button("删除全部数据与设置", role: .destructive) { confirmWipe = true }
            } header: {
                SettingsSectionHeader("清除", info: String(localized: "删除对话、录音与转写记录、调试文件和钥匙串中的 API Key，并把全部设置恢复为默认值；不可撤销。"))
            }
        }
        .formStyle(.grouped)
        .alert("清理录音与转写？", isPresented: $confirmListeningWipe) {
            Button("清理", role: .destructive) {
                do {
                    try listening.clearRecords()
                    cleanupResult = String(localized: "录音与转写已清理。")
                } catch { cleanupResult = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除所有本地录音与转写文件，无法撤销。对话和 API Key 保留。")
        }
        .alert("删除全部数据？", isPresented: $confirmWipe) {
            Button("全部删除", role: .destructive, action: wipe)
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有对话、录音与转写记录和 API Key 都会被删除，全部设置恢复为默认值，无法撤销。")
        }
    }

    private func wipe() {
        model.stopStreaming()
        listening.discardForDataReset()
        do {
            try settings.wipeLocalData(in: AppSettings.supportDirectory)
        } catch {
            wipeResult = String(localized: "有本地文件未能删除。请处理系统错误后重试。\(error.localizedDescription)")
            return
        }

        model.store.resetAfterDataWipe()
        let keysRemoved = KeychainStore.deleteAll()
        listening.reloadPreferences()
        QuickCommandStore.shared.restoreDefaults()
        KeyboardShortcuts.reset(KeyboardShortcuts.Name.appDefined)
        AppDelegate.applyShortcutTrigger()
        wipeResult = keysRemoved
            ? String(localized: "全部数据已删除。")
            : String(localized: "记录已删除，但 API Key 没能从钥匙串里全部删掉。请重启应用后再试一次清除。")
    }
}
