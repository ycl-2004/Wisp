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
    /// 「开始使用 Wisp」正在跑真验证（实际发一次测试请求，要等网络
    /// 往返）。期间主按钮禁用，避免连点发两次。
    @State private var verifying = false
    /// 真验证的失败原因（给人看的那句，与设置页「测试连接」同口径）。
    /// 就绪复查只证明存在性，这里存的是真请求之后的结论——失败不
    /// 关窗、就地显示（UX 改造第 4 项）。用户一改设置就清掉，免得
    /// 旧结论赖在已经改过的配置上面。
    @State private var verifyFailure: String?

    var body: some View {
        VStack(spacing: 0) {
            subtitle
            Divider()
            stepHeader(1, "连接模型", chip: "必须", required: true)
            keyGuide
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
        .onAppear {
            screenRecordingGranted = Permissions.hasScreenRecording
            // 视图随窗口终身复用（不再是 sheet 时代的每次新建）：上次
            // 点「开始使用 Wisp」失败留下的提示不该在重开时直接在场，
            // 每次出现先清掉，用户再点按钮、判定再失败时才会重新出现。
            showsNeedsHint = false
            verifyFailure = nil
        }
        .onReceive(AppSettings.shared.objectWillChange) { _ in
            // 配置被改动了，上一次真验证的结论就作废：留着它，用户
            // 改对了也会以为还没对。
            verifyFailure = nil
        }
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

    /// 第 1 步的 Key 导览（UX 改造第 4 项）：下面的表单默认用户已经
    /// 有 Key，新用户其实卡在更前面——不知道 Key 是什么、去哪拿。
    /// 三行讲完：是什么、去哪创建、没想好先用哪家。最短路径也点明
    /// 了：默认服务商 OpenRouter 有免费档，不用先花钱。另外两种接法
    /// 不需要 Key，它们的卡片副标题已经写明「适合谁」，这里不重复。
    private var keyGuide: some View {
        Text("API Key 是你向服务商证明身份的凭证：在服务商网站注册后，到 API Keys 页面创建一个，粘贴到下面的输入框（旁边的「获取」会打开对应页面）。还没想好用哪家？默认的 OpenRouter 有免费模型，可以先免费用。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
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
            } else if Permissions.sessionRequestedScreenRecording {
                // 申请已无效（本会话已请求过且仍未授权）：再调
                // CGRequest 也不会有任何反应，直接送去系统设置里手动
                // 开。信号读 Permissions 的会话级共享标记——采集路径
                // 先请求过被拒的，进向导直接是这个形态，不必先白点
                // 一下死的「去授权」（与设置页权限行常驻「系统设置…」
                // 入口同一兜底口径）。
                Button("系统设置…") { Permissions.openScreenRecordingSettings() }
            } else {
                Button("去授权") {
                    Permissions.requestScreenRecording()
                    screenRecordingGranted = Permissions.hasScreenRecording
                    // 首次请求系统会弹窗；弹窗里当场授权的上面一行即时
                    // 生效，从系统设置授权回来的由 didBecomeActive 刷新。
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
                    Task { await startUsing() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(verifying)
            }
            // 真验证的状态行：进行中给一行进度，失败给人话原因（与
            // 设置页 testResult 同样的呈现：红叉、可选中、多行）。它
            // 只在点过主按钮之后才出现，下面的固定槽位提示不受影响。
            if verifying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在验证连接…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else if let verifyFailure {
                Label(verifyFailure, systemImage: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 「开始使用 Wisp」的两段判定（UX 改造第 4 项把第二段从存在性
    /// 复查升级为真验证）：
    /// 1. 就绪复查（存在性）：还没配好就停在原来的提示，不浪费一次
    ///    真请求；
    /// 2. 真验证：对当前选择实际发一次测试请求（与设置页「测试
    ///    连接」同一条路径）——Key 填错一位、模型没权限这类问题只
    ///    有真发一次才现形。失败不关窗，原因就地显示在页脚；通过
    ///    才走完成交接（关窗 + 面板亮出，落点是提问框）。
    /// 两段都要等网络/探测，在飞期间用户可能关窗或改配置：结论落地
    /// 前按配置代次对账（`AssistantModel.onboardingConfigGeneration`），
    /// 对不上就静默丢弃——旧配置的成功不许替新配置完成交接。
    private func startUsing() async {
        verifyFailure = nil
        await model.refreshOnboardingReadiness()
        // 复查这段也要等（Ollama 探测最长数秒）：期间用户把窗口关了，
        // 这次点击到此为止——别在背后继续验证、更别完成交接。
        guard model.showsOnboarding else { return }
        guard !model.onboardingNeeded else {
            showsNeedsHint = true
            return
        }
        showsNeedsHint = false
        verifying = true
        // 归属对账：验证是真网络请求，慢端点能拖到分钟级。发起前领
        // 一个配置代次，回来先对账——窗口还开着、且代次没变（期间
        // 没改过设置/Key、没关过窗），结论才许落地（显示失败或完成
        // 交接）；对不上就静默丢弃：用户已经在处理新配置了，旧结论
        // 无论对错都不再属于它。verifying 先复位再对账，本视图随
        // 窗口终身复用，绝不能把主按钮永久留在禁用态。
        let generation = model.onboardingConfigGeneration
        let failure = await model.verifyOnboardingConnection()
        verifying = false
        guard model.showsOnboarding,
              generation == model.onboardingConfigGeneration else { return }
        if let failure {
            verifyFailure = failure
        } else {
            model.completeOnboarding()
        }
    }
}
