import AppKit
import SwiftUI

/// 头部那一行右边的接法／模型切换器。常用的切换不用再去开设置窗口。
/// 这里换模型只换「当前回答模式」用的那个，和设置页里那一行是同一个值；默认模型只在设置页改。
struct ModelSwitcher: View {
    var width: CGFloat = 200
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var state = ModelMenuState.shared
    @State private var hovering = false

    private var models: ActiveModels { ActiveModels(settings: settings, state: state) }

    var body: some View {
        let models = self.models
        let mode = settings.responseMode
        let choice = models.choice(for: mode)
        Menu {
            Section("接法") {
                ForEach(ProviderKind.allCases) { kind in
                    Button {
                        settings.providerKind = kind.rawValue
                        if kind == .ollama { state.refreshOllama() }
                    } label: {
                        Label(kind.title, systemImage: kind == currentKind ? "checkmark" : kind.symbol)
                    }
                }
            }

            if currentKind == .openAICompatible {
                Section("服务商") {
                    ForEach(providerChoices) { provider in
                        Button {
                            settings.selectCloudProvider(provider)
                        } label: {
                            Label(providerLabel(provider),
                                  systemImage: provider == settings.cloudProvider ? "checkmark" : "cloud")
                        }
                    }
                }
            }

            if currentKind == .codexCLI {
                Section("本地 Cli") {
                    ForEach(CLIProvider.allCases) { provider in
                        Button {
                            settings.cliProvider = provider
                            if provider == .agy { state.refreshAgy() }
                        } label: {
                            Label(provider.title,
                                  systemImage: provider == settings.cliProvider ? "checkmark" : "terminal")
                        }
                    }
                }
            }

            Section(String(localized: "\(mode.title)模式的模型")) {
                Button {
                    models.setChoice("", for: mode)
                } label: {
                    Label(models.defaultChoiceTitle(for: mode), systemImage: choice.isEmpty ? "checkmark" : "circle")
                }
                ForEach(models.presets(including: choice), id: \.slug) { preset in
                    Button {
                        models.setChoice(preset.slug, for: mode)
                    } label: {
                        Label(preset.title, systemImage: preset.slug == choice ? "checkmark" : "circle")
                    }
                }
            }

            Divider()

            if currentKind == .ollama {
                Button("刷新本机模型") { state.refreshOllama() }
            }
            if currentKind == .codexCLI, settings.cliProvider == .agy {
                Button("刷新 Agy 模型") { state.refreshAgy() }
            }
            SettingsLink { Text("更多设置…") }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: currentKind.symbol).font(.system(size: 9))
                Text(verbatim: models.effectiveTitle(for: mode))
                    .font(DS.meta)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.05))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Allow long model names to yield space to capture status and turn counts.
        // https://developer.apple.com/documentation/swiftui/view/fixedsize()
        .frame(width: width, alignment: .trailing)
        .clipped()
        .layoutPriority(-1)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(fullLabel(models, mode: mode)))
        .help("切换接法和模型：\(fullLabel(models, mode: mode))")
        .onAppear {
            if currentKind == .ollama { state.refreshOllamaIfStale() }
            if currentKind == .codexCLI, settings.cliProvider == .agy { state.refreshAgyIfStale() }
        }
    }

    private var currentKind: ProviderKind { ProviderKind.current }

    /// 内置的几家；用户正用着「自定义」时把它也列出来，好知道自己在哪。
    private var providerChoices: [CloudProvider] {
        settings.cloudProvider == .custom
            ? CloudProvider.builtIn + [.custom]
            : CloudProvider.builtIn
    }

    /// 没配 Key 的那几家先标出来，省得切过去发一条才发现。
    private func providerLabel(_ provider: CloudProvider) -> String {
        guard provider != .custom, !KeychainStore.hasKey(for: provider) else { return provider.title }
        return String(localized: "\(provider.title)（未配置 Key）")
    }

    private func fullLabel(_ models: ActiveModels, mode: ResponseMode) -> String {
        var parts = [currentKind.title]
        if currentKind != .ollama { parts.append(models.connectionTitle) }
        let model = models.effectiveModel(for: mode)
        if !model.isEmpty { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

/// 当前接法下能选哪些模型、各叫什么、每个模式实际用哪个。发送、测试连接、头部菜单和设置页
/// 都从这里取，所以界面上写的「默认」和真正发出去的永远是同一个模型。
///
/// 每个模式的选择按接法分开存（见 `ProviderConfig.responseConnectionKey`），空值表示跟随默认：
/// 快速直接用默认模型；深入在 Antigravity 上换成它的 High 思考档——Agy 把思考强度写在模型名里，
/// 不像 Codex 和各家 API 那样用请求参数调（那两类的深入由 `ResponsePolicy` 和 Codex 自己提高强度）。
@MainActor
struct ActiveModels {
    let settings: AppSettings
    let baseline: ProviderConfig
    /// 算一次存下来：Codex 的清单要读磁盘上的缓存文件，一次渲染里会用到好几回。
    let presets: [ModelCatalog.Preset]

    init(settings: AppSettings, state: ModelMenuState) {
        self.settings = settings
        baseline = ProviderConfig.selection(settings: settings)
        switch baseline.kind {
        case .openAICompatible:
            presets = ModelCatalog.cloudPresets(provider: settings.cloudProvider, baseURL: settings.baseURL)
        case .ollama:
            presets = state.ollamaModels.map { .init(slug: $0, title: $0, note: "") }
        case .codexCLI:
            switch settings.cliProvider {
            case .codex:      presets = ModelCatalog.codexPresets()
            case .agy:        presets = state.agyPresets
            case .claudeCode: presets = ClaudeCodeCLIProvider.presets
            }
        }
    }

    /// 预设之外再带上一个手填的值，菜单里才看得到它被选中。
    func presets(including slug: String) -> [ModelCatalog.Preset] {
        let list = presets
        guard ModelCatalog.isCustom(slug, in: list) else { return list }
        return list + [.init(slug: slug, title: slug, note: String(localized: "自定义"))]
    }

    var connectionTitle: String {
        switch baseline.kind {
        case .openAICompatible: return settings.cloudProvider.title
        case .ollama:           return "Ollama"
        case .codexCLI:         return settings.cliProvider.title
        }
    }

    func choice(for mode: ResponseMode) -> String {
        settings.responseModel(for: mode, connection: baseline.responseConnectionKey)
    }

    func setChoice(_ slug: String, for mode: ResponseMode) {
        settings.setResponseModel(slug, for: mode, connection: baseline.responseConnectionKey)
    }

    /// 跟随默认时这个模式用哪个模型。
    func defaultModel(for mode: ResponseMode) -> String {
        guard mode == .deep, baseline.kind == .codexCLI, settings.cliProvider == .agy else { return baseline.model }
        return ModelCatalog.highThinkingSibling(of: baseline.model, in: presets) ?? baseline.model
    }

    /// 深入跟随默认时换到了另一个（High 档）模型。
    func defaultRaisesThinking(for mode: ResponseMode) -> Bool {
        defaultModel(for: mode) != baseline.model
    }

    func effectiveModel(for mode: ResponseMode) -> String {
        let choice = choice(for: mode)
        return choice.isEmpty ? defaultModel(for: mode) : choice
    }

    /// 这个模式要发出去的完整配置（API Key 另由 `ProviderConfig.authorized` 补上）。
    func config(for mode: ResponseMode) -> ProviderConfig {
        baseline.selecting(mode, model: effectiveModel(for: mode))
    }

    /// 默认模型的名字；没选时说清楚是谁在决定。
    var defaultTitle: String { title(of: baseline.model) }

    /// 「默认：Gemini 3.6 Flash (Low)」：不用翻到上面也知道默认是哪个。深入换了 High 档就明说。
    func defaultChoiceTitle(for mode: ResponseMode) -> String {
        let name = title(of: defaultModel(for: mode))
        return defaultRaisesThinking(for: mode) ? String(localized: "默认 · 高思考：\(name)")
                                                : String(localized: "默认：\(name)")
    }

    func effectiveTitle(for mode: ResponseMode) -> String { title(of: effectiveModel(for: mode)) }

    /// 能认出来的最短写法：有预设用预设名，否则去掉厂商前缀和 :free 后缀。
    func title(of slug: String) -> String {
        guard !slug.isEmpty else {
            guard baseline.kind == .codexCLI else { return String(localized: "未选择模型") }
            switch settings.cliProvider {
            case .codex:      return String(localized: "Codex 默认")
            case .agy:        return String(localized: "Agy 默认")
            case .claudeCode: return String(localized: "Claude Code 默认")
            }
        }
        if let preset = presets.first(where: { $0.slug == slug }), preset.title != slug { return preset.title }
        var name = slug.components(separatedBy: "/").last ?? slug
        if name.hasSuffix(":free") { name = String(name.dropLast(5)) }
        return name
    }
}

/// Ollama 的模型清单要现扫，缓存一下别每次开菜单都跑一次。
@MainActor
final class ModelMenuState: ObservableObject {
    static let shared = ModelMenuState()

    @Published private(set) var ollamaModels: [String] = []
    @Published private(set) var agyModels: [ModelCatalog.Preset] = []
    @Published private(set) var isScanningAgy = false
    private var lastProbe: Date?
    private var lastAgyScan: Date?

    private init() {}

    func refreshOllamaIfStale() {
        if let lastProbe, Date().timeIntervalSince(lastProbe) < 60 { return }
        refreshOllama()
    }

    func refreshOllama() {
        lastProbe = Date()
        let base = AppSettings.shared.ollamaBaseURL
        Task {
            if case .running(let models) = await OllamaSupport.probe(baseURL: base) {
                ollamaModels = models.filter { !$0.contains("embed") }
            } else {
                ollamaModels = []
            }
        }
    }

    func refreshAgyIfStale() {
        if let lastAgyScan, Date().timeIntervalSince(lastAgyScan) < 60 { return }
        refreshAgy()
    }

    /// 扫到之前先用内置清单顶着，免得下拉是空的。
    var agyPresets: [ModelCatalog.Preset] { agyModels.isEmpty ? AgyCLIProvider.fallbackModels : agyModels }

    func refreshAgy() {
        guard !isScanningAgy else { return }
        lastAgyScan = Date()
        isScanningAgy = true
        let configuredPath = AppSettings.shared.agyPath
        Task {
            let models = await AgyCLIProvider.scanModels(configuredPath: configuredPath)
            if !models.isEmpty { agyModels = models }
            isScanningAgy = false
        }
    }
}
