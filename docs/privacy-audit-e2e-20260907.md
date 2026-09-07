# 端到端隐私审计

测试日期：2026-09-07。环境：macOS 26.6.1，Apple Silicon，Xcode 26.6。所有验证使用合成数据，
没有调用任何模型 CLI，也没有把真实屏幕内容发给任何服务。

这份文档覆盖「按下快捷键 → 采集 → 提取 → 传输 → 回答 → 落盘」这条链路上 Wisp 自己控制的部分。
屏幕共享隐藏的像素级验证是另一件事，见 [屏幕共享隐藏验证](screen-privacy-validation.md)。

## 结论与范围

本轮收敛的是**Wisp 能控制的泄漏面**：HTTP 传输的持久化状态、非本机明文传输、本地存储目录权限、
默认联网行为、以及编进日常构建的诊断入口。收敛后的行为已用单元测试和构建产物比对验证。

本轮**不能**证明：整机不可观测、操作系统与浏览器不留痕、第三方服务不留存、CLI 工具自身的
网络与日志行为。这些在下面「残余边界」里逐条写明。全屏兜底截图这一既有行为按决策保留，没有改动。

## 暴露面清单（调用 → 回答）

| 环节 | 涉及数据 | 出口 | 本轮处理 |
| --- | --- | --- | --- |
| 唤起与采集 | 目标窗口图像；无匹配窗口时整屏兜底 | 进程内存 | 未改动；行为在 PRIVACY.md 中改写为准确表述 |
| 页面提取 | 当前标签页 URL、标题、选中文本、正文 | `osascript` Apple Events + 注入脚本 | 未改动；页面临时收集器的清理在上一轮已修复并有回归测试 |
| 直连 API 传输 | 提问、页面正文、截图、近期对话 | `OpenAICompatibleProvider` | 改为 ephemeral 会话（无缓存 / 无 Cookie / 无 HTTP 凭据存储）、拒绝重定向、远端强制 HTTPS |
| Ollama 探测 | 模型列表请求 | `OllamaSupport` | 同上；`localhost`、`127.0.0.1`、`::1` 的 HTTP 仍然可用 |
| 更新检查 | 版本号请求（IP + `Wisp/<版本>` UA） | `AppLifecycle` | 同上；注册默认值改为**关闭** |
| CLI 集成 | 提问与截图 | `claude` / `agy` 走 argv，`codex` 走 stdin，截图写入临时工作目录 | 未改动实现；在 PRIVACY.md 中明确 argv 可被同机进程观察 |
| 本地落盘 | `conversations.json`、调试文件 | `~/Library/Application Support/Wisp` | 目录强制 `0700`（含已有安装）；目录保护失败时**放弃写入**而不是降级写明文 |
| 日志 | — | — | Wisp 自身没有 `os_log` / `NSLog` / `print` 调用点（0 处） |
| 诊断入口 | 截图 + 整页正文写到固定路径；可被任意本地 App 远程触发 | `--dump-context`、`--show`、`--render-*` | 从 `#if DEBUG` 收紧为 `#if DEBUG && WISP_DIAGNOSTICS`，日常 Debug 构建也不再包含 |

## 本轮改动与验证

| 改动 | 验证方式 | 结果 |
| --- | --- | --- |
| 远端强制 HTTPS，回环地址仍允许 HTTP | `PrivacyTransportTests` 逐个断言 URL 构造 | HTTPS、`localhost`、`127.0.0.1`、`[::1]` 通过；远端 HTTP、局域网 IP、URL 内嵌用户名密码、带 query 的 Base URL 被拒 |
| 传输不落任何持久状态 | 断言 `URLSessionConfiguration` 的 cache / cookie / 凭据存储 | 三者均为 nil，`httpShouldSetCookies=false`，缓存策略为 `reloadIgnoringLocalCacheData` |
| 拒绝重定向 | 用合成 307 响应驱动 `PrivateAPIRedirectPolicy` | 转发请求为 nil，私有 POST 不会被转到另一个主机 |
| 只发往配置的地址 | 用 `URLProtocol` 拦截的合成端点跑一次 `validate` | 命中 `https://api.example.test/v1/chat/completions`，方法为 POST，携带预期 Authorization，无 Cookie / Referer |
| 已有目录也收紧到 `0700` | 先建 `0755` 目录并写入文件，再调 `ensurePrivateDirectory` | 权限变为 `0700`，文件内容不变；本机实际支持目录实测为 `drwx------` |
| 诊断入口不进日常构建 | 三种构建的产物做字符串对照 | 标准 Debug 与 Release 中 `--dump-context`、`com.yichenlin.Wisp.show` 均不存在；带 `WISP_DIAGNOSTICS` 的构建中两者存在 |
| 门控代码本身仍可编译 | 用 `SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG WISP_DIAGNOSTICS"` 构建 | BUILD SUCCEEDED，说明这是开关而不是死代码 |
| 网络出口没有遗漏 | 全仓搜索传输相关 API | 只有三处调用点，全部走 ephemeral 配置与拒绝重定向；无 `URLSession.shared` 残留，也没有 WKWebView / Network.framework / 裸 socket |
| 整体没有回归 | 全量 XCTest | 20 项通过、0 失败、0 跳过（新增 `PrivacyTransportTests` 5 项） |
| 构建未被破坏 | Debug 与 Release 构建 | 均 exit 0（`CODE_SIGNING_ALLOWED=NO`） |

Xcode 26 把 Debug 代码放进 `Wisp.debug.dylib`，所以 Debug 的字符串对照要查这个 dylib，查主可执行文件会得到
「三种构建都不存在」的假阴性。带 flag 的构建在这里的作用是阳性对照：它证明检查方法本身能发现这些入口。

原始结果见 [证据 JSON](evidence/privacy-audit-e2e-20260907.json)，测试结果包在
`/private/tmp/wisp-privacy-e2e-20260907.xcresult`。

## 残余边界

- **同用户进程与管理员。** `0700` 挡的是本机其他账户，不挡以你的身份运行的任何进程、管理员、
  备份软件，也不追回此前已经复制出去的副本。`conversations.json` 仍是明文 JSON。
- **CLI 比直连 API 的边界宽。** Claude Code 和 AGY 目前通过 argv 接收提问，同机进程可以观察到；
  Codex 走 stdin，但用的是你自己的 CLI 配置。CLI 自身的日志、hook、集成与网络行为不在 Wisp 控制内。
- **操作系统与浏览器。** 系统网络日志、浏览器焦点事件、页面脚本与滚动行为可能被外部观察到，
  本轮改动不影响这些。
- **服务方。** 你配置的服务或网关如何记录、保留、转发请求，由它们自己的策略决定。拒绝重定向意味着
  会重定向的网关需要你直接配置最终地址，它并不能阻止网关在服务端把请求转发给上游。
- **更新检查偏好保留。** 新的注册默认值是关闭；`UserDefaults.register(defaults:)` 只填补未显式
  设置过的键，因此已有的显式选择会保留。本机没有该键的显式值，所以这条是语义层面的确认，
  不是在带显式值的机器上跑出来的实测结果。
- **屏幕共享。** 与上一轮一致：窗口仍可被 `SCShareableContent` 枚举，系统授权弹窗、动画 / Space
  切换、多显示器和第三方录屏工具仍未逐项验证，也不构成任何监考系统的结论。

## 复现命令

```bash
# 全量测试（合成数据，不调用任何模型 CLI）
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

# 两种标准构建
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Release CODE_SIGNING_ALLOWED=NO build

# 诊断构建（阳性对照，产物不要用于日常使用）
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Debug \
  CODE_SIGNING_ALLOWED=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG WISP_DIAGNOSTICS" \
  SYMROOT=/tmp/wisp-diagbuild build

# 字符串对照
strings -a Build/Debug/Wisp.app/Contents/MacOS/Wisp.debug.dylib | grep -F -e '--dump-context'
strings -a Build/Release/Wisp.app/Contents/MacOS/Wisp | grep -F -e '--dump-context'
strings -a /tmp/wisp-diagbuild/Debug/Wisp.app/Contents/MacOS/Wisp.debug.dylib | grep -F -e '--dump-context'
```
