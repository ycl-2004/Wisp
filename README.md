<p align="center">
  <img src="Design/App_Icon_Mac_Master.png" alt="Wisp app icon" width="120" height="120">
</p>

<h1 align="center">Wisp</h1>

<p align="center">
  <strong>一个按需读取当前屏幕和浏览器上下文的原生 macOS AI 助手。</strong>
</p>

<p align="center">
  <a href="https://github.com/ycl-2004/Wisp/releases/latest"><img src="https://img.shields.io/github/v/release/ycl-2004/Wisp?label=release&color=111111" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-111111?logo=apple&logoColor=white" alt="macOS 14.0 或更高版本">
  <img src="https://img.shields.io/badge/Mac-Universal%202-111111?logo=apple&logoColor=white" alt="Apple Silicon 和 Intel 通用版本">
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%C2%B7%20AppKit-F05138?logo=swift&logoColor=white" alt="使用 SwiftUI 和 AppKit 构建">
</p>

<p align="center">
  <a href="https://github.com/ycl-2004/Wisp/releases/latest/download/Wisp-macOS-universal.zip"><strong>⬇ 下载 macOS 版本</strong></a>
  ·
  <a href="https://github.com/ycl-2004/Wisp/releases">Releases</a>
  ·
  <a href="#features">功能</a>
  ·
  <a href="#privacy">隐私</a>
  ·
  <a href="#build-from-source">从源码构建</a>
</p>

Wisp 住在菜单栏里。按下 `⌃⌥Space`，它会在浮窗出现前记住当前应用，然后按需读取当前窗口截图；如果当前是浏览器，还会读取网址、标题、选中文字和整页正文。你只需要问问题，不需要复制粘贴上下文。

它是一个本地优先的桌面壳：对话文字和页面文字快照保存在 Mac 上，截图只在内存里停留到本轮请求结束。模型请求由你选择的 OpenAI-compatible 接口、Ollama 或 Codex CLI 处理。

> **当前发布状态：** `v0.1.0 (build 3)`。公开包是 Universal 2（`arm64` + `x86_64`）的 ad-hoc 签名版本，尚未 Apple notarize。首次打开时可能需要 Control-click → **Open**。当前仓库公开，但还没有选择开源许可证。

## Quick start

1. 从 [Releases](https://github.com/ycl-2004/Wisp/releases/latest) 下载 `Wisp-macOS-universal.zip`，解压后把 `Wisp.app` 移到 `~/Applications` 或 `/Applications`。
2. 第一次打开时 Control-click `Wisp.app`，选择 **Open** 并确认。因为当前包未 notarize，普通双击可能被 Gatekeeper 拦截。
3. 在系统设置中允许 **屏幕录制**。第一次读取浏览器时，再允许 Wisp 控制对应浏览器的 **Automation**。
4. 点击菜单栏里的 Wisp 图标 → 设置 → 模型，选择一种模型接法并点 **保存并测试连接**。
5. 切回想提问的窗口，按 `⌃⌥Space`。

如果右键菜单里没有 **Open**，可以在终端移除当前 App 的 quarantine 标记：

```bash
xattr -dr com.apple.quarantine "$HOME/Applications/Wisp.app"
open "$HOME/Applications/Wisp.app"
```

### System requirements

- macOS 14.0 或更高版本。
- Universal 2 包可以在 Apple Silicon 和 Intel Mac 上启动；本次发布在 Apple Silicon 机器上完成了两个架构切片检查，尚未在 Intel 实机上运行回归。
- 屏幕截图需要 **系统设置 → 隐私与安全性 → 屏幕录制** 权限。
- 浏览器整页文字需要 **Automation** 权限，以及浏览器自己的 `Allow JavaScript from Apple Events` 开关。
- 使用云端接口需要网络和你自己的 API Key；Ollama 需要本机服务；Codex CLI 需要本机已登录的 Codex CLI。

## Why Wisp

- **上下文在提问之前就准备好。** 浮窗出现前先记录目标应用，避免浮窗自己被读进去。
- **看得见这次会发送什么。** 头部两行会显示当前应用、网页地址、截图／正文状态和对话计数。
- **按需读取，不常驻录屏。** 常驻药丸只跟踪当前应用，不截图，也不跑浏览器脚本；真正采集发生在唤起、切换应用或发送前。
- **模型接法由你决定。** 可以把请求发给任意 OpenAI-compatible 服务，也可以完全在本机使用 Ollama，或复用已登录的 Codex CLI。
- **对话可控。** 对话数量和每个对话的轮数都有上限，删除由用户触发，不做隐形的时间淘汰。

## Features

**屏幕和浏览器上下文**

- 捕获当前前台应用的窗口截图；截图默认只在内存中保存。
- 支持 Chrome、Brave、Edge、Vivaldi、Yandex Browser、Opera、Safari、Arc 及其部分稳定／测试版 bundle ID。
- 浏览器可读取当前网址、页面标题、选中文字和整页正文。
- 记录跨域 iframe 的地址与读不到正文的原因，避免模型误以为内容完整。
- 浏览器没有开启 JavaScript 或当前应用不受支持时，明确退回到“网址／截图”边界。

**浮窗和常驻药丸**

- 菜单栏应用，没有普通 Dock 主窗口。
- 主浮窗默认从紧凑小卡片开始，发送时向上展开；内容区在有限高度内滚动。
- 浮窗支持拖动、调整大小、Esc 收起和离开后自动收起。
- 常驻药丸显示当前应用和上下文状态；支持底部 Dock 上方或刘海位置。

**模型接法**

- **云端接口：** 使用 `chat/completions`、SSE 和 `image_url`，适配 OpenAI、OpenRouter 及其他兼容服务。
- **Ollama 本地：** 默认连接 `http://localhost:11434/v1`，模型清单从本机 Ollama 读取，并标记可读图的模型。
- **Codex CLI：** 调用本机 `codex exec --json --ephemeral --sandbox read-only`，不在 Wisp 对话目录里写会话文件。

**本地对话**

- 默认最多保留 10 个对话，每个对话最多 30 轮；两个上限都可以在设置里调整。
- 历史消息中最近 2 轮保留完整上下文，更早的上下文折叠成摘要行。
- 页面正文默认上限为 60,000 字，超过后保留开头 75% 和结尾 25%。
- 对话保存为可读的 JSON；设置页可以删除全部对话与 API Key。

## Usage

### 一次提问

```text
⌃⌥Space
  ↓ 记住当前前台应用
  ↓ 截图；浏览器同时读取网址、标题和整页正文
  ↓ 显示浮窗，并在头部标明本轮上下文
  ↓ 提问 → 请求发送到当前选择的模型接法
  ↓ 回答完成；关闭浮窗后对话仍保存在本机
```

### 快捷键和操作

| 操作 | 默认行为 |
| --- | --- |
| `⌃⌥Space` | 唤起／收起浮窗，可在设置中更改 |
| `⌘↩` | 发送 |
| `⌘.` | 停止生成 |
| `Esc` | 收起浮窗 |
| 头部 `∧`／`∨` | 在紧凑小卡片和展开面板之间切换 |
| 头部 `↻` | 重新读取当前上下文 |
| 点击「截图」 | 开关本轮截图 |
| 点击 `ⓘ` | 查看本次采集的说明 |
| 点击左侧气泡 | 打开对话列表 |

Wisp 会在三种时机自动刷新上下文：唤起浮窗时、浮窗打开期间切换到其他应用时、以及发送前发现上次采集已超过 20 秒或用户离开过浮窗时。回答生成中不会自动重读。

### 选择模型

打开菜单栏图标 → 设置 → 模型：

- **云端接口**：填写 Base URL、模型名和 API Key。Key 存在 macOS 钥匙串，不写进对话 JSON。
- **Ollama 本地**：先启动 Ollama，再刷新模型清单。只有视觉模型能理解截图。
- **Codex CLI**：选择已检测到的 `codex`，可选模型；它会使用你的 Codex 登录状态。

三种接法都提供 **保存并测试连接**。云端和 Ollama 的测试会发送一张很小的测试图片；Codex CLI 只检查 `codex --version` 能否正常执行。

## Screenshots

这些图片由当前构建中的离线渲染入口生成，不包含真实桌面、真实对话或个人文件。头部截图使用模拟的 Chrome 页面信息；右侧模型菜单因 SwiftUI `Menu` 不支持离线 ImageRenderer，已从图片中裁去。

<table>
  <tr>
    <td align="center"><strong>上下文头部</strong><br><img src="docs/screenshots/context-header.png" alt="Wisp 显示 Chrome、网址、截图和正文状态的上下文头部" width="680"></td>
  </tr>
  <tr>
    <td align="center"><strong>常驻药丸的闲置、悬停和生成中状态</strong><br><img src="docs/screenshots/island-states.png" alt="Wisp 常驻药丸的闲置、悬停和生成中三种状态" width="520"></td>
  </tr>
</table>

生成命令：

```bash
Build/Release/Wisp.app/Contents/MacOS/Wisp --render-header docs/screenshots/context-header.png
Build/Release/Wisp.app/Contents/MacOS/Wisp --render-island docs/screenshots/island-states.png
```

## Privacy

**本地保存**

- 对话文字和页面文字快照：`~/Library/Application Support/Wisp/conversations.json`。
- API Key：macOS 钥匙串，不在 Wisp 支持目录中保存。
- 截图：默认只存在内存中，作为本轮请求的图片附件；不会写入对话 JSON。
- 可选调试文件：只有在设置中打开调试时，才会写入 `debug/last-context.json` 和 `debug/last-screenshot.jpg`。

**网络边界**

- OpenAI-compatible 接法会把你选择的上下文和本轮截图发到你配置的 Base URL。服务端的日志、留存和隐私政策由该服务决定。
- Ollama 默认请求 `localhost`，但如果你把 Base URL 改成远程地址，数据也会发往那个地址。
- Codex CLI 由 Wisp 启动本机 Codex 进程；Wisp 创建临时目录放置图片，使用 `--ephemeral` 和只读沙箱，命令结束后删除该临时目录。Codex 自身的网络、账号和服务端日志不在 Wisp 控制范围内。
- Wisp 没有自己的账号、同步服务、分析 SDK 或后台持续录屏逻辑。

**权限**

- 屏幕录制：用于当前窗口截图。
- Automation／Apple Events：用于向支持的浏览器读取网址、标题和执行页面 JavaScript。
- 网络客户端：仅在你使用云端接口、远程 Ollama 或 Codex 自身需要联网时使用。

## Current release

当前版本为 `0.1.0 (build 3)`，对应 Git tag `v0.1.0`。

| Artifact | 用途 |
| --- | --- |
| `Wisp-macOS-universal.zip` | 同时包含 `arm64` 和 `x86_64` 的 macOS App |
| `Wisp-macOS-universal.zip.sha256` | ZIP 的 SHA-256 校验值 |

本次 Universal 包通过 `lipo -info` 检查包含两个架构；发布验证在 Apple Silicon 机器上完成。当前包为 ad-hoc signed、未 notarized，因此首次启动可能需要 Control-click → **Open**。

## FAQ

<details>
<summary>macOS 提示无法验证 Wisp 的开发者，怎么办？</summary>

当前公开包没有 Apple notarization。Control-click `Wisp.app`，选择 **Open** 并确认一次；如果没有 Open 选项，运行 [Quick start](#quick-start) 里的 `xattr` 命令。

</details>

<details>
<summary>为什么浏览器只有截图，没有整页正文？</summary>

确认三件事：Wisp 有 Automation 权限；对应浏览器配置文件打开了 `Allow JavaScript from Apple Events`；当前页面不是浏览器内部页面（例如 `chrome://`）。Chrome 的 JavaScript 开关按配置文件分别保存，每个配置文件都要单独打开一次。跨域 iframe 的正文仍可能读不到，只能依赖截图。

</details>

<details>
<summary>Wisp 会不会一直录屏？</summary>

不会。常驻药丸只跟踪当前应用；截图发生在唤起浮窗或刷新上下文时。回答完成后，截图数据不会写入 Wisp 的对话文件。

</details>

<details>
<summary>怎样完全卸载？</summary>

退出菜单栏中的 Wisp，把 `Wisp.app` 移到废纸篓。若还要删除本地对话、设置和调试文件，可删除：

```text
~/Library/Application Support/Wisp/
```

API Key 还需要在 Wisp 设置的「数据」页中点击 **删除全部对话与 API Key**，或从 macOS 钥匙串中删除对应项目。

</details>

## Build from source

<details>
<summary>要求、构建命令和 Universal 2 打包</summary>

要求：

- macOS 14.0 或更高版本。
- Xcode 26.6（当前验证环境）或能提供 macOS 14 SDK 的兼容版本。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45.4 或更高版本，用来从 `project.yml` 重新生成 Xcode 工程。
- Swift Package Manager 会解析 `KeyboardShortcuts` 2.4.0。

普通本地开发构建：

```bash
xcodegen generate
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Debug build
cp -R Build/Debug/Wisp.app "$HOME/Applications/"
```

如果你的机器没有项目中记录的开发团队或签名身份，可以在本地 Xcode 中换成自己的 Team，或用于检查编译时加上：

```bash
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

构建 Universal 2 Release：

```bash
rm -rf Build
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Release \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES build

mkdir -p dist
lipo -info Build/Release/Wisp.app/Contents/MacOS/Wisp
ditto -c -k --sequesterRsrc --keepParent \
  Build/Release/Wisp.app \
  dist/Wisp-macOS-universal.zip
shasum -a 256 dist/Wisp-macOS-universal.zip > dist/Wisp-macOS-universal.zip.sha256
```

`lipo -info` 应该显示 `arm64` 和 `x86_64`。Apple 的 [Universal macOS binary 文档](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)说明，Universal binary 会包含两个原生架构；在 Apple Silicon 上可以用 Rosetta 运行 `x86_64` 切片，但 Intel 实机回归仍应单独完成。

Release 前建议核对：

```bash
plutil -p Build/Release/Wisp.app/Contents/Info.plist
codesign --verify --deep --strict Build/Release/Wisp.app
unzip -l dist/Wisp-macOS-universal.zip
shasum -a 256 -c dist/Wisp-macOS-universal.zip.sha256
```

`codesign --verify` 在没有受信任的开发证书时可能报告本地证书信任问题；公开包使用 ad-hoc 签名，不代表已完成 Apple notarization。当前仓库没有自动化测试 target 或 CI workflow；已验证的核心检查是当前 Release 构建、App bundle 元数据、资源封装和 Universal 架构切片。

</details>

## Project layout

- `Wisp/App/` — App 入口、菜单栏、全局快捷键和诊断入口。
- `Wisp/Capture/` — 屏幕截图、浏览器 AppleScript、整页文字和上下文采集编排。
- `Wisp/LLM/` — OpenAI-compatible HTTP、Ollama、Codex CLI、SSE 解析和提示词组装。
- `Wisp/Store/` — 本地对话 JSON 和 macOS Keychain 封装。
- `Wisp/UI/` — 浮窗、常驻药丸、聊天、上下文头部、对话列表和设置。
- `Wisp/Support/` — 权限、屏幕几何和 UserDefaults 设置。
- `Wisp/Assets.xcassets/` — macOS AppIcon 全部尺寸。
- `Design/` — App icon 原图和 Mac master 图。
- `docs/screenshots/` — README 使用的当前离线渲染截图。
- `project.yml` — XcodeGen 的工程与版本配置源文件。
- `Wisp.xcodeproj/` — 可直接用 Xcode 打开的共享工程及 Swift Package 锁定文件。

## Versioning and releases

版本源在 `project.yml`：

- `MARKETING_VERSION`：用户可见版本，例如 `0.1.0`。
- `CURRENT_PROJECT_VERSION`：构建号，例如 `3`。

发布约定：

1. 从干净工作区生成工程并完成 Debug／Release 构建。
2. 用 `lipo -info` 确认 `arm64` 和 `x86_64`，再检查 bundle 签名、Info.plist 和 ZIP 校验值。
3. 创建 annotated tag `v<MARKETING_VERSION>`，例如 `v0.1.0`。
4. 将 `Wisp-macOS-universal.zip` 和对应 `.sha256` 上传到同名 GitHub Release。

`Build/`、`dist/`、Xcode 用户状态、诊断输出和本地环境文件不会进入 Git；源码、图标资源、工程文件、锁定依赖和公开文档会被跟踪。

## Known limitations

- 当前公开包 ad-hoc signed、未 Apple notarized；没有自动更新器。
- Universal 2 的 `arm64` 和 `x86_64` 切片已在本机生成并检查，但尚未在 Intel Mac 上完成运行回归。
- 非浏览器应用通常只有截图，没有整页文字。
- 跨域 iframe、浏览器内部页面和未允许 Apple Events JavaScript 的浏览器配置文件无法提供完整正文。
- Codex CLI 的回答是一次性返回，不是逐字流式；每次请求还会带上 Codex 自身的固定上下文成本。
- 本项目目前没有自动化测试、CI workflow 或公开的 notarization/release signing pipeline。
- 仓库当前没有 `LICENSE` 文件；公开可见不等于授予复制、修改、再分发或商业使用许可。

## License

当前项目尚未选择开源许可证。源码可以公开查看，但在添加明确许可证或获得作者书面许可前，不应复制、修改、再分发、重新品牌化或销售本项目及其图标、截图和其他素材。

## Links

- [GitHub repository](https://github.com/ycl-2004/Wisp)
- [Latest release](https://github.com/ycl-2004/Wisp/releases/latest)
- [Release assets](https://github.com/ycl-2004/Wisp/releases)
