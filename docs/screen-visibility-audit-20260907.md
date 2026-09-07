# 全表面可见性体检

测试日期：2026-09-07。环境：macOS 26.6.1，Apple Silicon，Xcode 26.6，单显示器 3024×1964 像素。

目标是回答一个问题：**别人在录屏、截屏、共享屏幕或远程看这台机器时，能不能看到 Wisp。**
上一轮验证的是助手面板这一个窗口，这一轮把 Wisp 会创建的每一种可见表面都拉出来单独测。

本地数据没有做任何隐藏处理：Spotlight 仍然索引对话文件，你自己搜得到，功能照常。

## 结论

日常使用路径（唤起助手 → 输入 → 发送 → 看回答）在测过的每一条捕获路径上都不出现。
有三个例外，两个可见、一个只是没有代码保障：

| 缺口 | 严重度 | 说明 |
| --- | --- | --- |
| 菜单栏图标 | 会被看到（已给出开关） | 系统绘制，`.none` 请求对它无效，任何录屏都会拍到。本轮新增「在菜单栏显示图标」开关，关掉即不存在 |
| 设置窗口 + Mission Control | 会被看到 | 按 F3 时设置窗口出现在 Mission Control 画面里，助手面板和药丸不会 |
| 菜单窗口 | 当前不可见 | 实测拍不到，但没有任何代码给它设过标记，属于系统行为 |

## 表面清单

探针进程编译自生产文件 `Wisp/Support/ScreenPrivacy.swift`，创建各类表面后，由另一个进程用
`CGWindowList` 枚举**该进程的全部在屏窗口**，逐个裁剪比对捕获图像。这样"没有任何保护路径覆盖到"的
表面不会从统计里漏掉。

| 表面 | 是否在 `NSApp.windows` 中 | 隐藏开启时的 `sharingType` | 隐藏组标记像素 | 结论 |
| --- | --- | --- | --- | --- |
| 助手面板 | 是 | 0（`.none`） | 0 | 保护有效 |
| 药丸 | 是 | 0 | 0 | 保护有效（上一轮已单独验证） |
| 设置窗口 | 是 | 0 | 0 | 普通捕获下有效，Mission Control 例外（见下） |
| popover | 是 | 0（首帧即为 0） | 0 | 保护有效 |
| sheet | 是 | 0（首帧即为 0） | 0 | 保护有效 |
| alert | 是 | 0 | 无有效样本 | 靠"是 `NSApp.windows` 成员"成立；像素标记在对照组也没渲染出来 |
| 菜单（右键菜单 / 菜单栏下拉） | **否**（layer 101） | 无法设置 | 0 | 拍不到，但无代码保障 |
| 菜单栏图标 | 窗口对象在，但设置不生效 | **1（`.readOnly`）** | 未能观测 | 系统合成，`.none` 无效 |

对照组（关闭隐藏）在同样位置分别测到 0.150、0.389、0.292、0.863 的标记比例，证明捕获链路确实
看得见这些表面，不是因为拍空了才得出 0。

## 捕获路径

同一组窗口在三条路径上同时测量，隐藏组全部为 0，对照组全部可见：

| 路径 | 谁在用 | 隐藏组 | 对照组 |
| --- | --- | --- | --- |
| ScreenCaptureKit | 现代录屏、会议软件、浏览器共享 | 0 | 0.150–0.863 |
| `CGWindowListCreateImage` | 旧录屏与远程控制工具（当前 SDK 已标为不可用，运行时仍可调用，故用 dlsym 调用） | 0 | 0.150–0.865 |
| `CGDisplayCreateImage` | 旧远程控制工具 | 0 | 0.150–0.865 |
| `screencapture` 系统截图 | 系统截图快捷键 | 0 | 可见 |
| 浏览器 `getDisplayMedia` | Meet / Zoom 网页版 / 在线监考 | 0 | 可见 |

后两条是上一轮的结果，见 [屏幕共享隐藏验证](screen-privacy-validation.md)。

## Mission Control 例外

Mission Control 由系统绘制，它画的窗口内容不遵守 `sharingType`。同一次隐藏组测量中：

| 窗口配置 | Mission Control 画面中的标记像素 |
| --- | --- |
| 无边框浮动 `NSPanel`（助手面板、药丸） | 4（噪声量级） |
| 普通标题栏 `NSWindow`（设置窗口） | 2181 |

对照：两个窗口在关闭隐藏、不开 Mission Control 时分别为 238968 和 237006 像素；隐藏开启、不开
Mission Control 时都是 0。也就是说，隐藏本身有效，是 Mission Control 这一层绕过了它。

三种改法都试过，都无效：`collectionBehavior = [.transient, .ignoresCycle]`（2181）、
`level = .floating`（2181）、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`（2145）。
差别来自窗口类型本身，把设置窗口改造成无边框非激活面板才可能规避，代价是失去标题栏和标准窗口行为。

**实际影响**：设置窗口只在你主动打开设置时存在。共享屏幕时不要一边开着设置窗口一边按 F3。
助手面板和药丸不受影响。

## 菜单栏图标

状态项的应用侧窗口即使在 `ScreenPrivacy.applyToAllWindows()` 之后，`sharingType` 仍然是 1
（`.readOnly`）——请求没有生效；它也不出现在本进程的 `CGWindowList` 窗口里，说明像素由系统合成。
结论：**菜单栏图标无法用现有机制隐藏**。

像素级验证在本机没能完成：探针的图标被系统放到了屏幕外（frame 原点 x = −4227），因为菜单栏没有空位；
检查时前台又是全屏应用，菜单栏本身被系统隐藏了。所以这一条的依据是窗口层面的两个事实，不是一张对照图。

## 本轮的修复：菜单栏图标开关

既然图标无法隐藏，就让它可以不存在。设置 → 屏幕共享里新增「在菜单栏显示图标」，默认开。

关掉后的入口：全局快捷键不受影响（它不经过菜单栏）；面板头部会多出一个齿轮按钮，只在
图标隐藏时出现，所以默认界面不变；药丸的右键菜单也一直有设置入口。

这一项只做了编译和测试验证（Debug、Release 均退出 0，20 项测试通过），**没有做运行时验证**：
需要重启 Wisp 才生效，而本轮全程没有启停已安装的 Wisp。请在重启后自己确认一次：关掉开关 →
菜单栏图标消失 → 快捷键仍能唤起面板 → 面板齿轮能回到设置。

## 顺带清掉的死代码

全量 clean build 零编译警告。另外扫出三个定义了但全仓无人调用的函数，已删除：

- `ScrollDriver.requestTrust()` —— 弹辅助功能授权提示的旧路径；实际 UI 走的是 `isTrusted` 检查加
  「去授权」按钮跳系统设置，这个函数从未被调用。
- `PromptBuilder.estimateTokens()`
- `ConversationStore.remainingTurns(in:)`

删除后全量 XCTest 20 项通过、0 失败，Debug 与 Release 构建均退出 0。

## 仍未验证

- **macOS 内置屏幕共享，当前会话那一半**。已经测了一半，见下节；能连上的那条路径看不到当前桌面，
  真正的"别人接管我的会话"没测到，**因此不能声称那种场景下 Wisp 不可见**。
- 第三方远程控制（TeamViewer、AnyDesk、向日葵等）各自的捕获实现。
- 切换 Space、Mission Control 动画过程中的中间帧、多显示器。
- 系统授权弹窗（由系统进程绘制，Wisp 无法设置）、硬件采集卡、用手机拍屏幕。

## 内置屏幕共享（VNC）实测到哪一步

开启系统设置里的屏幕共享并设临时 VNC 密码后，用自写的最小 RFB 客户端
（`tools/screen-privacy/VNCFrameProbe.swift`，密码走 stdin，不进命令行参数）连本机 5900 端口：

| 观察项 | 结果 |
| --- | --- |
| 服务器提供的认证方式 | `[30, 33, 36, 31, 32, 2, 35]` —— 只有 2 是标准 VNC 密码，其余是 Apple 私有类型 |
| 用类型 2 连上后的画面 | 3024×1964，99% 非黑，内容是**登录/锁屏界面**，不是当前桌面 |
| 同一时刻屏幕上的测试窗口（隐藏已关闭） | 本机 `screencapture` 测得 239034 / 237006 像素，VNC 画面里 **0** |

结论：**VNC 密码连进来的人拿到的是一个独立登录会话**，看不到当前桌面上的任何东西——包括终端、
浏览器，当然也包括 Wisp。这是 macOS 的会话隔离，不是 Wisp 的隐藏机制在起作用，两者不要混为一谈。

「Anyone may request permission to control screen」那条流程走的是 Apple 私有认证类型
（30/33/35/36），标准 RFB 客户端接不上；接管当前会话需要账号密码，本轮没有使用，也不打算使用。
所以**"别人用你的账号远程接管、看着你的桌面"这个场景仍然没有验证**，要测只能用第二台设备连进来，
由人在那块屏幕上判断。

## 复现

```sh
swiftc -parse-as-library -module-cache-path /private/tmp/wisp-privacy-module-cache \
  Wisp/Support/ScreenPrivacy.swift tools/screen-privacy/SurfaceProbe.swift \
  -o /private/tmp/wisp-surface-probe

# 各类表面 × 三条捕获路径
/private/tmp/wisp-surface-probe visible /private/tmp/wisp-surface-visible
/private/tmp/wisp-surface-probe hidden  /private/tmp/wisp-surface-hidden

# Mission Control 对照（左洋红=面板配置，右青色=设置窗口配置）
/private/tmp/wisp-surface-probe fixture hidden missioncontrol &
sleep 2.5; open -a "Mission Control"; sleep 2.5; screencapture -x /private/tmp/mc.png
open -a "Mission Control"; kill %1
```

结果 JSON：[surface-visibility-20260907.json](evidence/surface-visibility-20260907.json)。
隐藏组的裁剪图可能包含窗口下方的桌面内容，因此只保留在本机临时目录，不进仓库。
