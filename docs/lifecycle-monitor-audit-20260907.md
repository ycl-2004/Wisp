# 界面生命周期与监控完整性测试

2026-09-07（America/Vancouver），分支 `feat/risk_test`，提交 `9295d3ba4acdf20ae672fc3a03034f106bfb56ff`。

初次审计结论：**部分验证完成，不能给三类要求整体通过。** 初次审计只增加脚本和证据；后续修复见下节。没有启动模型 CLI、调用模型服务或改变系统授权。

## 后续修复（同分支）

已修复 browser.html 的异常处理：意外 ended 显示报警并释放流；主动停止单独标注；mute 立即标注捕获源不可用；unmute 后等待新帧；每 500ms 检查帧更新时间，超过 3 秒没有预览帧则报警。增加独立的 aria-live 报警区域（role=alert），历史日志不再承担当前状态显示。停止、离开页面会清理计时器和帧回调，尚未完成的共享选择请求即使晚返回，也会立即释放轨道。

焦点仍仅记录。后台状态标为待确认，回前台需新帧；不支持帧回调的浏览器也标待确认。**新帧到达不等于内容新鲜**：捕获源可能持续输出重复旧内容，静态页面也可能不产生帧。此实现检查呈现帧进度，不做图像相同即冻结的判断；状态始终要求用共享源可见变化复核内容，不能充当完整的远程监控判定器。页面被浏览器挂起期间无法执行本地报警，真正独立的监控端仍需要自己的心跳/超时机制。

验证：合成事件和单调时钟测试 **22/22 通过**；真实无头 Chromium 149.0.7827.55 使用本地 CanvasCaptureMediaStream，通过首次帧、缺帧超时、恢复、合成 ended 四阶段，0 页面脚本错误；AppKit 生命周期复跑 **8/8 通过**。App Debug 构建及全量 XCTest **32/32 通过，0 失败**，结果包 `/private/tmp/wisp-monitor-fix-tests-retry.xcresult`；执行的是合成 fixture，不调用已安装的模型 CLI。OS 真实授权撤销、多显示器、Space 切换仍不在这些测试覆盖内。

修复后证据：[事件回归](evidence/browser-integrity-fixed-20260907.json)、[真实浏览器运行](evidence/browser-runtime-fixed-20260907.json)。初次失败 JSON 保留，以下初次审计表格不改写成通过。

```sh
node tools/screen-privacy/BrowserIntegrityAudit.cjs
# 环境需已安装 Playwright 及 Chromium；必要时用 NODE_PATH 指向已有 node_modules。
node tools/screen-privacy/BrowserRuntimeAudit.cjs
```

媒体事件依据：[W3C Media Capture](https://www.w3.org/TR/mediacapture-streams/#life-cycle-and-media-flow)；呈现帧检测依据：[requestVideoFrameCallback 规范](https://wicg.github.io/video-rvfc/)。

## 原始要求与覆盖

| 要求 | 本轮验证 | 状态 |
| --- | --- | --- |
| 打开设置、弹窗、切换桌面和显示器时不意外泄露 | 生产 ScreenPrivacy + 合成 AppKit 窗口；8 项生命周期检查；可见/隐藏组各一次、三条捕获路径 | 部分覆盖；真实设置 UI、动画中间帧、Space 切换和显示器切换未测 |
| 捕获失败、授权撤销、冻结、断流明确报警，缺失画面不能算正常 | 执行仓库 browser.html 的脚本，注入媒体错误、ended、mute，检查缺帧监测注册 | 3 项通过、3 项失败；不代表任何外部监控产品 |
| 正常应用切换、通知、辅助功能作为误报对照，不仅凭失焦判违规 | 注入 blur/focus，确认只记日志、保留预览 | 合成焦点事件通过；真实应用切换、通知和辅助功能操作未测 |

仓库没有独立监控/违规判定服务。用户尚未指定外部监控应用或网页，因此外部接收端的报警和误报率无法验证。

## 窗口生命周期与像素结果

`Probe.swift lifecycle` 退出 0，8/8：启动时已有窗口、关闭隐藏恢复、挂载尊重关闭偏好、重新开启更新已有窗口、首次显示前挂载保护、晚创建窗口通知兜底、开关不改变输入/位置/可见性、关闭覆盖晚创建窗口。

`SurfaceProbe.swift` 编译自本分支的 `ScreenPrivacy.swift`；设置替身隔离已安装 Wisp 的偏好、凭据和会话。可见组和隐藏组均退出 0。初次沙箱内运行报 `permissionRequired` 并退出 133；同一可执行文件在沙箱外成功，故这不是一次真实的系统授权撤销测试。

三条路径：ScreenCaptureKit、CGWindowListCreateImage、CGDisplayCreateImage。后两条由现有探针动态解析旧接口。隐藏组 5 个区域的标记比例均为 0。可见组中，4 个区域的比例为 0.150–0.865，构成有效阳性对照；另一个区域在全部路径中也是 0，**该区域无结论，不能算隐藏成功**。它对应本次 fixture 中最先创建的 popover 窗口（visible window 43111 / hidden window 43125），可能被其他表面遮挡。

Popover 和 sheet 创建后立即读到的 sharingType：隐藏组均为 0，可见组均为 1。该读数证明窗口属性设置时机，不证明捕获端首帧无泄露。菜单虽在本次捕获中没有标记，但不在应用保护可达的窗口集合内，仍无代码保障。菜单栏图标位于屏幕外，不能做像素判断。

本次截图是稳定状态采样，不是连续动画录像；也没有打开用户实际 Wisp 设置窗口。旧报告已记录设置型窗口在 Mission Control 中泄露标记的情况，见 [历史报告](screen-visibility-audit-20260907.md#mission-control-例外)。本轮未重新运行 Mission Control，不能把旧证据当成新测试，也没有证据说明该缺口已修复。

## 浏览器探针异常注入

`BrowserIntegrityAudit.cjs` 使用 Node VM 执行当前 `browser.html` 的原始脚本，提供合成 DOM 和媒体对象。不需要浏览器或录屏权限，不上传画面。退出 1 表示发现不满足要求的断言。

| 检查 | 结果 | 观察 |
| --- | --- | --- |
| getDisplayMedia 拒绝 | 通过 | 明确记录 NotAllowedError，不显示共享进行中 |
| 意外 ended 清除预览 | 通过 | srcObject 置空，记录共享已停止 |
| 区分意外结束与用户停止 | 失败 | 两者共用 end，只记录共享已停止，没有异常原因 |
| mute 提示不可用 | 失败 | 无处理器，日志仍停留在共享进行中 |
| 注册缺帧监测 | 失败 | 没有 timer 或帧回调监测；此项是机制检查，未模拟真实冻结时长 |
| blur/focus 不直接判违规 | 通过 | 只记录 window blur / focus，不清除预览 |

因此不能用这个页面证明持续监控完整性：共享流存在并不代表持续收到有效画面。页面没有“正常/违规”分类器，所以也不能声称它已经把缺失画面判成正常；能观察到的是缺失相关报警和状态更新。

生产 Wisp 则是按需截图助手，不是持续监控端。代码检查显示 ContextCapture 对无权限添加 blocking 提示、对其他截图失败添加说明，ContextHeaderView 显示“无截图”；本轮没有执行生产采集错误路径，不能据此声称运行时报警通过。

## 证据与复现

- [生命周期及捕获原始 JSON](evidence/lifecycle-audit-20260907.json)
- [浏览器合成事件结果](evidence/browser-integrity-20260907.json)
- 本机裁剪图片：`/private/tmp/wisp-lifecycle-visible/`、`/private/tmp/wisp-lifecycle-hidden/`；未加入仓库，因为隐藏组可能含窗口下方的桌面内容。

从仓库根目录运行：

```sh
swiftc -parse-as-library -module-cache-path /private/tmp/wisp-lifecycle-module-cache \
  Wisp/Support/ScreenPrivacy.swift tools/screen-privacy/Probe.swift \
  -o /private/tmp/wisp-lifecycle-probe
/private/tmp/wisp-lifecycle-probe lifecycle

swiftc -parse-as-library -module-cache-path /private/tmp/wisp-lifecycle-module-cache \
  Wisp/Support/ScreenPrivacy.swift tools/screen-privacy/SurfaceProbe.swift \
  -o /private/tmp/wisp-lifecycle-surface-probe
/private/tmp/wisp-lifecycle-surface-probe visible /private/tmp/wisp-lifecycle-visible
/private/tmp/wisp-lifecycle-surface-probe hidden /private/tmp/wisp-lifecycle-hidden

node tools/screen-privacy/BrowserIntegrityAudit.cjs
```

初次审计未运行全量 XCTest；后续修复已运行并通过 32 项，见上节。未验证真实通知、辅助功能、授权撤销、冻结、Space 动画、多显示器和第三方监控端。后续需明确监控产品及测试会话，并提供显示器切换条件，才能完成剩余验收。
