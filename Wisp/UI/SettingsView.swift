import AppKit
import AVFoundation
import Speech
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelSettingsView().tabItem { Label("模型", systemImage: "cpu") }
            PanelSettingsView().tabItem { Label("面板", systemImage: "macwindow") }
            CaptureSettingsView().tabItem { Label("采集", systemImage: "camera.viewfinder") }
            AudioSettingsView().tabItem { Label("音频", systemImage: "waveform") }
            PrivacySettingsView().tabItem { Label("隐私", systemImage: "hand.raised") }
            DataSettingsView().tabItem { Label("数据", systemImage: "internaldrive") }
            GeneralSettingsView().tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: - 设置页的小零件

private struct SettingsSectionHeader: View {
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
private struct InfoButton: View {
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
        .buttonStyle(.plain)
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
        }
    }
}

/// 权限行：状态在前，操作在后。已经授权就不再给「请求」——系统不会再弹第二次窗，
/// 留着那颗按钮等于把同一件事问两遍，还让人以为授权没生效。
private struct PermissionRow: View {
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
    @State private var agyModels: [ModelCatalog.Preset] = []
    @State private var agyScanning = false
    @FocusState private var keyFieldFocused: Bool

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
        .onChange(of: settings.cloudProvider) { previous, provider in
            // Key 是一家一份的。换家就得把输入框换成新那家的那份，
            // 否则「保存并测试」会把上一家的 Key 写到新那家名下。
            // 换走之前先把输入框里那份落到旧那家名下，不然它跟着输入框一起没了；
            // 药丸菜单也能换家，所以这一步放在这里，而不是设置页的选择器里。
            persistKey(apiKey, for: previous)
            apiKey = KeychainStore.load(for: provider) ?? ""
            testResult = nil
        }
        .onChange(of: keyFieldFocused) { _, focused in
            // 失焦就是这一次输入结束。只在这里落盘，手打 Key 的中间态就进不了钥匙串。
            if !focused { persistKey(apiKey, for: settings.cloudProvider) }
        }
        .onDisappear { persistKey(apiKey, for: settings.cloudProvider) }
        .onAppear {
            if !keyLoaded {
                apiKey = KeychainStore.load(for: settings.cloudProvider) ?? ""
                keyLoaded = true
            }
            if kind == .ollama { probeOllama() }
            if kind == .codexCLI {
                ensureCLIPath()
                if settings.cliProvider == .agy { scanAgyModels() }
            }
        }
        .onChange(of: settings.cliProvider) { _, provider in
            guard kind == .codexCLI else { return }
            ensureCLIPath()
            testResult = nil
            if provider == .agy { scanAgyModels() }
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
                    if option == .codexCLI { ensureCLIPath() }
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

    private var cloudProvider: CloudProvider { settings.cloudProvider }

    private var cloudFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "服务商") {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { cloudProvider },
                        set: { switchCloudProvider(to: $0) }
                    )) {
                        ForEach(CloudProvider.builtIn) { provider in
                            Text(provider.title).tag(provider)
                        }
                        Divider()
                        Text(CloudProvider.custom.title).tag(CloudProvider.custom)
                    }
                    .labelsHidden()
                    if let note = cloudProvider.note {
                        InfoButton(message: note)
                    }
                }
            }

            // 选了某一家就把 Base URL 定死，省得改坏；只有「自定义」才让手填。
            Field(label: "Base URL") {
                if cloudProvider == .custom {
                    TextField("https://api.openai.com/v1", text: Binding(
                        get: { settings.baseURL },
                        set: { settings.baseURL = $0; testResult = nil }
                    ))
                } else {
                    HStack(spacing: 6) {
                        Text(settings.baseURL)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }

            ModelPickerRow(
                label: "模型",
                presets: ModelCatalog.cloudPresets(provider: cloudProvider, baseURL: settings.baseURL),
                placeholder: cloudProvider.defaultModel.isEmpty ? "gpt-5.6-luna" : cloudProvider.defaultModel,
                emptyOptionTitle: nil,
                value: Binding(get: { settings.model },
                               set: { settings.model = $0; testResult = nil })
            )

            Field(label: "API Key") {
                HStack(spacing: 6) {
                    SecureField(cloudProvider.keyPlaceholder, text: $apiKey)
                        .focused($keyFieldFocused)
                        .onChange(of: apiKey) { testResult = nil }
                        .onSubmit { persistKey(apiKey, for: settings.cloudProvider) }
                    if let console = cloudProvider.keyConsoleURL {
                        Link("获取", destination: console)
                            .font(.system(size: 11))
                    }
                    InfoButton(message: String(localized: "请求发送到 \(endpointText)。API Key 按服务商分开保存在 macOS 钥匙串。"))
                }
            }
        }
    }

    /// 换一家：Base URL 和模型交给 AppSettings 处理。输入框里那份 Key 的存和换
    /// 都由上面 `cloudProvider` 的 onChange 统一做，这样从药丸菜单换家时也一样。
    private func switchCloudProvider(to provider: CloudProvider) {
        settings.selectCloudProvider(provider)
    }

    /// 填完就存，但只在输入框收工时存：失焦、回车、切换服务商、关掉窗口。
    ///
    /// 以前只有点「保存并测试」才写钥匙串，填完 Key 直接切到另一家或者关掉窗口，
    /// 刚填的就没了；改成每敲一个字符写一次，手打 Key 又会把 `s`、`sk`、`sk-`
    /// 依次盖进钥匙串，中途切走就留下一份残缺的，而菜单还显示这家「已配置」。
    ///
    /// 空值不覆盖已存的那份——清空要走「清除 Key」，否则光标划过输入框就可能把 Key 抹掉。
    private func persistKey(_ value: String, for provider: CloudProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != KeychainStore.load(for: provider) else { return }
        _ = KeychainStore.save(trimmed, for: provider)
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
                    InfoButton(message: String(localized: "本机运行、无需联网；请选择支持图片输入的模型。"))
                }
            }

            statusLine
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
            Field(label: "本地 Cli") {
                Picker("", selection: Binding(
                    get: { settings.cliProvider },
                    set: { provider in
                        settings.cliProvider = provider
                        ensureCLIPath()
                        if provider == .agy { scanAgyModels() }
                        testResult = nil
                    }
                )) {
                    ForEach(CLIProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .labelsHidden()
            }

            switch settings.cliProvider {
            case .codex:      codexCLIFields
            case .agy:        agyFields
            case .claudeCode: claudeCodeFields
            }
        }
    }

    private var codexCLIFields: some View {
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
                    InfoButton(message: String(localized: "使用 Codex 登录，回答实时显示。"))
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

        }
    }

    private var agyFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "可执行文件") {
                HStack(spacing: 6) {
                    TextField(AgyCLIProvider.detectedPath ?? "/usr/local/bin/agy",
                              text: Binding(get: { settings.agyPath },
                                            set: { settings.agyPath = $0; testResult = nil }))
                    Button("自动查找") {
                        if let detected = AgyCLIProvider.detectedPath {
                            settings.agyPath = detected
                            testResult = nil
                        }
                    }
                    InfoButton(message: String(localized: "使用 Agy 登录。截图临时保存，用后删除。"))
                }
            }

            ModelPickerRow(
                label: "模型",
                presets: agyModels.isEmpty ? AgyCLIProvider.fallbackModels : agyModels,
                placeholder: "gemini-3.8-flash-high",
                emptyOptionTitle: String(localized: "跟随 Agy 默认"),
                value: Binding(get: { settings.agyModel },
                               set: { settings.agyModel = $0; testResult = nil })
            )
            HStack(spacing: 8) {
                Spacer()
                Button(agyScanning ? "扫描中…" : "刷新模型") { scanAgyModels() }
                    .disabled(agyScanning)
                InfoButton(message: String(localized: "从 Agy 获取最新可用模型。"))
            }

            if AgyCLIProvider.resolvePath(settings.agyPath) == nil {
                Label("找不到 agy，请填完整路径。", systemImage: "xmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private var claudeCodeFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "可执行文件") {
                HStack(spacing: 6) {
                    TextField(ClaudeCodeCLIProvider.detectedPath ?? "/opt/homebrew/bin/claude",
                              text: Binding(get: { settings.claudeCodePath },
                                            set: { settings.claudeCodePath = $0; testResult = nil }))
                    Button("自动查找") {
                        if let detected = ClaudeCodeCLIProvider.detectedPath {
                            settings.claudeCodePath = detected
                            testResult = nil
                        }
                    }
                    InfoButton(message: String(localized: "使用 Claude Code 登录。截图临时保存，用后删除。"))
                }
            }

            ModelPickerRow(
                label: "模型",
                presets: ClaudeCodeCLIProvider.presets,
                placeholder: "sonnet",
                emptyOptionTitle: String(localized: "跟随 Claude Code 默认"),
                value: Binding(get: { settings.claudeCodeModel },
                               set: { settings.claudeCodeModel = $0; testResult = nil })
            )

            if ClaudeCodeCLIProvider.resolvePath(settings.claudeCodePath) == nil {
                Label("找不到 claude，请填完整路径。", systemImage: "xmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    // MARK: 测试

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(testing ? "测试中…" : "保存并测试") { runTest() }
                    .disabled(testing || (kind.needsAPIKey && apiKey.isEmpty))
                if kind.needsAPIKey, KeychainStore.hasKey(for: settings.cloudProvider) {
                    Button("清除 Key") {
                        KeychainStore.delete(for: settings.cloudProvider)
                        apiKey = ""
                        testResult = nil
                    }
                }
                Spacer(minLength: 0)
                InfoButton(message: String(localized: kind == .codexCLI
                                            ? "仅检查本地工具能否启动，不消耗模型额度。"
                                            : "发送一张 64×64 测试图，验证连接和图片输入。"))
            }
            if let result = testResult {
                Label(result.message, systemImage: result.ok ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(result.ok ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
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
            _ = KeychainStore.save(trimmed, for: settings.cloudProvider)
            config = ProviderConfig(kind: .openAICompatible, baseURL: settings.baseURL,
                                    apiKey: trimmed, model: settings.model)
        case .ollama:
            config = ProviderConfig(kind: .ollama, baseURL: settings.ollamaBaseURL,
                                    apiKey: "ollama", model: settings.ollamaModel)
        case .codexCLI:
            switch settings.cliProvider {
            case .codex:
                config = ProviderConfig(kind: .codexCLI, model: settings.codexModel,
                                        cliProvider: .codex, cliPath: settings.codexPath)
            case .agy:
                config = ProviderConfig(kind: .codexCLI, model: settings.agyModel,
                                        cliProvider: .agy, cliPath: settings.agyPath)
            case .claudeCode:
                config = ProviderConfig(kind: .codexCLI, model: settings.claudeCodeModel,
                                        cliProvider: .claudeCode, cliPath: settings.claudeCodePath)
            }
        }
        Task {
            do {
                try await ProviderConfig.provider(for: config).validate(config: config)
                testResult = (true, kind == .codexCLI
                              ? String(localized: "\(settings.cliProvider.title) 可以运行，配置已保存。")
                              : String(localized: "连接正常，这个模型接受图片输入。配置已保存。"))
            } catch let error as ProviderError {
                testResult = (false, error.errorDescription ?? String(localized: "失败"))
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }

    private func ensureCLIPath() {
        switch settings.cliProvider {
        case .codex:
            if settings.codexPath.isEmpty, let detected = CodexCLIProvider.detectedPath {
                settings.codexPath = detected
            }
        case .agy:
            // Keep this empty by default so each request can re-scan candidates
            // and pick the newest installed AGY version. A typed path is explicit.
            break
        case .claudeCode:
            if settings.claudeCodePath.isEmpty, let detected = ClaudeCodeCLIProvider.detectedPath {
                settings.claudeCodePath = detected
            }
        }
    }

    private func scanAgyModels() {
        guard !agyScanning else { return }
        agyScanning = true
        Task {
            let models = await AgyCLIProvider.scanModels(configuredPath: settings.agyPath)
            if !models.isEmpty { agyModels = models }
            agyScanning = false
        }
    }
}

// MARK: - 模型页小零件

private struct ProviderCard: View {
    let option: ProviderKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
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
                RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10)
                                   : Color.primary.opacity(hovering ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : DS.hairline,
                                  lineWidth: selected ? 1.2 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                HStack {
                    Spacer()
                    InfoButton(message: note)
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
            // 换了服务商，推荐列表整个换掉。当前值在新列表里就退回下拉，
            // 不在就转成自定义——只往「自定义」单向切的话，换家之后输入框会一直挂着上一家的模型名。
            let isCustom = ModelCatalog.isCustom(value, in: presets)
            custom = isCustom
            if isCustom { customText = value }
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

private struct CaptureModeOption: View {
    let mode: CaptureMode
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(mode.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            // Keep the hit target as large as the visual card, including its empty space.
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .overlay(alignment: .topTrailing) {
            InfoButton(message: mode.detail)
                .padding(.top, 7)
                .padding(.trailing, 7)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

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
private struct PanelSettingsView: View {
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

// MARK: - 采集

/// 读一次上下文要用到的东西：先是系统和浏览器的许可，然后是读到什么程度、
/// 哪些应用一概不读。权限排在最前面——没有它，底下几项调了也不生效。
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

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "屏幕录制",
                              status: hasScreenRecording ? String(localized: "已授权") : String(localized: "未授权"),
                              granted: hasScreenRecording,
                              request: { Permissions.requestScreenRecording(); refresh() },
                              open: Permissions.openScreenRecordingSettings)
                HStack {
                    Text("浏览器自动化")
                    Spacer()
                    Button("系统设置…") { Permissions.openAutomationSettings() }
                }
            } header: {
                SettingsSectionHeader("权限", info: String(localized: "整页文字需要浏览器的 Apple Events 权限；在浏览器的 Developer 菜单中开启。"))
            }

            Section {
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
            } header: {
                SettingsSectionHeader("浏览器整页文字", info: String(localized: "每个 Chromium 配置文件都要单独开启；未开启时仍可读网址和截图。"))
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(CaptureMode.allCases) { mode in
                        CaptureModeOption(mode: mode, selected: settings.captureMode == mode) {
                            settings.captureMode = mode
                        }
                    }
                }

                if settings.captureMode == .scrollCollect && !ScrollDriver.isTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("需要辅助功能权限才能滑动采集。")
                            .font(.system(size: 10))
                        Button("去授权") { Permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            } header: {
                SettingsSectionHeader("采集模式")
            }

            Section {
                HStack {
                    Text("字符数")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    TextField("", value: Binding(
                        get: { settings.pageTextLimit },
                        set: { settings.pageTextLimit = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    Spacer()
                    InfoButton(message: String(localized: "超出上限时保留开头和结尾，并标记省略。"))
                }
                .accessibilityElement(children: .contain)
            } header: {
                SettingsSectionHeader("页面文字上限")
            }

            Section {
                if settings.excludedBundleIDs.isEmpty {
                    Text("没有排除的应用").font(.system(size: 11)).foregroundStyle(.secondary)
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
                Button("排除当前应用") { model.excludeCurrentApp() }
                    .disabled(model.packet?.bundleID == nil)
            } header: {
                SettingsSectionHeader("排除的应用", info: String(localized: "排除后不截图，也不读取浏览器页面。"))
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

// MARK: - 隐私

/// 别人的屏幕上看不看得见 Wisp。两个开关都只影响它自己的窗口，不碰系统设置。
private struct PrivacySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var confirmHidingMenuBarIcon = false

    /// 关掉菜单栏图标之后，用户还剩什么办法把 Wisp 叫出来。
    private var fallbackEntry: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleAssistant) {
            return String(localized: "快捷键 \(shortcut.description)，或者在访达里再打开一次 Wisp")
        }
        return String(localized: "在访达里再打开一次 Wisp")
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.hideFromScreenCapture },
                    set: { ScreenPrivacy.setEnabled($0) }
                )) {
                    HStack(spacing: 5) {
                        Text("在共享和录屏中隐藏 Wisp")
                        InfoButton(message: String(localized: "在兼容的共享和录屏中隐藏 Wisp，本机仍可正常使用。效果因系统和录屏工具而异，请检查接收端画面。录制 Wisp 演示时请关闭。"))
                    }
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

// MARK: - 音频

struct AudioSettingsView: View {
    @ObservedObject private var listening = ListeningModel.shared
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
                } header: {
                    SettingsSectionHeader("快捷键", info: String(localized: "转写取上一次交出去之后说的全部内容，最多 12,000 字。「放入输入框」不会自动发送；两个「分析」会连同当前上下文一起发送给所选模型。"))
                }

                Section {
                    Picker("识别引擎", selection: $listening.recognitionEngine) {
                        ForEach(ListeningRecognitionEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(listening.isActive)
                    if listening.recognitionEngine == .senseVoice {
                        Picker("转写语言", selection: $listening.senseVoiceLanguage) {
                            Text("自动检测").tag("auto")
                            Text("中文").tag("zh")
                            Text("English").tag("en")
                            Text("日本語").tag("ja")
                            Text("한국어").tag("ko")
                            Text("粤语").tag("yue")
                        }
                        .disabled(listening.isActive)
                        HStack {
                            Text("共享本地模型")
                            Spacer()
                            Text(deviceSupport).foregroundStyle(.secondary)
                            Button("检查") { refresh() }
                            Button("打开文件夹") { NSWorkspace.shared.open(SenseVoiceRecognition.modelFolder.deletingLastPathComponent()) }
                        }
                        .help(SenseVoiceRecognition.modelFolder.path)
                    } else {
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
                    }
                } header: {
                    SettingsSectionHeader("转写", info: String(localized: "两种引擎均在本机转写。SenseVoice 复用 Documents/huggingface 中的模型，支持自动检测语言；不会下载、复制或删除模型。Apple Speech 使用系统语言资源。"))
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
                    if listening.recognitionEngine.requiresSpeechAuthorization {
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
        .onAppear { refresh() }
        .onChange(of: listening.locale) { refresh() }
        .onChange(of: listening.recognitionEngine) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
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
        if listening.recognitionEngine == .senseVoice {
            do {
                try SenseVoiceRecognition.validateModel()
                deviceSupport = String(localized: "文件就绪")
            } catch {
                deviceSupport = String(localized: "模型缺失")
            }
        } else if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: listening.locale)), recognizer.supportsOnDeviceRecognition {
            deviceSupport = recognizer.isAvailable ? String(localized: "可用") : String(localized: "暂不可用")
        } else {
            deviceSupport = String(localized: "不支持")
        }
    }
}

// MARK: - 数据

struct DataSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AssistantModel
    @State private var confirmWipe = false
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
                Button("删除全部记录与 API Key", role: .destructive) { confirmWipe = true }
            } header: {
                SettingsSectionHeader("清除", info: String(localized: "删除对话、录音与转写记录、调试文件和钥匙串中的 API Key；不可撤销。"))
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
            Button("全部删除", role: .destructive) {
                ListeningModel.shared.discardForDataReset()
                model.store.deleteAll()
                KeychainStore.deleteAll()
                settings.wipeLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有对话、录音与转写记录和 API Key 都会被删除，无法撤销。")
        }
    }
}

/// 原生 Stepper 的竖向双箭头在紧凑设置行里太拥挤；改成轻量横向减／加控件。
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

            if store.isReadOnly {
                Section("对话记录被锁为只读") {
                    Text(store.loadIssue?.message ?? "")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("备份并重置", role: .destructive) {
                        archivedName = store.archiveBlockingFileAndReset()
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
