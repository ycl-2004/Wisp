import AppKit
import AVFoundation
import Speech
import KeyboardShortcuts
import SwiftUI

// MARK: - 音频

struct AudioSettingsView: View {
    @ObservedObject private var listening = ListeningModel.shared
    @ObservedObject private var catalog = LocalSpeechCatalog.shared
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var screen = Permissions.hasScreenRecording
    @State private var deviceSupport = ""
    @State private var requesting = false

    var body: some View {
        Form {
            Section {
                Toggle("启用语音输入", isOn: $listening.isEnabled)
            } header: {
                SettingsSectionHeader("语音输入", info: String(localized: "关掉之后面板上不再有语音那一行，快捷键也不再开始录音；正在录的会先停下来。"))
            }

            // 关掉之后底下这些都不再影响任何事，留在页面上只会让人以为它们还在生效。
            if listening.isEnabled {
                Section {
                    Picker("音源", selection: $listening.mode) {
                        ForEach(ListeningMode.allCases) { Text($0.title).tag($0) }
                    }
                    if listening.mode.sources.contains(.application) {
                        HStack {
                            Picker("应用", selection: $listening.selectedPID) {
                                Text("选择音频应用…").tag(pid_t(0))
                                ForEach(listening.applications, id: \.processID) { app in
                                    Text(app.applicationName).tag(app.processID)
                                }
                            }
                            Button("刷新") { listening.refreshApplications() }
                                .disabled(listening.isRefreshing)
                        }
                    }
                    Toggle("保存音频", isOn: $listening.savesAudio)
                } header: {
                    SettingsSectionHeader("录音", info: String(localized: "应用按次选择；录音期间不能更改音源、语言或保存选项。"))
                }
                .disabled(listening.isActive)

                Section {
                    KeyboardShortcuts.Recorder("开始／停止录音", name: .toggleListening)
                    KeyboardShortcuts.Recorder("转写放入输入框", name: .stageListening)
                    KeyboardShortcuts.Recorder("停止并交给 AI 分析", name: .stopAndAnalyzeListening)
                    KeyboardShortcuts.Recorder("现在分析一下（不停止录音）", name: .analyzeListening)
                    KeyboardShortcuts.Recorder("按住说话提问", name: .pushToTalk)
                } header: {
                    SettingsSectionHeader("快捷键", info: String(localized: "转写取上一次交出去之后说的全部内容，最多 12,000 字。「放入输入框」不会自动发送；两个「分析」会连同当前上下文一起发送给所选模型。")
                        + "\n\n" + String(localized: "「按住说话提问」：按住快捷键说出问题，松开后连同当前屏幕上下文，用当前回答模式直接发送。只用麦克风，不写进录音记录；录音进行中不可用。按一下就松开不会发送。"))
                }

                Section {
                    Picker("识别引擎", selection: $listening.engine) {
                        Text("Apple 设备端语音识别").tag(ListeningEngine.appleSpeech)
                        ForEach(catalog.models) { model in
                            Text(catalog.title(for: model)).tag(ListeningEngine.local(model.id))
                        }
                        // Keep a vanished choice visible instead of silently showing another engine.
                        if let id = selectedLocalID, catalog.model(id: id) == nil {
                            Text(catalog.hasScanned ? String(localized: "找不到：\(URL(fileURLWithPath: id).lastPathComponent)")
                                                    : URL(fileURLWithPath: id).lastPathComponent)
                                .tag(listening.engine)
                        }
                    }
                    .disabled(listening.isActive)
                    if listening.engine == .appleSpeech {
                        Picker("转写语言", selection: $listening.locale) {
                            Text("English").tag("en-US")
                            Text("简体中文").tag("zh-CN")
                            Text("繁體中文").tag("zh-TW")
                            Text("日本語").tag("ja-JP")
                        }
                        .disabled(listening.isActive)
                        HStack {
                            Text("本机语言支持")
                            Spacer()
                            Text(deviceSupport).foregroundStyle(.secondary)
                            Button("检查") { refresh() }
                        }
                    } else if let family = selectedLocalModel?.family {
                        if family.languages.count > 1 {
                            Picker("转写语言", selection: Binding(
                                get: { family.language(for: listening.localLanguage) },
                                set: { listening.localLanguage = $0 })) {
                                ForEach(family.languages, id: \.self) { Text(Self.languageName($0)).tag($0) }
                            }
                            .disabled(listening.isActive)
                        } else {
                            LabeledContent("转写语言") { Text("模型自动识别") }
                        }
                        Picker("中文字形", selection: $listening.chineseScript) {
                            ForEach(ChineseScript.allCases) { Text($0.title).tag($0) }
                        }
                        .disabled(listening.isActive)
                        .help("有的本地模型会把普通话写成繁体字，这里统一换成你习惯的写法。")
                    }
                    HStack {
                        Text("本地模型")
                        Spacer()
                        Text(localModelStatus).foregroundStyle(.secondary)
                        Button(catalog.isScanning ? "扫描中…" : catalog.hasScanned ? "重新扫描" : "扫描") { catalog.rescan() }
                            .disabled(catalog.isScanning)
                        if catalog.rootExists {
                            Button("打开文件夹") { NSWorkspace.shared.open(LocalSpeechCatalog.root) }
                        }
                    }
                    .help(selectedLocalModel?.folder.path ?? LocalSpeechCatalog.root.path)
                } header: {
                    SettingsSectionHeader("转写", info: String(localized: "所有引擎都在本机转写。本地模型从 ~/Documents/huggingface/models 自动发现：放入新的 sherpa-onnx 模型文件夹后点「重新扫描」即可选用，不需要重装 Wisp。第一次扫描时 macOS 可能询问是否允许访问「文稿」文件夹。Wisp 不会下载、复制或删除模型。Apple Speech 使用系统语言资源。")
                        + "\n\n" + String(localized: "可识别的模型架构：\(LocalSpeechCatalog.families.map(\.title).formatted(.list(type: .and)))"))
                }

                Section {
                    permissionRow("麦克风", status: microphoneStatus, granted: microphone == .authorized, request: {
                        requesting = true
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                            requesting = false
                            refresh()
                        }
                    }, open: Permissions.openMicrophoneSettings)
                    if listening.engine.requiresSpeechAuthorization {
                        permissionRow("语音识别", status: speechStatus, granted: speech == .authorized, request: {
                            requesting = true
                            SFSpeechRecognizer.requestAuthorization { _ in
                                Task { @MainActor in requesting = false; refresh() }
                            }
                        }, open: Permissions.openSpeechSettings)
                    }
                    permissionRow("屏幕与系统音频",
                                  status: screen ? String(localized: "已授权") : String(localized: "未授权"),
                                  granted: screen, request: {
                        Permissions.requestScreenRecording()
                        refresh()
                    }, open: Permissions.openScreenRecordingSettings)
                } header: {
                    SettingsSectionHeader("权限", info: String(localized: "仅在点击请求时弹出系统授权；打开此页不会开始录音。系统采集指示无法由 Wisp 的状态点替代。"))
                }

                Section {
                    HStack {
                        Text("输入与输出音量")
                        Spacer()
                        Button("系统声音…") { Permissions.openSoundSettings() }
                    }
                } header: {
                    SettingsSectionHeader("声音", info: String(localized: "使用系统默认麦克风。设备及输入、输出音量在 macOS 声音设置中调整；Wisp 不改变其他应用的音量。"))
                }
            }
        }
        .formStyle(.grouped)
        // Rescanning is cheap (folder listings plus a few header reads, off the main thread), and
        // coming back to this page is how a model copied in meanwhile shows up.
        .onAppear { refresh(); catalog.refresh(for: listening.engine) }
        .onChange(of: listening.locale) { refresh() }
        .onChange(of: listening.engine) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
            catalog.refresh(for: listening.engine)
        }
    }

    private var selectedLocalID: String? {
        if case .local(let id) = listening.engine { return id }
        return nil
    }

    private var selectedLocalModel: LocalSpeechModel? { selectedLocalID.flatMap(catalog.model(id:)) }

    /// The selected model's state first, then how many models there are to choose from.
    private var localModelStatus: String {
        guard catalog.hasScanned else { return catalog.isScanning ? "" : String(localized: "未扫描") }
        guard catalog.rootExists else { return String(localized: "文件夹不存在") }
        let count = catalog.models.count
        let found = count == 0 ? String(localized: "没有找到模型") : String(localized: "找到 \(count) 个")
        guard selectedLocalID != nil else { return found }
        return selectedLocalModel == nil ? String(localized: "所选模型不可用") : String(localized: "文件就绪") + " · " + found
    }

    /// Native names, matching the Apple Speech language list beside it.
    private static func languageName(_ code: String) -> String {
        code == "auto" ? String(localized: "自动检测")
            : Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    }

    /// 录音期间请求会打断采集，所以这一页的「请求」统一带上同一个禁用条件。
    private func permissionRow(_ title: LocalizedStringKey, status: String, granted: Bool,
                               request: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        PermissionRow(title: title, status: status, granted: granted,
                      requestDisabled: requesting || listening.isActive,
                      request: request, open: open)
    }

    private var microphoneStatus: String {
        switch microphone {
        case .authorized: return String(localized: "已授权")
        case .notDetermined: return String(localized: "未请求")
        case .denied: return String(localized: "未授权")
        case .restricted: return String(localized: "受限")
        @unknown default: return String(localized: "未知")
        }
    }

    private var speechStatus: String {
        switch speech {
        case .authorized: return String(localized: "已授权")
        case .notDetermined: return String(localized: "未请求")
        case .denied: return String(localized: "未授权")
        case .restricted: return String(localized: "受限")
        @unknown default: return String(localized: "未知")
        }
    }

    private func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        speech = SFSpeechRecognizer.authorizationStatus()
        screen = Permissions.hasScreenRecording
        if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: listening.locale)), recognizer.supportsOnDeviceRecognition {
            deviceSupport = recognizer.isAvailable ? String(localized: "可用") : String(localized: "暂不可用")
        } else {
            deviceSupport = String(localized: "不支持")
        }
    }
}
