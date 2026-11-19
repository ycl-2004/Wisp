import SwiftUI

// MARK: - 模型

struct ModelSettingsView: View {
    /// 离线渲染时用平铺布局。ImageRenderer 画不出 ScrollView 里的内容。
    var flat = false

    /// 首次设置向导复用本视图时为 false：向导只管把模型连上，
    /// 回答模式的取舍留到设置里。默认 true，设置页行为不变。
    var showsResponseModes = true

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelState = ModelMenuState.shared

    @State private var apiKey = ""
    @State private var keyLoaded = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var ollamaStatus: OllamaSupport.Status?
    @State private var probing = false
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
            // 否则「测试连接」会把上一家的 Key 写到新那家名下。
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
                if settings.cliProvider == .agy { modelState.refreshAgyIfStale() }
            }
        }
        .onChange(of: settings.cliProvider) { _, provider in
            guard kind == .codexCLI else { return }
            ensureCLIPath()
            testResult = nil
            if provider == .agy { modelState.refreshAgyIfStale() }
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 18) {
            picker
            Divider()
            fields
            if showsResponseModes {
                Divider()
                ResponseModeSettings()
            }
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
                label: "默认模型",
                presets: ModelCatalog.cloudPresets(provider: cloudProvider, baseURL: settings.baseURL),
                placeholder: cloudProvider.defaultModel.isEmpty ? "gpt-5.6-luna" : cloudProvider.defaultModel,
                emptyOptionTitle: nil,
                value: Binding(get: { settings.model },
                               set: { settings.model = $0; testResult = nil })
            )

            Field(label: "API Key") {
                HStack(spacing: 6) {
                    SecureField(cloudProvider.keyPlaceholder, text: $apiKey)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .focused($keyFieldFocused)
                        .onChange(of: apiKey) { testResult = nil }
                        .onSubmit { persistKey(apiKey, for: settings.cloudProvider) }
                    if let console = cloudProvider.keyConsoleURL {
                        Link("获取", destination: console)
                            .font(.system(size: 11))
                            .fixedSize()
                    }
                    InfoButton(message: String(localized: "请求发送到 \(endpointText)。API Key 按服务商分开保存在 macOS 钥匙串。"))
                        .fixedSize()
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
        // 存不进去必须让用户知道（#43）：否则菜单照样显示「已配置」、
        // 测试还会拿输入框里的 Key 蒙混过关，重启之后 Key 凭空消失。
        if !KeychainStore.save(trimmed, for: provider) {
            testResult = (ok: false, message: String(localized: "API Key 没能存进钥匙串，这次输入没有保存下来。"))
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

            Field(label: "默认模型") {
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
                        // ensureCLIPath and the Agy scan follow from the onChange above.
                        settings.cliProvider = provider
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
                label: "默认模型",
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
                label: "默认模型",
                presets: modelState.agyPresets,
                placeholder: "gemini-3.8-flash-high",
                emptyOptionTitle: String(localized: "跟随 Agy 默认"),
                value: Binding(get: { settings.agyModel },
                               set: { settings.agyModel = $0; testResult = nil })
            )
            HStack(spacing: 8) {
                Spacer()
                Button(modelState.isScanningAgy ? "扫描中…" : "刷新模型") { modelState.refreshAgy() }
                    .disabled(modelState.isScanningAgy)
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
                label: "默认模型",
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
                Button(testing ? "测试中…" : "测试连接") { runTest() }
                    .disabled(testing || (kind.needsAPIKey && apiKey.isEmpty))
                if kind.needsAPIKey, KeychainStore.hasKey(for: settings.cloudProvider) {
                    Button("清除 Key") {
                        // 删不掉就明说，别清掉输入框假装删了（#43）。
                        if KeychainStore.delete(for: settings.cloudProvider) {
                            apiKey = ""
                            testResult = nil
                        } else {
                            testResult = (ok: false, message: String(localized: "API Key 没能从钥匙串里删除。"))
                        }
                    }
                }
                Spacer(minLength: 0)
                InfoButton(message: kind == .codexCLI
                           ? String(localized: "设置改动会自动保存。这里只检查本地工具能否启动，不消耗模型额度。")
                           : String(localized: "设置改动会自动保存。这里给快速、深入模式实际使用的模型各发送一张 64×64 测试图，验证连接和图片输入。"))
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
        // 输入框里可能是还没失焦落盘的新 Key，测它，也顺手存下。
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .openAICompatible, !trimmedKey.isEmpty,
           !KeychainStore.save(trimmedKey, for: settings.cloudProvider) {
            // 存不下就不要测了（#43）：拿没落盘的 Key 测出一个绿勾，
            // 用户会以为一切正常，重启之后 Key 却不在。
            testing = false
            testResult = (ok: false, message: String(localized: "API Key 没能存进钥匙串，这次输入没有保存下来。"))
            return
        }
        // 测的是两个模式真正会发出去的模型。本地 CLI 只检查能否启动、与模型无关，测一次就够。
        let models = ActiveModels(settings: settings, state: modelState)
        var configs: [ProviderConfig] = []
        for mode in ResponseMode.allCases {
            var config = models.config(for: mode)
            if kind == .openAICompatible { config.apiKey = trimmedKey }
            let alreadyCovered = kind == .codexCLI ? !configs.isEmpty : configs.contains { $0.model == config.model }
            if !alreadyCovered { configs.append(config) }
        }
        Task {
            var failures: [String] = []
            for config in configs {
                do {
                    try await ProviderConfig.provider(for: config).validate(config: config)
                } catch {
                    let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
                    failures.append(configs.count > 1 ? "\(config.model)：\(message)" : message)
                }
            }
            if !failures.isEmpty {
                testResult = (false, failures.joined(separator: "\n"))
            } else if kind == .codexCLI {
                testResult = (true, String(localized: "\(settings.cliProvider.title) 可以运行。"))
            } else if configs.count > 1 {
                let names = configs.map(\.model).formatted(.list(type: .and))
                testResult = (true, String(localized: "连接正常，\(names) 都接受图片输入。"))
            } else {
                testResult = (true, String(localized: "连接正常，这个模型接受图片输入。"))
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
