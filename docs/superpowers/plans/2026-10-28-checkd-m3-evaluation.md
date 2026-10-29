# M3 体验、评测与材料 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 同学 C 交付可复现的三组教育场景、边界验收、真实证据和匿名比赛材料。
**Architecture:** 首先在独立 `docs/contest/` 维护场景与验收；不抢改 Flutter 页面。后续只在 M0/M1/M2 真正运行后采集截图、日志和演示视频。
**Tech Stack:** Markdown/JSON 场景、现有 Flutter 测试命令、WorkBuddy 真实执行证据。
**Spec:** `docs/CheckD_team_plan.md`、[总计划](2026-10-28-checkd-team-overview.md)。

## Global Constraints

仅用虚拟/脱敏数据；截图与视频来自真实调用；不得把建议输出当结果；开源来源和原创贡献清楚披露；C 不修改共享业务文件。

## Review Focus

非开发者可复现、截图与工具日志对应、匿名性、知识库不可信指令、材料页数/演示时长。

### Task 1：场景、边界与披露模板（C，10/29；PR M3-1）

**Files:** Create `docs/contest/acceptance-cases.md`、`docs/contest/demo-script.md`、`docs/contest/oss-disclosure.md`。基于 `docs/CheckD_team_plan.md`；不声称 `tests/e2e/`、`fixtures/education/` 已存在。

**Interfaces:** 给 M0/M1/M2 提供三组虚拟输入（查明天、拆报告、插会议重排）与至少十条边界；每条写前置数据、WorkBuddy 提示词、预期工具、预期状态、证据位置。

- [ ] 写三组具体虚拟课程/周期任务/单次事项与预期时窗；不含真实人名、课表、密钥。
- [ ] 写十条边界：空任务、无时窗、过期截止、跨日、时区、固定冲突、容量不足、重复审批、版本漂移、越权、超时、恶意知识内容；各有可观察通过标准。
- [ ] 写开源组件/平台/原创贡献表与匿名材料检查项；人工检查 Markdown 路径和内容后由 C 手动提交仅三文件 PR。

### Task 2：真实验收与展示文案（C，11/05；PR M3-2；依赖 M1/M0/M2 集成）

**Files:** Update `docs/contest/acceptance-cases.md`、`docs/contest/demo-script.md`；Create `docs/contest/evidence-index.md`、`docs/contest/submission-outline.md`。

**Interfaces:** 消费 A 的链接/工具日志、B 的调度测试、M0 的写入回读；输出每案例“预期→真实结果→trace/截图→结论”。若需 Flutter UI 调整，先单独提 Issue，由队长决定并给 C 独立新文件，不抢改 Today/Calendar。

- [ ] 跑至少十条边界并记录真实失败/通过；未执行标未测，不能填通过。
- [ ] 准备≤3 页初赛大纲、≥3 组提示词/真实输出截图清单、5 分钟演示与 5 分钟答辩脚本。
- [ ] 非开发者按脚本复现一次，反馈缺口并修订；C 手动提交 PR。

### Task 3：封版证据（C，11/08；PR M3-3；依赖 11/06 冻结）

**Files:** Update `docs/contest/evidence-index.md`、`docs/contest/submission-outline.md`、`docs/contest/oss-disclosure.md`。

**Interfaces:** 三场景各三次真实执行记录、Agent 链接、连续录屏、匿名检查、第三方许可和最终版本对应关系。

- [ ] 11/07 完成盲测、录屏与彩排；核对截图时间、工具 trace 和版本一致。
- [ ] 11/08 完成材料清单；若外部 Agent 链接不可访问或写入未回读成功，明确标阻断而非补静态演示；C 手动提交材料 PR。
