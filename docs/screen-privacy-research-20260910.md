# Wisp 的 macOS 屏幕隐藏能力与验证方案

## 结论

**Wisp 目前的窗口隐藏方式在本机多条捕获路径中有效，但不能兑现“本机仍可操作，其他人通过任何渠道都看不到 App”的无条件承诺。** 这次扩展测试没有发现普通稳定显示阶段的内容泄漏，却确认了验证范围和保证范围之间的差别：窗口仍可枚举；菜单栏和系统预览不等同于 App 自己的窗口；一种录制方式通过，不代表另一种方式已经通过。

不需要第二台物理设备才能继续验证。独立进程的 ScreenCaptureKit 截图、连续视频、动态过滤器更新、直接窗口捕获、系统原生区域视频，以及旧捕获 API，都可以在当前 Mac 上做有阳性对照的测试。第二台设备的主要价值是验证真实会议接收端和远程接管当前会话，尤其是确认应用版本、共享来源、网络接收链路和最终渲染都符合预期。

当前策略不是唯一做法。另有原生受保护视频图层、捕获端过滤后的专用共享窗口，以及共享前停止本机显示等路线。它们改变了保护对象和工作方式。没有发现一种可直接替换现有开关、同时覆盖任意录屏软件、系统缩略图、管理员访问、外接采集和摄像机拍屏的通用 macOS API。

**严格优先级应落实为：保护状态未知时不把敏感内容输出到不受控的共享来源。** 如果还要求敏感内容继续显示在原始物理屏幕上，就必须接受相应信任边界；增加轮询频率或连续截图自检无法消除这一限制。

## 保护对象与验收边界

“看不到”至少有四种不同含义。把它们混成一个布尔值，会让测试和产品承诺失真。

| 对象 | 可验证方式 | 当前结论 |
| --- | --- | --- |
| 聊天、输入、上下文等窗口像素 | 捕获结果的实际像素对照 | 本机合成窗口与所测路径通过；不等于所有真实交互通过 |
| App 的存在、窗口名称和进程身份 | 窗口枚举、共享来源列表 | 不隐藏；本次直接窗口测试仍能取得目标窗口 |
| 系统绘制的图标、预览、弹窗 | 单独测试系统表面 | 不受同一窗口保护标记完整覆盖 |
| 文件、辅助功能内容、模型服务收到的数据 | 独立的数据访问和传输审计 | 不属于窗口像素保护，不能由开关推导安全结论 |

物理摄像机拍摄屏幕、外部硬件接收显示信号，不经过 Wisp 可以控制的窗口捕获接口。允许的人在本机看到内容时，软件无法证明现场没有另一台相机。同用户进程或管理员读取数据，也不是窗口隐藏可以阻止的行为。应把“会议观众只看到被允许的内容”与“任何人不能发现 App 存在”分开验收。

当前已安装版为 `8828c76`；本次研究和改动保留在工作区，没有再次替换 Applications，也没有新建提交或推送。

## Apple 原生能力

### NSWindow.sharingType

Apple 在线文档将 `.none` 描述为旧常量，并明确要求不要用它作为阻止捕获的手段，而指向 FairPlay Streaming。[^1] 当前本机 SDK 的头文件仍保留较旧的“其他进程不能读取”描述；在线文档与头文件的表述有差异，因此既不能依据头文件许诺全局保护，也不能忽略实际测得有效的捕获路径。

合理定位是保留其兼容效果，同时要求像素验证。`.sharingType == .none` 只能证明请求被设置，不能证明外部录制结果已经隐藏。Electron 的官方文档说明其 macOS 内容保护也设置这个属性，并提醒较新的 ScreenCaptureKit 应用可能仍捕获窗口；换成 Electron 不会自动获得更强的系统保证。[^2]

Apple 论坛的一个具体案例报告了 ScreenCaptureKit 初始排除窗口、刷新过滤器后又出现窗口的行为。Apple DTS 要求提交复现项目调查，而没有给出通用修复。[^3] 本次专门加入相应过滤器切换测试；本机没有复现该案例，不能因此推断其他系统版本也不会出现。

### AVSampleBufferDisplayLayer.preventsCapture

这是另一条真实存在的公开原生路径。Apple 将其定义为视频显示图层的捕获保护属性，本机 SDK 与官方 API 数据均显示 macOS 10.15 起可用。[^4]

本次创建了一个始终保持普通可读窗口状态的视频窗口，只改变视频图层的 `preventsCapture`。关闭时合成洋红视频可捕获；开启后，在所测截图、视频及直接窗口捕获中洋红内容消失。此实验说明它可以保护本机测试中的视频内容，**不是整个窗口或任意 SwiftUI 子视图的保护开关**。

将 Wisp 的聊天画面转成视频帧还需独立设计：原始 SwiftUI 内容不能同时作为可见底层出现；文本输入、输入法候选、选择菜单、复制、快捷键、滚动和辅助功能必须逐项处理；渲染器失败时必须停止显示，不能回退成普通明文视图。它可能把远端内容变成黑块，而非展示背后的桌面。当前实验没有证明视频保护模式下本机交互、每一帧更新、显示器变化或崩溃恢复满足这些要求，因此没有接入生产聊天界面。

### FairPlay Streaming

Apple 官方推荐方向保护的是 HLS 流媒体的传输和播放，涉及内容加密、密钥交换及服务器实现。生产部署凭据还有申请条件。[^5] 这可以解释受保护影片为何具有不同的捕获行为，却不是给聊天窗口添加一行代码即可启用的 App 级 DRM。不能把普通视频图层实验等同于已经实现 FairPlay。

### SCContentFilter

此 API 控制**创建该 SCStream 的捕获方**可以输出哪些显示器、应用和窗口。[^6] Wisp 可以用它排除自己的窗口或用户黑名单，但是不能替 Zoom、Teams 或其他进程设置它们的捕获过滤器。

因此，从“我的截图里排除了 Wisp”推导“Zoom 的共享也一定排除了 Wisp”是无效的。可控的另一种架构是先生成经过过滤的共享画面，再让会议软件分享那一份画面。保证仍绑定到这个输出来源，而不是原始桌面。

### 自动检测和停止显示

本次没有找到一个可证明“所有外部录屏都尚未开始”的受支持公共 API。常见的 `CGDisplayIsCaptured` 属于旧的显示器捕获／占用接口且已经弃用，不能拿其名称当作现代会议录屏探测器。[^7]

即使能观测一部分录制状态，发现录制已经开始后再隐藏也存在先后顺序：第一帧可能已被获取。看门狗、自检截图、定时清空窗口适合故障发现，不能提供零泄漏证明。一次自检成功只能说明那次采样的那条捕获路径，而无法约束另一进程稍后换用的捕获方式。

## 相似 Mac 应用与可借鉴内容

以下是来源中描述的实现方向，不是本次对这些产品的兼容认证；没有安装它们、运行它们的二进制或复制其代码。

| 产品／项目 | 作者描述的方式 | 对 Wisp 的意义 | 限制 |
| --- | --- | --- | --- |
| GhostLayer | Flutter + Swift 浮层，隐私模式设置 `.sharingType = .none` | 证明 Wisp 使用的是常见原生浮窗路线 | 使用相同标记不构成更强的保证；README 承诺不能替代实测[^8] |
| Unshown | 用 macOS 应用排除过滤器生成独立 Protected Share 窗口 | 可借鉴“本地桌面”与“会议输出”分开的架构 | 必须共享该专用窗口，分享原始显示器会绕过保护；官网列出尚无认证的会议宿主[^9] |
| Mica | 隐藏本机应用窗口、菜单栏等；作者描述用私有 `CGSIsScreenWatcherPresent` 检测捕获 | 可借鉴“共享前收起内容”的工作流和状态恢复设计 | 用户自己也看不到被隐藏窗口；私有信号不是全路径保证，不宜作为严格模式的唯一判据[^10] |

不能根据外观、营销词或“使用同样机制”得出某个闭源 App 拥有特殊系统权限。更有价值的借鉴是它把可信边界放在哪里：自己的窗口、视频层、自己生成的共享输出，还是直接停止显示。

## 本机深度测试

### 环境与控制方法

测试执行于 2026-09-10，macOS 26.6.1（25G76）、Apple Silicon、单显示器。研究矩阵由两个独立进程组成：一个创建合成窗口，另一个进行捕获。没有调用模型、读取账号凭据或把屏幕内容发送到网络。

四个窗口分别为始终可见的青色控制窗口、使用生产 `ScreenPrivacy.apply` 的面板、使用同一保护逻辑的普通设置窗口，以及始终可枚举而仅保护视频层的视频窗口。可见组和隐藏组逐项比较。每个窗口取内部区域做颜色统计；因此结论覆盖这些被采样内容，不能扩展成边框、标题、阴影或任意单像素都绝对不存在。

矩阵工具的完整桌面帧只在内存中处理，JSON 只保存统计；系统区域视频只存在于随机临时路径，分析后删除。旧表面探针仍会把测试窗口矩形裁剪保存到本机临时目录；隐藏组裁剪可能包含底层桌面内容，所以没有把这些图片放进仓库。仓库中的证据均为统计 JSON。

### 捕获矩阵结果

| 路径 | 关闭保护的内容标记 | 开启保护的内容标记 | 控制窗口 | 判定 |
| --- | --- | --- | --- | --- |
| SCK 整屏截图，不排除任何窗口 | 面板、设置、视频均可见 | 三者均为 0 | 可见 | 所测内容通过 |
| SCK 截图，包括所有应用 | 同上 | 同上 | 可见 | 所测内容通过 |
| SCK 截图，不排除任何应用 | 同上 | 同上 | 可见 | 所测内容通过 |
| SCK 截图，包括所有窗口 | 同上 | 同上 | 可见 | 所测内容通过 |
| SCK 连续视频，从第一种过滤器切换到其他三种 | 各阶段均可见 | 采样帧内容标记为 0 | 每帧可见 | 本次过滤器转换通过 |
| SCK 直接指定目标窗口截图 | 目标均可见 | 内容标记为 0 | 可见 | 内容通过，窗口仍可枚举 |
| 系统 `screencapture -v` 两秒区域视频 | 5 个采样时点均可见 | 5 个时点内容标记为 0 | 每个时点可见 | 所采样时点通过 |

A/B 校验器共检查 **114 组采样**，报告 `PASS_SAMPLED_PATHS`，不把这一标签写成全平台安全认证。系统视频抽样时点为 0.2、0.6、1.0、1.4、1.8 秒；没有声称检查了该电影的每一个编码帧。SCK 只统计 `.complete` 帧，其他帧状态不是被证明安全的画面。

校验器另外做了三种人为反例：去掉控制色块、去掉视频帧、向隐藏目标注入 `0.000001` 比例的标记。前两种判为 `INCONCLUSIVE`，最后一种判为 `LEAK`，不会因采集失败或空数据报成功。

原始证据：[可见组](evidence/screen-privacy-20260910/matrix-visible.json)、[隐藏组](evidence/screen-privacy-20260910/matrix-hidden.json)、[汇总](evidence/screen-privacy-20260910/summary.json)。

### 气泡、sheet、菜单与旧捕获路径

现有表面探针重新执行 A/B。SCK、`CGWindowListCreateImage` 和 `CGDisplayCreateImage` 三条路径都产生有效数据。可见组的主窗口、气泡、sheet 和菜单检测到约 0.150、0.389、0.292、0.863 的标记比例；隐藏组相应比例均为 0。旧 API 只用于诊断探针，不加入生产实现。

有一个 alert 表面在可见组也没有标记，故不能把它在隐藏组为 0 当作通过。系统菜单当前在本机没有被捕获，但仍不代表 App 能给所有菜单窗口设置保护。菜单栏状态项也不应由这些结果推断不可见。

新增挂载保护后，探针的气泡在 `.show()` 返回时、sheet 在 `beginSheet` 返回时，隐藏组均已是 `.none`；关闭组均为 `.readOnly`。这是窗口构造时机的验证，不是高帧率录像的首帧零泄漏证明。

原始证据：[表面可见组](evidence/screen-privacy-20260910/surfaces-visible.json)、[表面隐藏组](evidence/screen-privacy-20260910/surfaces-hidden.json)。

### Mission Control 与仍未覆盖的场景

历史报告已经发现普通设置窗口在 Mission Control 的系统预览中暴露过，并记录 `.transient` 等属性调整未能解决。[^11] 本次额外记录了 Mission Control 全屏标记比例，但没有把每个缩略图分离定位，没有足够证据判定该缺口消失。该项明确排除在矩阵通过结果之外。

仍未验收：完整 Wisp 的所有开关窗口／拖动／缩放动画、Space 切换、多显示器与热插拔、不同 macOS 版本、第三方远程桌面当前会话、其他会议接收端，以及受保护视频层的完整交互。此前 Zoom 接收端成功是实际使用环境的有效记录，不能替代这些项目。

## 不使用第二台设备的验证方法

1. **独立进程捕获矩阵。** 当前已实现。与在 Wisp 内给自己截图相比，它不会误用 Wisp 自己的排除列表作为外部保护证明。
2. **原生录像回放。** 系统录制一个只包含合成测试区域的短片，关掉测试窗口再检查输出；必须有关闭保护的对照影片。
3. **浏览器真实 `getDisplayMedia` 预览。** 使用仓库现有本地测试页，在系统选择器中选择整个显示器；核对 `displaySurface=monitor`。只共享标签页会天然排除桌面浮窗，不能用作整屏隐藏证明。
4. **同机两个浏览器上下文的本地 WebRTC 回环。** 可以检验发送帧编码到接收显示的过程，不需要把真实屏幕上传。它仍不等于 Zoom 原生客户端的实现；本次没有新增运行这一项。
5. **虚拟机作为第二端。** 在宿主机上通过独立系统和账户连接宿主当前会话，可减少对第二台物理设备的需求，但需要 VM、网络与交互授权的明确配置，本次未安装或配置。第二个登录会话不是当前会话的替代对照。
6. **实际会议程序的本地预览或本地录制。** 有助于确认所选来源，最终观众画面仍以真实接收端为最强证据。

以前 VNC 测试得到的是登录／独立会话画面，连可见对照窗口也没出现。这证明的是会话隔离，不能记为 Wisp 隐藏成功。[^11] 无论是虚拟机还是另一台电脑，都必须先在关闭隐藏时看见同一个测试窗口，才有资格继续验证隐藏组。

## 严格隐藏的产品设计

### 建议优先实现可控制的共享输出

专用共享输出应只接收已通过过滤的帧。输出窗口可以被会议软件捕获，但其像素中不得包含 Wisp 私有界面。启动默认空白；过滤器创建成功、指定来源明确且收到有效帧后才输出。发生来源变化、过滤更新失败、停止、睡眠或重连时，先清空输出，不允许回退到未过滤桌面。

代价是共享操作必须选择专用输出窗口。对于强制全桌面共享或选择错误来源的场景，它不能提供保证。这个代价应直接体现在产品命名和操作说明中，而不是藏在“已保护”状态后面。

### 原始桌面的严格模式

如果要求任意外部捕获都不能取得内容，同时允许本机也不可用，那么唯一不依赖未知录制方是否遵守标记的显示策略，是**在暴露风险出现之前不显示敏感内容**。不能先显示一帧再检测，也不能仅把一个透明遮罩盖在仍可独立捕获的窗口上。

这类模式应关闭所有敏感表面，并阻止快捷键、重新打开 App、设置链接、sheet、popover、恢复窗口和异步回调再次显示内容。恢复显示需要明确切换模式，而不是一个可能漏报的“没有发现录屏”信号。它仍不隐藏进程、文件和已经复制出去的信息，也不证明此前内容没有被捕获。

本轮没有收到对“本机也停止显示”的明确选择，因此没有把已安装 App 自动变成不可用状态。严格模式是待选择的产品行为，不是已经完成的功能。

### 视频图层路线

可作为单独实验分支继续实现：先只显示无交互的合成／只读内容；在每次渲染、尺寸变化和错误路径中保持保护属性；没有安全渲染能力时不显示。再逐项加入输入和辅助功能验收。通过当前色块实验只能批准继续研究，不能直接批准替换所有聊天窗口。

### 不应采用的“保证”

不要把 `.none`、某个监控进程不存在、某次截图为空、VM 中看到登录界面、或一款 App 的营销文案转换成“绝对不可见”。不要通过隐藏进程、注入会议软件或修改系统安全设置来假装拥有全局保护能力。这些做法既改变威胁模型，也不会解决物理捕获问题。

## 本次交付改动与验证

生产代码为四类 SwiftUI 辅助表面添加 `ScreenPrivacyWindow`：通用信息气泡、上下文详情、耗时详情、许可说明 sheet。它复用已有 AppKit 挂载回调，在内容进入窗口时应用当前隐藏偏好，减少仅依赖后续 `NSWindow.didUpdateNotification` 的时机缺口。Apple 提供 `viewDidMoveToWindow()` 来处理视图进入新窗口层级的时机。[^12]

没有修改会议程序，也没有把私有录屏探测 API 放入生产代码。没有宣称 Mission Control 缺口已修复。隐藏关闭时仍保持原有可录制行为。

新增 `CaptureMatrixProbe.swift` 与 `validate-matrix.py`，扩展现有表面和生命周期探针。生命周期检查 **9 项通过**，包括视图转移到新窗口时在显示前重新应用保护；XCTest **69 项通过，0 失败**，覆盖窗口／界面行为、响应模式及截图范围。结果包在 `/private/tmp/wisp-privacy-popover-final.xcresult`。

复现矩阵（会短暂显示合成色块；需要已有屏幕录制权限）：

```sh
swiftc -parse-as-library -module-cache-path /private/tmp/wisp-privacy-cache \
  Wisp/Support/ScreenPrivacy.swift tools/screen-privacy/CaptureMatrixProbe.swift \
  -o /private/tmp/wisp-capture-matrix
/private/tmp/wisp-capture-matrix visible /private/tmp/wisp-visible.json
/private/tmp/wisp-capture-matrix hidden /private/tmp/wisp-hidden.json
python3 tools/screen-privacy/validate-matrix.py \
  /private/tmp/wisp-visible.json /private/tmp/wisp-hidden.json
```

两组必须顺序执行，显示器、缩放和桌面环境保持一致。退出码 0 表示所列采样路径通过；1 表示测到目标标记；2 表示控制缺失或数据不足。`mission-control` 参数仅用于探索，不能被上述校验器认证。多显示器当前明确拒绝运行，避免默默测错屏幕。

## 来源

以下在线资料均在 2026-09-10 检索。产品资料代表作者对当前版本的描述；Apple API 文档代表受支持接口的公开说明；本地实测只代表本报告的方法与环境。

[^1]: Apple, [NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)。正文同时从官方文档 JSON 核对，不能只看 SDK 头文件旧注释。
[^2]: Electron, [BrowserWindow.setContentProtection](https://www.electronjs.org/docs/latest/api/browser-window#winsetcontentprotectionenable-macos-windows)。
[^3]: Apple Developer Forums, [ScreenCaptureKit sample initially omits application with NSWindowSharingType NSWindowSharingNone](https://developer.apple.com/forums/thread/808016)，2025 年 11 月；包含开发者复现与 DTS 回复，反馈编号 FB21115847。
[^4]: Apple, [AVSampleBufferDisplayLayer.preventsCapture](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture)。平台可用性同时核对本机 Xcode SDK 的 AVSampleBufferDisplayLayer.h。
[^5]: Apple, [FairPlay Streaming](https://developer.apple.com/streaming/fps/)。
[^6]: Apple, [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)。
[^7]: Apple, [CGDisplayIsCaptured](https://developer.apple.com/documentation/coregraphics/cgdisplayiscaptured(_:))。
[^8]: HelithaSri, [GhostLayer repository](https://github.com/HelithaSri/GhostLayer)，作者 README 的 Privacy Mode 说明。
[^9]: Unshown, [产品与兼容说明](https://unshown.vercel.app/)、[安全边界](https://unshown.vercel.app/security)。
[^10]: Vedant-29, [Mica repository](https://github.com/Vedant-29/mica)，How it works 与 Known limitations。
[^11]: Wisp, [历史全表面审计](screen-visibility-audit-20260907.md)与[历史屏幕共享验证](screen-privacy-validation.md)，2026-09-07。本地项目证据，并非 Apple 认证。
[^12]: Apple, [NSView.viewDidMoveToWindow](https://developer.apple.com/documentation/appkit/nsview/viewdidmovetowindow())。
