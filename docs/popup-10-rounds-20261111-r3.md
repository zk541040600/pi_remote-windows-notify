# pi-notify 弹窗改进：第三组 10 轮

日期：2026-11-11。基线：`b29d8acf327128ec1b75379fb6b49dcbfbad5a07`。
分支：`codex/pi-notify-popup-10-rounds-20261111-r3`。

本组完成 10 轮代码修改，每轮独立提交；另有 CI 平台分工修正及本验证记录。10 轮提交的远端文件树逐一与本地文件树核对一致。

## 逐轮修改

| 轮次 | 提交 | 已确认的问题与修改 | 验证重点 |
|---|---|---|---|
| 1 | `f11e4e3` | 满栈时最旧卡片关闭失败，原逻辑会继续关闭其他卡片；现在立即停止本次分配，保留无关通知 | 失败只尝试最旧一张；成功时仍正常复用槽位 |
| 2 | `e956148` | 延迟激活及取消完成回调可能赶在到期计时器前启动已过期卡片；在真正创建 worker 前检查有效期、关闭和释放状态 | broker/fallback 的过期、正在关闭、已释放、终止及正常场景；跳过过期项后继续启动有效项 |
| 3 | `8c5111d` | 点击已被抢占、正在取消的 resolver，可能再抢占其他卡片或与自己的旧任务并行；点击意图现在等待自身 worker 释放 | 满容量与有空位、resolve/activate 两种旧任务、阻塞项保留、其他项继续、一次性领取、空 notificationId |
| 4 | `f1a5e47` | listener 与 broker 都可能接受正文短于 Content-Length 的请求；现在拒绝截断、非法/重复长度及不支持的传输编码，并释放读取缓冲 | 两个实际解析器的 UTF-8 分片、EOF、最大长度及格式错误；broker 入队前拒绝并返回 400 |
| 5 | `147f7ad` | fallback 分配失败时原逻辑静默返回成功；现在把失败交还调用方 | Paseo 返回 retry、不写成功去重，之后可重新投递；broker 已接受时跳过 fallback |
| 6 | `06481d0` | 启动轮询使用完整默认探测超时，可能越过剩余预算；现在用 Stopwatch 与剩余时间限制每次探测 | 休眠后重新检查期限，预算耗尽不再探测，成功探测结果继续复用 |
| 7 | `eacfa40` | 热键的两条 HTTP 路径行为不同，分包/丢失回执可能误开下一张卡；合并为一个发送函数 | 分包 200/拒绝、空/部分/reset 回执、700ms 共用预算；完整请求发出而回执不明时消耗本次按键 |
| 8 | `e8a5d56` | 进程命令行只匹配配置路径子串，可能误认其他参数或子路径；改为精确匹配 ConfigPath 参数 | 空格与引号路径、冒号语法、大小写、其他参数、子目录及文件名后缀 |
| 9 | `0cdcf75` | 快捷键解析把字面加号当分隔符删除，Ctrl++ 无法使用；现在正确识别并拒绝空键或空修饰符 | Ctrl++、空格写法、显式 Shift、默认 Alt+L、函数键及非法组合 |
| 10 | `0d02b12` | listener 退出时调用不存在的 Runspace.Stop，关闭监听 socket 后还可能持续捕获异常；现在保留实际 PowerShell 实例，先中断 Accept/Read，再结束并释放 pipeline/runspace | 空闲、半个请求头、半个正文；主动中断 30 秒读取等待、资源释放、重复关停 |

第 3 轮复用既有 deferred 队列，不改变 watchdog 的可重试策略。正在取消的任务继续占用原槽位，直到清理完成。
第 5 轮的自动重试保证适用于 Paseo，其调用方和发送端已有 retry/pending 机制。Pi Web 失败会返回 500，现有发送端没有自动重试机制，不能将 Paseo 的保证扩大到全部来源。

## 实现结构

继续使用 listener → broker / fallback、现有 WinForms Tick 和 worker/deferred 队列。热键发送共用一个函数；正文按声明长度读取到一个数组；listener 退出共用一个清理入口，只有停止标志和当前客户端两个共享字段。本组没有增加运行时依赖。

5 个运行脚本合计增加 281 行、删除 228 行，净增加 53 行；测试、CI 和文档不计入该数字。新增部分主要是生命周期检查和完整退出清理，不引入新的调度层。

## 已完成的验证

[GitHub Actions 运行 42952530547](https://github.com/zk541040600/pi_remote-windows-notify/actions/runs/42952530547) 在提交 `46ac6f679153d46e4dce88846d0fd1201c77ffa7` 上完成，Linux 与 Windows 两个 job 均为 success。随后提交仅更新本文与 README，运行脚本、测试和 workflow 与上述已验证提交一致。

| 验证 | 结果 |
|---|---|
| 本地 Linux npm test：sender | 77 pass，0 fail |
| 本地 Linux npm test：main | 84 pass，0 fail，4 项 Windows 专用检查跳过 |
| 本地 npm run check / git diff --check | 通过 |
| 本地 PowerShell 解析 | 41 个脚本通过 |
| CI Linux sender | 77 pass，0 fail，0 skip |
| CI Linux 独立 Node 回归 | 78 pass，0 fail，4 项 Windows 专用检查跳过 |
| CI Windows popup UI | 222 项通过 |
| CI Windows popup state | 42 项通过 |
| CI Windows popup hotkey | 60 项通过 |
| CI Windows popup delivery | 69 项通过 |
| CI Windows popup identity | 34 项通过 |
| CI Windows popup paint | 33 项通过 |
| CI Windows 来源标识实绘 | 通过 |
| CI Windows popup coordination | 61 项通过 |
| CI Windows popup listener | 25 项通过 |
| CI Windows route | 331 pass，0 fail |
| CI Windows recovery / QQ | 13 pass，0 fail，0 skip，含 Linux 跳过的原生检查 |
| 独立源码复审 | 无阻断项 |

本地 main 比公开 CI 多 6 项桌面项目源码约束检查：本地具备对应的独立源码副本，CI 不复制该跨仓库源码。这 6 项已在本地实际执行通过，没有删除或替换测试。

首次云端检查在 Windows 启动 Linux sender 的 npm 子进程入口时失败。CI 随后按平台拆分：Linux 执行 sender、包检查和独立 Node 回归；Windows 直接执行包结构、PowerShell 5.1 弹窗、路由及原生恢复/QQ 回归。上表来自拆分后的成功运行。

## 响应与清理测量

- 在不返回健康回执的 loopback 服务器上，默认探测超时 2000ms、给定剩余预算 80ms：旧版约 2034ms，新版约 93ms。该结果仅表示此探测场景，不代表端到端通知延迟。
- 本地 listener 设定 30 秒读取超时，空闲、半请求头、半正文三种关停实测分别约 23ms、3ms、2ms。自动回归使用小于 2 秒的宽裕阈值，验证主动中断读取，不把机器调度抖动当成精确性能指标。

## 复查入口与范围

Linux，在仓库根目录：

```bash
npm ci --ignore-scripts --prefix linux/paseo-sender
npm test
npm run check
```

完整 npm test 的桌面源码约束检查需要现有 sibling 项目。独立检出场景可参考 workflow 中的明确测试分工。

Windows PowerShell 5.1，在仓库根目录：

```powershell
npm run test:popup
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File windows/test-route.ps1
node --experimental-transform-types --test test/pi-web-notify-recovery.test.mjs test/windows-qq-notify.test.mjs
```

本组交付为源码及 Git 提交，未更新用户 Windows 安装目录或重启常驻通知服务。原生 CI 使用隔离状态、WinForms/GDI 对象及 loopback 服务器；实际多屏/DPI 变化、真实 Pi Web/Paseo 会话激活的桌面端到端流程不在本组已验证范围内。
