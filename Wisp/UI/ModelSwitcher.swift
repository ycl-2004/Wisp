import AppKit
import SwiftUI

/// 头部那一行右边的接法／模型切换器。常用的切换不用再去开设置窗口。
struct ModelSwitcher: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var state = ModelMenuState.shared
    @State private var hovering = false

    var body: some View {
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

            if !models.isEmpty {
                Section("模型") {
                    ForEach(models, id: \.slug) { preset in
                        Button {
                            setModel(preset.slug)
                        } label: {
                            Label(preset.title,
                                  systemImage: preset.slug == currentModel ? "checkmark" : "circle")
                        }
                    }
                }
            }

            Divider()

            if currentKind == .ollama {
                Button("重新扫描本机模型") { state.refreshOllama() }
            }
            if currentKind == .codexCLI, settings.cliProvider == .agy {
                Button("重新扫描 Agy 模型") { state.refreshAgy() }
            }
            SettingsLink { Text("更多设置…") }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: currentKind.symbol).font(.system(size: 9))
                Text(shortLabel)
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
        .fixedSize()
        .onHover { hovering = $0 }
        .help("切换接法和模型：\(fullLabel)")
        .onAppear {
            if currentKind == .ollama { state.refreshOllamaIfStale() }
            if currentKind == .codexCLI, settings.cliProvider == .agy { state.refreshAgyIfStale() }
        }
    }

    private var currentKind: ProviderKind { ProviderKind.current }

    private var currentModel: String {
        switch currentKind {
        case .openAICompatible: return settings.model
        case .ollama:           return settings.ollamaModel
        case .codexCLI:
            switch settings.cliProvider {
            case .codex:      return settings.codexModel
            case .agy:        return settings.agyModel
            case .claudeCode: return settings.claudeCodeModel
            }
        }
    }

    private func setModel(_ slug: String) {
        switch currentKind {
        case .openAICompatible: settings.model = slug
        case .ollama:           settings.ollamaModel = slug
        case .codexCLI:
            switch settings.cliProvider {
            case .codex:      settings.codexModel = slug
            case .agy:        settings.agyModel = slug
            case .claudeCode: settings.claudeCodeModel = slug
            }
        }
    }

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

    private var models: [ModelCatalog.Preset] {
        switch currentKind {
        case .openAICompatible:
            var list = ModelCatalog.cloudPresets(provider: settings.cloudProvider,
                                                baseURL: settings.baseURL)
            if ModelCatalog.isCustom(settings.model, in: list) {
                list.append(.init(slug: settings.model, title: settings.model, note: String(localized: "自定义")))
            }
            return list
        case .ollama:
            return state.ollamaModels.map { .init(slug: $0, title: $0, note: "") }
        case .codexCLI:
            switch settings.cliProvider {
            case .codex:      return ModelCatalog.codexPresets()
            case .agy:        return state.agyModels.isEmpty ? AgyCLIProvider.fallbackModels : state.agyModels
            case .claudeCode: return ClaudeCodeCLIProvider.presets
            }
        }
    }

    /// 头部空间有限，只显示能认出来的最短形式。
    private var shortLabel: String {
        let model = currentModel
        if model.isEmpty {
            if currentKind == .codexCLI {
                switch settings.cliProvider {
                case .codex:      return String(localized: "Codex 默认")
                case .agy:        return String(localized: "Agy 默认")
                case .claudeCode: return String(localized: "Claude Code 默认")
                }
            }
            return currentKind.title
        }
        if let preset = models.first(where: { $0.slug == model }), preset.title != model {
            return preset.title
        }
        // 去掉厂商前缀和 :free 后缀，只留模型名本身。
        var name = model.components(separatedBy: "/").last ?? model
        if name.hasSuffix(":free") { name = String(name.dropLast(5)) }
        return name
    }

    private var fullLabel: String {
        var parts = [currentKind.title]
        if currentKind == .openAICompatible { parts.append(settings.cloudProvider.title) }
        if currentKind == .codexCLI { parts.append(settings.cliProvider.title) }
        if !currentModel.isEmpty { parts.append(currentModel) }
        return parts.joined(separator: " · ")
    }
}

/// Ollama 的模型清单要现扫，缓存一下别每次开菜单都跑一次。
@MainActor
final class ModelMenuState: ObservableObject {
    static let shared = ModelMenuState()

    @Published private(set) var ollamaModels: [String] = []
    @Published private(set) var agyModels: [ModelCatalog.Preset] = []
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

    func refreshAgy() {
        lastAgyScan = Date()
        let configuredPath = AppSettings.shared.agyPath
        Task {
            let models = await AgyCLIProvider.scanModels(configuredPath: configuredPath)
            if !models.isEmpty { agyModels = models }
        }
    }
}
