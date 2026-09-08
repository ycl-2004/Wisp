# 用户界面文案检查

范围：菜单栏、药丸右键菜单、设置的 Model / Permissions / Data / General、模型切换和聊天头部提示。目标是缩短操作名称，将可选说明移入现有 ⓘ，保留错误、授权和不可撤销操作的必要信息。

本轮主要修改：

- 菜单栏：Hide from Capture，去掉 Try to hide…。
- 屏幕共享设置：保留两行开关及各自的 ⓘ，不常驻显示解释段落。
- 右键菜单：Refresh Context、Include / Exclude Screenshot。
- Startup：Launch at Login；固定的 Login Items → Manage… 入口。需要配置时显示 Setup Required，具体原因放入 ⓘ；执行失败仍直接显示。
- 其他操作：Scroll Capture、Reset Position、Exclude Current App、Save & Test、Refresh Models、Save Diagnostics、Back Up & Reset。
- 快捷键：静态帮助使用 ⓘ，正在录制时保留操作指引；权限警告保持可见。
- 模型帮助：移除过时的“Codex 一次性返回”和“只有 Claude 实时显示”说法，简化 CLI 实现描述。
- 存储帮助：移除“截图不会写入磁盘”的过度概括，保留本地存储说明；临时截图用途仍在模型帮助中说明。

沿用原生设置页和现有 InfoButton，没有改变采集、模型调用和登录项注册逻辑。中英文新增词条均已检查。旧词条留在本地化资源中，不代表仍在活动界面使用。

验证：最终 Debug 构建成功，日志 `/private/tmp/wisp-copy-polish-final-build.log`；本轮与上一轮新增的 34 个本地化词条均包含中英文；git diff --check 通过。本次没有新增单元测试，也没有重新运行与文案无关的模型测试。

限制：这是代码与构建检查，未逐页运行截图验收，也未替换正在运行的安装版本。不能声称所有运行时动态内容都已视觉验证。原始截图揭示的菜单和 Startup 问题已在代码中处理。
