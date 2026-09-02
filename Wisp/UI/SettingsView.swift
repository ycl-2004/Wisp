import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelSettingsView().tabItem { Label("模型", systemImage: "cpu") }
            CaptureSettingsView().tabItem { Label("屏幕与权限", systemImage: "lock.shield") }
            DataSettingsView().tabItem { Label("数据", systemImage: "internaldrive") }
            GeneralSettingsView().tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 580, height: 470)
    }
}

// MARK: - 模型

struct ModelSettingsView: View {
    /// 离线渲染时用平铺布局。ImageRenderer 画不出 ScrollView 里的内容。
    var flat = false

    @ObservedObject private var settings = AppSettings.shared

    @State private var apiKey = ""
    @State private var keyLoaded = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var ollamaStatus: OllamaSupport.Status?
    @State private var probing = false

    private var kind: ProviderKind {
        ProviderKind(rawValue: settings.providerKind) ?? .openAICompatible
    }

    var body: some View {
        Group {
            if flat {
                inner
            } else {
                ScrollView { inner }
            }
        }
        .onAppear {
            if !keyLoaded { apiKey = KeychainStore.load() ?? ""; keyLoaded = true }
            if kind == .ollama { probeOllama() }
            if kind == .codexCLI, settings.codexPath.isEmpty,
               let detected = CodexCLIProvider.detectedPath {
                settings.codexPath = detected
            }
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 18) {
            picker
            Divider()
            fields
            Divider()
            testRow
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    // MARK: 三选一

    private var picker: some View {
        HStack(spacing: 8) {
            ForEach(ProviderKind.allCases) { option in
                ProviderCard(option: option, selected: option == kind) {
                    settings.providerKind = option.rawValue
                    testResult = nil
                    if option == .ollama { probeOllama() }
                    if option == .codexCLI, settings.codexPath.isEmpty,
                       let detected = CodexCLIProvider.detectedPath {
                        settings.codexPath = detected
                    }
                }
            }
        }
    }

    // MARK: 各自的字段

    @ViewBuilder
    private var fields: some View {
        switch kind {
        case .openAICompatible: cloudFields
        case .ollama:           ollamaFields
        case .codexCLI:         codexFields
        }
    }

    private var cloudFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "Base URL") {
                TextField("https://api.openai.com/v1", text: Binding(
                    get: { settings.baseURL },
                    set: { settings.baseURL = $0; testResult = nil }
                ))
            }
            ModelPickerRow(
                label: "模型",
                presets: ModelCatalog.cloudPresets(baseURL: settings.baseURL),
                placeholder: "gpt-4o-mini",
                emptyOptionTitle: nil,
                value: Binding(get: { settings.model },
                               set: { settings.model = $0; testResult = nil })
            )
            Field(label: "API Key") {
                SecureField("sk-…", text: $apiKey)
                    .onChange(of: apiKey) { testResult = nil }
            }
            Note("请求发到 \(endpointText)。Key 存在 macOS 钥匙串，不会写进对话文件。")
        }
    }

    private var ollamaFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "Base URL") {
                TextField(OllamaSupport.defaultBaseURL, text: Binding(
                    get: { settings.ollamaBaseURL },
                    set: { settings.ollamaBaseURL = $0; testResult = nil }
                ))
            }

            Field(label: "模型") {
                HStack(spacing: 6) {
                    if case .running(let models) = ollamaStatus, !models.isEmpty {
                        Picker("", selection: Binding(
                            get: { settings.ollamaModel },
                            set: { settings.ollamaModel = $0; testResult = nil }
                        )) {
                            Text("未选择").tag("")
                            ForEach(models, id: \.self) { name in
                                Text(OllamaSupport.looksLikeVisionModel(name) ? String(localized: "\(name)  · 可读图") : name)
                                    .tag(name)
                            }
                        }
                        .labelsHidden()
                    } else {
                        TextField("minicpm-v4.6:1b", text: Binding(
                            get: { settings.ollamaModel },
                            set: { settings.ollamaModel = $0; testResult = nil }
                        ))
                    }
                    Button(probing ? "检测中…" : "刷新") { probeOllama() }
                        .disabled(probing)
                }
            }

            statusLine
            Note("模型跑在本机，不联网也不花钱，但必须选一个能读图的模型，否则截图会被忽略。这里的清单直接读自本机 Ollama。")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch ollamaStatus {
        case .running(let models):
            let vision = models.filter(OllamaSupport.looksLikeVisionModel)
            Label(vision.isEmpty
                  ? "Ollama 在运行，装了 \(models.count) 个模型，但没找到能读图的。"
                  : "Ollama 在运行，可读图的模型：\(vision.joined(separator: String(localized: "、")))",
                  systemImage: vision.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(vision.isEmpty ? .orange : .green)
                .fixedSize(horizontal: false, vertical: true)
        case .notRunning:
            HStack(spacing: 8) {
                Label("Ollama 没在运行", systemImage: "xmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.red)
                Button("启动 Ollama") {
                    _ = OllamaSupport.startServer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { probeOllama() }
                }
                .disabled(OllamaSupport.executablePath == nil)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    private var codexFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "可执行文件") {
                HStack(spacing: 6) {
                    TextField(CodexCLIProvider.detectedPath ?? "/usr/local/bin/codex",
                              text: Binding(get: { settings.codexPath },
                                            set: { settings.codexPath = $0; testResult = nil }))
                    Button("自动查找") {
                        if let detected = CodexCLIProvider.detectedPath {
                            settings.codexPath = detected
                            testResult = nil
                        }
                    }
                }
            }
            ModelPickerRow(
                label: "模型",
                presets: ModelCatalog.codexPresets(),
                placeholder: "gpt-5.6-sol",
                emptyOptionTitle: ModelCatalog.codexConfiguredModel
                    .map { String(localized: "跟随 Codex 默认（\($0)）") }
                    ?? String(localized: "跟随 Codex 默认"),
                value: Binding(get: { settings.codexModel },
                               set: { settings.codexModel = $0; testResult = nil })
            )

            if CodexCLIProvider.resolvePath(settings.codexPath) == nil {
                Label("找不到 codex，请填完整路径。", systemImage: "xmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }

            Note("复用你已经登录的 Codex，不用另配 API Key。以只读沙箱运行，不落会话文件。两点要知道：它每次都会带上约两万 token 的固定上下文，走的是你的 Codex 额度；而且没有逐字流式，回答会一次性出现。")
        }
    }

    // MARK: 测试

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(testing ? "测试中…" : "保存并测试连接") { runTest() }
                    .disabled(testing || (kind.needsAPIKey && apiKey.isEmpty))
                if kind.needsAPIKey, KeychainStore.hasKey {
                    Button("清除 Key") {
                        KeychainStore.delete(); apiKey = ""; testResult = nil
                    }
                }
            }
            if let result = testResult {
                Label(result.message, systemImage: result.ok ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(result.ok ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Note(kind == .codexCLI
                 ? "测试只检查能不能跑起 codex，不会真的发一次提问。"
                 : "测试会发一张 64×64 的小图，用来同时验证连通性、模型名和这个模型是否接受图片输入。")
        }
    }

    private var endpointText: String {
        OpenAICompatibleProvider.endpoint(kind == .ollama ? settings.ollamaBaseURL : settings.baseURL)?
            .absoluteString ?? String(localized: "（地址无效）")
    }

    private func probeOllama() {
        probing = true
        let base = settings.ollamaBaseURL
        Task {
            ollamaStatus = await OllamaSupport.probe(baseURL: base)
            if case .running(let models) = ollamaStatus,
               settings.ollamaModel.isEmpty,
               let first = models.first(where: OllamaSupport.looksLikeVisionModel) {
                settings.ollamaModel = first
            }
            probing = false
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        var config: ProviderConfig
        switch kind {
        case .openAICompatible:
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = KeychainStore.save(trimmed)
            config = ProviderConfig(kind: .openAICompatible, baseURL: settings.baseURL,
                                    apiKey: trimmed, model: settings.model)
        case .ollama:
            config = ProviderConfig(kind: .ollama, baseURL: settings.ollamaBaseURL,
                                    apiKey: "ollama", model: settings.ollamaModel)
        case .codexCLI:
            config = ProviderConfig(kind: .codexCLI, model: settings.codexModel,
                                    codexPath: settings.codexPath)
        }
        Task {
            do {
                try await ProviderConfig.provider(for: kind).validate(config: config)
                testResult = (true, kind == .codexCLI
                              ? String(localized: "codex 可以运行，配置已保存。")
                              : String(localized: "连接正常，这个模型接受图片输入。配置已保存。"))
            } catch let error as ProviderError {
                testResult = (false, error.errorDescription ?? String(localized: "失败"))
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}

// MARK: 设置页的小零件

private struct ProviderCard: View {
    let option: ProviderKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: option.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text(option.title)
                .font(.system(size: 12, weight: .medium))
            Text(option.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10)
                               : Color.primary.opacity(hovering ? 0.06 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                              lineWidth: selected ? 1.2 : 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// 模型选择行：预设走下拉，最后一项是「自定义」，选中才露出输入框。
private struct ModelPickerRow: View {
    let label: LocalizedStringKey
    let presets: [ModelCatalog.Preset]
    let placeholder: String
    /// 非 nil 时，下拉最上面多一项代表「空值」。
    let emptyOptionTitle: String?
    @Binding var value: String

    @State private var custom = false
    @State private var customText = ""
    @State private var loaded = false

    private var selection: String {
        if custom { return ModelCatalog.customTag }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Field(label: label) {
                Picker("", selection: Binding(
                    get: { selection },
                    set: { newValue in
                        if newValue == ModelCatalog.customTag {
                            custom = true
                            customText = value
                        } else {
                            custom = false
                            value = newValue
                        }
                    }
                )) {
                    if let emptyOptionTitle {
                        Text(emptyOptionTitle).tag("")
                    }
                    ForEach(presets) { preset in
                        Text(preset.title).tag(preset.slug)
                    }
                    if presets.isEmpty {
                        Text("没有内置推荐").tag("__none__")
                    }
                    Divider()
                    Text("自定义…").tag(ModelCatalog.customTag)
                }
                .labelsHidden()
            }

            if custom {
                Field(label: "") {
                    TextField(placeholder, text: $customText)
                        .onChange(of: customText) { _, newValue in
                            value = newValue.trimmingCharacters(in: .whitespaces)
                        }
                }
            } else if let note = presets.first(where: { $0.slug == value })?.note, !note.isEmpty {
                HStack(spacing: 0) {
                    Spacer().frame(width: 94)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if ModelCatalog.isCustom(value, in: presets) {
                custom = true
                customText = value
            }
        }
        .onChange(of: presets.map(\.slug)) {
            // 换了 Base URL，推荐列表会变；当前值若不在新列表里就转成自定义。
            if ModelCatalog.isCustom(value, in: presets) {
                custom = true
                customText = value
            }
        }
    }
}

private struct Field<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .multilineTextAlignment(.leading)
        }
    }
}

private struct Note: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 屏幕与权限

private struct CaptureSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AssistantModel
    @State private var hasScreenRecording = Permissions.hasScreenRecording

    struct ProfileEntry {
        var key: String
        var browserName: String
        var profile: ChromeProfileInspector.Profile
    }
    @State private var browserProfiles: [ProfileEntry] = []
    /// 关掉自动收起时把秒数存在这，再打开时不用重新调。
    @State private var idleSecondsDraft = 10

    var body: some View {
        Form {
            Section("快捷键") {
                KeyboardShortcuts.Recorder("唤起助手：", name: .toggleAssistant)
            }

            Section("常驻小药丸") {
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
                        Text("按住药丸拖动就能把它挪到桌面上任何地方，松手就记住，重新打开也在那儿。助手面板不受影响，始终从底部中间展开。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("回到默认位置") { IslandController.shared.resetPosition() }
                            .disabled(!settings.hasCustomIslandAnchor || !settings.showIsland)
                    }
                }

                Text("闲置时只有一颗图标大小，鼠标移上去才展开成一条，点一下打开助手。生成回答时会变宽并给出停止键。它只跟踪当前是哪个应用，不截图也不读页面。主面板打开时它会自动收起。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("自动收起") {
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
                Text("你去看别的窗口以后才开始倒计时。面板有焦点、鼠标停在上面、或者回答正在生成，都不会收起。收起只是把面板收回小药丸，对话不会丢。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("权限") {
                HStack {
                    Label(hasScreenRecording ? "屏幕录制：已授权" : "屏幕录制：未授权",
                          systemImage: hasScreenRecording ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(hasScreenRecording ? .green : .red)
                    Spacer()
                    Button("请求") { Permissions.requestScreenRecording(); refresh() }
                    Button("打开系统设置") { Permissions.openScreenRecordingSettings() }
                }
                HStack {
                    Text("自动化（控制浏览器）")
                    Spacer()
                    Button("打开系统设置") { Permissions.openAutomationSettings() }
                }
                Text("读取整页文字还需要在浏览器里打开一次：Chrome 是「View → Developer → Allow JavaScript from Apple Events」，Safari 是「Develop → Allow JavaScript from Apple Events」。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("浏览器整页文字") {
                if browserProfiles.isEmpty {
                    Text("没有检测到已安装的 Chromium 系浏览器配置文件。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(browserProfiles, id: \.key) { entry in
                        HStack {
                            Label(entry.profile.displayName,
                                  systemImage: entry.profile.allowsJavaScript ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.profile.allowsJavaScript ? .green : .orange)
                            Spacer()
                            Text(entry.browserName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("重新检测") { reloadProfiles() }
                Text("这个开关每个浏览器配置文件要各开一次：切到该配置文件的窗口，菜单栏「View → Developer → Allow JavaScript from Apple Events」。没开的配置文件只能读到网址和截图。Safari 在「Develop」菜单里，且不分配置文件。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("采集模式") {
                Picker("采集到什么程度", selection: Binding(
                    get: { settings.captureMode },
                    set: { settings.captureMode = $0 }
                )) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.captureMode.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.captureMode == .scrollCollect && !ScrollDriver.isTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("还没有「辅助功能」权限，滑动采集无法生效。")
                            .font(.system(size: 10))
                        Button("去授权") { Permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            }

            Section("页面文字上限") {
                HStack {
                    TextField("字符数", value: Binding(
                        get: { settings.pageTextLimit },
                        set: { settings.pageTextLimit = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    Text("字，超出会保留头尾并标注省略")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Section("排除的应用") {
                if settings.excludedBundleIDs.isEmpty {
                    Text("目前没有排除任何应用。").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(displayName(for: bundleID)).font(.system(size: 11))
                            Spacer()
                            Button("移除") {
                                settings.excludedBundleIDs.removeAll { $0 == bundleID }
                            }
                            .font(.system(size: 10))
                        }
                    }
                }
                Button("把当前正在读取的应用加进来") { model.excludeCurrentApp() }
                    .disabled(model.packet?.bundleID == nil)
                Text("被排除的应用不会截图，也不会跑浏览器脚本。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh(); reloadProfiles() }
    }

    private func refresh() {
        hasScreenRecording = Permissions.hasScreenRecording
    }

    private func reloadProfiles() {
        var entries: [ProfileEntry] = []
        for (bundleID, family) in BrowserTextExtractor.supported
        where family == .chromium && ChromeProfileInspector.supportsInspection(bundleID: bundleID) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
                .deletingPathExtension().lastPathComponent ?? bundleID
            for profile in ChromeProfileInspector.statusSummary(bundleID: bundleID) {
                entries.append(ProfileEntry(key: "\(bundleID)/\(profile.directoryName)",
                                            browserName: name,
                                            profile: profile))
            }
        }
        browserProfiles = entries.sorted { $0.key < $1.key }
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return "\(url.deletingPathExtension().lastPathComponent)  (\(bundleID))"
    }
}

// MARK: - 数据

private struct DataSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AssistantModel
    @State private var confirmWipe = false

    var body: some View {
        Form {
            Section("上限") {
                CompactStepper("最多保留 \(settings.maxConversations) 个对话",
                               value: Binding(get: { settings.maxConversations },
                                              set: { settings.maxConversations = $0 }),
                               in: 1...50)
                CompactStepper("每个对话最多 \(settings.maxUserTurns) 轮",
                               value: Binding(get: { settings.maxUserTurns },
                                              set: { settings.maxUserTurns = $0 }),
                               in: 5...200)
                Text("到上限不会自动删旧的。新建时会问你要不要顶掉最久没更新的那个，确认后才删。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("存储位置") {
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
                Text("只保存对话文字与页面文字快照。截图从不写入硬盘。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("调试") {
                Toggle("把每次采集的上下文写到 debug 文件夹", isOn: Binding(
                    get: { settings.debugDumpEnabled },
                    set: { settings.debugDumpEnabled = $0 }
                ))
                Text("打开后会额外写入 last-context.json 与 last-screenshot.jpg，方便排查读不到文字的问题。平时请关掉。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("清除") {
                Button("删除全部对话与 API Key", role: .destructive) { confirmWipe = true }
                Text("会删除对话文件、调试文件和钥匙串里的 Key。系统的 Time Machine 备份和模型供应商那边的请求日志不在本应用控制范围内。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .alert("删除全部数据？", isPresented: $confirmWipe) {
            Button("全部删除", role: .destructive) {
                model.store.deleteAll()
                KeychainStore.delete()
                settings.wipeLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有对话和 API Key 都会被删除，无法撤销。")
        }
    }
}

/// 原生 Stepper 的竖向双箭头在紧凑设置行里太拥挤；改成轻量横向减／加控件。
private struct CompactStepper: View {
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
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.primary.opacity(0.24))
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
        .help(label)
    }
}


// MARK: - 通用

private struct GeneralSettingsView: View {
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
            Section("语言") {
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
                        Button("立即重启 Wisp") { AppRelaunch.now() }
                        Spacer()
                    }
                }
                Text("不选的话就跟随系统语言。这个设置只影响 Wisp 自己，不动系统设置。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("启动") {
                Toggle("登录时自动启动 Wisp", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let note = LaunchAtLogin.statusNote {
                    HStack(spacing: 8) {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("打开登录项设置") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let launchError {
                    Text(launchError).font(.system(size: 10)).foregroundStyle(.red)
                }
            }

            Section("更新") {
                Toggle("启动时检查有没有新版本", isOn: Binding(
                    get: { settings.checkForUpdates },
                    set: { settings.checkForUpdates = $0 }
                ))
                HStack(spacing: 10) {
                    Button(checking ? "检查中…" : "现在检查") { runCheck() }
                        .disabled(checking)
                    updateLine
                    Spacer()
                }
                Text("只向 GitHub 请求一次最新版本号，不发送任何关于你或你使用情况的信息，也不会自动下载或安装。关掉之后就完全不联网检查。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.isReadOnly {
                Section("对话记录被锁为只读") {
                    Text(store.loadIssue?.message ?? "")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("备份那份文件并重新开始", role: .destructive) {
                        archivedName = store.archiveBlockingFileAndReset()
                    }
                    if let archivedName {
                        Text("已备份为 \(archivedName)，现在可以正常保存了。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("关于") {
                LabeledContent("版本", value: version)
                HStack(spacing: 10) {
                    Button("项目主页") { NSWorkspace.shared.open(UpdateChecker.releasesPage) }
                    Button("报告问题") { NSWorkspace.shared.open(UpdateChecker.issuesPage) }
                    Button("开源许可") { showsNotices = true }
                    Spacer()
                }
                Text("崩溃日志由 macOS 自己保存在「控制台 → 崩溃报告」里。Wisp 不内置任何崩溃上报或统计 SDK，所以报问题时请自己附上那份日志。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsNotices) { NoticesSheet() }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
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
