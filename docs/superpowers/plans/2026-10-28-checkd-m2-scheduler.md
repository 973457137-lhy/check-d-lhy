# M2 智能调度 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 同学 B 提供确定性、无硬冲突、能最小扰动重排的纯提案调度器。
**Architecture:** 新建独立 Dart domain 模块，不接数据库；M0 把真实数据适配为冻结的 DTO。调度器输出提案，不直接写 Task、Calendar 或 TimerSession。
**Tech Stack:** Dart、`flutter_test`；Horolog 仅在许可证和集成成本确认后可选。
**Spec:** `docs/CheckD_team_plan.md`、[总计划](2026-10-28-checkd-team-overview.md)。

## Global Constraints

固定 Course/会议不可移动；日期型截止与精确截止分别处理；计划块不能充当计时事实；输入相同输出稳定。B 独占 `lib/features/agent_scheduler/` 和 `test/agent_scheduler_test.dart`。

## Review Focus

跨日/时区、无空闲时窗、期限已过、重复/重叠固定项、插入会议后的局部重排。

### Task 1：DTO 与基础排程（B，11/02；PR M2-1；依赖 10/29 M0 v1 契约）

**Files:** Create `lib/features/agent_scheduler/domain/schedule_contract.dart`、`lib/features/agent_scheduler/domain/schedule_engine.dart`、`test/agent_scheduler_test.dart`。参考现有 `CalendarOccurrence`、`TaskDetails`、`TaskDeadline`、`DailyItemOverride`，但不修改它们。

**Interfaces:** 拟定 `ScheduleProposal generateSchedule(ScheduleInput input)`；`ScheduleInput` 含用户时区、窗口、任务需求分钟数、硬约束区间、现有柔性安排、`baseVersion`；`ScheduleProposal` 含 `changes`、`unplannedTasks`、`explanations`。字段名/JSON 与 M0 v1 一致；`DateTime` instant 保留偏移，日期型 deadline 单独字段。无现有 ScheduleBlock 实体，`ProposedBlock` 只在该模块。

- [ ] 写五个失败测试：课程/会议避让、截止日期、空闲不足有未安排量、固定事件重叠无非法写提案、相同输入排序稳定。
- [ ] 运行 `flutter test test/agent_scheduler_test.dart` 预期因类未定义失败；实现最小纯函数；重跑预期 PASS。
- [ ] 加日期型截止与带偏移精确截止用例；保留零数据库访问；负责人手动提交仅三文件 PR。

### Task 2：动态重排与降级（B，11/04；PR M2-2；依赖 Task 1）

**Files:** Modify `lib/features/agent_scheduler/domain/schedule_engine.dart`、`test/agent_scheduler_test.dart`；Create `docs/scheduler/algorithm-and-license.md`。

**Interfaces:** `ScheduleProposal repairSchedule(ScheduleInput input, ScheduleProposal previous)`；同样只返回差异，不移动硬约束，不自动落库。

- [ ] 写失败测试：插入会议只移动冲突柔性块；不可行返回未安排分钟及理由；跨日边界不越界；相同输入同输出。
- [ ] 实现最小扰动排序与确定性规则降级；若引入 Horolog，先记录准确源码版本、许可证、部署义务和基线对照；许可证/集成未明确则使用自有规则实现。
- [ ] 运行 `flutter test test/agent_scheduler_test.dart test/calendar_occurrence_builder_test.dart test/task_time_semantics_test.dart`，全 PASS；负责人手动提交 PR。
