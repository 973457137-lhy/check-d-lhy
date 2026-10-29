# CheckD × WorkBuddy 四人校赛 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本仓库本轮只制定计划；上述执行 Skill 若未安装，由负责人按本计划人工执行。

**Goal:** 2026-11-08 内部交付可从腾讯官方 WorkBuddy 访问、以真实工具完成“理解→检索→提案→批准后执行→回读核验”的 CheckD 智能体作品。

**Architecture:** 保留 Flutter/Drift 本地优先架构与 Supabase 同步。WorkBuddy 通过经鉴权的远程工具读取云端用户数据；独立调度模块只生成提案；队长负责审批、版本校验、写入和回读。新增的“时间块”仅是提案 DTO，绝不是现有持久化模型。

**Tech Stack:** Flutter/Dart、Riverpod、Drift、Supabase/Postgres/RLS、腾讯 WorkBuddy（平台工具与部署能力待验证）。

**Spec:** `docs/CheckD_team_plan.md`（当前为未跟踪文件）；本地 `AGENTS.md`；附加的 `CheckD_Codex_prompt.txt` 是本轮委托的补充要求。

## Global Constraints

- 本轮只读审计业务代码与数据库；只新增本目录计划文件；不执行 git add/commit/push/merge。
- 课程为独立 Course；周期任务、单次事项、临时计时、TimerSession、Check-in 各自独立。
- 计划日期、计划时间、实际计时与完成互不覆盖；到达目标不自动完成。
- 仅单日例外可改某一天的周期安排；不污染之后的周期规则。
- 11/06 冻结功能，11/07 测试和彩排，11/08 内部交付。
- 无真实密钥、未经授权个人数据；LLM 文本不得充作执行成功证明；第三方组件披露来源和许可证。

## Review Focus

1. 外部用户凭证缺失或跨用户 ID：只返回拒绝，不泄露任务。M0 的鉴权测试覆盖。
2. 同日课程、周期规则、单次事项及单日例外并存：提案只移动合法柔性项。M2 约束测试覆盖。
3. 日期型截止与带时区的精确截止：不把日期型截止合成为 23:59 时间戳。M2 时间测试覆盖。
4. 批准期间另一设备改动计划：版本冲突中止写入，M0 并发测试覆盖。
5. 工具超时或回读不一致：Agent 报“未确认成功”并展示可追踪错误，M1/M3 场景覆盖。

## 只读审计结论（2026-10-28）

| 主题 | 已证实的实现 | 计划含义 |
|---|---|---|
| 技术栈 | `pubspec.yaml` 为 Flutter；iOS/macOS 有 Swift 平台胶水，核心业务在 `lib/` 的 Dart | 原 Spec 中“Swift 主架构”及 `server/checkd-api/` 只能作为建议，不能当现成服务 |
| Task | `lib/features/tasks/domain/task_models.dart` 有 `TaskKind.recurring/oneTime`、`TaskDeadline`、`TaskTimeSemantics`；`TaskRepository` 有 `getTask`、`watchTasksForDate`、`saveOneTimeReminder`、`scheduleOneTimeTask` | 复用语义；外部只读接口需新建，不能将 LLM 直接接入仓库 |
| Calendar | `lib/features/calendar/domain/calendar_occurrence_builder.dart` 的 `buildCalendarOccurrencesForDate` 合成 Course、Task、Override；`CalendarOccurrence` 有 `startMinute/endMinute` | 无现成 `ScheduleBlock`；提案 DTO 必须映射到单次事项或单日例外 |
| TimerSession | `TaskRepository.startTimer/pauseTimer/resumeTimer/endTimer` 及 `TimerSessionRecords`；`getUnfinishedTimers` 支持多任务计时 | Agent MVP 不写计时表；回归检查多计时、手动完成、统计并集 |
| Supabase | `lib/core/sync/sync_upload_service.dart`、`sync_download_service.dart` 与 `supabase/migrations/`；同步仍以本地 Drift 为运行时源 | 云端读写若绕过本地仓库须验证同步收敛；RLS 不能替代服务端审批 |
| 工作区 | 当前为 `main`，`origin` 指向队长仓库；业务、测试、迁移及团队 Spec 有未提交改动 | 四位成员需从明确基线开 Fork/PR；不得覆盖当前工作区 |

已见基线测试：`test/task_repository_test.dart`、`test/task_time_semantics_test.dart`、`test/calendar_occurrence_builder_test.dart`、`test/statistics_test.dart`、`test/sync_upload_service_test.dart`、`test/sync_download_service_test.dart`。本轮测试运行结果见本文末尾。

**BLOCKED-1：** 仓库没有可访问的 CheckD Agent API、提案审批表/服务或独立 ScheduleBlock 表；M0 须先证明远程部署与同步路线，再实现写入。**BLOCKED-2：** WorkBuddy 当前账号的平台工具、分享权限和外部账号访问未在此仓库中证实；A 须在 10/29 前实测。**BLOCKED-3：** 正式比赛通知、Horolog 许可证/适配成本与线上 Supabase 迁移状态不能从本地仓库证明，分别由队长/B 实证。

## 所有权与接口依赖

```text
M1 WorkBuddy 分享/只读通路 ──┐
                             ├── M0 契约/只读 API ── M2 调度提案
M3 虚拟场景/验收证据 ────────┘                    │
                                                  ▼
                                 M0 审批/写入/回读 → M1 真实闭环 → M3 盲测/材料
```

关键路径：10/29 **分享链接和远程工具可达 + v1 契约冻结** → 10/30 真实只读 → 11/02 无冲突提案 → 11/04 审批后写入并回读 → 11/06 功能冻结 → 11/07 彩排 → 11/08 内部交付。若 10/29 分享失败，优先修复平台入口并暂停高级排程。

| 模块 | 唯一负责人 | 专属新路径/首个 PR | 计划详见 |
|---|---|---|---|
| M0 API/权限/集成 | 队长 | `docs/contracts/agent-api-v1.md`、`docs/contracts/agent-api-v1.examples.json` | [M0](2026-10-28-checkd-m0-api.md) |
| M1 WorkBuddy Agent | 同学 A | `docs/workbuddy/access-check.md`、`docs/workbuddy/tool-mapping.md` | [M1](2026-10-28-checkd-m1-workbuddy.md) |
| M2 智能调度 | 同学 B | `lib/features/agent_scheduler/domain/schedule_contract.dart`、`lib/features/agent_scheduler/domain/schedule_engine.dart`、`test/agent_scheduler_test.dart` | [M2](2026-10-28-checkd-m2-scheduler.md) |
| M3 体验/评测/材料 | 同学 C | `docs/contest/acceptance-cases.md`、`docs/contest/demo-script.md`、`docs/contest/oss-disclosure.md` | [M3](2026-10-28-checkd-m3-evaluation.md) |

首个 PR 中上述均为**拟新建文件**，目前不存在。M0 独占契约文件；B 不改 `task_repository.dart`、`calendar_occurrence_builder.dart`、`app_database.dart`；A/C 不改业务代码。跨模块更改先提 Issue，经队长定接口后由文件所有者实施。

## 逐日交付表（每天 21:30 展示可验证结果）

| 日期 | 队长 M0 | A M1 | B M2 | C M3 | 日终门槛 |
|---|---|---|---|---|---|
| 10/28 | 审计与计划、确认现有未提交基线 | 创建最小 WorkBuddy Agent 并试分享 | 评估调度规则与 Horolog 许可 | 提取赛规与虚拟场景 | 链接可试或阻断证据 |
| 10/29 | v1 契约与 Mock、确定部署/鉴权 | 第二账号访问及只读工具 Mock | 纯函数 DTO 和五组约束测试起步 | 三组场景、十条边界用例 | 契约冻结，分享入口可达 |
| 10/30 | 真实只读任务/课程/日历接口 | 接入真实只读工具并留调用日志 | 固定事件避让、稳定排序 | 查空列表、越权、超时 | 真实读取成功 |
| 10/31 | 提案校验和版本策略 | 结构化拆解与提案解释 | 截止时间/可用时窗/未安排量 | 评拆解与计划前后文案 | 未批准无写入 |
| 11/01 | 审批凭据与幂等写入初版 | WorkBuddy 人工确认节点 | 独立约束验证 | 内部录屏和失败路径 | 首条写入/回读闭环 |
| 11/02 | 接调度工具和同步核验 | 读→拆解→调度工作流 | 五组用例全部通过，选算法路线 | 做基础可用性走查 | 无硬冲突提案 |
| 11/03 | 单日例外写入与版本冲突防护 | 突发事件重排提示 | 最小扰动重排 | 比较移动次数/基线 | 固定课程未动 |
| 11/04 | 权限、超时、重复批准回归 | 多轮错误回复与链接复验 | 跨日/无解/降级 | 十条边界执行记录 | 不稳定加分项停做 |
| 11/05 | 端到端发布候选 | 固化配置和证据 | 输出算法与许可说明 | 3 页大纲、截图、脚本初稿 | 仅修关键缺陷 |
| 11/06 | 人工审核 PR、功能冻结 | 异账号异网络复验 | 随机组合与性能回归 | 非开发者盲测 | 三场景各连续通过三次 |
| 11/07 | 密钥/版本/回滚检查 | 链接与权限复验 | 回归与答辩准备 | 连续录屏、匿名审查、彩排 | 提交包可复现 |
| 11/08 | 内部交付核对 | 最终 Agent 可用性记录 | 最终测试报告 | 材料清单封版 | 链接、代码、证据齐备 |

## GitHub Fork + PR 流程

每位成员 Fork 队长仓库；个人克隆中 `origin` 指向本人 Fork、`upstream` 指向 `https://github.com/Dai-xx66/check-d.git`。从最新 `upstream/main` 建各自 `codex/m0-...` / `codex/m1-...` / `codex/m2-...` / `codex/m3-...` 分支，保持独立文件所有权。本人执行 git add/commit/push，向队长仓库 `main` 开 PR；队长审查契约版本、文件清单、测试、截图/日志、许可证、密钥，再人工合并；其他人同步后开启下一 PR。当前共享工作区有未提交修改，**不要**在该工作区直接切分支/拉取；先由队长界定基线并给成员各自克隆。Fork 不等于 PR；不自动合并、不直改 main。

## 基线验证

本轮运行：`flutter test test/task_repository_test.dart test/task_time_semantics_test.dart test/calendar_occurrence_builder_test.dart test/statistics_test.dart test/sync_upload_service_test.dart test/sync_download_service_test.dart`。结果：**93 项通过，All tests passed**。这只证明当前相关基线；尚未测试任何拟建 Agent 接口或 WorkBuddy 链路。
