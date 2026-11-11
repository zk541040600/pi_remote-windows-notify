# pi-notify 弹窗逻辑改进：10 轮记录

日期：2026-11-10（Asia/Shanghai）
基线：`fde445b`；改动基于与现有运行脚本匹配的独立仓库版本。
部署状态：**已部署并核验通过**，北京时间 2026-11-10 20:16:34。

## 结果与范围

本次围绕弹窗显示、激活、关闭、堆叠、热键和异常处理完成 10 轮实质修改。复用现有 broker、fallback 弹窗和来源专用激活逻辑，没有增加新的路由框架。5 个运行脚本合计增加 260 行、删除 715 行，净减少 **455 行**；新增行为回归单独统计。

运行脚本为 `NotifyBridge.Common.ps1`、`notify-listener.ps1`、`pi-notify-broker.ps1`、`pi-notify-popup.ps1`、`pi-notify-hotkey.ps1`，均在 `windows/` 下。

## 逐轮修改与验证重点

| 轮次 | 具体问题 | 修改与结果 | 验证重点 |
|---|---|---|---|
| 1 | 标签把通知原文中的 `&` 当成快捷键标记 | broker 与 fallback 的展示标签统一关闭 mnemonic 解析，保留会话名、标题和正文的字面内容 | 含 `&` 的文本及实际 Label 属性 |
| 2 | 点击后会话名称被“跳转中”替换，用户难以确认正在打开哪一条 | 保留原会话名称，使用现有应用名、标题和正文区域显示打开进度 | 激活反馈保留原会话名 |
| 3 | `DoEvents()` 的嵌套消息处理允许卡片关闭后继续入队激活；过期卡片也缺少入口检查 | 移除 `DoEvents()`，在激活前检查释放、关闭、终止、重复点击和剩余寿命；刷新后再次检查关闭状态 | 已释放、正在关闭、已终止、过期、刷新中关闭及重复点击均不启动新激活 |
| 4 | 单条请求的 `popupPlacement` 被读取，却没有用于实际定位 | 传递当前请求的 placement，共享工作区选择和坐标计算；broker 使用同一工作区结果计算容量与位置 | cursor、right、primary、大小写/空白归一化和无效值回退；负坐标工作区 |
| 5 | 小工作区仅钳制卡片 Y 坐标，导致多个槽位重叠；旧卡关闭失败仍可能被复用 | 按工作区高度和卡片高度限制显示容量，保留既有最旧卡片淘汰策略；冲突槽位重新分配；同目标或越界旧卡关闭失败时停止新增 | 不同工作区/卡片高度下不重叠；同目标复用、过载、失效槽位提示及关闭失败 |
| 6 | 超大秒数转毫秒可能超过 WinForms Timer 的整数范围，计时器与有效期也可能不一致 | 用一个共享函数把生命周期统一限制在 3000 至 Int32.MaxValue 毫秒；计时器、截止时间和 live-state TTL 使用同一结果 | 负值、0、正常值、整数边界和极大值 |
| 7 | broker 在一次 Tick 内无限清空请求队列，持续通知可能阻塞点击和关闭计时器 | 每个 Tick 最多处理 8 条，随后交回 WinForms 消息循环，下一 Tick 继续 FIFO | 混合 popup/close/activate 请求跨批次顺序一致；处理期间持续入队仍按 8 条让出 |
| 8 | 窗口预热缓存没有实际激活消费者；fallback 去重分支始终无效 | 删除死预热、无消费缓存、无调用选择函数、无效 fallback 去重和闲置参数，保留仍被使用的前台识别与来源激活链 | 无残留引用；现有路由、生命周期和 package 检查通过 |
| 9 | fallback 热键另起激活进程，无法完整复用弹窗已绑定的来源、重试和最终确认状态 | 热键通过进程与随机键对应的 named event 通知现有弹窗，复用点击处理；关闭时释放事件 | 三种既有来源的信号分发、重复信号、关闭后信号、进程归属与无效状态 |
| 10 | 复审发现旧卡关闭失败仍可能复用槽位、健康但无卡片的 broker 吞掉 fallback 热键、永久失败卡阻塞最旧卡片选择，以及日志异常中断回调 | 确认旧卡移除后才复用槽位；热键先查有效 live-state 再交给 broker；永久失败卡移出热键队列；listener、fallback 和 hotkey 的诊断 I/O 改为 best effort | 关闭失败、空 broker、失效卡跳过、同 Tick 关闭优先及锁日志回归；完整套件通过 |

第 10 轮独立审查针对第 5 轮的改动，额外复现了“旧卡未关闭但槽位已复用”的失败路径，最终修复检查 `ActivePopups` 中的旧卡是否确已移除，并补入两条行为断言。

## 实现结构

- `NotifyBridge.Common.ps1` 仅承载小型共享函数：生命周期边界、工作区选择、容量/位置计算和事件名称校验。
- broker 继续负责队列、卡片和槽位；通过固定批次保持 UI 响应，没有引入额外队列层或线程。
- fallback 与 broker 使用相同几何和寿命计算。热键只向已有卡片发出激活意图，由卡片自己的点击链决定是否执行。
- Pi Web、Paseo 与原有 Terminal 来源仍各走既有激活策略。没有新增跨来源猜测或回退，也没有把中间导航结果改成最终成功。

### 运行脚本行数变化

以下为本次基于 `git diff --numstat` 对 5 个运行脚本单独计算的结果，不含测试和文档。

| 文件 | 增加 | 删除 | 净变化 |
|---|---:|---:|---:|
| `windows/NotifyBridge.Common.ps1` | 47 | 0 | +47 |
| `windows/notify-listener.ps1` | 38 | 19 | +19 |
| `windows/pi-notify-broker.ps1` | 75 | 420 | -345 |
| `windows/pi-notify-hotkey.ps1` | 35 | 123 | -88 |
| `windows/pi-notify-popup.ps1` | 65 | 153 | -88 |
| **合计** | **260** | **715** | **-455** |

## 验证结果

| 环境与检查 | 本次执行结果 | 说明 |
|---|---|---|
| Linux sender | 77 pass | sender 回归通过 |
| Linux main | 84 pass、4 native skips | 4 项为 Linux 上跳过的 Windows 原生检查，不计为通过 |
| Windows popup UI | 171 pass | 新增行为回归执行实际函数和事件回调；隔离状态，不操作真实会话 |
| Windows route | 326 pass | 既有来源与路由契约回归 |
| Windows native recovery | 7 pass | Windows 原生恢复/生命周期回归 |
| Windows QQ | 6 pass | 既有 QQ 相关回归 |
| `npm run check` | 成功 | package 与 sender 检查 |
| `git diff --check` | 成功 | 无 diff 空白错误 |

运行新增 Windows 行为检查：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\windows\test-popup-ui.ps1
```

常规检查：

```bash
npm test
npm run check
```

## 验证边界

几何回归覆盖不同工作区尺寸、负坐标和不同卡片高度；这不等同于真实显示器上的 DPI 变化、跨屏拖动或多屏热插拔验证。上述真实桌面场景本次未宣称完成。

PiWebDesktop 导航到目标会话的端到端流程也未在本次宣称验证完成。已有路由与恢复回归通过，能够支持本次弹窗侧修改；它们不能证明历史记录中的目标会话加载确认超时已消失。

## 部署记录

**已部署并核验通过**，北京时间 2026-11-10 20:16:34（UTC 12:16:34）。

- 实际运行目录：`C:\Users\Administrator\.pi-notify\bin`，更新上述 5 个脚本；部署前、暂存候选和部署后均逐文件核对 SHA-256。
- 备份目录：`C:\Users\Administrator\.pi-notify\backups\popup-10-rounds-20261110-200955`，包含旧版 5 个脚本、配置快照、hash 清单及 `deployment-result.json`。
- 通知监听服务 `23118/health` 与弹窗 broker `23119/health` 均通过本机 HTTP 健康检查。
- broker、listener runner、hotkey、watchdog 各有一个归属本实例的进程；新热键日志确认 `Alt+L` 注册并开始常驻。
- 延迟复查发现首次启动的进程随远程启动命令结束而退出。现通过已有 Explorer 桌面对象的普通 `ShellExecute` 启动，4 个进程均以现有 Explorer 为父进程、位于交互会话 1；已经跨命令复查，并通过 4 次当前 watchdog 的 listener/tunnel/broker 全健康巡检。
- 初次即时检查另存为 `deployment-initial-check.json`；`deployment-result.json` 为持久运行复查后的最终结果。
- 配置语义对比一致（忽略启动自动更新的 `updatedAtUtc` 时间戳）；反向隧道进程保持不变。
- 更新前确认没有活动卡片；源码变更保存在 Linux 独立工作树 `/root/work/pi-notify-popup-10-rounds`，分支 `codex/pi-notify-popup-10-rounds-20261110`。Windows 旧源码目录中的既有未提交修改保持原状。
- 测试期间临时依赖软链接已移除。未执行 Git commit 或 push。

需要复核运行状态时，可检查上述两个本机健康端点及 `logs\hotkey.log` 的新 `resident-register` / `resident-start` 记录。回退时先停止本实例的 watchdog、broker、hotkey 和 listener，再用备份中的 5 个脚本恢复运行目录，并由现有交互桌面按原启动方式重启；配置快照只用于核对，避免覆盖后续配置变更。
