import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelSettingsView().tabItem { Label("模型", systemImage: "cpu") }
            CaptureSettingsView().tabItem { Label("权限", systemImage: "lock.shield") }
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
    /// 以前只有点「保存并测试连接」才写钥匙串，填完 Key 直接切到另一家或者关掉窗口，
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
            Field(label: "本地 CLI") {
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
                    InfoButton(message: String(localized: "使用已登录的 Codex，无需 API Key；回答一次性返回。"))
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
                    InfoButton(message: String(localized: "使用已登录的 AGY，不需要单独填写 API Key；有截图时会先写进临时目录，再交给 AGY 读取，用完即删。"))
                }
            }

            ModelPickerRow(
                label: "模型",
                presets: agyModels.isEmpty ? AgyCLIProvider.fallbackModels : agyModels,
                placeholder: "gemini-3.8-flash-high",
                emptyOptionTitle: String(localized: "跟随 AGY 默认"),
                value: Binding(get: { settings.agyModel },
                               set: { settings.agyModel = $0; testResult = nil })
            )
            HStack(spacing: 8) {
                Spacer()
                Button(agyScanning ? "扫描中…" : "扫描最新 AGY 模型") { scanAgyModels() }
                    .disabled(agyScanning)
                InfoButton(message: String(localized: "每次扫描都会直接执行 agy models，不缓存版本或模型列表；AGY 更新后重新扫描即可。"))
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
                    InfoButton(message: String(localized: "使用已登录的 Claude Code，不需要单独填写 API Key；有截图时会先写进临时目录，再交给它读取，用完即删。三个本地 CLI 里只有它是逐字显示答案的。"))
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
                Button(testing ? "测试中…" : "保存并测试连接") { runTest() }
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
                                            ? "本地 CLI 测试只检查当前选中的命令能否启动，不会为了测试额外消耗模型额度。"
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10)
                                   : Color.primary.opacity(hovering ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
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

// MARK: - 权限

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
            Section {
                KeyboardShortcuts.Recorder("唤起助手：", name: .toggleAssistant)
            } header: {
                SettingsSectionHeader("快捷键")
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
                        Button("回到默认位置") { IslandController.shared.resetPosition() }
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

            Section {
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

// MARK: - 数据

private struct DataSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var model: AssistantModel
    @State private var confirmWipe = false

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
                SettingsSectionHeader("存储位置", info: String(localized: "只保存对话和页面文字快照；截图不会写入磁盘。"))
            }

            Section {
                Toggle("把每次采集的上下文写到 debug 文件夹", isOn: Binding(
                    get: { settings.debugDumpEnabled },
                    set: { settings.debugDumpEnabled = $0 }
                ))
            } header: {
                SettingsSectionHeader("调试", info: String(localized: "额外写入 last-context.json 和 last-screenshot.jpg，仅用于排查。"))
            }

            Section {
                Button("删除全部对话与 API Key", role: .destructive) { confirmWipe = true }
            } header: {
                SettingsSectionHeader("清除", info: String(localized: "删除对话、调试文件和钥匙串中的 API Key；不可撤销。"))
            }
        }
        .formStyle(.grouped)
        .alert("删除全部数据？", isPresented: $confirmWipe) {
            Button("全部删除", role: .destructive) {
                model.store.deleteAll()
                KeychainStore.deleteAll()
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
                        Button("立即重启 Wisp") { AppRelaunch.now() }
                        Spacer()
                    }
                }
            } header: {
                SettingsSectionHeader("语言", info: String(localized: "留空跟随系统；只影响 Wisp，不改系统语言。"))
            }

            Section {
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
            } header: {
                SettingsSectionHeader("启动")
            }

            Section {
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
            } header: {
                SettingsSectionHeader("更新", info: String(localized: "仅请求 GitHub 的版本号，不发送使用信息，也不会自动下载。"))
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
