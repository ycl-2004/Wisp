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
    private var models: ActiveModels { ActiveModels(settings: settings, state: modelState) }

    private var cliPath: String {
        switch settings.cliProvider {
        case .codex: return settings.codexPath
        case .agy: return settings.agyPath
        case .claudeCode: return settings.claudeCodePath
        }
    }

    private var responseInfo: String {
        let models = self.models
        var lines = [String(localized: "当前连接：\(models.connectionTitle)")]
        switch models.baseline.kind {
        case .openAICompatible:
            lines.append(String(localized: "接口：\(settings.baseURL)"))
        case .ollama:
            let model = settings.ollamaModel.isEmpty ? String(localized: "未选择模型") : settings.ollamaModel
            lines.append(String(localized: "本地模型：\(model)"))
        case .codexCLI:
            let path = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { lines.append(String(localized: "可执行文件：\(path)")) }
        }

        let presets = models.presets
        for mode in ResponseMode.allCases {
            let model = models.effectiveModel(for: mode)
            let title = mode == .quick ? String(localized: "快速模型：") : String(localized: "深入模型：")
            let source = !models.choice(for: mode).isEmpty ? ""
                : models.defaultRaisesThinking(for: mode) ? String(localized: "（默认模型的 High 档）")
                : String(localized: "（默认）")
            lines.append(title + (model.isEmpty ? models.defaultTitle : model) + source)
            if let note = presets.first(where: { $0.slug == model })?.note, !note.isEmpty {
                lines.append(note)
            }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text("速度与准确性").font(.system(size: 13, weight: .semibold))
                InfoButton(message: [
                    settings.responseMode.explanation,
                    String(localized: "没有单独指定时，快速直接用默认模型；深入在 Antigravity 上自动换成默认模型的 High 思考档，在 Codex 和 API 上用同一个模型、调高思考强度。"),
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
            let kind = models.baseline.kind
            if kind == .ollama { modelState.refreshOllamaIfStale() }
            if kind == .codexCLI, settings.cliProvider == .agy { modelState.refreshAgyIfStale() }
        }
    }

    private func responseModeRow(_ mode: ResponseMode) -> some View {
        let models = self.models
        return HStack(alignment: .top, spacing: 10) {
            Label(mode.title, systemImage: mode.symbol)
                .frame(width: 100, alignment: .leading)
            KeyboardShortcuts.Recorder("", name: shortcutName(for: mode))
                .frame(width: 150, alignment: .leading)
            ResponseModeModelPicker(
                presets: models.presets,
                placeholder: models.defaultChoiceTitle(for: mode),
                value: Binding(
                    get: { models.choice(for: mode) },
                    set: { models.setChoice($0, for: mode) }))
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
