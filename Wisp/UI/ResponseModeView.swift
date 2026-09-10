import SwiftUI
import KeyboardShortcuts

struct ResponseModeBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = AssistantModel.shared
    @State private var showsTiming = false

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("回答模式", selection: $settings.responseMode) {
                    ForEach(ResponseMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Divider()
                Text(settings.responseMode.explanation)
                SettingsLink { Text("模式与模型设置…") }
            } label: {
                Label(settings.responseMode.title, systemImage: settings.responseMode.symbol)
                    .font(DS.meta)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(settings.responseMode.explanation)

            Text(model.isStreaming ? String(localized: "修改将在下次提问生效") : model.isPreparingResponse ? String(localized: "正在准备上下文…")
                 : settings.responseMode == .quick ? String(localized: "已有上下文 · 不取新正文")
                 : String(localized: "按采集设置读取正文"))
                .font(DS.meta).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .help(settings.responseMode.explanation)
            Spacer(minLength: 0)
            if let timing = model.lastResponseTiming {
                Button { showsTiming.toggle() } label: {
                    Image(systemName: "stopwatch").font(DS.meta)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("本次回答耗时")
                .accessibilityLabel("本次回答耗时")
                .popover(isPresented: $showsTiming) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(timing.display).font(DS.meta.monospacedDigit())
                        if model.lastResponseSkippedPage {
                            Text("本轮跳过了新的整页正文采集。").foregroundStyle(.orange)
                        }
                        Text("计时仅保存在内存；首字不代表答案正确。").foregroundStyle(.secondary)
                    }
                    .font(DS.meta)
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 18)
    }
}

struct ResponseModeSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var modelState = ModelMenuState.shared
    private var baseline: ProviderConfig { ProviderConfig.selection() }

    private var connectionName: String {
        switch baseline.kind {
        case .openAICompatible:
            return settings.cloudProvider.title
        case .ollama:
            return "Ollama"
        case .codexCLI:
            return settings.cliProvider.title
        }
    }

    private var connectionModel: String {
        let mode = settings.responseMode
        return baseline.selecting(mode,
            model: settings.responseModel(for: mode, connection: baseline.responseConnectionKey)).model
    }

    private var modelPresets: [ModelCatalog.Preset] {
        switch baseline.kind {
        case .openAICompatible:
            return ModelCatalog.cloudPresets(provider: settings.cloudProvider, baseURL: settings.baseURL)
        case .ollama:
            return modelState.ollamaModels.map { .init(slug: $0, title: $0, note: "") }
        case .codexCLI:
            switch settings.cliProvider {
            case .codex: return ModelCatalog.codexPresets()
            case .agy: return modelState.agyModels.isEmpty ? AgyCLIProvider.fallbackModels : modelState.agyModels
            case .claudeCode: return ClaudeCodeCLIProvider.presets
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text("速度与准确性").font(.system(size: 13, weight: .semibold))
                InfoButton(message: [
                    settings.responseMode.explanation,
                    String(localized: "所有模式均优先请求可用的 Fast／Priority；模型不因加速自动更换。"),
                    String(localized: "回答期间可修改；下次提问生效。")
                ].joined(separator: "\n\n"))
            }
            HStack {
                Text("回答模式").frame(width: 110, alignment: .leading)
                Picker("回答模式", selection: $settings.responseMode) {
                    ForEach(ResponseMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
            Text("当前连接")
                Text("·")
                Text(connectionName)
                Text("·")
                Text(connectionModel.isEmpty ? String(localized: "未选择模型") : connectionModel)
            }
            .font(DS.meta).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                Text("模式").frame(width: 100, alignment: .leading)
                Text("快捷键").frame(width: 150, alignment: .leading)
                Text("模型")
            }
            .font(DS.meta).foregroundStyle(.secondary)
            ForEach(ResponseMode.allCases) { mode in
                responseModeRow(mode)
            }
            HStack(spacing: 5) {
                Text("Fast / Priority").font(DS.meta).foregroundStyle(.secondary)
                InfoButton(message: String(localized: "所有模式均优先请求可用的 Fast／Priority；模型不因加速自动更换。"))
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            if baseline.kind == .ollama { modelState.refreshOllamaIfStale() }
            if baseline.kind == .codexCLI, settings.cliProvider == .agy { modelState.refreshAgyIfStale() }
        }
    }

    private func responseModeRow(_ mode: ResponseMode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label(mode.title, systemImage: mode.symbol)
                .frame(width: 100, alignment: .leading)
            KeyboardShortcuts.Recorder("", name: shortcutName(for: mode))
                .frame(width: 150, alignment: .leading)
            ResponseModeModelPicker(
                presets: modelPresets,
                placeholder: String(localized: "使用默认模型"),
                value: Binding(
                    get: { settings.responseModel(for: mode, connection: baseline.responseConnectionKey) },
                    set: { settings.setResponseModel($0, for: mode, connection: baseline.responseConnectionKey) }))
        }
    }

    private func shortcutName(for mode: ResponseMode) -> KeyboardShortcuts.Name {
        mode == .quick ? .responseQuick : .responseDeep
    }
}

private struct ResponseModeModelPicker: View {
    let presets: [ModelCatalog.Preset]
    let placeholder: String
    @Binding var value: String
    @State private var custom = false
    @State private var customText = ""

    private let customTag = "__wisp_response_custom__"

    private var selection: String {
        if custom { return customTag }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("模型", selection: Binding(
                get: { selection },
                set: { selected in
                    if selected == customTag {
                        custom = true
                        customText = value
                    } else {
                        custom = false
                        value = selected
                    }
                })) {
                Text(placeholder).tag("")
                ForEach(presets) { preset in
                    Text(preset.title).tag(preset.slug)
                }
                Divider()
                Text("自定义…").tag(customTag)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            if custom {
                TextField(placeholder, text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customText) { _, newValue in
                        value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
            }
        }
        .onAppear {
            custom = !value.isEmpty && !presets.contains(where: { $0.slug == value })
            customText = value
        }
        .onChange(of: presets.map(\.slug)) {
            custom = !value.isEmpty && !presets.contains(where: { $0.slug == value })
            if custom { customText = value }
        }
    }
}
