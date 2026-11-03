import AppKit
import KeyboardShortcuts
import SwiftUI

/// 首次设置向导（#8）：一个模型都没连上时打开。一张 sheet、四块内容、
/// 一个出口 —— 连接模型直接复用设置页的 `ModelSettingsView` 本体，
/// 两处永远不可能对「什么算配置好了」有不同理解。设计见
/// `ONBOARDING-DESIGN.md`。
struct OnboardingView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    @State private var screenRecordingGranted = Permissions.hasScreenRecording
    @State private var showsNeedsHint = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // 设置页的模型标签页本体（省去回答模式一节）：服务商卡片、
            // 分服务商的 Key、测试连接、Ollama 探测、CLI 路径识别全在里面。
            ModelSettingsView(showsResponseModes: false)
            Divider()
            permissionsRow
            Divider()
            hotkeyRow
            Divider()
            footer
        }
        .frame(width: 600, height: 720)
        .onAppear { screenRecordingGranted = Permissions.hasScreenRecording }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户可能刚从系统设置里授权回来。
            screenRecordingGranted = Permissions.hasScreenRecording
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("欢迎使用 Wisp")
                    .font(.title3.weight(.semibold))
                Text("先连上一个模型，Wisp 才能开始回答你。所有设置只保存在这台 Mac 上。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var permissionsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: screenRecordingGranted ? "checkmark.circle.fill" : "rectangle.on.rectangle.slash")
                .foregroundStyle(screenRecordingGranted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("屏幕录制")
                    .font(.system(size: 13, weight: .medium))
                Text(screenRecordingGranted
                     ? String(localized: "已授予，Wisp 可以读取当前窗口和屏幕。")
                     : String(localized: "提问时读取当前窗口和屏幕需要这个权限；纯文字提问不受影响。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if screenRecordingGranted {
                Text("已授权")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Button("去授权") {
                    Permissions.requestScreenRecording()
                    // 首次请求系统会弹窗；授权与否回来时由 didBecomeActive 刷新。
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var hotkeyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("呼出快捷键")
                    .font(.system(size: 13, weight: .medium))
                Text("在任何应用里按这个组合键呼出或收起 Wisp。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            KeyboardShortcuts.Recorder("", name: .toggleAssistant)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button("打开完整设置") {
                    dismiss()
                    openSettings()
                }
                Spacer(minLength: 0)
                Button("稍后再说") { dismiss() }
                Button("开始使用") {
                    Task {
                        await model.refreshOnboardingReadiness()
                        if model.onboardingNeeded {
                            showsNeedsHint = true
                        } else {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            if showsNeedsHint, model.onboardingNeeded {
                Text("还没有可用的模型 — 完成上面任意一种连接就可以开始，也可以先跳过。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }
}
