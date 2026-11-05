# A 轨调度引擎集成与服务接线实施蓝图（工作包 A2）

> 依据：M0 2026-11-03 09:34Z 邮件《[CheckD][M0大型工作包 A2] A轨调度引擎集成与服务接线完整实施蓝图》。
> 性质：**纯设计蓝图 + 测试规划**。未改任何生产代码、契约、Mock、现有测试、M3 录制材料。
> 未提交、未推送、未建 PR、未合并；PR #2/#3/#4 head 与冻结基线均未动。
> 负责人：B（M2 刘恒瑜）。

## 基准声明（本文所有事实引用的锚点）

| 项 | 值 |
|---|---|
| M2 代码基准 | `feat/m2-scheduler-basic` head `070fb6e`（`lib/features/agent_scheduler/domain/` + `test/agent_scheduler_test.dart`） |
| M2 文档版本 | 本蓝图 v1；输入文档 `a-track-integration-map.md` v1、`a-track-cross-review.md` v1 |
| 契约基准 | `docs/contracts/agent-api-v1.md` + `agent-api-v1.examples.json` @ `39f7f965`（§5.8 为八值 violations，含 `BLOCK_OVERLAP`） |
| M1 侧参照 | M1 代码 `7e1367c2`、S0 清单 29 条（服务端用例，本蓝图仅做分层映射，不重复计数） |
| 纯函数测试 | **48 条**（`test/agent_scheduler_test.dart`） |

> 每项标注体系：[现有代码事实] / [契约已支持] / [设计建议] / [待 M0 裁定] / [需要真实资源验证]。
> 所有未证实假设显式标注为「假设」，不作事实陈述。

---

## 一、现有调度引擎能力盘点

### 1.1 两个公开入口（`schedule_engine.dart`）

| 入口 | 签名 | 位置 | 语义 | 状态 |
|---|---|---|---|---|
| 从零排程 | `ScheduleProposal generateSchedule(ScheduleInput input)` | `:377` | 最早可行贪心，不拆分 | [现有代码事实] |
| 最小扰动重排 | `ScheduleProposal repairSchedule(ScheduleInput input, ScheduleProposal previous, {int? maxShiftMinutes})` | `:560` | 只移被撞块；`maxShiftMinutes` 可选边界 | [现有代码事实] |

引擎两条纪律（头注释）：不 import repository/drift/UI；不调用 `DateTime.now()`（时间基准全来自 `ScheduleInput.now`）→ 保证「相同输入相同输出」可复现。

### 1.2 关键输入/输出类型（`schedule_contract.dart`）

| 类型 | 符号 | 关键字段 |
|---|---|---|
| 排程输入 | `ScheduleInput` | `now`、`horizonStart/End`、`baseVersion`（服务端可信版本）、`timezone`（默认 Asia/Shanghai，**引擎未消费**）、`preferences`、`availability`、`fixedBlocks`、`demands`、`existingPlacements` |
| 任务需求 | `ScheduleTaskDemand` | `taskId/title/requiredMinutes`（服务端可信快照）、`taskKind`、`deadline`、`earliestStartAt`、`priority`、`targetDurationSeconds`、`remainingMinutesToday`（服务端可信快照三态） |
| 硬约束 | `ScheduleFixedBlock` | `ownerId/ownerType`（course/event）、`startAt/endAt/title`，**永不可移动** |
| 偏好 | `SchedulePreferences` | `dayStartMinute=480`、`dayEndMinute=1320`、`minimumBlockMinutes=15` |
| 提案 | `ScheduleProposal` | 只含四部分 `blocks/changes/unplannedTasks/notes`（方案 A，§5.7 明文） |
| 展示块 | `ProposedBlock` | `blockId=blk-$taskId`、`source=proposal`、`persistableAs`、`durationSource` |
| 白名单变更 | `ProposedScheduleChange` | 仅两种实现：`ScheduleOneTimeChange`（单次事项）、`UpsertDailyOverrideChange`（周期任务） |
| 未排任务 | `UnplannedTask` | `remainingMinutes/reason/reasonText`，JSON 恰好四项 |
| 解释 | `ScheduleNote` | `code/message/taskId`，`isPublic` 判据 |

### 1.3 已实现能力 vs 仅文档建议 vs 未实现

| 能力 | 状态 | 依据 |
|---|---|---|
| 确定性排序（截止 rank → priority 降序 → taskId 字典序） | ✅ 已实现 | `_orderedDemands` `:169`；打乱输入顺序输出逐字节不变（2 条用例） |
| 时长三级优先级（目标 > 快照估算 > 兜底 `max(minBlock,30)`） | ✅ 已实现 | `_durationOf` `:209` |
| `remaining_minutes_today` 三态（0/正/null） | ✅ 已实现 | `_durationOf` `:213-218` |
| 块不跨本地日 | ✅ 已实现 | `_splitByLocalDay` `:82` |
| 块间两两不重叠（§5.8 `BLOCK_OVERLAP` 构造性成立） | ✅ 已实现 | `_subtract` 每放一块即扣除；2 条守卫 |
| 硬约束重叠只记录不解决 | ✅ 已实现 | `_overlappingFixedBlocks` `:146` |
| repair 就近重排 + `maxShiftMinutes` 边界 | ✅ 已实现 | `_placeNearest` `:278`；第 48 条无边界守卫 |
| 方案 A 序列化（只输出内部四部分） | ✅ 已实现 | `ScheduleProposal.toJson` `:624` |
| `validate_schedule`（§5.8 八值 violations） | ❌ 未实现 | [契约已支持] 属服务端职责，M2 不产出 violations |
| 服务层组装 ScheduleInput | ❌ 未实现 | [设计建议] 无调用方（grep 已验证） |
| 服务端权威字段（proposal_id 等） | ❌ 未实现 | [设计建议] 方案 A 归服务端包装层 |
| `scheduling_weight` | ⚠️ 仅文档建议 | [契约已支持 §5.2 仍 BLOCKED]，M2 不消费不伪造 |
| 时区解析 | ⚠️ 字段存在、引擎未消费 | [待 M0 裁定] 语义未定 |
| `maxShiftMinutes=120` 服务层落地 | ⚠️ 参数已实现、服务层默认待接入 | [待 M0 裁定] 入口归属 |

---

## 二、可信快照 → 调度输入的完整映射

### 2.1 字段映射表（可信快照字段 → `ScheduleInput` / `ScheduleTaskDemand`）

| 快照来源 | 映射目标 | 类型 | 组装规则 | 状态 |
|---|---|---|---|---|
| 任务（Task） | `ScheduleTaskDemand.taskId/title` | String | 直接取可信快照 task id/name | [设计建议] |
| 周期任务剩余量 | `ScheduleTaskDemand.remainingMinutesToday` | int? | 服务端从一致性快照折算，`0` 表已完成；**不得接受 LLM 伪可信估算** | [现有代码事实 + 设计建议] |
| 任务时长目标 | `ScheduleTaskDemand.targetDurationSeconds` | int? | 快照 `duration_target_seconds` | [设计建议] |
| 服务端快照估算 | `ScheduleTaskDemand.requiredMinutes` | int | 服务端从快照折算（非 LLM 直供） | [设计建议] |
| 任务类型 | `ScheduleTaskDemand.taskKind` | enum | 周期任务→recurring、单次事项→oneTime | [设计建议] |
| 截止 | `ScheduleTaskDemand.deadline` | `ScheduleDeadline?` | 日期型→`dateOnly`、精确型→`exact`，**绝不伪造 23:59** | [设计建议] |
| 可开始时刻 | `ScheduleTaskDemand.earliestStartAt` | DateTime? | `availableFrom` | [设计建议] |
| 优先级 | `ScheduleTaskDemand.priority` | int | 快照 priority（截止相同时参与排序） | [设计建议] |
| 课程/会议 | `ScheduleInput.fixedBlocks` | `List<ScheduleFixedBlock>` | 课程→`ownerType.course`、外部会议→`ownerType.event` | [设计建议] |
| 用户偏好 | `ScheduleInput.preferences` | `SchedulePreferences` | 快照 `day_start/end_minute`、`minimum_block_minutes` | [设计建议] |
| 可用窗口 | `ScheduleInput.availability` | `List<ScheduleWindow>` | 显式给出时优先，否则由偏好逐日推导 | [现有代码事实] |
| 数据版本 | `ScheduleInput.baseVersion` | String | 可信服务产生的版本号 | [契约已支持 + 设计建议] |
| 时区 | `ScheduleInput.timezone` | String | 默认 Asia/Shanghai；**引擎当前不消费，需服务层先统一转换** | [待 M0 裁定] |
| 基准时刻 | `ScheduleInput.now` | DateTime | 服务层传入，**引擎不自行读系统时间** | [现有代码事实] |
| 上一版安排 | `ScheduleInput.existingPlacements` | `List<SchedulePlacement>` | repair 时由上一版 Proposal 折出 | [现有代码事实] |

### 2.2 数据缺失 / 过期 / 冲突处理（服务层职责，M2 不越界）

| 场景 | 处理 | 责任方 | 状态 |
|---|---|---|---|
| 快照缺 `remaining_minutes_today` | 回落完整 `targetDurationSeconds` | 引擎已处理 | [现有代码事实] |
| 快照缺时长目标与估算 | 兜底 `max(minBlock,30)`，标 `scheduler_estimate` | 引擎已处理 | [现有代码事实] |
| 快照版本过期（`base_version` 陈旧） | 服务层事务核验拒绝 | 服务层 | [需要真实资源验证] |
| 快照字段冲突/不一致 | 服务层以单一致性快照为准，拒绝脏读 | 服务层 | [需要真实资源验证] |
| 截止已过 | 引擎入 `unplanned_tasks`（`PAST_DEADLINE`） | 引擎已处理 | [现有代码事实] |

---

## 三、调度输出 → 服务端 Proposal 的映射

### 3.1 字段生成/校验责任矩阵

| 字段 | M2 引擎（domain） | 服务端包装层 | 状态 |
|---|---|---|---|
| `blocks` | ✅ 生成 | 透传 | [现有代码事实] |
| `changes` | ✅ 生成（白名单两种 type） | 透传 + 事务核验 | [现有代码事实] |
| `unplanned_tasks` | ✅ 生成（四值 reason_code） | 透传 | [现有代码事实] |
| `explanations` | ✅ 生成（七公共码） | 用 `publicExplanations` 滤掉 repair 专用码 | [现有代码事实] |
| `violations`（§5.8 八值） | ❌ 不产出 | ✅ `validate_schedule` 生成 | [契约已支持] |
| `proposal_id` / `snapshot_ref` / `base_version` / `input_digest` / `generated_at` / `expires_at` / `status` | ❌ 不产出（方案 A） | ✅ 生成并持久化 | [契约已支持 §5.7] |

### 3.2 服务端必须补充或重算的权威字段（M2 绝不伪造）

1. `proposal_id` — 提案唯一标识；
2. `snapshot_ref` — 快照引用；
3. `base_version` — 数据版本（事务核验用）；
4. `input_digest` — 覆盖 horizon 起止 + Asia/Shanghai 时区（M0 已裁定要含）；
5. `generated_at` / `expires_at` — 生成时刻 / 30 分钟 TTL；
6. `status` — 状态机（draft → … → applied/rejected/expired/failed）。

---

## 四、规则决策卡（R1–R7）

> 每项列：可确认事实 + 备选方案（≥2）+ 影响 + 阻塞点 + 推荐（明确标「建议」，不替 M0 决定）。

### R1 · 时区语义（引擎输入侧）

- **事实**：`ScheduleInput.timezone` 字段存在（默认 Asia/Shanghai），引擎当前**未消费**；`ScheduleDeadline.isPast` 用 `toUtc()` 比较，跨时区 DST 边界未定义。[现有代码事实]
- **备选**：① 服务层统一把时间转成本地 `DateTime` 再入参（引擎零改动）；② 引擎内解析 timezone（需引入时区库，破坏 domain 零依赖纪律）；③ 固定 Asia/Shanghai（简单但锁死）。
- **影响**：① 服务层/组装侧；② domain 增依赖；③ 契约语义。
- **阻塞**：不裁定 → 跨时区排程的「块不跨日」「截止判定」无法写引擎侧用例。
- **推荐（建议）**：① 服务层统一转本地时间，domain 保持零时区库依赖。

### R2 · `scheduling_weight` 层级

- **事实**：契约 §5.2 仍标 BLOCKED；M2 不消费不伪造；当前确定性由「截止 rank → priority 降序 → taskId 字典序」兜底，已用「打乱输入顺序输出逐字节不变」锁死。[现有代码事实]
- **备选**：① 不参与（服务端折算成 priority）；② 截止后、优先级前；③ 优先级后、taskId 前。
- **影响**：调度输出确定性排序；若插入会改 `_orderedDemands`。
- **阻塞**：§5.2 持续 BLOCKED，M2 不消费。
- **推荐（建议）**：① 服务端把 weight 折算进 priority，M2 不引入新 tie-break 层。

### R3 · `maxShiftMinutes=120` 服务入口归属

- **事实**：M0 已裁定服务层默认 120；`repairSchedule` 已实现可选边界，domain Dart 默认 `null`（无边界）；全仓无调用方。[现有代码事实]
- **备选**：① M2 domain 建常量 `kDefaultMaxShiftMinutes=120` + 服务层接线；② 服务端包装层自建常量。
- **影响**：① domain 小改（仅新增常量，不改算法）；② 常量落在服务端，domain 零改动。
- **阻塞**：120 一直是「待接入」，服务层默认路径测试无法写。
- **推荐（建议）**：① domain 导出单一事实源常量，服务层引用（阈值将来只改一处）；入口出现时与接入同轮提交。

### R4 · Q2 审批 Token 签发方

- **事实**：§6.5 已定义「未终结审批」集合（R1 死锁已解）；Token 签发方归属未定。[契约已支持 + 待 M0 裁定]
- **备选**：① M2 调度侧（不可能，M2 纯函数无状态）；② M0 侧；③ 外部 IdP。
- **影响**：T-3.4-01/02 无法开工。
- **阻塞**：3.4 缺口整体 BLOCKED。
- **推荐（建议）**：③ 外部 IdP（Supabase Auth），与 M1 服务端蓝图的 IdP 一致。

### R5 · Q3 双人复核覆盖面

- **事实**：§15 表二 review 字段契约待定；M1 单列 3.9 双人复核缺口。[待 M0 裁定]
- **备选**：① 全面强制复核；② 仅高风险（大位移/写例外）才复核。
- **影响**：T-3.9 系列、§15 表二。
- **阻塞**：3.9 缺口 BLOCKED。
- **推荐（建议）**：② 高风险才复核（降低端到端时延）。

### R6 · `retryable` 18 码补值

- **事实**：M1 §14.5 发现 21 个 §4.1 错误码里 18 个 `retryable` 未定义；M2 从调度侧佐证 `READBACK_MISMATCH` 若标 true 会触发终态 failed 重复写入，与 §6 冲突。[现有代码事实 + 契约空白]
- **备选**：① 按 M1 §14.5 建议表补值；② 逐码另定。
- **影响**：契约 §4.1、验收判定。
- **阻塞**：18 码 `retryable` 无契约值，验收无法判对错。
- **推荐（建议）**：① 采纳 M1 §14.5 建议表（M2 已佐证 `READBACK_MISMATCH` 应为 false）。

### R7 · `error.details` 是否承载 violation code（M-4）

- **事实**：§5.8 八值 violations 与 §4.1 二十一个错误码严格分开（零交集）。[契约已支持]
- **备选**：① 允许 `error.details` 复用 8 值（502 后细化原因）；② 不承载。
- **影响**：回读不一致定位能力。
- **阻塞**：`READBACK_MISMATCH`（502）无法定位具体违规块。
- **推荐（建议）**：① 允许 `details` 承载 violation code，但**不得**与 §4.1 错误码混用。

---

## 五、校验与错误边界（§5.8 八值 vs §4.1 二十一码）

### 5.1 两个闭集严格分离

| 闭集 | 位置 | 值个数 | 归属 | M2 是否产出 |
|---|---|---|---|---|
| `explanations[].code` | §5.7 | 7（`kPublicExplanationCodes`） | M2 输出侧 | ✅ 是 |
| `validate_schedule.violations[].code` | §5.8 | 8（含 `BLOCK_OVERLAP`） | 服务端校验 | ❌ 否 |
| `unplanned_tasks.reason_code` | §5.7 | 4（`UnplannedReason`） | M2 输出侧 | ✅ 是 |
| `§4.1` 错误码 | §4.1 | 21 | 服务端 HTTP | ❌ 否 |

### 5.2 `validate_schedule` 调用层与返回结构

- **调用层**：服务端包装层，在 M2 引擎产出内部四部分之后、组装完整 Proposal 之前/之后各一道（建议：组装前先验 blocks 结构，组装后验完整 Proposal）。[设计建议]
- **返回结构**：`violations[]` 每项含 `code`（八值闭集）+ 定位信息（block/task 引用）。[契约已支持 §5.8]
- **HTTP/service 错误映射**：业务校验失败（violation）**不是** HTTP 错误——violations 是 `validate_schedule` 工具的**正常成功响应**；HTTP 错误码（§4.1）只用于协议层失败（如 502 `READBACK_MISMATCH`、503 `READBACK_PENDING`）。[设计建议]
- **防误写**：服务端不得把「检出 violation」映射成 4xx/5xx；反之，§4.1 错误码也不得降级成 violations 列表。

---

## 六、并发与一致性接线

### 6.1 责任边界（domain 不应承担哪些职责）

| 职责 | 归属 | M2 domain 是否承担 | 状态 |
|---|---|---|---|
| `snapshot_version`/`base_version` 产生与校验 | 服务端 + 事务 | ❌ 不承担 | [契约已支持] |
| 服务端重读（权威 readback） | 服务端 | ❌ 不承担 | [契约已支持 §6.7] |
| Proposal 状态机（8 态） | 服务端 | ❌ 不承担（M2 proposal 恒 draft，且方案 A 不输出 status） | [契约已支持] |
| 幂等键（approval_id / 幂等记录） | 服务端 | ❌ 不承担 | [契约已支持 §6.5] |
| 事务原子写入 | 服务端 + DB | ❌ 不承担 | [需要真实资源验证] |
| `readback_pending` 恢复路径 | 服务端 | ❌ 不承担 | [契约已支持 §6.7] |
| 确定性计算 + 输出内部四部分 | M2 domain | ✅ 承担 | [现有代码事实] |

### 6.2 关键接线点

1. **`snapshot_version`/`base_version`**：服务层读快照时取得版本，传入 `ScheduleInput.baseVersion`；apply 时事务核验当前版本一致，不一致 → `SNAPSHOT_CONFLICT` 零写入。[契约已支持 §7.2]
2. **服务端重读**：apply 后服务端权威回读，比对批准内容；不一致 → `READBACK_MISMATCH`（502）；未确认 → `READBACK_PENDING`（503），两路径零业务写入。[契约已支持 §6.7]
3. **Proposal 状态机**：draft → pending_approval → applying → readback_pending → applied / rejected / expired / failed。M2 只产出 draft 语义的「内部四部分」，状态由服务端推进。[契约已支持]
4. **幂等键**：同用户同 Proposal 已有未终结 Approval → 返回同一 `approval_id`；Token 过期后旧审批终结，可重建。[契约已支持 §6.5]
5. **事务写入**：`changes` 逐条原子写入，`base_version` 事务核验。[需要真实资源验证]
6. **`readback_pending`/权威 readback**：三条恢复路径只做权威回读 + 状态收敛，业务写入增量均为 0。[契约已支持 §6.7]

---

## 七、与 M1 服务端蓝图的接口对接草案

> 收到 M1 完整蓝图后做一次接口交叉核对。本草案为 M2 侧提议，**非冻结**。

### 7.1 scheduler adapter 输入/输出接口草案

```
// 输入（服务端 → domain）
ScheduleInput {
  now, horizonStart, horizonEnd,
  baseVersion,                 // 可信版本
  timezone,                    // 默认 Asia/Shanghai，服务层先统一转换
  preferences,                 // day_start/end_minute, minimum_block_minutes
  availability[],              // 显式窗口（可空，空则按偏好推导）
  fixedBlocks[],               // 课程 + 会议（硬约束）
  demands[],                   // 周期/单次任务需求
  existingPlacements[],        // repair 时上一版安排
}

// 输出（domain → 服务端）
ScheduleProposal {
  blocks[],                    // 展示块
  changes[],                   // 白名单两种变更
  unplannedTasks[],            // 未排任务（四值 reason_code）
  notes[],                     // 解释（七公共码 + repair 专用码）
  // 不含任何服务端权威字段（方案 A）
}
```

### 7.2 调用时序（端到端）

```
可信快照读取 → 组装 ScheduleInput → generate/repair（domain 纯函数）
  → 内部四部分 → 服务端补权威字段 → validate_schedule（§5.8）
  → request_approval（幂等 §6.5）→ apply_approved_changes（事务 §6.7）
  → 权威 readback（§6.7 恢复路径）
```

### 7.3 双方责任矩阵

| 环节 | M2（domain） | M1（服务端） |
|---|---|---|
| 调度计算 | ✅ | — |
| 快照组装 | 提供 DTO 形状 | ✅ 组装 |
| 权威字段 | ❌ 不产出 | ✅ 生成/持久化 |
| violations | ❌ 不产出 | ✅ validate |
| 幂等/事务/readback | ❌ | ✅ |
| IdP/审计/双人复核 | ❌ | ✅ |

---

## 八、测试与验收（48 + 29 分层映射）

### 8.1 分层矩阵（不重复计数）

| 层 | 用例数 | 归属 | 通道 |
|---|---|---|---|
| M2 纯函数 | **48** | `test/agent_scheduler_test.dart` | 隔离 `dart test` + 宿主 `flutter test` |
| M1 服务端 S0 | **29** | M1 侧 | M1 通道 |

两者互不重叠、互为补充：M1 29 条 = 服务端/基础设施验收；M2 48 条 = 纯函数验收。**不合并计数。**

### 8.2 缺失测试清单（建议新增，本轮不写）

| 缺失测试 | 类型 | 前置 | 状态 |
|---|---|---|---|
| 时区语义用例（跨时区块不跨日） | 边界 | R1 裁定 | [待 M0 裁定] |
| `scheduling_weight` 层级用例 | 属性 | R2 裁定 | [待 M0 裁定] |
| 服务层默认 120 路径测试 | 集成 | 真实入口出现 | [需要真实资源验证] |
| 快照过期拒绝（`base_version` 核验） | 集成 | 真实 DB | [需要真实资源验证] |
| 幂等重复请求返回同一 approval_id | 集成 | 真实后端 | [需要真实资源验证] |
| readback 三条恢复路径 | 集成 | 真实后端 | [需要真实资源验证] |
| 端到端验收（真实设备） | 验收 | 全链路 | [需要真实资源验证] |

### 8.3 真实资源验收条件

- 域名/TLS/部署环境（T-3.1）；
- Supabase Auth/IdP/测试账号（T-3.2）；
- 真实设备「可信」标准（T-3.3，Q2 未定）；
- PostgreSQL 实例 + 事务（T-3.5/3.6）；
- 多实例 + 共享库（T-3.7）；
- 权威只读连接（T-3.8）；
- review 字段 + Q3 覆盖面（T-3.9）；
- 不可变存储 + 保留策略（T-3.10）。

---

## 九、实施路线（依赖图 + 并行工作包 + 回滚点 + 验收标准）

### 9.1 依赖图（阶段顺序）

```
规则裁定（R1–R7）
  ├─→ adapter/DTO（ScheduleInput 组装 + 常量导出）
  │     └─→ service 接线（generate/repair 调用）
  │           └─→ validate（§5.8）
  │                 └─→ 事务/幂等协作（§6.5/§6.7）
  │                       └─→ 权威 readback（§6.7）
  │                             └─→ 端到端验收
```

### 9.2 并行工作包

| 工作包 | 前置 | 交付物 | 验收标准 |
|---|---|---|---|
| W1 引擎侧未决项落地 | M0 裁 R1/R2/R3 | 引擎补充用例 + `kDefaultMaxShiftMinutes` 常量 | 两通道全绿 |
| W2 契约补白 | M0 裁 R6/R7 | 契约补句（M0 侧执行） | 21 码 retryable 全覆盖 |
| W3 服务层组装 + 接线 | W1 + 环境 | ScheduleInput 组装 + repair(120) 调用 | T-3.1-01 通过 |
| W4 基础设施接入 | 环境/IdP/DB | HTTP endpoint + IdP + DB | T-3.1/3.2/3.5/3.6/3.7/3.8 通过 |
| W5 可信链 + 双人复核 + 审计 | Q2/Q3 裁定 | confirm/review/audit 落地 | T-3.3/3.4/3.9/3.10 通过 |

W1、W2 可并行（都只等 M0 裁定）；W3 依赖 W1；W4 与 W1/W2 可并行（纯资源）；W5 最后。

### 9.3 回滚点

1. 规则裁定未落地前，不启动 W1（避免白写引擎用例）；
2. adapter/DTO 只新增、不改算法（`generate/repair` 签名冻结）；
3. 服务接线后若验收失败，回滚到「纯函数 + 48 条」冻结基线，不污染 domain。

### 9.4 阶段验收标准

| 阶段 | 验收 |
|---|---|
| 规则裁定 | R1–R7 全部有 M0 明确结论 |
| adapter/DTO | ScheduleInput 组装字段齐全，常量导出 |
| service 接线 | 端到端调用链贯通，48 条 + 新集成测试全绿 |
| validate | §5.8 八值覆盖，业务失败不误写 HTTP |
| 事务/幂等 | 重复请求返回同一 approval_id，零二次写入 |
| readback | 三条恢复路径零业务写入 |
| 端到端 | 真实设备全链路验收通过 |

---

## 十、接口差异清单（与 M1 的已知差异）

| # | 差异项 | M2 侧 | M1 侧 | 是否需 M0 决策 | 是否阻塞 |
|---|---|---|---|---|---|
| 1 | IdP（3.2） | 归入「服务层职责」 | 单列缺口 + 独立用例 | 否（属 M1 拆解） | 否 |
| 2 | 双人复核（3.9） | 归入「服务层职责」 | 单列缺口 | 是（Q3 覆盖面） | 是（3.9 BLOCKED） |
| 3 | 审计（3.10） | 未展开审计表 | 单列缺口 | 否（属 M1 拆解） | 否 |
| 4 | 时区语义（R8→R1） | 引擎未消费 timezone | 清单无时区用例 | 是（R1） | 是（引擎侧用例缺覆盖） |
| 5 | scheduling_weight（P0→R2） | 不消费不伪造 | 清单不涉及 | 是（R2） | 是（§5.2 BLOCKED） |
| 6 | maxShiftMinutes=120（R3） | 参数已实现、默认待接入 | 清单不涉及 | 是（R3 入口归属） | 否（domain 已就绪） |

---

## 十一、预计后续实施拆分（供排期，M2 不自行启动）

1. **P0 规则确认**：R1–R7 待 M0 裁定（R4/R5/R6/R7 偏契约/服务端，M2 侧只需 R1/R2/R3 结论）。
2. **P1 服务层组装**：可信快照 → `ScheduleInput` 映射 + 服务端权威字段生成（M1 牵头，M2 提供 domain 对照基准）。
3. **P2 接线**：服务层调 `repairSchedule(maxShiftMinutes: 120)`，domain 导出 `kDefaultMaxShiftMinutes`（domain 小改，与接入同轮）。
4. **P3 校验与事务**：`validate_schedule`（§5.8）+ 幂等 + `base_version` 事务核验。
5. **P4 恢复路径**：§6.7 三条恢复路径 + 真实后端集成测试。

---

## 附：边界声明

- 本文为**纯设计蓝图 + 测试规划**，未改 `lib/`、未改 `test/`、未改契约本体、未改 Mock、未碰 M3 录制材料。
- 未提交、未推送、未建 PR、未合并。PR #2/#3/#4 head 与冻结基线（录制 `7e1367c2` + 契约 `39f7f965`）未动。
- 未替 M0 做任何规则选择；R1–R7 全部列选项与阻塞点，明确标「建议」。
- 所有 [待 M0 裁定] 与 [需要真实资源验证] 项均为显式标注的未证实假设，不作事实陈述。
