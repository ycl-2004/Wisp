import AppKit
import KeyboardShortcuts
import SwiftUI

/// 首次设置向导（#8）：一个模型都没连上时打开。三步内容、一个出口 ——
/// 连接模型直接复用设置页的 `ModelSettingsView` 本体，两处永远不可能
/// 对「什么算配置好了」有不同理解。设计见 `ONBOARDING-DESIGN.md`。
///
/// 宿主是独立窗口（UX 改造第 3 项，`OnboardingWindowController`）：
/// 标题「欢迎使用 Wisp」在窗口标题栏里，正文头部只剩一行副标题；
/// 本视图不感知宿主，关闭一律置模型的 `showsOnboarding = false`，
/// 记账由控制器在窗口消失时收口（`onboardingWindowClosed()`）。
struct OnboardingView: View {
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.openSettings) private var openSettings

    @State private var screenRecordingGranted = Permissions.hasScreenRecording
    @State private var showsNeedsHint = false

    var body: some View {
        VStack(spacing: 0) {
            subtitle
            Divider()
            stepHeader(1, "连接模型", chip: "必须", required: true)
            // 设置页的模型标签页本体（省去回答模式一节）：服务商卡片、
            // 分服务商的 Key、测试连接、Ollama 探测、CLI 路径识别全在
            // 里面。它自带的 ScrollView 是整个窗口唯一的滚动区——窗口
            // 高度封顶 640，超出的部分只在这里滚（其余各步与页脚常驻）。
            // 已知小账：它内部 .padding(18)，与本视图各区的 20 有 2pt
            // 左缘错位；内边距是与设置页共享的，改它会动设置页版式，
            // 本项不动，只在此记明。
            ModelSettingsView(showsResponseModes: false)
            Divider()
            stepHeader(2, "屏幕录制", chip: "可选", required: false)
            permissionsRow
            Divider()
            stepHeader(3, "呼出快捷键", chip: "可选", required: false)
            hotkeyRow
            Divider()
            footer
        }
        .onAppear { screenRecordingGranted = Permissions.hasScreenRecording }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户可能刚从系统设置里授权回来。
            screenRecordingGranted = Permissions.hasScreenRecording
        }
    }

    /// 标题已由窗口标题栏承担，正文头部只留这一行：哪步必须、哪步
    /// 可以以后再说，先讲清楚，免得三步看起来一样重。
    private var subtitle: some View {
        Text("只有第一步是必须的，另两步随时能在设置里补。所有设置只保存在这台 Mac 上。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
    }

    // chip 文案由调用点以字面量传入：三元表达式里的字符串字面量有被
    // 推断成逐字 String（不走本地化）的风险，参数类型定死为
    // LocalizedStringKey 就没有这个歧义。
    private func stepHeader(_ number: Int, _ title: LocalizedStringKey,
                            chip: LocalizedStringKey, required: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(chip)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(required ? Color.accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(required ? Color.accentColor.opacity(0.14)
                                            : Color.primary.opacity(0.06))
                )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var permissionsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: screenRecordingGranted ? "checkmark.circle.fill" : "rectangle.on.rectangle.slash")
                .foregroundStyle(screenRecordingGranted ? .green : .secondary)
            Text(screenRecordingGranted
                 ? String(localized: "已授予，Wisp 可以读取当前窗口和屏幕。")
                 : String(localized: "提问时读取当前窗口和屏幕需要这个权限；纯文字提问不受影响。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("在任何应用里按这个组合键呼出或收起 Wisp。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            KeyboardShortcuts.Recorder("", name: .toggleAssistant)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // 降为链接样式：它是逃生口，不是和主按钮并列的出口。
                Button("打开完整设置") {
                    model.showsOnboarding = false
                    openSettings()
                }
                .buttonStyle(.link)
                Spacer(minLength: 0)
                Button("稍后再说") { model.showsOnboarding = false }
                Button("开始使用 Wisp") {
                    // 先让 Key 输入框失焦，它的内容才落进钥匙串（模型页的
                    // 保存时机是失焦/回车/切换）——不然刚填完就点这里，
                    // 复查会误判成还没配置。
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    Task {
                        await model.refreshOnboardingReadiness()
                        if model.onboardingNeeded {
                            showsNeedsHint = true
                        } else {
                            // 完成交接：关窗 + 面板亮出，落点是提问框。
                            model.completeOnboarding()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            // 提示行常驻一个固定 16pt 槽位：没提示时空着，有提示时原地
            // 出现——页脚高度恒定，按「开始使用 Wisp」不会把布局顶开。
            Text(hintText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16)
        }
        .padding(20)
    }

    private var hintText: String {
        guard showsNeedsHint, model.onboardingNeeded else { return "" }
        return String(localized: "还没有可用的模型 — 完成上面任意一种连接就可以开始，也可以先跳过。")
    }
}
