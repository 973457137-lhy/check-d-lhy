# M0 CheckD API 与审批 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 队长提供经鉴权的只读工具、审批后写入和回读核验。
**Architecture:** 先发布版本化 JSON 契约和 Mock；选定 WorkBuddy 可达的 HTTPS/平台工具入口后再做服务。云端写入需与 Drift 同步协议收敛。
**Tech Stack:** Dart/Flutter、Supabase/Postgres、WorkBuddy 远程工具（部署形态待实测）。
**Spec:** `docs/CheckD_team_plan.md`、[总计划](2026-10-28-checkd-team-overview.md)。

## Global Constraints

仅 M0 可改契约和核心适配；Task/Calendar/TimerSession 原语义不变；不在本轮改业务代码或数据库；所有提交由负责人手动完成。

## Review Focus

越权、过期审批、重复审批、版本漂移、部分成功与回读不一致均必须返回可识别错误，不能宣称完成。

### Task 1：冻结 v1 契约与 Mock（队长，10/29；PR M0-1）

**Files:** Create `docs/contracts/agent-api-v1.md`、`docs/contracts/agent-api-v1.examples.json`。现有证据：`lib/features/tasks/domain/task_models.dart`、`lib/features/calendar/domain/calendar_models.dart`、`lib/features/calendar/domain/calendar_occurrence_builder.dart`、`lib/features/schedule/domain/day_schedule_models.dart`。

**Interfaces:** 约定工具 `list_tasks(userContext, dateRange)`、`get_calendar_events(userContext, dateRange)`、`generate_schedule(snapshot)`、`validate_schedule(proposal)`、`apply_approved_changes(proposalId, approvalToken, idempotencyKey)` 的 JSON v1 字段；`snapshot` 含任务、课程、单日例外和版本；`proposal` 含 `proposal_id/base_version/changes/unplanned_tasks/explanations`。这是**拟建协议，不是仓库现有函数**；写入策略需证明与真实云端表兼容。

- [ ] 写契约：明确 `dateOnly` 与带偏移的 ISO 8601 instant、北京时间、Course 与 Task 独立、计划块非 TimerSession；确认单次事项仅一个现有计划时间，多个未来块不得假称已支持。
- [ ] 写脱敏 JSON Mock：一组课程、周期任务、单次事项、突发会议、空数据和越权错误；验证 `python3 -m json.tool docs/contracts/agent-api-v1.examples.json >/dev/null` 退出码 0。
- [ ] 与 A/B/C 逐字段评审并记录版本 v1；负责人手动提交 PR，仅含这两个文件。

### Task 2：只读远程适配（队长，10/30；PR M0-2；依赖 Task 1 与 M1 分享通路）

**Files:** 现有读取来源 `lib/core/sync/sync_download_service.dart` 的 `SyncRemoteReader.readTable(String table,{required String userId})`、`lib/features/tasks/data/task_repository.dart` 的 `getTask` / `watchTasksForDate`、`lib/features/courses/data/course_repository.dart` 的 `loadCourses`、`lib/features/schedule/data/day_schedule_repository.dart` 的 `loadOverridesForDate`。拟建服务路径 **BLOCKED：待 10/29 确定 WorkBuddy 可用工具、远程部署和身份令牌后在契约中落定**，不得编造现成 `server/`。

**Interfaces:** 输出契约 v1 的 `list_tasks` 与 `get_calendar_events`；真实鉴权身份必须来自服务端验证过的 token，不能信请求体 `userId`。

- [ ] 先写失败测试：无 token、过期 token、甲用户查乙用户、空任务、云端/本地同一用户数据一致性。
- [ ] 选定 HTTPS/平台托管入口并记录实际路径、运行命令、密钥注入方式；未实证时保持 BLOCKED。
- [ ] 实现只读映射并运行新测试及 `flutter test test/task_repository_test.dart test/calendar_occurrence_builder_test.dart test/sync_download_service_test.dart`；期望全 PASS。
- [ ] 负责人手动提交 PR，报告异账号 WorkBuddy 调用日志。

### Task 3：提案校验、审批与写入（队长，11/04；PR M0-3；依赖 M2 合法提案、M1 确认流）

**Files:** 拟建服务及测试路径随 Task 2 技术决策确定；可能触及 `supabase/migrations/`，须独立 PR 和迁移验收，不直接改 `app_database.g.dart`。现有安全写入参考 `TaskRepository.scheduleOneTimeTask(String taskId, DateTime dateTime)`、`DayScheduleRepository.saveDailyOverride(DailyItemOverrideDraft draft,{String? overrideId})`；这些是本地写入，不是外部 API。

**Interfaces:** `validate_schedule` 只校验并产生 `PENDING_APPROVAL`；`apply_approved_changes` 只接受服务端可核验的审批凭据、版本和幂等键；成功后回读并返回实际 ID/时间，失败返回状态和原因。写操作只允许批准的单次事项计划或单日例外，不修改周期规则、计时/完成记录。

- [ ] 写失败测试：未批准零写入、跨用户拒绝、重复审批仅一次、版本冲突零写入、非法移动固定课程拒绝、回读不一致不报成功。
- [ ] 审核 Supabase RLS、线上迁移状态和事务能力；若无法保证原子/幂等，标 BLOCKED 并保持只读演示，不宣称已写入。
- [ ] 最小实现后运行新测试及 `flutter test test/task_repository_test.dart test/task_time_semantics_test.dart test/calendar_occurrence_builder_test.dart test/statistics_test.dart test/sync_upload_service_test.dart test/sync_download_service_test.dart`；全 PASS。
- [ ] 队长人工审 PR、合并；11/06 后只接阻断性修复。
