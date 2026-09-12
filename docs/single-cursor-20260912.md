# 单光标修复与录屏交互验证（2026-09-12）

本次修复替代此前的“共享静止箭头 + 本机移动箭头”方案。开启隐私光标锁定后，Wisp 只绘制一个本机私有箭头；兼容录屏中省略指针。本机保留输入光标、文字选区、菜单选中状态等编辑提示。

## 原因与修复

原来的静止箭头是一个真实的共享窗口，不是录屏专用图层。透明面板或面板移动会让它在本机露出来，与移动箭头并存。现在删除该窗口，先隐藏系统指针，再显示唯一私有箭头；退出时先撤掉箭头，再释放 Wisp 自己的隐藏计数。

私有箭头附属于普通宿主窗口，宿主隐藏时同步消失。关闭、最小化、停用、切换宿主、离开窗口和关闭开关都会清理箭头。临时菜单的子窗口排序由 AppKit 管理。

连续录屏还发现 AppKit 的菜单跟踪会发出一次未配对的 `NSCursor.unhide()`，抵消 Wisp 的隐藏计数，导致真实鼠标与私有箭头同时出现。现在区分本进程的原生隐藏计数与 Wisp 私有计数：原生配对调用照常执行，菜单不能提前释放 Wisp 的那一次隐藏。菜单之后关闭锁定的系统指针恢复也单独验证。

输入事件仍交给原生控件；没有抑制、重放或拦截其他应用的全局输入。本机文字选区、插入光标和菜单状态保持可见，自定义按钮按压特效继续遵循隐私光标开关。

## 本机验证范围

环境：macOS 26.6.2（25G83），单显示器。录制对象是合成内容；窗口隐藏、光标、按钮样式、拖动和缩放使用生产源文件。录屏端是独立进程，启用 `showsCursor`，没有排除任何应用或窗口。

- 透明窗口连续录屏：480 个采样帧；开／关对照各 15 帧。锁定时所有检测像素均为应当露出的青色背景，未发现系统鼠标或私有窗口内容。连续帧检查没有第二个分离鼠标图形。
- 原生点击、输入、文字选区、滚动、下拉菜单、拖动缩放共六阶段，分别 4／8／17／9／21／31 帧，均未出现界面变化；原生状态确认一次按钮动作、`cursor test` 输入、11 字符选区、菜单第二项、滚动和窗口移动缩放成功。
- 本机光标窗采样分别 528／504／498 次，未发现两个私有光标窗；录屏中隐藏系统指针与本机可见的私有窗状态相互交叉验证。此检查不等于摄像机对每一帧本机合成结果的证明。
- 关闭锁定和菜单操作后的恢复对照中，系统鼠标重新可见；本机私有箭头已撤掉。系统 `screencapture` 视频也通过可见背景与指针的正反对照。
- 后台／前台切换：401 个连续帧；关闭／后台悬停／激活锁定／恢复分别 15／15／14／14 帧。后台保留真实指针，激活后才替换。
- 自定义 Press、Icon、Plain 三种按钮的开启／关闭对照共 6 组，按住时像素行为符合开关，每次动作恰好执行一次。
- 验证器拒绝 11 种人为注入的错误，包括双鼠标、内容泄露、彩色选区泄露、无正对照、操作失败和系统鼠标无法恢复。

最终 XCTest 25／25 通过（13 项光标、9 项非音频、3 项窗口测试）。录屏端主动开启点击高亮时，40 个锁定帧中有 27 帧出现附加像素，验证器按预期拒绝通过，说明外部点击圆圈仍是实际限制。

已使用证书签名的 Universal2 Release 替换并启动 `/Applications/Wisp.app`，版本 0.4.0（6）。严格签名验证通过，安装二进制与当前构建一致，未包含调试器 entitlement。实际设置界面已打开，窗口隐藏与隐私光标锁定均为开启。旧包保存在 `/var/folders/bj/_6886nzd0rd2f4vvw_2bdq7h0000gn/T/wisp-install-backup.Xxa34U/previous-Wisp.app`。

完整摘要及源文件哈希见 [证据摘要](evidence/single-cursor-20260912.json)。原始本机文件保存在 `/private/tmp/wisp-single-cursor.7AFr2v/`，属于临时诊断文件，不包含真实聊天内容。

## 复现

需要已有屏幕录制与事件发送权限。测试会短暂切换到合成窗口并恢复原前台应用与鼠标位置，运行时不要同时操作鼠标。

```sh
probe_dir="$(mktemp -d /private/tmp/wisp-cursor-check.XXXXXX)"
swiftc -O -parse-as-library -module-cache-path "$probe_dir/cache" \
  Wisp/Support/ScreenPrivacy.swift Wisp/Support/LocalCursorController.swift \
  Wisp/UI/DesignKit.swift Wisp/UI/PanelResize.swift \
  tools/screen-privacy/LocalCursorProbe.swift -o "$probe_dir/probe"
"$probe_dir/probe" run "$probe_dir/native" --translucent --feedback
python3 tools/screen-privacy/validate-cursor.py "$probe_dir/native/result.json" --feedback --self-test
"$probe_dir/probe" run "$probe_dir/activation" --nonkey
python3 tools/screen-privacy/validate-cursor.py "$probe_dir/activation/result.json"
```

逐帧图像分析需使用优化编译 `-O`，否则测试进程本身可能处理不过来。独立系统视频包含启动开销，因此使用两秒片段；连续 ScreenCaptureKit 流不丢弃切换时的帧。

## 不能承诺的部分

录屏软件可以独立绘制点击圆圈、按键提示或传输指针位置。这些由录屏端控制，Wisp 无法关闭；本功能也不清除其他应用的行为记录。系统托管的输入法候选、菜单栏、其他进程弹窗和硬件采集不在 Wisp 控制范围。尚未逐一验证 Zoom、Meet、Teams、OBS、浏览器共享等接收端。

Apple 将 [`NSWindow.SharingType.none`](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none) 列为旧机制，并明确不保证它可以防止内容被捕获。此次实测支持当前机器和上述捕获路径，不支持“所有录屏永远不可见”的声明。录屏创建者可独立设置 [`showMouseClicks`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showmouseclicks)。
