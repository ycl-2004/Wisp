# 屏幕共享隐藏验证

2026-09-11 补充：[本地光标实验](#本地光标实验)在独立捕获进程中加入鼠标可见对照；同时验证原生点击、输入、选字、滚动、拖动和缩放。2026-09-10 补充：[原生能力研究与扩展捕获矩阵](screen-privacy-research-20260910.md)。新增独立进程过滤器切换、直接窗口截图、系统区域视频、受保护视频图层对照与辅助表面挂载检查；历史 Mission Control 与远程当前会话限制仍保留。

测试日期：2026-09-07。环境：macOS 26.6.1（25G76），Apple Silicon，Xcode 26.6（17F113），单显示器。

## 结论与范围

当前 `NSWindow.sharingType = .none` 在本机的原生捕获测试中有效：合成的面板、药丸和设置窗口的洋红色标记均未出现在整屏截图、视频帧或系统区域截图中；关闭隐藏后，三种窗口都能被捕获。**窗口仍能被 ScreenCaptureKit 枚举。**

测试编译并使用生产文件 `Wisp/Support/ScreenPrivacy.swift`，以只存在于内存的 `AppSettings` 替身代替真实偏好。创建窗口的进程与捕获进程分开，捕获器使用 `SCContentFilter(display:excludingWindows: [])`，没有主动排除测试应用。三个窗口模拟 Wisp 的窗口种类，不是完整的 Wisp UI。

因此，本报告证明的是这一环境下生产隐藏机制的效果，不能证明已安装 Wisp 的所有界面、动画或第三方录屏路径都不可见，也不能证明任何监考系统无法识别异常。

另外，已对已安装的 `/Applications/Wisp.app` 做了真实面板验证：面板保持在屏幕上时，ScreenCaptureKit 整屏截图和视频帧的对应裁剪区域只显示底层内容；同一浏览器测试页拿到真实 `getDisplayMedia` 整屏流后也看不到面板。临时关闭开关的 A/B 对照会在同一裁剪区域显示 Wisp 面板，随后已恢复开启。这个结果仍只代表当前 macOS、当前显示器和本地测试页，不是 CodeSignal 的审核结论。

## 本地光标实验

测试日期：2026-09-11。实验开关默认关闭，只有在窗口隐藏开关开启时才生效。Wisp 在面板内绘制当前 `NSCursor` 的图像并隐藏系统光标；鼠标事件不被拦截、不重放，也不移动系统指针。面板失活、鼠标离开 Wisp、打开原生菜单、关闭实验或应用退出时恢复系统光标。

独立合成窗口使用 `SCStreamConfiguration.showsCursor = true`，并分别运行关闭、开启、恢复三组。ScreenCaptureKit 截图和 15 帧视频、系统区域截图、系统区域视频均观察到：关闭时有鼠标像素，开启时鼠标像素为 0，恢复后鼠标像素重新出现。捕获使用的窗口排除仍保持开启，所以这证明的是“隐藏系统光标 + 隐藏 Wisp 窗口”在本机捕获链路的组合效果，不是对第三方会议软件的保证。

同一合成窗口中，原生按钮点击次数为 1，文本输入为 `cursor test`，选区长度为 11，滚动偏移为 140，窗口拖动和缩放均改变了 frame。实验报告保存在 `/private/tmp/wisp-local-cursor-capture-2/result.json`；只保存合成测试窗口的裁剪结果，不保存完整桌面。

浏览器 `getDisplayMedia` 探针已打开本地测试页面，但浏览器的系统共享选择器需要用户在当前机器上选择“整个屏幕”，本轮没有把未完成的浏览器选择器当作通过证据。Zoom、Meet、Teams、飞书、OBS、Screen Studio 和远程桌面仍未逐一验证。

## 实测矩阵

| 检查 | 隐藏关闭 | 隐藏开启 | 结论 |
| --- | --- | --- | --- |
| ScreenCaptureKit 整屏截图 | 三种窗口标记均可见 | 三种窗口标记均为 0 | 此路径隐藏有效 |
| ScreenCaptureKit 视频帧（每组 2 秒、21 个完整帧） | 每个窗口均为 21/21 帧可见 | 每个窗口均为 0/21 帧可见 | 稳定显示阶段隐藏有效 |
| 系统 `screencapture -R` 区域截图 | 三种窗口均可见 | 三种窗口均不可见 | 此路径隐藏有效；不等同于测试 `⌘⇧5` 视频录制 |
| `SCShareableContent.windows` 枚举 | 3/3 窗口存在 | 3/3 窗口存在 | 不隐藏窗口列表 |
| 窗口生命周期回归 | 共 8 项通过 | 覆盖开关两种状态 | 不能代替像素验证 |
| Chrome 152 的 `getDisplayMedia` 整屏共享 | A/B 中可见 | A/B 中不可见 | 本地页面拿到真实整屏流；不是 CodeSignal 审核结论 |
| 实际 Wisp 面板（已安装 Debug 版） | 同一裁剪区域出现面板内容 | 同一裁剪区域显示底层页面/共享提示 | 当前显示器、面板和浏览器流验证通过；窗口仍可枚举 |
| 实际 Wisp 全流程交互、菜单、popover、系统弹窗 | 面板唤起和进程运行已验证 | 面板、设置窗口、药丸均已单独验证 | 系统授权弹窗、动画/Space 切换仍未逐项验证 |
| CodeSignal、Zoom、Meet、飞书、Teams、OBS | 未执行 | 未执行 | 不做兼容性或审核结论 |

洋红色像素比例的精确结果保存在 [原始统计](evidence/screen-privacy-20260907.json)。关闭组原生截图比例约为 79%–84%，开启组均为 0。该对照确认捕获链路确实能看到测试窗口，避免把权限不足、空画面或错误坐标误判为隐藏成功。

原始裁剪图片与各组统计保存在本机临时目录：

- `/private/tmp/wisp-screen-privacy-visible-final/`
- `/private/tmp/wisp-screen-privacy-hidden-final/`

检查过关闭组面板视频帧、开启组设置视频帧和药丸系统截图：前者显示测试标记，后两者显示窗口下方的背景。完整桌面图像只在捕获进程内存中处理，保存到磁盘的只有测试窗口矩形区域；隐藏组的这些裁剪区域可能包含下方背景，因此不将图片加入仓库或上传。

## 本次代码与文档调整

1. 保留已经在本机测得有效的 `.none` 请求及其开关，不把官方警告解读为“所有环境中必然失效”。
2. 为 SwiftUI 设置内容添加 `ScreenPrivacyWindow`：视图挂载到窗口时即应用当前偏好，减少对后续 `didUpdateNotification` 的依赖。生命周期测试确认，在窗口还没被显示时标记已经设置。
3. 纠正观察器范围：它只收到本进程窗口通知，不能控制其他进程承载的系统授权弹窗。
4. 开关改为“尝试隐藏”，中英文说明明确区分开关状态与实际捕获结果。README、隐私政策、变更日志和代码注释同步去掉“所有工具都不可见”和“窗口列表没有 Wisp”的承诺。
5. 说明 Wisp 自身截图中的排除列表只影响它自己的捕获器，不能给 Chrome 等应用的捕获流设置过滤规则。
6. 普通页面正文采集结束后清理 `window.__wispCollector`，避免把采集正文留在 Chrome 当前页面的临时全局中；该路径有 XCTest 回归覆盖。

没有改变正常唤起、输入或模型调用流程。没有调用模型 CLI，也没有进入真实考试。本次把重建的 Debug 版覆盖安装到 `/Applications/Wisp.app`；原先版本可在 `/private/tmp/Wisp.app.backup-before-privacy-20260907` 恢复。

## 复现原生测试

项目验证：Debug 与 Release 构建均退出 0（`CODE_SIGNING_ALLOWED=NO`）。现有 XCTest 共 15 项通过，0 失败、0 跳过；结果包位于 `/private/tmp/wisp-privacy-tests-20260907-r3.xcresult`。字符串目录与结果 JSON 解析通过，浏览器测试脚本语法检查和 `git diff --check` 通过。这些检查不替代上面的实际捕获测试。

在仓库根目录运行；需要 Xcode 和已有屏幕录制权限。工具不会自行请求新权限，不使用 Wisp 的账号、偏好、对话或模型接口。

```sh
swiftc -parse-as-library \
  -module-cache-path /private/tmp/wisp-privacy-module-cache \
  Wisp/Support/ScreenPrivacy.swift tools/screen-privacy/Probe.swift \
  -o /private/tmp/wisp-screen-privacy-probe

/private/tmp/wisp-screen-privacy-probe lifecycle
/private/tmp/wisp-screen-privacy-probe visible /private/tmp/wisp-privacy-visible
/private/tmp/wisp-screen-privacy-probe hidden /private/tmp/wisp-privacy-hidden
```

两组按顺序运行，避免同时出现的测试窗口互相遮挡。执行时保持测试窗口所在显示器、缩放和桌面不变。工具针对本次单显示器环境编写，多显示器需先扩展显示器匹配和坐标逻辑，不应直接套用结果。

生命周期检查覆盖：启动时处理已有窗口、关闭后恢复读取、挂载尊重关闭状态、重新开启处理全部窗口、新视图挂载后在首次显示前应用标记、晚创建窗口的通知兜底、输入/尺寸/可见状态不被开关改变、关闭时包含后来创建的窗口。它不模拟真实键盘输入或模型生成，也不证明打开、拖动、缩放、切换 Space 的每一帧都无泄漏。

## 复现浏览器与实际 Wisp 验证

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory tools/screen-privacy
```

在 Chrome 前台打开 `http://127.0.0.1:8765/browser.html`，手动点击开始并选择“整个屏幕”。页面会校验 `displaySurface`，拒绝把窗口或标签页共享当成整屏测试。画面仅在当前页面预览，不上传、不保存；停止按钮、浏览器结束共享或关闭页面都会停止流。

最初通过自动点击返回过 `InvalidStateError`；保留页面诊断后，在共享状态持续存在时成功取得流。成功日志包含 `trustedClick=true`、`transientActivation=true`、`documentFocused=true`、`visibility=visible`、`secureContext=true`、`displaySurface=monitor` 以及 3024×1964 的帧尺寸。页面预览显示了 Wisp 面板隐藏/显示的 A/B 差异；数据只在本地当前页面预览，不上传、不保存。

已安装 `/Applications/Wisp.app` 的实际面板、设置窗口和药丸在隐藏状态下都保持 `onScreen=true`、`sharingState=0`，并且仍被 `SCShareableContent.windows` 枚举；对应的 ScreenCaptureKit 截图和 10 帧视频流裁剪均显示底层内容，没有 Wisp 像素。窗口级 `screencapture -l` 返回状态 1 且不生成文件。该组合说明“像素排除”与“窗口不可见/不可枚举”是两回事。

关于“Chrome 后台”：代码审计显示 `ChromeProfileInspector` 只读取 Chrome 的 `Local State`/`Preferences` 来判断 Apple Events 开关，未发现对 Chrome 配置、缓存或历史文件的写入路径；`BrowserTextExtractor` 通过 Apple Events 读取当前页信息，结果由 Wisp 自己处理。对本机 Chrome 用户数据做了只读关键词审计（`com.yichenlin.Wisp`、`hideFromScreenCapture`、`wisp-screen-privacy`、`WispCaptureProbe`，排除大型缓存目录），命中 0 个文件。这不能证明 Chrome 的屏幕录制端或 CodeSignal 后台不会记录 Wisp 的存在，也不应被当作监考规避保证。

系统授权弹窗、打开/关闭/拖动/缩放/Space 切换的每一帧，以及多个显示器仍未逐项验收；也没有在 CodeSignal、Zoom、Meet、飞书、Teams 或 OBS 中做兼容性测试。测试只使用本地无敏感内容页面；不能据此保证第三方审核系统不会把失焦、复制粘贴、代码相似度或其他行为作为信号。

## 官方依据与限制

- [Apple：NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none) 将其标为旧机制，并明确写道： “Don’t use this value to hide or omit content from being captured.” 本地有效与官方不提供可靠保证可以同时成立；不要按 macOS 大版本推定所有捕获路径一致。
- [Apple：ScreenCaptureKit 捕获示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) 说明内容过滤由捕获者配置，窗口枚举与画面捕获是不同操作。
- [Apple：viewDidMoveToWindow](https://developer.apple.com/documentation/appkit/nsview/viewdidmovetowindow()) 用于视图加入新窗口后的处理；不提供针对所有系统弹窗或录屏方式的保护保证。
- [W3C：Screen Capture](https://www.w3.org/TR/screen-capture/#dom-mediadevices-getdisplaymedia) 定义浏览器共享请求，网站不能仅凭调用参数保证用户选择的是整个显示器。

Wisp 的面板打开流程会主动激活应用。隐藏窗口像素不会撤销浏览器失焦、复制粘贴或代码提交等其他信号；本测试页的焦点日志只描述测试页自身事件，不代表 CodeSignal 的具体 telemetry 字段。

## 浏览器探针的异常状态

探针现在单独显示当前捕获状态：失败、意外断流和 mute 明确报警；超过 3 秒没有预览帧更新则警告无法确认画面。后台或缺少帧检测 API 时显示待确认，失焦只记日志。恢复必须等到新帧，不能仅凭轨道仍 live 判正常。连续重复旧图像无法仅靠帧回调识别，仍需在共享源产生可见变化后复核。页面被挂起时也无法保证即时报警。详见[修复与验证记录](lifecycle-monitor-audit-20260907.md#后续修复同分支)。
