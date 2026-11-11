# pi-notify 弹窗改进：第二组 10 轮

日期：2026-11-11。范围：弹窗体验、调度响应、并发状态、热键、投递与异常清理。

本组完成 10 轮实质修改与回归，6 个运行脚本合计增加 191 行、删除 293 行，净减少 **102 行**。这组数字只统计本次改动，不重复计算前一组优化。

## 基线与交付

- 基线提交为 `e74a858`：合并 `origin/main` 的 `9e0f4a8`（Pi 蓝色来源标识）和上一组弹窗修复 `f4625d8`。合并时同步修正了 3 处已过时的 QQ 来源标签静态断言。
- 本组分支：`codex/pi-notify-popup-10-rounds-20261111`；合并基线之后，10 轮各有一个提交。
- 验证采用独立 Linux 工作树及 Windows 测试目录。Windows 中经过测试的 6 个运行脚本与待提交源码逐文件 SHA-256 一致。
- **本组交付为源码和 Git 提交；本轮未部署、未重启 Windows 常驻通知服务。** 上一份报告中的部署记录属于前一组版本。

## 逐轮改进

| 轮次 | 已确认的问题 | 修改与体验收益 | 对应验证 |
|---|---|---|---|
| 1 | 读取旧关闭标记后按路径删除，可能误删并发写入的新标记 | 查询不再删除旧读结果对应的文件；清理仍由既有受锁保护的流程执行，保留更新的关闭信号 | 在读取与验证之间原子替换新标记，确认旧查询不会删除新文件；route 回归 |
| 2 | 部分来源的激活看门狗可以超出卡片剩余寿命 | 所有来源的看门狗取现有预算与剩余寿命的较小值；启动激活前检查过期 | Terminal、空来源、Paseo、Pi Web，以及有/无快照的边界检查 |
| 3 | fallback 启动仍执行没有消费者的窗口扫描与缓存 | 删除无用启动扫描、缓存函数和相关声明；自检同步使用现有信号计时器名称 | PowerShell 解析、引用检查、自检断言和 package 检查 |
| 4 | 共用日志目录时可能清理其他配置的状态；同进程多个卡片重复查询进程归属 | 先按配置指纹筛选，再检查和清理；在单次扫描内复用正、负进程归属结果 | 其他配置状态保留、失效状态清理、同 PID 查询次数；hotkey 16 项 |
| 5 | HTTP 状态行分包会误判投递失败，可能重复打开 fallback；健康探测重复执行 | 有界累积状态行，完整写入后的不明确回执沿用已接受策略；复用成功健康探测 | 本机 TCP 分包 200/503、断开、reset、超长/不完整状态行；健康路径探测由 2 次降至 1 次 |
| 6 | fallback 旧卡关闭失败后仍可能分配空槽，造成同目标重复或堆叠冲突 | 同目标、越界和溢出卡片的进程停止失败时，立即终止本次槽位分配 | 模拟关闭失败与正常替换；投递/堆叠套件共 24 项 |
| 7 | 卡片尚未显示、正在激活或已经失效时仍可能出现在热键队列；状态写入可能读到半份 JSON | 只发布已显示且可操作的状态，激活时撤下，重试时恢复；保留原创建/过期时间；使用同目录临时文件原子替换 | 实际生命周期函数、Shown 回调、重试顺序、不可重试 Paseo 失败、替换失败与临时文件清理 |
| 8 | 固定每批 8 条仍可能被多张慢卡片连续拖住 | 每批同时限制最多 8 条和 20ms 调度预算；下一次取队列项前检查预算，保持 FIFO 并至少处理一项 | 注入 40ms 慢卡片，确认只处理一项就让出，后续项保持顺序；UI 总回归 222 项 |
| 9 | 前台标题子串匹配会把相似会话误判成目标会话，从而提前关闭提示 | broker/fallback 共用身份判断；选中标签优先，来源标题完整匹配，旧 cwd 模式匹配完整字段或路径末段 | 相似名称、父子路径、正则特殊字符、Unicode、Windows Terminal 后缀；identity 34 项 |
| 10 | 绘图或壁纸加载异常可能泄漏 GDI 资源；复审发现热键读句柄会阻挡状态替换/删除 | 绘图资源统一在 finally 释放，失败壁纸释放已创建位图；状态读取允许共享删除；增加统一弹窗回归入口 | GDI 原生操作验证正常/异常释放，paint 33 项；持有读句柄时实际替换/删除，state 共 42 项；全套回归 |

第 8 轮的 20ms 是**开始下一项之前检查的调度预算**，单张卡片内部操作仍可超过该时间。这项改动阻止多张慢卡连续占用同一批次，不能据此宣称所有 UI 操作或端到端通知延迟都低于 20ms。

第 10 轮的 GDI 检查使用 `Clone()` 验证原生资源是否仍可操作，并先验证四类资源的存活、释放两种状态。`Pen.Width` 和 `SolidBrush.Color` 等属性可能返回缓存值，不能作为释放成功与否的可靠判据。

## 实现结构

- 沿用既有 listener → broker / fallback 流程，队列仍由 WinForms Tick 驱动。
- 公共层增加三个有实际消费者的小函数：前台身份匹配、live-state 原子写入、允许共享删除的 live-state 读取。
- 卡片自身管理显示、激活、重试和关闭；热键读取可操作状态后向已有卡片发送意图。
- 状态文件采用一次写入与原子替换，失败时清理临时文件；进程归属缓存仅存在于一次热键扫描中。

运行代码的行数变化（`git diff --numstat e74a858`，排除测试和文档）：

| 文件 | 增加 | 删除 | 净变化 |
|---|---:|---:|---:|
| `windows/NotifyBridge.Common.ps1` | 60 | 2 | +58 |
| `windows/notify-listener.ps1` | 33 | 23 | +10 |
| `windows/pi-notify-broker.ps1` | 44 | 47 | -3 |
| `windows/pi-notify-popup.ps1` | 42 | 214 | -172 |
| `windows/pi-notify-hotkey.ps1` | 11 | 6 | +5 |
| `windows/pi-notify-check.ps1` | 1 | 1 | 0 |
| **合计** | **191** | **293** | **-102** |

## 最终验证结果

| 检查 | 结果 |
|---|---|
| Linux `npm test`：sender | 77 pass，0 fail |
| Linux `npm test`：main | 84 pass，0 fail，4 项 Windows 专用检查在 Linux 跳过 |
| Linux `npm run check` | sender 与 package 检查通过 |
| Windows `npm run test:popup` | 7 个独立进程套件全部通过 |
| Popup UI | 222 项断言通过 |
| Popup state | 42 项断言通过 |
| Popup hotkey | 16 项断言通过 |
| Popup delivery / stacking | 24 项断言通过 |
| Popup identity | 34 项断言通过 |
| Popup paint | 33 项断言通过 |
| 来源标识实绘 | Pi Web、Paseo、Terminal 三种来源的 Label 文本、蓝点像素和 padding 通过 |
| Windows route | 331 pass，0 fail |
| Windows recovery / QQ Node 套件 | 13 pass，0 fail，0 skip；包括 Linux 跳过的 4 项原生检查 |
| `git diff --check` | 通过 |
| 独立源码复审 | 无阻断项；状态读写、生命周期和删除代码的引用已检查 |

UI 套件含逐批次进度断言，执行时长造成批次数变化时，其断言数量可能略有变化；上表为最终执行的实际结果。

常规验证：

```bash
npm test
npm run check
```

Windows PowerShell 5.1 原生验证（在仓库根目录执行）：

```powershell
npm run test:popup
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\windows\test-route.ps1
node --experimental-transform-types --test test/pi-web-notify-recovery.test.mjs test/windows-qq-notify.test.mjs
```

查看本组 10 个提交：

```bash
git log --reverse --oneline e74a858..codex/pi-notify-popup-10-rounds-20261111
```

## 验证范围

Windows 行为验证执行实际函数和事件回调，并使用隔离状态、内存中的 WinForms/GDI 对象、本机测试服务器和假 QQ 发送器。实际显示器 DPI 变化、多屏热插拔以及真实 Pi Web 目标会话加载的端到端流程，本组未验证。后续部署时仍需按仓库现有刷新流程更新已安装副本，并检查常驻服务健康状态。
