import AppKit
import AVFoundation
import KeyboardShortcuts
import Speech
import SwiftUI

// MARK: - 音频

/// Three groups: captions (switch, recognizer, language, how questions are asked), the two voice
/// shortcuts, and the permissions still missing.
struct AudioSettingsView: View {
    @ObservedObject private var captions = LiveCaptions.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screen = Permissions.hasScreenRecording
    @State private var languageStatus = ""
    @State private var speechKey = ""
    @State private var hasSpeechKey = KeychainStore.loadSpeechKey() != nil
    @State private var requesting = false
    @State private var speechKeyError = false

    /// 字幕开着时识别引擎和语言改不了；灰掉的同时说清楚原因。
    private var lockedWhileCaptioning: String {
        captions.isActive ? String(localized: "字幕开着时不能改，先关掉字幕。") : ""
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用语音", isOn: $captions.isEnabled)
                if captions.isEnabled {
                    Picker("识别", selection: $captions.engine) {
                        Text("Apple 设备端（免费，音频不出电脑）").tag(ListeningEngine.appleSpeech)
                        Text("Soniox 云端（按用量计费）").tag(ListeningEngine.soniox)
                    }
                    .disabled(captions.isActive)
                    .help(lockedWhileCaptioning)
                    if captions.engine == .soniox { sonioxKeyRow }
                    Picker("语言", selection: $captions.locale) {
                        Text("简体中文").tag("zh-CN")
                        Text("繁體中文").tag("zh-TW")
                        Text("English").tag("en-US")
                        Text("日本語").tag("ja-JP")
                    }
                    .disabled(captions.isActive)
                    .help(lockedWhileCaptioning)
                    if captions.engine == .appleSpeech, !languageStatus.isEmpty {
                        LabeledContent("本机识别") { Text(languageStatus).foregroundStyle(.secondary) }
                    }
                    Toggle("字幕提问走 API 连接（\(settings.cloudProvider.title)）", isOn: $captions.asksThroughAPI)
                    Toggle("对方一问就自动回答（实验）", isOn: $captions.autoAnswer)
                }
            } header: {
                SettingsSectionHeader("实时字幕", info: String(localized: "字幕听这台电脑放出来的所有声音（会议里对方的声音、视频、音乐），不听麦克风。点面板上的字幕按钮或按快捷键打开。字幕只在内存里保留最近 30 秒，不写进磁盘。")
                    + "\n\n" + String(localized: "Apple 设备端识别免费，音频不离开这台 Mac，一次只认所选的那一种语言。Soniox 云端识别能同时认所选语言和英文，对中英混说、英文术语通常更准，按用量计费（约每小时 0.12 美元），字幕开着时电脑放出来的声音会发送到 Soniox。")
                    + "\n\n" + String(localized: "「走 API 连接」：带上对方说的话的提问（在「指令」里设置）用「模型」页里配置的 API，不管面板当前用哪种连接。Agent CLI 每问一次都要启动一个进程，API 通常更快出第一个字。")
                    + "\n\n" + String(localized: "「自动回答」：对方说完一句以问号结尾的话、停顿 1 秒后，自动执行第一条带字幕的指令（默认「快问」）。两次之间至少隔 8 秒。每次会向模型发一次请求，输入框里的草稿会保留。"))
            }

            if captions.isEnabled {
                Section {
                    KeyboardShortcuts.Recorder("打开／关闭字幕", name: .toggleListening)
                    KeyboardShortcuts.Recorder("按住说话提问", name: .pushToTalk)
                } header: {
                    SettingsSectionHeader("快捷键", info: String(localized: "「按住说话提问」：按住快捷键说出问题，松开后按当前回答模式发送。麦克风录音不会保存，发出的转写文字会按当前对话的规则保留。按一下就松开不会发送。")
                        + "\n\n" + String(localized: "对方提问时的快捷键（「快问」「看屏幕问」）在「指令」里改。"))
                }

                if !screen || microphone != .authorized {
                    Section {
                        if !screen {
                            permissionRow("屏幕与系统音频", status: String(localized: "未授权"), granted: false, request: {
                                Permissions.requestScreenRecording()
                                refresh()
                            }, open: Permissions.openScreenRecordingSettings)
                        }
                        if microphone != .authorized {
                            permissionRow("麦克风", status: microphoneStatus, granted: false, request: {
                                requesting = true
                                Task {
                                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                                    requesting = false
                                    refresh()
                                }
                            }, open: Permissions.openMicrophoneSettings)
                        }
                    } header: {
                        SettingsSectionHeader("还缺的权限", info: String(localized: "字幕需要「屏幕与系统音频」来听电脑放出来的声音；麦克风只给「按住说话提问」用。仅在点击请求时弹出系统授权。"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onChange(of: captions.locale) { refresh() }
        .onChange(of: captions.engine) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    /// The key is written to the Keychain only when saved, and never shown again.
    private var sonioxKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if hasSpeechKey {
                    Text("Soniox API Key 已保存")
                    Spacer()
                    Button("清除") {
                        if KeychainStore.deleteSpeechKey() {
                            hasSpeechKey = false
                            speechKeyError = false
                        } else {
                            speechKeyError = true
                        }
                    }
                } else {
                    SecureField("Soniox API Key", text: $speechKey)
                    Button("保存") {
                        let key = speechKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        // 存不进钥匙串时要说出来，否则看起来像按钮没反应。
                        guard KeychainStore.saveSpeechKey(key) else {
                            speechKeyError = true
                            return
                        }
                        speechKey = ""
                        speechKeyError = false
                        hasSpeechKey = true
                    }
                    .disabled(speechKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link("获取", destination: URL(string: "https://console.soniox.com")!)
                }
            }
            if speechKeyError {
                Text("Soniox API Key 没能存进钥匙串，这次输入没有保存下来。")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
    }

    /// 字幕进行中请求会打断采集，所以这一页的「请求」统一带上同一个禁用条件。
    private func permissionRow(_ title: LocalizedStringKey, status: String, granted: Bool,
                               request: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        PermissionRow(title: title, status: status, granted: granted,
                      requestDisabled: requesting || captions.isActive,
                      request: request, open: open)
    }

    private var microphoneStatus: String {
        switch microphone {
        case .notDetermined: return String(localized: "未请求")
        case .restricted: return String(localized: "受限")
        default: return String(localized: "未授权")
        }
    }

    private func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        screen = Permissions.hasScreenRecording
        hasSpeechKey = KeychainStore.loadSpeechKey() != nil
        let identifier = captions.locale
        Task {
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
                languageStatus = String(localized: "不支持这种语言")
                return
            }
            let installed = await SpeechTranscriber.installedLocales
                .contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
            languageStatus = installed ? String(localized: "已就绪") : String(localized: "首次使用时下载")
        }
    }
}
