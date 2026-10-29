# M1 WorkBuddy Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 同学 A 在腾讯官方 WorkBuddy 提供另一账号可访问、会真实调用 CheckD 工具的 Agent。
**Architecture:** 平台配置先用 Mock 只读工具证实分享/调用；对接 M0 的 v1 契约后再编排调度、确认和写入。配置和日志以去敏文档留痕。
**Tech Stack:** WorkBuddy 平台、M0 远程工具 v1。
**Spec:** `docs/CheckD_team_plan.md`、[总计划](2026-10-28-checkd-team-overview.md)。

## Global Constraints

Agent 链接必须真实可访问；工具未返回成功不得说“已保存”；不提交密钥、真实个人数据；A 不改 Flutter 核心文件。

## Review Focus

分享权限、工具不可达、误选写工具、多轮对话上下文串用户、工具超时和伪造成功。

### Task 1：平台分享与只读工具通路（A，10/29；PR M1-1）

**Files:** Create `docs/workbuddy/access-check.md`、`docs/workbuddy/tool-mapping.md`。平台配置在 WorkBuddy 控制台，仓库中无现成 WorkBuddy 代码。

**Interfaces:** 消费 M0 契约草案 `list_tasks`/ `get_calendar_events` 的 Mock JSON；输出 Agent URL、分享范围、外部账号访问结果、工具请求/响应摘要、平台支持的工具类型与实际截图路径。

- [ ] 建最小 Agent，在第二账号/不同浏览器打开分享链接；记录时间、结果和失败码，绝不把开发者登录态当公众可访问证明。
- [ ] 配只读 Mock 工具，输入“明天有哪些任务”，核对真实工具调用 ID、响应和回答一致。
- [ ] 若平台不能直连本地 MCP，验证受支持的远程 HTTPS/托管入口并把能力与限制发 M0；无法访问标 BLOCKED。
- [ ] 人工 PR 只含上述两份文档；验收为非本人账号能打开且可触发只读工具。

### Task 2：真实读取、拆解、调度（A，11/03；PR M1-2；依赖 M0-2、M2-1）

**Files:** Create `docs/workbuddy/workflow-v1.md`、`docs/workbuddy/prompts-and-failures.md`；仅平台侧改 Agent 配置。

**Interfaces:** 消费真实 `list_tasks` / `get_calendar_events`、M2 `generate_schedule` / `repair_schedule` 提案；输出带来源、方案差异和未排入原因的回答，不执行写入。

- [ ] 用三条去敏提示词验证真实只读调用；检查工具日志中的用户/任务 ID 与回答一致。
- [ ] 加拆解→调度提案工作流；核对固定课程未移动、缺少时窗时可见原因。
- [ ] 模拟超时、401、空结果和恶意知识文本，回答须说清未执行状态；A 手动提交 PR。

### Task 3：人工确认和复验（A，11/06；PR M1-3；依赖 M0-3）

**Files:** Update `docs/workbuddy/workflow-v1.md`、`docs/workbuddy/access-check.md`；新建 `docs/workbuddy/verification-log.md`。

**Interfaces:** WorkBuddy 明示提案差异→用户确认→调用 `apply_approved_changes`→再次调用只读工具核验；错误时输出真实状态与 trace ID。

- [ ] 测未确认、拒绝、重复确认、工具失败、回读不一致；均不得显示成功。
- [ ] 他人账号/不同网络跑三条场景，各连续成功三次并保存去敏日志；11/06 前完成，负责人手动提交 PR。
