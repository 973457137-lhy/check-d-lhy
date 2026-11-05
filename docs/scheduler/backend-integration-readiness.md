# CheckD Scheduler-to-Backend Integration Readiness

> M0 统一任务（M2 完整工作包）｜作者：B（M2 刘恒瑜）｜2026-11-04 00:xx (+08)
> 目标：回答「现有 CheckD App、A2 调度 domain、A1 服务端」三者如何接成一条真实可实现的链路。
> 性质：**纯只读盘点 + 文档/配置方案**。未改任何代码/契约/Mock/测试/数据库；未提交、未推送、未建 PR、未合并。
> 契约基准：`39f7f965`（§5.8 八值 violations，含 `BLOCK_OVERLAP`）；Mock 冻结 `7e1367c2`；PR #2 head `070fb6e`。

---

## 0. 交付总览与边界声明

本工作包把 M0 16:29:59Z 派发的 8 项要求收敛为一份完整准入包，对应关系：

| M0 要求项 | 本文件章节 |
|---|---|
| 1. 只读盘点 CheckD 数据模型与数据接口 | §1 |
| 2. App 模型 → A2 → A1 完整字段映射表 | §2 |
| 3. generate/repair/validate 调用时序 + JSON + 错误语义 + 时区日期边界 | §3 |
| 4. 服务端权威字段 / 客户端可提供 / 禁止自定字段 | §4 |
| 5. 48 条测试逐项证据状态（清单核对/源码检查/实际运行） | §5 |
| 6. 与 A1 §7 29 条、v3 §11 29 条追踪映射 | §6 |
| 7. 修正版 Canonical Decision Register | 独立文件 `canonical-decision-register.md`（§7 说明修正点） |
| 8. 集成实施蓝图 | §8 |

**全局边界（贯穿全文，不重复声明）**：不连接生产库 check-c、不触发真实审批/日程写入、不索取/传播 M0 生产密钥、不改代码/契约/Mock/测试/数据库、不提交/推送/建 PR/合并。

---

## 1. 现有 CheckD 数据模型与数据接口盘点（只读）

> 结论均带真实源码行号，不臆测。所有路径相对 `lib/`。

### 1.1 前置：A2 调度 domain 已有「契约 DTO」层（对照物）

- `lib/features/agent_scheduler/domain/schedule_contract.dart` —— 纯提案 DTO，非数据库表、非 Drift 实体。
- `lib/features/agent_scheduler/domain/schedule_engine.dart` —— 纯函数引擎，零数据库访问。

引擎纪律（schedule_engine.dart L7-12）：不 import repository/drift/UI；不读 `DateTime.now()`（时间基准来自 `ScheduleInput.now`）；绝不移动 `ScheduleFixedBlock`；只产出提案、不写库。

### 1.2 Task 任务模型

- 模型：`lib/features/tasks/domain/task_models.dart`
- 关键类型：`TaskKind{recurring,oneTime}`(L1)、`TaskLifecycle{active,paused,archived}`(L3)、`TimerSessionStatus`(L9)、`TimerStatus`(L13)、`CompletionStatus{pending,completed}`(L15)
- `TaskDeadline`(L50-65)：`date`(仅日期)/`at`(精确时刻) 互斥（断言 L52），`isDateOnly`(L62)/`hasTime`(L63)
- `TaskScheduleRule`(L240-259)：周期排程规则 `preset`/`weekdaysMask`/`startsOn`/`endsOn`，`isDueOn`(L253)
- `RecurringTaskDraft`(L261-295)：`tagId`/`name`/`executionMode`/`targetDurationSeconds`/`targetDays`/`schedulePreset`/`weekdays`/`startsOn`/`endsOn`/`scheduledMinuteOfDay`(固定时间)/`reminderMinuteOfDay`/`holidayPause`
- `OneTimeReminderDraft`(L297-384)：`scheduledAt`/`availableFrom`(可开始日期)/`plannedDate`(计划日期)/`deadline`/`executionMode`/`remindBeforeMinutes`
- `TaskDetails`(L388-477)：只读详情，含派生 getter `hasTimer`/`hasDurationTarget`/`effectivePlannedDate`/`hasDeadline`/`isPastDeadline`/`completionStatus`
- `TaskTimeSemantics`(L67-217)：计划时间语义校验/判定核心

- Repository：`lib/features/tasks/data/task_repository.dart`（类 L13）
  - 读：`watchTasksForDate(date)`(L68)、`watchTasksByStatus(status)`(L200)、`watchTask(taskId)`(L215)、`watchCompletionHistory(taskId)`(L228)、`watchTimerState(taskId,date)`(L248)、`watchCalendarMonth(month)`(L273)、`getTask(taskId,{date})`(L290)、`getUnfinishedTimers()`(L43)
  - 写：`saveRecurringTask`(L509)、`saveOneTimeReminder`(L613)、`planOneTimeTask`(L728)、`scheduleOneTimeTask`(L738)、`cancelOneTimeSchedule`(L749)、`updateOneTimeDeadline`(L759)、`toggleRecurringCompletion`(L778)、`toggleOneTimeCompletion`(L854)、`startTimer`(L893)/`pauseTimer`(L928)/`resumeTimer`(L944)/`endTimer`(L996)、`archiveTask`(L1034，软归档)

- **与调度输入相关**：`deadline`（→`ScheduleDeadline`）、`scheduledMinuteOfDay`/`scheduledAt`（固定时间）、`availableFrom`（→`earliestStartAt`）、`plannedDate`/`scheduledAt`（`effectivePlannedDate`）、`targetDurationSeconds`（→`targetDurationSeconds`）。**`priority` 字段在当前 Task 模型不存在**——`ScheduleTaskDemand.priority` 需由映射层/服务端快照提供。

### 1.3 Course 课程模型（硬约束来源）

- 模型：`lib/features/courses/domain/course_models.dart`
- `CourseDetails`(L35-67)：`id/name/colorValue/status/teacher/classroom/semester/semesterId/semesterStartsOn/semesterEndsOn/rules[]`
- `CourseScheduleRule`(L105-164)：`weekday(1-7)`/`weekRuleType`/`startWeek`/`endWeek`/`intervalWeeks`/`weekNumbers`/`scheduleTemplateId`/`sectionIds`/`timeMode`/`startsAtMinute`/`endsAtMinute`/`classroomOverride`，`isDueInWeek(weekNumber)`(L146)
- `SemesterDetails`(L258-297)：`firstWeekStartDate/totalWeeks`，`weekNumberFor(date)`(L283)
- Repository：`lib/features/courses/data/course_repository.dart`（类 L11）、`semester_repository.dart`（类 L8）
- **与调度相关**：课程是 `ScheduleFixedBlock`（ownerType=course）来源，时间由 `startsAtMinute/endsAtMinute` 经 `CourseOccurrenceTiming` 展开；周次规则由 `weekRuleType`+`startWeek/endWeek/intervalWeeks/weekNumbers` 判定。

### 1.4 Calendar 日历

- 模型：`lib/features/calendar/domain/calendar_models.dart` + `calendar_occurrence_builder.dart`
- `CalendarOccurrence`(L162-194)：`id/type/date/colorValue/startMinute/endMinute/title/course/courseRule/courseTiming/classroom/task`，`hasTime`(L193)
- 构建：`buildCalendarOccurrencesForDate`(L33)、`buildCourseOccurrencesForDate`(L107，含补课/reschedule 覆盖)、`isCourseRuleActiveOnDate`(L282)
- 无独立 Repository，数据来源 `TaskRepository.watchCalendarMonth` + builder。
- `CalendarDayData` 定义在 `task_models.dart` L570-590；`CalendarMonthData` L592-605。

### 1.5 TimerSession / 计时事实记录（实际发生，不可被计划覆盖）

- 模型：`task_models.dart` `TimerSessionEntry`(L479-504)：`id/taskId/startedAt/logicalDate/endedAt/durationSeconds/status`
- `TaskTimerState`(L506-550)：聚合视图 `isRunning/isPaused/timerStatus/totalElapsedSecondsAt`
- 表：`app_database.dart` `TimerSessionRecords`(L105-122)：`taskId/tagId/startedAt/logicalDate/endedAt/durationSeconds/state`
- 关键写方法：`startTimer`(L893)、`_closeTimerSession`(L1335)、`_durationForLogicalDate`(L1430)、`_durationFromSessionsForDay`(L1459，真实时间戳与自然日求交)

### 1.6 Completion / 打卡完成记录

- 模型：`task_models.dart` `CompletionHistoryEntry`(L552-568)：`localDate/progressPercent/isSuccess/actualDurationSeconds/targetReached/completedAt`
- 表：`app_database.dart` `TaskCompletionRecords`(L79-103)，唯一约束 `{taskId, localDate}`(L100-102)
- **Check-in 无独立实体**：「打卡」= 周期任务完成（`toggleRecurringCompletion` L778 写 `isSuccess`）+ 单次事项完成（`toggleOneTimeCompletion` L854 写 `completedAt`）；统计侧 `checkInDays` 是派生量，非独立模型。

### 1.7 单日例外 / 提醒 / 闹钟（lib/features/schedule/）

- 模型：`lib/features/schedule/domain/day_schedule_models.dart`
- `DailyItemOverride`(L45-75)：`itemType/itemId/localDate/action/plannedStartMinute/plannedEndMinute/reminderMinuteOfDay/targetDurationSeconds/temporaryClassroom`
- `ReminderRule`(L99-125)、`AlarmRule`(L149-175)、`AdHocTimerDetails`(L203-256)
- Repository：`lib/features/schedule/data/day_schedule_repository.dart`（类 L10）：`watchOverridesForDate`(L27)、`saveDailyOverride`(L57)
- **单日例外是调度落库载体**：调度引擎对周期任务的持久化走 `UpsertDailyOverrideChange`（schedule_contract.dart L463-503，action=reschedule），对应 `DailyItemOverride.plannedStartMinute/plannedEndMinute`；唯一约束 `{userId,itemType,itemId,localDate}`(app_database L366-368)。

### 1.8 标签 / 统计（仅调度输入相关）

- 标签：`lib/features/tags/data/tag_repository.dart`（类 L9）；表 `TagRecords`(L163-174)。`tagId` 出现在 LocalTasks/TimerSessionRecords/AdHocTimerRecords，但 `ScheduleTaskDemand` **未携带标签字段**。
- 统计：`lib/features/statistics/domain/statistics_models.dart`；`TaskHistory`（task_history.dart L59-66）重放 `task_revision_records` 还原周期任务历史排程规则，是「某天该不该排」的历史依据来源之一。

### 1.9 app_database 概览（lib/core/database/app_database.dart）

`@DriftDatabase` 注册表 L449-476，schemaVersion=20(L483)，共 24 张表（详见盘点表：local_tasks、long_term_task_records、task_schedule_records、one_time_reminder_records、task_completion_records、timer_session_records、task_revision_records、sync_operations、app_settings、tag_records、tag_revision_records、plan_records、plan_task_records、review_records、course_records、course_schedule_rule_records、schedule_template_records、schedule_template_segment_records、semester_records、daily_item_override_records、reminder_rule_records、alarm_rule_records、ad_hoc_timer_records、ad_hoc_timer_interval_records）。

### 1.10 计划 vs 实际（集成准入核心结论）

| 类别 | 字段（可被调度写入的计划时间） |
|---|---|
| 周期任务计划 | `LongTermTaskRecords.scheduledMinuteOfDay`、`TaskScheduleRecords.startsOn/endsOn/weekdaysMask` |
| 单次事项计划 | `OneTimeReminderRecords.scheduledAt/plannedDate/availableFrom/dueDate/dueAt` |
| 单日例外 | `DailyItemOverrideRecords.plannedStartMinute/plannedEndMinute` |
| 课程 | `CourseScheduleRuleRecords.startsAtMinute/endsAtMinute/weekday/weekRuleType/...` |

| 类别 | 字段（实际发生，绝不可被计划覆盖） |
|---|---|
| 计时事实 | `TimerSessionRecords.startedAt/endedAt/durationSeconds/logicalDate` |
| 完成事实 | `TaskCompletionRecords.actualDurationSeconds/completedAt/isSuccess` |
| 单次完成 | `OneTimeReminderRecords.completedAt` |
| 临时计时 | `AdHocTimerIntervalRecords.startedAt/endedAt/durationSeconds` |

调度引擎现有落库白名单只有两种（schedule_contract.dart）：
- `ScheduleOneTimeChange`（单次事项 → 写 `scheduledAt/plannedDate`，L432-458）
- `UpsertDailyOverrideChange`（周期任务 → 写 daily_override reschedule，L463-503）
两者都不触碰课程规则、不触碰计时/完成事实记录。

---

## 2. App 模型 → A2 Scheduler Input/Output → A1 API/Proposal 字段映射表

> 标记：✅ 直接复用｜🔄 需转换｜❌ 缺失｜⚠️ 冲突/待裁定

### 2.1 CheckD App → A2 ScheduleInput

| A2 字段（schedule_contract.dart） | CheckD 来源 | 映射 | 说明 |
|---|---|---|---|
| `now`(L326) | 服务端时钟 | 🔄 | 引擎不读系统时间，由服务端传入「排程基准时刻」 |
| `horizonStart`/`horizonEnd`(L328-329) | 服务端排程窗口 | 🔄 | 由服务端按「今天起 N 天」折算，非本地模型字段 |
| `baseVersion`(L335) | 权威快照版本 | ❌ | 本地无此概念，须服务端可信服务产生 |
| `timezone`(L337) | 课程作息模板 timezone / 固定 Asia/Shanghai | 🔄 | 引擎**不消费**，仅透传规范化，见 §4 R1 |
| `preferences`(L340) | 用户设置 | 🔄 | dayStart/dayEnd/minBlock，前端直传形状是 `day_start_minute/day_end_minute` |
| `availability`(L345) | 用户可用时间窗口 | ⚠️ | 当前 non-nullable `const []`，空=按偏好推导；无法表达「null=未指定 vs []=明确无时间」，见 D3 |
| `fixedBlocks`(L348) | 课程 + 外部会议 | 🔄 | 课程由 `CourseScheduleRule` 展开；会议由 `external_fixed_event` 映射 |
| `demands`(L350) | Task（周期+单次） | 🔄 | 见 2.2 |
| `existingPlacements`(L352) | 上一版提案 blocks | 🔄 | repair 专用，服务端从上版 proposal 回填 |

### 2.2 CheckD Task → A2 ScheduleTaskDemand

| ScheduleTaskDemand 字段 | CheckD 来源 | 映射 | 说明 |
|---|---|---|---|
| `taskId`(L250) | Task.id | ✅ | 直接复用 |
| `title`(L251) | Task.name | ✅ | 直接复用 |
| `requiredMinutes`(L258) | — | 🔄 | 服务端可信快照折算，**不接受 LLM 伪估算**（M0 10-31 决定） |
| `taskKind`(L261) | TaskKind | ✅ | recurring/oneTime 一一对应 |
| `deadline`(L264) | TaskDeadline | ✅ | `dateOnly`→`ScheduleDeadline.dateOnly`，`exact`→`.exact` |
| `earliestStartAt`(L267) | availableFrom | ✅ | 直接映射 |
| `priority`(L270) | — | ❌ | Task 模型无 priority 字段，须服务端快照/映射层提供 |
| `targetDurationSeconds`(L274) | targetDurationSeconds | ✅ | 直接复用 |
| `remainingMinutesToday`(L288) | — | 🔄 | 服务端可信快照折算（当天剩余），仅周期任务有意义 |

### 2.3 A2 ScheduleProposal → A1 API/Proposal

| A2 输出（schedule_contract.dart） | A1 契约位置 | 映射 | 说明 |
|---|---|---|---|
| `blocks`(L606) | 契约 §5.6 `schedule_block` | 🔄 | `ProposedBlock.toJson()`(L406) |
| `changes`(L609) | 契约白名单变更 | 🔄 | 仅 `schedule_one_time`/`upsert_daily_override` 两种 |
| `unplannedTasks`(L611) | 契约 §5.7 `unplanned_tasks` | 🔄 | `UnplannedTask.toJson()`(L528) 仅 4 键 |
| `notes`(L612) | 契约 §5.7 `explanations` | 🔄 | `toJson()` 键名即 `explanations`(L628) |
| `proposal_id/snapshot_ref/base_version/input_digest/generated_at/expires_at/status` | 契约服务端权威字段 | ❌ | M2 **不产出**，服务端包装层生成（方案 A） |

关键：`ScheduleProposal.toJson()`(L624-629) 只输出 `blocks/changes/unplanned_tasks/explanations` 四部分，服务端权威字段一律不输出（方案 A 明文，c53b1a9 起）。

### 2.4 缺口与冲突汇总

| 项 | 状态 | 说明 |
|---|---|---|
| Task.priority | ❌ 缺失 | 需 M0 定映射来源（服务端快照 or 新增字段），见 R2 相关 |
| availability null vs [] | ⚠️ 冲突 | 见 D3，契约 §6.3 远程接口甚至无 availability 字段 |
| baseVersion | ❌ 缺失 | 本地无版本概念，须服务端产生 |
| tagId | ❌ 未进 DTO | ScheduleTaskDemand 无标签，若需标签级统计/约束需扩展 |

---

## 3. generate / repair / validate 统一调用时序与边界

### 3.1 入口盘点（重要事实）

引擎**只有两个入口**，没有独立的 `validate` 入口：

| 入口 | 位置 | 签名 | 语义 |
|---|---|---|---|
| `generateSchedule` | schedule_engine.dart L377 | `ScheduleProposal generateSchedule(ScheduleInput input)` | 从零排一版提案 |
| `repairSchedule` | schedule_engine.dart L560 | `ScheduleProposal repairSchedule(ScheduleInput input, SchedulePlacement previous, {int? maxShiftMinutes})` | 硬约束变化后最小扰动重排 |

**`validate` 是服务端职责**（契约 `validate_schedule` 放服务端分界），M2 domain 不实现。这一点与此前 a1-a2 接口审查结论一致。若 M0 工作包第 3 项的「validate」指服务端校验层，则它属于 A1 侧，M2 只提供被校验的 proposal 形状。

### 3.2 generate 调用时序

```
服务端(A1)                          M2 domain(A2)
   │ 1. 组装 ScheduleInput（now/horizon/baseVersion/fixedBlocks/demands）
   │ 2. 调 generateSchedule(input)
   │ ──────────────────────────────────►  3. _usableWindows 裁剪+按日切分（L38）
   │                                      4. _effectiveAvailability（显式 or 偏好推导）
   │                                      5. 空闲片段 = 窗口 − 硬约束
   │                                      6. 需求排序（截止→priority→taskId）
   │                                      7. 逐条找位（最早可行，不拆分）
   │ ◄──────────────────────────────────  8. 返回 ScheduleProposal
   │ 9. 服务端生成 proposal_id/snapshot_ref/generated_at/status 等权威字段
   │ 10. 组装完整 Proposal（blocks/changes/unplanned_tasks/explanations + 权威字段）
```

### 3.3 repair 调用时序

```
服务端(A1)                          M2 domain(A2)
   │ 1. 拿上一版 proposal 的 blocks → List<SchedulePlacement> previous
   │ 2. 调 repairSchedule(input, previous, maxShiftMinutes: 120)
   │ ──────────────────────────────────►  3. 未被新硬约束撞到的块原样保留
   │                                      4. 被撞的块走 _placeNearest（就近，位移最小）
   │                                      5. 边界内无解 → 退最早可用（maxShiftMinutes 生效时）
   │ ◄──────────────────────────────────  6. 返回 ScheduleProposal（含 DISPLACED_BY_FIXED/REPAIR_SUMMARY）
   │ 7. 服务端过滤 repair 专用码（publicExplanations）
```

### 3.4 输入/输出 JSON 示例

`ScheduleInput` 不直接远程化——它是进程内 DTO。远程请求形状以契约 `generate_schedule` 为准（§6.3 仅 `date_range`/`external_fixed_events`/`preferences`）。`ScheduleProposal.toJson()` 输出形状见 2.3。

### 3.5 错误语义

| 层 | 错误码 | 来源 |
|---|---|---|
| HTTP/SDK 协议层 | §4.1 21 码 | 服务端 |
| violations | §5.8 8 值（含 BLOCK_OVERLAP） | 服务端校验产出 |
| unplanned reason | 4 值（WINDOW_INSUFFICIENT/PAST_DEADLINE/OVERLAPS_FIXED/NO_AVAILABILITY） | M2 `UnplannedReason`(L124-136) |
| explanations | 7 公共码 + 2 repair 专用码 | M2 `kPublicExplanationCodes`(L544)/`kRepairOnlyExplanationCodes`(L557) |

### 3.6 时区与日期边界

- 引擎**不做时区转换**（`timezone` 字段仅透传规范化，冻结目标守卫 34/36 已固化）。时区统一由服务层负责（R1 建议方案①：服务层统一转本地时间再入参）。
- 「块不跨自然日」由 `_splitByLocalDay`(L52-54) 保证：窗口按本地日切分后，每窗口属同一自然日。
- 日期型截止 `latestEndAt`(L194-200)：当天最后一刻；不伪造 23:59 记录（仅排程含义）。
- `minuteOfDay`(L633) 从 00:00 起算，用于 `planned_start_minute` 等契约字段。

---

## 4. 服务端权威字段 / 客户端可提供 / 禁止自定

### 4.1 服务端权威字段（M2 不产出，服务端生成并持久化）

`proposal_id`、`snapshot_ref`、`base_version`、`input_digest`、`generated_at`、`expires_at`、`status`。

依据：方案 A（M0 2026-10-31 决定，c53b1a9 起写入契约 §5.7），`ScheduleProposal.toJson()` 只输出内部四部分。

### 4.2 客户端可提供字段（M2 可信快照折算后填入 DTO）

- `requiredMinutes`（服务端可信快照估算，非 LLM 伪估算）
- `remainingMinutesToday`（服务端可信快照折算，仅周期任务）
- `baseVersion`（服务端可信服务产生，进程内仅测试用）

### 4.3 禁止客户端自行决定的字段

| 字段 | 禁令 | 依据 |
|---|---|---|
| `scheduling_weight` | 契约 §5.2 仍 BLOCKED，M2 不消费不伪造；tie-break 层级待 M0 指位 | R2 |
| `maxShiftMinutes` | M2 不自定阈值；M0 已裁定服务层默认 120，domain Dart 默认 null（无边界） | R3 |
| `availability` 的 null/[] 语义 | 契约 §6.3 无 availability 字段，null/[] 区分属契约层，待 M0 裁定 | D3 |
| repair 专用码 | 不进 v1 公开响应，服务端用 `publicExplanations` 过滤 | D2 |

### 4.4 关键字段专门处理（M0 工作包第 4 项点名的 5 项）

1. **availability null/[]**：当前 `ScheduleInput.availability` non-nullable `const []`，空一律按 preferences 推导（`_effectiveAvailability`）。无法表达「null=未指定 vs []=明确无时间」区分。详见 D3（方案 A 保持现状 vs 方案 B 改 nullable）。契约 §6.3 远程接口无 availability 字段，属契约空白待 M0。
2. **scheduling_weight**：§5.2 BLOCKED，M2 确定性由「截止 rank → priority 降序 → taskId 字典序」兜底（`_orderedDemands` L168）。weight 层级待 M0 指位，M2 不引入新 tie-break 层。
3. **maxShiftMinutes=120**：M0 已裁定服务层默认 120。domain Dart 默认 null（无边界）。120 常量由谁导出（M2 domain `kDefaultMaxShiftMinutes` vs 服务端自建）待定，见 R3。入口尚不存在（全仓 grep 无生产调用），不预建。
4. **publicExplanations**：`ScheduleProposal.publicExplanations`(L620-621) 滤掉 repair 专用码 + 枚举外码。服务端序列化必须用这个 getter，**不能用 `toJson()['explanations']`**（那会漏进 repair 码）。
5. **repair code 过滤**：`DISPLACED_BY_FIXED`/`REPAIR_SUMMARY` 在 `kRepairOnlyExplanationCodes`，`isPublic=false`。过滤责任落点见 D2（建议方案①：服务端序列化层负责）。

### 4.5 关键事实（M3 已核验，D2 技术事实闭合）

`ScheduleProposal.toJson()` **确实输出 explanations 全集**（含 repair 专用码），`publicExplanations` 才是唯一公开入口。因此 E2E-EXPL-FILTER 是真实义务：服务端若不用 `publicExplanations`，契约 §5.7 当场失守。此事实双方无分歧，但仍待 M0 一句确认（M2 不自行裁定）。

---

## 5. 48 条测试逐项证据状态

> 三档严格区分：**清单核对**（有清单、有编号）｜**源码检查**（行号逐位命中，M3 已做 2d068687 交付）｜**实际运行通过**（本轮两通道实测，仅 M2 能做）。
> 本轮我做的：源码检查引用 M3 结果（不重做）；实际运行两通道全跑通。

### 5.1 实际运行证据（本轮，2026-11-04 00:38 前后）

| 通道 | 命令 | 结果 |
|---|---|---|
| 隔离工程 `/e/m2-verify` | `dart test test/agent_scheduler_test.dart`（PATH 含 /e/flutter/bin） | **48/48 All tests passed!**（退出码 0） |
| 宿主工程 | `flutter test test/agent_scheduler_test.dart`（去代理） | **48/48 All tests passed!**（退出码 0） |

两通道结果一致，无 skip、无 flaky。宿主编译后已 `git checkout --` 还原 macos/Flutter/GeneratedPluginRegistrant.swift 与 windows/flutter/generated_* 四个被自动改写的文件。

### 5.2 逐项清单（8 group，48 条）

> 每项列：编号｜名称｜源码行号｜层级｜证据状态。行号以 `test/agent_scheduler_test.dart` 为准。

**Group 1 · generateSchedule 硬避让（2 条）**
| # | 名称 | 行号 | 层级 | 状态 |
|---|---|---|---|---|
| 1 | 任务必须绕开固定课程 | L39 | L1 纯函数 | 清单✅ 源码✅ 运行✅ |
| 2 | 多个课程之间依次避让且不重叠 | L74 | L1 | 清单✅ 源码✅ 运行✅ |

**Group 2 · 截止语义（3 条）**
| # | 名称 | 行号 | 层级 | 状态 |
|---|---|---|---|---|
| 3 | 精确截止已过则不再排入 | L114 | L1 | 清单✅ 源码✅ 运行✅ |
| 4 | 日期型截止整天宽限，不能被当成 23:59 处理 | L145 | L1 | 清单✅ 源码✅ 运行✅ |
| 5 | ScheduleDeadline 两种形态互斥且语义不同 | L172 | L1 | 清单✅ 源码✅ 运行✅ |

**Group 3 · 容量与冲突处理（3 条）**
| # | 名称 | 行号 | 层级 | 状态 |
|---|---|---|---|---|
| 6 | 可用时间不足时给出未安排量与机器可读原因 | L188 | L1 | 清单✅ 源码✅ 运行✅ |
| 7 | 固定项相互重叠时不会通过移动它们来消解冲突 | L216 | L1 | 清单✅ 源码✅ 运行✅ |
| 8 | 开放时段被占满时报 OVERLAPS_FIXED | L263 | L1 | 清单✅ 源码✅ 运行✅ |

**Group 4 · 确定性与边界（4 条）**
| # | 名称 | 行号 | 层级 | 状态 |
|---|---|---|---|---|
| 9 | 相同输入必须得到完全相同的输出 | L299 | L1 | 清单✅ 源码✅ 运行✅ |
| 10 | 确定性排序：打乱输入列表顺序不改变任何输出字节 | L369 | L1 | 清单✅ 源码✅ 运行✅ |
| 11 | 同等约束下的兜底排序键是 taskId 字典序（scheduling_weight 尚不参与） | L450 | L1 | 清单✅ 源码✅ 运行✅ |
| 12 | 排出来的块不跨自然日 | L477 | L1 | 清单✅ 源码✅ 运行✅ |

**Group 5 · repairSchedule 最小扰动重排（9 条）**
| # | 名称 | 行号 | 层级 | 状态 |
|---|---|---|---|---|
| 13 | 插入会议只移动冲突的柔性块 | L514 | L1 | 清单✅ 源码✅ 运行✅ |
| 14 | 被撞掉的块就近重排：落在原位置之后最近空档，不是最早可用 | L580 | L1 | 清单✅ 源码✅ 运行✅ |
| 15 | 就近重排：位移相同时优先落在原位置之后 | L672 | L1 | 清单✅ 源码✅ 运行✅ |
| 16 | 就近重排：只有往前才排得下时才往前，不跳到最早可用 | L713 | L1 | 清单✅ 源码✅ 运行✅ |
| 17 | 就近重排：边界内两侧都不可行时退最早可用兜底 | L757 | L1 | 清单✅ 源码✅ 运行✅ |
| 18 | 就近重排：搜索边界不会误杀界内候选 | L809 | L1 | 清单✅ 源码✅ 运行✅ |
| 19 | 不传 maxShiftMinutes 就是无边界：超 120 分钟的位移照常接受 | L856 | L1 | 清单✅ 源码✅ 运行✅ |
| 20 | 无可排位置时返回未安排量与理由 | L905 | L1 | 清单✅ 源码✅ 运行✅ |
| 21 | 上一版未排进去的任务在重排时会被重新尝试 | L945 | L1 | 清单✅ 源码✅ 运行✅ |

**Group 6 · 与 M0 v1 契约对齐（6 条）**
| # | 名称 | 行号 | 层级 | 状态 |
|---|---|---|---|---|
| 22 | 单次事项与周期任务分别产出各自的白名单变更 | L1003 | L1 | 清单✅ 源码✅ 运行✅ |
| 23 | 提案 JSON 字段与契约第 5.7 节一致 | L1032 | L1 | 清单✅ 源码✅ 运行✅ |
| 24 | 未显式给出可用窗口时用 preferences 逐日推导 | L1068 | L1 | 清单✅ 源码✅ 运行✅ |
| 25 | 小于最小块长度的碎片不参与排程 | L1094 | L1 | 清单✅ 源码✅ 运行✅ |
| 26 | generate 输出块两两不重叠：不会触发 §5.8 BLOCK_OVERLAP | L1124 | L1 | 清单✅ 源码✅ 运行✅ |
| 27 | repair 输出块两两不重叠：重排后也不会撞到别人 | L1172 | L1 | 清单✅ 源码✅ 运行✅ |

**Group 7 · 冻结目标守卫（20 条）**
| # | 名称 | 行号 | 层级 | 状态 |
|---|---|---|---|---|
| 28 | 时长优先级：任务自带目标优先于调用方给出的时长 | L1237 | L1 | 清单✅ 源码✅ 运行✅ |
| 29 | 时长兜底为 max(minimum_block_minutes, 30)，且一律算估算 | L1269 | L1 | 清单✅ 源码✅ 运行✅ |
| 30 | remaining_minutes_today 为 0 时不再排程，且不算未安排 | L1312 | L1 | 清单✅ 源码✅ 运行✅ |
| 31 | remaining_minutes_today 非空时优先于完整目标 | L1342 | L1 | 清单✅ 源码✅ 运行✅ |
| 32 | P3 样例一：remaining_minutes_today=0 不排程、不算未安排、产出 ALREADY_DONE_TODAY | L1369 | L1 | 清单✅ 源码✅ 运行✅ |
| 33 | P3 样例二：remaining_minutes_today=40 时只排 40 分钟且标 task_target | L1401 | L1 | 清单✅ 源码✅ 运行✅ |
| 34 | horizon 起止会改变输出，因此 input_digest 必须覆盖它 | L1430 | L1 | 清单✅ 源码✅ 运行✅ |
| 35 | 时区只作为可规范化字段携带，M2 不做时区转换 | L1454 | L1 | 清单✅ 源码✅ 运行✅ |
| 36 | B19：remaining_minutes_today 三态语义（null / 0 / 正数） | L1473 | L1 | 清单✅ 源码✅ 运行✅ |
| 37 | 时区标签不改变 M2 输出（M2 不做时区转换） | L1517 | L1 | 清单✅ 源码✅ 运行✅ |
| 38 | 内部调度 DTO 递归不含任何服务端字段 | L1548 | L1 | 清单✅ 源码✅ 运行✅ |
| 39 | explanations 码必须落在 v1 公共枚举内，repair 专用码不得外泄 | L1598 | L1 | 清单✅ 源码✅ 运行✅ |
| 40 | 未安排项带 reason_code、remaining_minutes 与 message | L1653 | L1 | 清单✅ 源码✅ 运行✅ |
| 41 | 写入次数可推算：每 block 恰一条白名单变更，change_id 唯一，状态恒为 draft | L1677 | L1 | 清单✅ 源码✅ 运行✅ |
| 42 | 周期任务同一本地日最多一个 block，且同一 (任务, 日期) 只产出一条变更 | L1728 | L1 | 清单✅ 源码✅ 运行✅ |
| 43 | DTO 键集合与契约逐字对齐：不多不少，服务端字段除外 | L1762 | L1 | 清单✅ 源码✅ 运行✅ |
| 44 | 单次事项必须显式带与 planned_date 同日的 scheduled_at | L1896 | L1 | 清单✅ 源码✅ 运行✅ |
| 45 | 单日例外变更字段齐全、分钟合法，且同一唯一键在提案内只出现一次 | L1935 | L1 | 清单✅ 源码✅ 运行✅ |
| 46 | reason_code 取值必须落在封闭枚举内 | L2012 | L1 | 清单✅ 源码✅ 运行✅ |
| 47 | explanations 元素结构统一，且不带额外字段 | L2039 | L1 | 清单✅ 源码✅ 运行✅ |

**Group 8 · 模块边界（1 条）**
| # | 名称 | 行号 | 层级 | 状态 |
|---|---|---|---|---|
| 48 | 调度模块不得访问数据库或任何应用层代码 | L2098 | L1 | 清单✅ 源码✅ 运行✅ |

### 5.3 证据状态口径说明

- **清单核对**：M2 11:33 自行产出 48 条清单（编号/名称/覆盖逻辑）。
- **源码检查**：M3 23:24 已交付 2d068687 文件，48/48 行号逐位命中，L39/L1598/L2098 原位抽查，expect 202 处，断言体在位。**M2 本轮不重做，直接引用**（哈希与比对方法在 M3 Addendum-1 §1、§8，可复算）。
- **实际运行通过**：本轮两通道 48/48，退出码 0（§5.1）。这是三档里唯一 M2 独有、也只有 M2 能做的。

---

## 6. 与 A1 §7 29 条、v3 §11 29 条的追踪映射

### 6.1 事实边界（重要）

- **v3 §11 的 29 条**：M1 08:32:17Z v3 文档 §11 的文档层 T-DOC-01~04 共 4 条 + 十项缺口 25 条。M2 可读（已在 cross-review 里核对过其结构）。
- **A1 §7 的 29 条**：**原文在 M1 手中，M2 没有**。M3 的 A3 矩阵第三张表 29 行也因此空着。

M3 已向 M0 建议：「A1 §7 原文由 M1 交包时一次性分发给 M2 与 M3，避免三次索要、三份不一致版本」。**M2 采纳此建议，当前无法对 A1 §7 29 条做逐项追踪映射**——这是跨模块依赖，属阻塞项（见 §8.4）。

### 6.2 三张表严格分离（不合并）

| 表 | 行数 | 归属 | M2 侧状态 |
|---|---|---|---|
| A2 48 条 | 48 | M2 纯函数测试 | 三档全过（§5） |
| M1 v3 §11 29 条 | 29 | M1 服务端验收（文档层 4 + 缺口 25） | 结构已核（cross-review），逐项源码追踪待 A1 落地 |
| A1 §7 29 条 | 29 | M1 A1 文档 | **无原文，无法追踪**（待 M1 分发） |

**口径铁律**：48+29+29 永不相加；不拿 77 当覆盖率；4/29≈13.8% 仅指 v3 §11 的文档层 4 条可执行，不代表 A 轨整体验收率。

### 6.3 M2 侧可给的最小追踪（在 A1 §7 原文到位前的临时对齐）

M2 的 48 条是「纯函数验收」，M1 的 29 条是「服务端验收」，二者互补不重叠（此结论与 a-track-cross-review.md 一致）。A1 §7 原文到位后，M2 按「字段/职责/时序」三维做逐项映射，不因数量接近就合并。

---

## 7. 修正版 Canonical Decision Register（第 7 项）

完整注册表在独立文件 `canonical-decision-register.md`。本轮针对 M3 14:54Z 的核验反馈做三处修正：

1. **项数口径明确**：12 个小节（11 项实质 + 1 个 M-1~M-4 合并块），15 是 canonical ID 数，不是独立条目数。已在注册表汇总表明确标注「12 节 / 15 ID」。
2. **补齐 4 类缺失字段**：M0 包 B 要求 11 字段，原版缺「最终决策人」「现状」「阻塞的 API/测试」「技术影响」4 类。本轮逐项补全。
3. **M1↔M2 编号映射落实**：原版 11 项「同号复用」被 M3 判定为「实际未提供编号映射」。本轮明确 M1 侧编号（Q2/R4/Q3/R5/R6/R7 来自 M1 A1 定义）与 M2 侧原报告编号的对应关系，D3 那格补上真实语义（不再用语义描述冒充编号）。

**D2 疑点回应**（M3 14:54Z 提出）：D2 的两个候选方案（①默认 toJson 维持全集 ②默认只出公共码）是**互斥候选**，不是并列结论。技术事实已闭合：`toJson()` 当前输出全集，`publicExplanations` 是唯一公开入口（用例㊴/L1598 断言的是 `isPublic` 与 `publicExplanations`，不是 `toJson`）。**M2 建议方案①（toJson 维持全集，服务端用 publicExplanations 过滤）**，但 D2 的「M2 零改动」能否成立最终由 M0 裁定，M2 不自行定。

（注册表文件随本工作包一并交付，未提交。）

---

## 8. 集成实施蓝图（第 8 项）

### 8.1 模块边界

| 模块 | 归属 | 职责 | 依赖 |
|---|---|---|---|
| A2 domain（纯函数引擎） | M2 | generateSchedule/repairSchedule，零 DB/零 IO | 无（纯 Dart） |
| 快照→ScheduleInput 映射层 | M0/M1 服务端 | 从一致性快照折算 DTO（requiredMinutes/remainingMinutesToday/priority） | 权威快照定义（R4） |
| A1 API/Proposal 组装 | M1 | 序列化、服务端权威字段、publicExplanations 过滤 | A2 proposal 形状 |
| 落库执行（changes 应用） | M1 服务端 | 应用 schedule_one_time/upsert_daily_override | CheckD repository |

### 8.2 M1 API 依赖

M2 需要 M1 提供/确认：① A1 §7 29 条原文（§6.1 阻塞）；② 服务端统一调用 A2 的入口契约（adapter 输入输出）；③ publicExplanations 过滤落点（D2）。

### 8.3 可并行工作

- M1：A1 服务端蓝图 §8 六阶段 + Supabase 对接盘点（M1 独立工作包）。
- M3：A3 验收矩阵（已交付四份 + 增量，待 M0 定「M3 有无工作包」）。
- M2：本准入包（已交付），无并行代码任务。

### 8.4 阻塞项（按优先级）

| 阻塞 | canonical ID | 解锁 | 依赖 |
|---|---|---|---|
| 权威快照定义 + base_version 算法 | R4 | T-3.8-01 | M0 裁定 |
| 审批 Token 签发方 | Q2 | T-3.4-01/02 | M0 裁定 + 可能 IdP |
| 双人复核覆盖面 + 分级依据 | Q3/R5 | T-3.9-01/02/03 | M0 裁定 |
| availability null/[] 语义 | D3 | 契约 §6.3 空白 | M0 裁定 |
| scheduling_weight 层级 | R2 | §5.2 BLOCKED | M0 指位 |
| maxShiftMinutes=120 入口归属 | R3 | 服务层默认路径测试 | 真实入口出现 |
| retryable 18 码补值 | R6 | 验收判定面 | M0 补契约 |
| repair 码过滤落点 | D2 | E2E-EXPL-FILTER | M0 确认 |
| A1 §7 原文 | — | §6 追踪映射 | M1 分发 |

### 8.5 验收条件（明早 M0 统一验收）

1. 修正版 Canonical Decision Register 覆盖 D2/D3/R1/R2/R3/Q2/R4/Q3/R5/R6/R7/M-1~M-4，Q2 与 R4 分列，M-1~M-4 标「定义缺失待 M0」。
2. 字段映射表：直接复用/转换/缺失/冲突四类标记齐全（§2）。
3. 48 条测试三档证据状态严格区分（§5），实际运行两通道 48/48。
4. 29 条追踪映射：v3 §11 结构已核；A1 §7 标注「待 M1 分发」而非伪造。
5. 实施蓝图含模块边界、依赖、并行、阻塞、验收（§8）。

### 8.6 边界重申

本工作包全部为只读盘点 + 文档方案。未改任何代码/契约/Mock/测试/数据库；未提交、未推送、未建 PR、未合并；未连接 check-c、未索取生产密钥。PR #2 head 仍 070fb6e，冻结基线（录制 7e1367c2 + 契约 39f7f965）未动。
