# 隐私光标锁定与点击反馈修复

后续修正：用户发现双鼠标后，已移除共享静止箭头。本文保留早先构建的历史证据，其中“静止共享箭头通过”不能证明本机无双鼠标；当前行为与结果见[单光标修复](single-cursor-20260912.md)。

日期：2026-09-12。环境：本机 macOS 26.6.2，单显示器。原始采样摘要见 [JSON 证据](evidence/cursor-lock-20260912.json)。

## 当前行为

「设置 → 权限 → 屏幕共享 → 隐私光标锁定（实验）」统一控制本地／共享箭头替代、原生控件的箭头样式、缩放箭头，以及自定义按钮和普通按钮的按压反馈。关闭时恢复光标请求、缩放指针和按钮反馈。点击、键盘操作、选区、滚动、窗口拖动和缩放保持原生事件语义。

设置窗口标题栏、同进程受保护的菜单和气泡纳入同一命中策略；菜单开始跟踪时不再无条件退出。原生拖动保存接收事件的窗口，鼠标暂时越过窗口边界时不立即退出。离开、失活、关闭窗口或关闭选项时恢复，并平衡本进程拥有的光标隐藏计数。

**后台悬停不锁定。** 非激活面板即使有键盘焦点，也不等于拥有系统指针控制权。此前控制器可能显示私有箭头并宣称替代成功，真实录屏却仍有移动的系统指针。现在后台保留系统指针，明确点击 Wisp 时先保存外部采集目标、激活 App，再进入替代；悬停不抢焦点。

## 录制端点击圆圈的边界

**Wisp 不能统一关闭其他录屏／共享工具自己添加的点击提示。** 独立 ScreenCaptureKit 进程开启 `showMouseClicks` 后，即使 Wisp 窗口和私有箭头没有被捕获，点击位置仍出现变化的鼠标图形。隐藏指针不等于抹去鼠标事件、鼠标位置或按键状态。

macOS 自带录屏／QuickTime：按 `⌘⇧5`，在「选项」中取消「显示鼠标点击」。这会作用于该次录制的全部应用，不能只对 Wisp 关闭。其他录制或共享工具需要使用各自的点击提示选项；没有这种选项的工具，本修复无法代为关闭。未修改用户的系统录制偏好，也未控制其他 App 的录制流。

自定义按钮与普通按钮的瞬时按压特效已关闭；系统菜单的选择高亮、复选框和选择器的实际状态、键盘焦点指示仍保留。它们帮助本机用户确认当前状态。窗口捕获隐藏仍依赖录制路径支持，不能把这个开关视为所有工具的通用隔离。

## 可观察验证

| 检查 | 结果 |
| --- | --- |
| 原始实现、点击提示关闭 | 关闭／开启／恢复为 16／15／15 帧，普通移动路径通过 |
| 原始实现、录制端点击提示开启 | 42／41／41 帧；锁定组捕获鼠标图形发生变化，验证器正确报告失败 |
| 三种按钮实际按住的像素与动作 | Press、Icon、Plain 各测开关两态；关闭时像素变化，开启时按下前后像素一致；6 次动作各触发一次 |
| 原生输入与普通视频回归 | 15／15／15 帧；开启组箭头静止。点击 1 次、输入 `cursor test`、选区 11 字符、滚动 140；拖动、缩放与离开恢复通过 |
| 中间修复的后台反例 | App 未激活且面板非 key，控制器宣称替代，但 15 帧包含 9 个鼠标边界位置；不能判为通过 |
| 最终后台与激活路径 | 关闭／后台／点击激活／恢复各 15 帧；后台保留系统指针，点击激活组只有 1 个鼠标边界位置，私有窗口标记均为 0 |

窗口、光标与非音频 XCTest 共 24 项，最终结果包：`/private/tmp/wisp-cursor-repair-20260912/final-regression.xcresult`。原始本机采样在同目录的 `baseline-native`、`click-baseline`、`feedback-native`、`nonkey-native-r2` 和 `nonkey-final` 子目录。保存的图片仅为合成测试区域；没有发送到网络。

菜单和标题栏的覆盖有窗口命中／生命周期回归证据；尚未逐个操作完整 Wisp 的全部原生菜单。静态截图可能没有共享静止箭头；第三方接收端、多显示器、Space 切换和系统代理窗口仍需单独验证。对其他录制工具的说明是接口边界分析，不是逐个软件实测的兼容列表。

## 本机构建

Universal2 Release 已构建并通过严格签名验证，不含调试器授权。候选 App 位于 `/private/tmp/wisp-cursor-repair-20260912/products/Release/Wisp.app`，二进制 SHA-256 记录在 JSON 证据中。尚未替换 `/Applications/Wisp.app`，当前安装版不会自动获得此修复。

## 复测

需要本机屏幕录制与输入自动化权限。探针显示合成窗口并移动鼠标，结束时恢复原鼠标位置及前台 App。输出目录每次使用新的路径。

```sh
swiftc -parse-as-library -module-cache-path /private/tmp/wisp-cursor-cache \
  Wisp/Support/ScreenPrivacy.swift Wisp/Support/LocalCursorController.swift \
  Wisp/UI/DesignKit.swift Wisp/UI/PanelResize.swift \
  tools/screen-privacy/LocalCursorProbe.swift -o /private/tmp/wisp-cursor-probe
/private/tmp/wisp-cursor-probe run /private/tmp/wisp-feedback-check --feedback
python3 tools/screen-privacy/validate-cursor.py \
  /private/tmp/wisp-feedback-check/result.json --feedback --self-test
/private/tmp/wisp-cursor-probe run /private/tmp/wisp-activation-check --nonkey
python3 tools/screen-privacy/validate-cursor.py /private/tmp/wisp-activation-check/result.json
/private/tmp/wisp-cursor-probe run /private/tmp/wisp-click-limit --click-effects
python3 tools/screen-privacy/validate-cursor.py /private/tmp/wisp-click-limit/result.json
```

最后一项是点击提示限制的反例，预期退出码为 1；不能把这个失败改成通过。原生移动和激活路径的通过也不能覆盖录制端圆圈。

## 官方接口依据

- [Apple：在 Mac 上录制屏幕](https://support.apple.com/en-ca/102618)：点击圆圈是录制工具的选项。
- [SCStreamConfiguration.showMouseClicks](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showmouseclicks)：由流的创建者配置。
- [AVCaptureScreenInput.capturesCursor](https://developer.apple.com/documentation/avfoundation/avcapturescreeninput/capturescursor)：即使不绘制指针，输出仍可包含鼠标位置和按键状态元数据。
- [CGDisplayHideCursor](https://developer.apple.com/documentation/coregraphics/cgdisplayhidecursor(_:))：一般需要前台应用才能影响光标。本项目同时用真实捕获验证 AppKit 的后台限制。
- [NSCursor.frameResize](https://developer.apple.com/documentation/appkit/nscursor/frameresize(position:directions:))：macOS 15 起提供窗口边缘和角落缩放光标；macOS 14 使用水平／垂直回退。
