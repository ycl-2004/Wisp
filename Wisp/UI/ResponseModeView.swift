import SwiftUI
import KeyboardShortcuts

/// Compact mode switch used in the voice row (or beside the composer when voice is off).
/// The icons keep the panel one row shorter while the labels remain available to VoiceOver
/// and the hover tooltip.
struct ResponseModeToggle: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = AssistantModel.shared
    @State private var showsTiming = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ResponseMode.allCases) { mode in
                Button {
                    settings.responseMode = mode
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 21, height: 19)
                        .foregroundStyle(settings.responseMode == mode ? Color.accentColor : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(settings.responseMode == mode ? Color.accentColor.opacity(0.14) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(mode.explanation)
                .accessibilityLabel(Text(mode.title))
                .accessibilityAddTraits(settings.responseMode == mode ? .isSelected : [])
            }

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
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("回答模式"))
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

    private func effectiveModel(for mode: ResponseMode) -> String {
        baseline.selecting(mode,
            model: settings.responseModel(for: mode, connection: baseline.responseConnectionKey)).model
    }

    private var cliPath: String {
        switch settings.cliProvider {
        case .codex: return settings.codexPath
        case .agy: return settings.agyPath
        case .claudeCode: return settings.claudeCodePath
        }
    }

    private var responseInfo: String {
        var lines = [String(localized: "当前连接：\(connectionName)")]
        switch baseline.kind {
        case .openAICompatible:
            lines.append(String(localized: "接口：\(settings.baseURL)"))
        case .ollama:
            let model = settings.ollamaModel.isEmpty ? String(localized: "未选择模型") : settings.ollamaModel
            lines.append(String(localized: "本地模型：\(model)"))
        case .codexCLI:
            let path = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { lines.append(String(localized: "可执行文件：\(path)")) }
        }

        for mode in ResponseMode.allCases {
            let model = effectiveModel(for: mode)
            let title = mode == .quick ? String(localized: "快速模型：") : String(localized: "深入模型：")
            lines.append(title + (model.isEmpty ? String(localized: "未选择模型") : model))
            if let note = modelPresets.first(where: { $0.slug == model })?.note, !note.isEmpty {
                lines.append(note)
            }
        }
        return lines.joined(separator: "\n")
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
                InfoButton(message: responseInfo)
            }
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
