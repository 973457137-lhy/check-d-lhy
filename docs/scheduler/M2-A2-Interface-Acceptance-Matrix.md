# M2 · A2 调度域 × A1 服务端 接口边界验收矩阵

> **依据**：M0 2026-11-05 `[CheckD][M0] 11-05 阶段交付确认与下一轮并行任务续派` 第二节【M2】第 2、3 项。
> **性质**：只读验收 + 独立文档。**不改冻结契约**；未改动任何 `lib/` 代码；测试基线保持 51 条。
> **阶段回报截止**：2026-11-07 12:00（北京时间）。

## 基准声明

| 项 | 值 |
|---|---|
| 契约 | `agent-api-v1.md` @ `39f7f96559abac9d4bc59d5c560e6a706ec19946` |
| M2 代码 | `feat/m2-a2-traceability` @ `64eb403`（domain 两份 + 51 条测试） |
| 测试基线 | **51 条**，本轮**未新增、未删除** |
| 标注 | ✅ 一致 ／ ⚠️ 字段一致但格式/取值有问题 ／ 🚫 不属 M2 ／ ❓ 契约未定义 |

---

## 零、结论摘要

1. **字段集合层面：M2 输出与契约 §5.6/§5.7 完全对齐**，四部分（blocks / changes / unplanned_tasks / explanations）逐字段比对，**无一缺失、无一多余**。
2. **发现 1 个 P0 缺陷（格式层）**：精确时间字段用 `DateTime.toIso8601String()` 序列化，**输出不带偏移**（`2026-11-05T09:40:00.000`），而契约 §3 明令「禁止无偏移时间」。影响 `block.start_at`、`block.end_at`、`scheduled_at` 三处。
3. **一处重要澄清**：`related_task_ids` 在 **`explanations` 侧 M2 已经实现**（单元素数组），并非"完全未提供"。真正没有的是 `violations.related_task_ids`——因为 M2 不产 `violations`。
4. **G18 的 3 个子项里，只有 18-a（violations.message）确实不属 M2**；18-b（related_task_ids）在 explanations 侧已具备。

---

## 一、generate_schedule 输出：逐字段映射

### 1.1 `blocks[]` — 契约 §5.6，M2 `ProposedBlock.toJson()`（contract L406–416）

| # | 契约字段 | 契约要求 | M2 实际 | 状态 |
|---|---|---|---|---|
| 1 | `block_id` | 提案内部 ID，非数据库 ID | `'blk-$taskId'`（L392） | ✅ |
| 2 | `task_id` | 关联 Task | 透传 | ✅ |
| 3 | `task_kind` | `recurring` / `one_time` | `taskKind.code` | ✅ |
| 4 | `start_at` | **带明确偏移**的 instant | `startAt.toIso8601String()` → **无偏移** | ⚠️ **P0-1** |
| 5 | `end_at` | 同上，且与 start 同上海本地日 | 同上（无偏移） | ⚠️ **P0-1** |
| 6 | `source` | 固定 `proposal` | 常量 `'proposal'`（L395） | ✅ |
| 7 | `persistable_as` | `one_time_schedule` / `daily_override` | 按 `taskKind` 派生（L398–400） | ✅ |
| 8 | `duration_source` | `task_target` / `scheduler_estimate` | 按 `hasDurationTarget` 派生（L403–404） | ✅ |
| 9 | `duration_seconds` | `end_at - start_at`，正整数 | `endAt.difference(startAt).inSeconds`（L387） | ✅ |

**约束核对**（契约 §5.6 L271–274）：

| 约束 | M2 是否满足 | 证据 |
|---|---|---|
| 同一单次事项最多一个可持久化 block | ✅ | 用例 ㉒:1003、㊶:1677 |
| 同一周期任务同一上海本地日最多一块 | ✅ | 用例 ㊷:1728 |
| block 的 start/end 必须同一上海本地日 | ✅ | 用例 ⑫:477（块不跨自然日） |
| 不得把估算写回 Task 持久化字段 | ✅ | `durationSource` 显式区分；用例 ㉙:1269 |

### 1.2 `changes[]` — 契约 §5.7 L356–364

**`schedule_one_time`（`ScheduleOneTimeChange.toJson()`，L451–457）**

| 契约字段 | 必填 | M2 实际 | 状态 |
|---|---|---|---|
| `change_id` | ✅ | 透传 | ✅ |
| `type` | ✅ | 常量 `'schedule_one_time'` | ✅ |
| `task_id` | ✅ | 透传 | ✅ |
| `planned_date` | ✅ | `_isoDate()` → `YYYY-MM-DD`（手写格式化，L116–118） | ✅ |
| `scheduled_at` | 可选 | `scheduledAt!.toIso8601String()` → **无偏移** | ⚠️ **P0-1** |

约束核对：Task 必须是 `one_time`（用例 ㉒）；与 `planned_date` 同日（用例 ㊹:1896）；一个提案内同 Task 最多一条（用例 ㊶）。

**`upsert_daily_override`（`UpsertDailyOverrideChange.toJson()`，L492–502）**

| 契约字段 | 必填 | M2 实际 | 状态 |
|---|---|---|---|
| `change_id` | ✅ | 透传 | ✅ |
| `type` | ✅ | 常量 `'upsert_daily_override'` | ✅ |
| `item_type` | ✅ | `itemKind.code`（`recurring`/`one_time`） | ✅ |
| `item_id` | ✅ | 透传 | ✅ |
| `local_date` | ✅ | `_isoDate()` | ✅ |
| `action` | ✅ | 常量 `'reschedule'` | ✅ |
| `planned_start_minute` | ✅ | 透传 | ✅ |
| `planned_end_minute` | ✅ | 透传 | ✅ |
| `existing_override_id` | 可选 | 非空才输出 | ✅ |

约束核对：结束分钟 > 开始分钟、分钟范围合法、同一唯一键在提案内不重复（用例 ㊺:1935）。

### 1.3 `unplanned_tasks[]` — 契约 §5.7 L312–315

| 契约字段 | 契约要求 | M2 实际（L528–533） | 状态 |
|---|---|---|---|
| `task_id` | 必含 | ✅ | ✅ |
| `reason_code` | 必含，4 值闭集 | `reason.code`，4 值 | ✅ |
| `remaining_minutes` | 必含 | ✅ | ✅ |
| `message` | 必含，安全可展示 | `reasonText` | ✅ |

**关键细节**：契约写的是「**至少**包含」四项，M2 输出**恰好四项**——`title` 保留在 Dart 对象内但不进 JSON（L524–527 有明确注释：`additionalProperties: false` 时多一个字段会整份被拒）。这个处理是对的，且用例 ㊵:1653、㊻:2012 已锁。

**reason_code 四值**（契约 L314–315）vs M2 `UnplannedReason`：

| 契约值 | M2 值 | 一致 |
|---|---|---|
| `WINDOW_INSUFFICIENT` | `windowInsufficient` | ✅ |
| `PAST_DEADLINE` | `pastDeadline` | ✅ |
| `OVERLAPS_FIXED` | `overlapsFixed` | ✅ |
| `NO_AVAILABILITY` | `noAvailability` | ✅ |

### 1.4 `explanations[]` — 契约 §5.7 L316–320

| 契约字段 | 契约要求 | M2 实际（L578–582） | 状态 |
|---|---|---|---|
| `code` | 必含，7 值封闭枚举 | ✅ 7 公共码，`isPublic` 过滤 | ✅ |
| `message` | 必含，安全可展示 | ✅ | ✅ |
| `related_task_ids` | **可选**字符串数组 | ✅ **已实现**：`taskId != null` 时输出 `[taskId]` | ✅ |

> **这是本节最重要的一条**：M0 此前在 G18 里记「`related_task_ids` 未按 A4-P1 要求提供」。**在 `explanations` 侧，M2 已经提供了**（单元素数组，因为 M2 一条解释只关联一个任务）。A4-P1 若要求的是 `violations.related_task_ids`，那属服务端（见 §二）。

**7 公共码**（契约 L318–320）vs `kPublicExplanationCodes`（contract L544–552）：

`SCHEDULED` ✓、`ESTIMATED_DURATION` ✓、`ALREADY_DONE_TODAY` ✓、`FIXED_BLOCKS_OVERLAP` ✓、`NO_AVAILABILITY_WINDOW` ✓、`AVAILABILITY_SATURATED` ✓、`PRESERVED_FIXED_EVENTS` ✓ —— **逐字一致，7/7**。

**repair 专用码隔离**（契约 L322–323）：`DISPLACED_BY_FIXED`、`REPAIR_SUMMARY` 由 `kRepairOnlyExplanationCodes` 隔离，`publicExplanations` 过滤；本轮新增的 3 条测试（:2100 / :2146 / :2159）锁死差集。

### 1.5 服务端 7 个权威字段 — 契约 §5.7 L325–328（方案 A）

| 字段 | M2 是否产出 | 状态 |
|---|---|---|
| `proposal_id` / `snapshot_ref` / `base_version` / `input_digest` / `generated_at` / `expires_at` / `status` | **全部不产出** | 🚫 服务端职责（正确） |

用例 ㊳:1548 已用递归断言锁死"内部 DTO 递归不含任何服务端字段"。

### 1.6 generate_schedule 的字段级缺口汇总

| 类别 | 项 | 责任方 |
|---|---|---|
| **无缺失** | blocks 9/9、changes 两 type 全字段、unplanned 4/4、explanations 3/3 | — |
| **格式缺陷** | `start_at` / `end_at` / `scheduled_at` 无偏移 | **M2（P0-1）** |
| 服务端职责 | 7 个权威字段 | 服务端组装层 |

---

## 二、validate_schedule 输出：逐字段映射

契约 §6.4 定义 `validate_schedule` 的关键输出为「校验状态 + violations」。M2 **完全不产出此工具的响应**。

### 2.1 `violations[]` — 契约 §5.8 L397–409

| 契约字段 | 必填 | M2 是否产出 | 状态 |
|---|---|---|---|
| `code`（8 值闭集） | ✅ | ❌ | 🚫 服务端校验层 |
| `message`（安全可展示） | ✅ | ❌ | 🚫 服务端校验层 |
| `related_task_ids` | 可选 | ❌ | 🚫 服务端校验层 |
| `related_block_ids` | 可选 | ❌ | 🚫 服务端校验层 |
| `related_event_ids` | 可选 | ❌ | 🚫 服务端校验层 |
| `field` | 可选 | ❌ | 🚫 服务端校验层 |

**8 值闭集**：`PLANNED_BEFORE_AVAILABLE_FROM`、`PLANNED_AFTER_DATE_ONLY_DEADLINE`、`BLOCK_AFTER_EXACT_DEADLINE`、`BLOCK_TIME_INVALID`、`FIXED_EVENT_CONFLICT`、`BLOCK_OVERLAP`、`MULTIPLE_CHANGES_FOR_ONE_TIME_TASK`、`MULTIPLE_BLOCKS_FOR_RECURRING_TASK_DAY`。

### 2.2 `validation_status` / `proposal_status` / `approval_status`

| 字段 | M2 是否产出 | 说明 |
|---|---|---|
| `validation_status`（valid/invalid） | ❌ | 由服务端 `validate_schedule` 判定 |
| `proposal_status`（8 态） | ❌ | M2 不输出 `status`（方案 A）；状态机全在服务端 |
| `approval_status` / `approval_readiness` | ❌ | 服务端审批层 |

> M2 侧对此**唯一可贡献的间接证据**：它输出的 blocks 直接决定服务端会不会判出 `BLOCK_OVERLAP` / `FIXED_EVENT_CONFLICT`。用例 ㉖:1124、㉗:1172 已用「块两两不重叠」「块不与固定块重叠」两条守卫证明 M2 的输出**不会**触发这两类 violation。

---

## 三、缺陷清单

### P0-1 · 精确时间字段无偏移，违反契约 §3

**契约原文**（§3 L60–61）：

> 精确时间必须是 RFC 3339 / ISO 8601 字符串，并**带明确偏移**，例如 `2026-10-30T14:00:00+08:00`。**禁止无偏移时间**。

**M2 实际**（`toIso8601String()`，3 处）：

| 位置 | 字段 | 实际输出 |
|---|---|---|
| contract L410 | `blocks[].start_at` | `2026-11-05T09:40:00.000` |
| contract L411 | `blocks[].end_at` | 同上 |
| contract L456 | `changes[].scheduled_at` | 同上 |

**实测证据**（Dart 运行时）：

```
local.toIso8601  = 2026-11-05T09:40:00.000      ← 无偏移
utc.toIso8601    = 2026-11-05T01:40:00.000Z     ← 带 Z，但是 UTC 时刻
```

**根因**：Dart 的 `DateTime.toIso8601String()` **只有两种输出形态**——本地时间（无任何偏移后缀）或 UTC（带 `Z`）。**它没有能力输出 `+08:00`**。

**影响**：服务端拿到 `2026-11-05T09:40:00.000` 时无法确定时区。
- 若按 UTC 解析 → 实际是上海时间 17:40，**差 8 小时**
- 若按本地解析 → 依赖解析方所在时区，**不可移植**

**为什么测试没抓到**：51 条测试里**没有任何一条断言 `start_at` / `end_at` 的字符串格式**（已 grep 确认）。用例 ㊸:1762 只校验 DTO 的**键集合**，不校验值的形态。

**两种修法（不代裁，依赖 R1）**：

| | 修法 A（最小） | 修法 B（彻底） |
|---|---|---|
| 做法 | 手写格式化，固定拼 `+08:00`：`yyyy-MM-ddTHH:mm:ss+08:00` | domain 内部统一 UTC，序列化时转 `+08:00` |
| 前提 | 引擎入参必须是**上海墙上时间**（当前既有假设） | 引擎入参可为任意时区 |
| 依赖 | 不依赖 R1 裁定 | **依赖 R1 裁定**（时区语义） |
| 风险 | 若运行机器不在 +08:00，`DateTime(...)` 构造的语义会漂 | 需改动 `ScheduleInput.now` 等全部时间字段的语义 |
| 改动面 | 仅 3 处序列化 | domain 全量时间处理 |

> **建议先修 A**：契约已固定业务时区为 `Asia/Shanghai`，拼固定偏移是契约的直接要求，不需要新裁定。但**是否授权改 `lib/` 需 M0 明确**——本轮任务是验收矩阵，不是实施。

### P1-1 · `deadline.at` 同为无偏移（输入侧，暂无远程暴露）

`ScheduleDeadline.toJson()`（contract L112）也用 `toIso8601String()`。当前该对象只用于 M2 内部，**不进入远程响应**，故不构成契约违约；但若将来服务端需要回传截止时间，会踩同一个坑。建议与 P0-1 一并用同一个格式化函数。

### 已确认无问题的项（避免误报）

| 项 | 结论 |
|---|---|
| `planned_date` / `local_date` | 用手写 `_isoDate()`（L116–118），输出 `YYYY-MM-DD`，符合契约 §3 的 dateOnly 规则 ✅ |
| `unplanned_tasks` 恰好 4 字段 | 正确：契约要求"至少"，多字段会被 `additionalProperties: false` 拒 ✅ |
| `explanations` 对象数组 | 正确：契约已禁止字符串与对象混用 ✅ |
| 7 公共码 | 逐字一致 7/7 ✅ |

---

## 四、G18 拆栏：调度域可测 vs 服务端不可伪造

M0 在 §一.3 把 G18 定义为「`validate_schedule` 缺少面向用户的中文 explanations / related_task_ids 证据」。M3 随后收窄为 18-a / 18-b（18-d 待裁）。逐项拆：

| 子项 | 内容 | 归属 | M2 现状 | 可测性 |
|---|---|---|---|---|
| **18-a** | `violations[].message` 必填（契约 §5.8 L400） | **服务端校验层** | M2 不产 violations | 🚫 **不可由 M2 伪造** |
| **18-b** | `related_task_ids` 数组（契约 §5.8 L401） | **服务端校验层**（若指 violations）<br>**M2 已具备**（若指 explanations） | explanations 侧已输出 `[taskId]` | ⚠️ 取决于归属，见 §五 |
| **18-c** | `explanations` 可展示中文 message | **M2 输出侧** | ✅ 已有 `message`（中文），且结构合规 | ✅ **可测**（用例 ㊼:2039） |
| **18-d** | A4-P1 的屏幕期望 | 待 M0 裁定 | — | ❓ 不属 M2 |

**调度域侧可测试项（M2 能证明的）**：

1. `explanations` 是对象数组，每项含 `code` + `message`（✅ 已有 ㊼）
2. `explanations[].code` 落在 7 值闭集内（✅ 已有 ㊴）
3. `explanations[].related_task_ids` 在 `taskId` 非空时输出单元素数组（✅ 已实现，**尚无专项断言**）
4. `unplanned_tasks[].message` 为安全可展示文本（✅ 已有 ㊵）
5. `unplanned_tasks[].reason_code` 落在 4 值闭集内（✅ 已有 ㊻）

**服务端侧不可由 M2 伪造的项目**：

| 项 | 为什么 M2 造不了 |
|---|---|
| `violations[].code`（8 值） | 校验发生在服务端；M2 输出合格不代表校验通过（M2 无 validate 能力） |
| `violations[].message` | 同上 |
| `violations.related_task_ids` | 同上 |
| `validation_status` | 同上 |
| 任何"面向用户的最终解释文案" | M2 只给调度语义解释，产品文案归服务端/前端 |

---

## 五、`related_task_ids` 归属：两种方案并列（不代裁）

M0 明确要求「不自行裁定 `related_task_ids` 的最终归属；对两种可能方案分别说明影响」。以下并列陈述，**不给结论**。

### 方案 ①：仅 `violations` 携带（校验层字段）

| 维度 | 内容 |
|---|---|
| 契约依据 | §5.8 L401 明确列出 `related_task_ids` |
| 含义 | `related_task_ids` 只用于标记"哪个任务违反了哪条规则" |
| M2 改动 | **零改动**（M2 不产 violations） |
| 服务端改动 | 校验层需在每条 violation 上填 `related_task_ids` |
| 对 G18-b 的影响 | G18-b 完全归服务端，M2 无责 |
| 风险 | `explanations` 侧的关联信息（M2 已输出的）可能被闲置 |

### 方案 ②：`explanations` 也要携带（调度器字段）

| 维度 | 内容 |
|---|---|
| 契约依据 | §5.7 L316–317 明确写「可选 `related_task_ids`」 |
| 含义 | 调度解释也能指出"这条解释是关于哪个任务的" |
| M2 改动 | **已经实现**（contract L581：`if (taskId != null) 'related_task_ids': <String>[taskId!]`）——若要支持**多任务**关联，需改字段类型并补用例 |
| 服务端改动 | 组装时透传即可 |
| 对 G18-b 的影响 | G18-b 的一半由 M2 承担，且**现状已满足** |
| 风险 | 若契约最终只允许单值，M2 当前的单元素数组是安全的；若要求多值，需扩字段 |

### 两方案的实质差异

| | 方案 ① | 方案 ② |
|---|---|---|
| `related_task_ids` 出现在 | 仅 `violations[]` | `violations[]` **和** `explanations[]` |
| M2 现状 | 已符合（不产） | **已符合**（已输出） |
| 需要谁动 | 服务端校验层 | 两边都不动（现状已满足） |
| 契约是否已支持 | ✅ §5.8 | ✅ §5.7 |

> **客观事实（非裁定）**：契约 §5.7 与 §5.8 **两处都提到了这个字段**，且 M2 在 explanations 侧已经按 §5.7 实现。也就是说，**方案 ② 在当前代码状态下已经成立**，不需要任何改动；方案 ① 会要求 M2 删掉 explanations 里的该字段（因为契约 §5.7 说是"可选"，删也不算违约）。**取舍由 M0 定。**

---

## 六、明确不属于 M2 的项（防伪装）

| 项 | 归属 | M2 侧事实 |
|---|---|---|
| R6 状态机（8 态、终态禁写） | 服务端 | M2 无状态机，不输出 `status` |
| §4.1 二十一个错误码 | 服务端 HTTP 层 | M2 只产 `explanations.code`(7) 与 `unplanned.reason_code`(4) |
| `retryable` 语义 | 服务端 | M2 无此字段 |
| 持久化幂等（`approval_id` / 幂等键） | 服务端 + DB | M2 是无状态纯函数 |
| `base_version` 事务核验 | 服务端 | M2 只透传 |
| `input_digest` 计算 | 服务端 | M2 **不产出**该字段（方案 A）；但 M2 的输出受 horizon 影响，用例 ㉞:1430 已锁 |
| 真实审批 / 写入 | 服务端 | Mock 的 `approval.mock.local` 是占位 |

---

## 七、测试建议（不破坏 51 条基线）

| # | 建议新增 | 目的 | 依赖 |
|---|---|---|---|
| T-1 | `blocks[].start_at / end_at 必须带 +08:00 偏移` | 锁死 P0-1 修复 | **需先授权修 lib** |
| T-2 | `changes[].scheduled_at 必须带 +08:00 偏移` | 同上 | 同上 |
| T-3 | `explanations[].related_task_ids 在 taskId 非空时为单元素数组，且元素等于 taskId` | 锁住已实现但**无断言**的行为 | 无（可直接加） |
| T-4 | `explanations[].related_task_ids 在 taskId 为空时整键不出现` | 防止输出 `[]` 或 `[null]` | 无 |

**执行口径**：若 M0 批准，T-1/T-2 与 P0-1 修复同轮提交；T-3/T-4 可立即加，预计 51 → 53 条，两通道各跑一遍。

---

## 八、边界声明

- ✅ 只读验收；**未改动** `lib/`、未改冻结契约、未改 A1/T-DOC/A4 原件
- ✅ 测试基线保持 **51 条**（本轮未增未删未运行）
- ❌ 未连接 Production/Dev 数据库，未执行 migration
- ❌ 未把 Mock 说成真实审批/持久化/写入能力
- ❌ 未把 R6 状态机、21 个服务端错误码、幂等写成 M2 已实现
- ❌ 未自行裁定 `related_task_ids` 归属（§五 两方案并列）
- ❌ 未合并任何分支；PR #2 / PR #5 均保持 Open

---

## 九、P0-1 修复记录（2026-11-05，M0 授权后实施）

> M0 2026-11-05 07:01Z 裁定：授权按方案 A 最小影响范围修复三处；**但实施前必须先核实时区语义，不能只依赖口头假设**。

### 9.1 前置核实：DateTime 输入的真实语义（源码证据）

| # | 证据 | 位置 |
|---|---|---|
| 1 | `schedule_engine.dart` **全文零 `DateTime` 构造、零 `DateTime.utc`、零 `timeZoneOffset` 读取**；所有时间都从 `ScheduleInput` 派生或做 `Duration` 加减 | engine 全文（grep 验证为空） |
| 2 | 但 `scheduleDayOnly` 用 `DateTime(value.year, value.month, value.day)` **重建**对象，**丢弃输入 DateTime 的时区属性**，产出 local DateTime | contract L149 附近 |
| 3 | `input.now` / `demand.earliestStartAt` / `deadline.latestEndAt` 是**直接透传**（`_later` / `_earlier` 保留原对象），若它们是 UTC 则保留 UTC 身份 | engine `_placeDemand` L247–253 |

**三条结论**：

1. M2 **不关心也不校验**输入的时区语义，语义完全由服务层决定（R1 至今未裁定）；
2. 同一份输出中可能**混合**出现「local 派生」（`scheduleDayOnly` 重建的窗口）与「UTC 透传」（`input.now` 更晚时），即**部分带 Z、部分无后缀**；
3. 因此**不能无条件在字符串末尾拼 `+08:00`** —— 若输入是 UTC，拼接会二次出错。

### 9.2 实施：按 instant 语义转换（M0 的第二种口径）

新增 `_isoShanghaiInstant(DateTime)`（contract L135）：

```dart
final shanghai = value.toUtc().add(const Duration(hours: 8));
return 'yyyy-MM-ddTHH:mm:ss+08:00';   // 固定偏移，字段取自上海墙上时间
```

- `toUtc()` 先把任意语义归一到 instant；
- 加 8 小时得到上海墙上时间；
- 末尾固定拼 `+08:00`，符合契约 §3。

**边界场景核对**（M0 明确要求的三类风险）：

| 风险 | 输入 | 实际输出 | 结论 |
|---|---|---|---|
| 本机 +08:00、local 构造 | `DateTime(2026,11,2,8,0)` | `2026-11-02T08:00:00+08:00` | ✅ 正确 |
| **UTC 被误标为 +08:00** | `DateTime.utc(2026,11,2,0,0)`（= 上海 08:00） | `2026-11-02T08:00:00+08:00` | ✅ **未**误输出 `00:00+08:00` |
| 重复转换 / 双重偏移 | 同上 | 不出现 `+16:00` | ✅ 有用例守卫 |

**已知边界（需服务层遵守，已写入函数文档注释）**：

若服务层在非 `+08:00` 机器上用 `DateTime(2026, 11, 5, 9, 40)` 表达"上海 9:40"，它实际表示"该机器本地 9:40 那一刻"，转换后会得到不同的上海时刻。**正确做法是传真实 instant**：`DateTime.parse('2026-11-05T09:40:00+08:00')` 或 `DateTime.utc(...)`。这条属于 R1（时区语义）的范畴，M2 在此只做"按 instant 处理"这一种约定，**不代替 R1 裁定**。

### 9.3 三处字段映射（授权范围内，一处未动）

| # | 位置（改后行号） | 字段 | 改前 | 改后 |
|---|---|---|---|---|
| 1 | contract L432 | `blocks[].start_at` | `startAt.toIso8601String()` | `_isoShanghaiInstant(startAt)` |
| 2 | contract L433 | `blocks[].end_at` | `endAt.toIso8601String()` | `_isoShanghaiInstant(endAt)` |
| 3 | contract L478 | `changes[].scheduled_at` | `scheduledAt!.toIso8601String()` | `_isoShanghaiInstant(scheduledAt!)` |

**未改**：`ScheduleDeadline.toJson()` 的 `at`（原 L112，现约 L154）—— 属输入侧、不进远程响应；M0 授权范围只列三处，不越界。

### 9.4 新增测试（51 → 56，编号连续）

| 编号 | 用例 | 行号 | 覆盖 |
|---|---|---|---|
| T-1 | blocks 的 start_at / end_at 必须带 +08:00 偏移，且时刻与块对象一致 | :2172 | 格式 + 值 + 反向守卫（不得无偏移） |
| T-2 | changes 的 scheduled_at 必须带 +08:00 偏移 | :2201 | 格式 + 值 |
| T-3 | UTC instant 输入：转成上海时区后带 +08:00，不把 UTC 时刻误标为 +08:00 | :2226 | 边界：UTC → 上海，防双重偏移 |
| T-4 | related_task_ids：taskId 非空时输出单元素数组，且元素等于 taskId | :2247 | 契约 §5.7 可选字段 |
| T-5 | related_task_ids：taskId 为空时整个键不出现（不得输出 `[]` 或 `[null]`） | :2259 | 键集合守卫 |

### 9.5 测试结果（两通道分开）

| 通道 | 命令 | 结果 | 退出码 | 日志 |
|---|---|---|---|---|
| 隔离 `dart test` | `cd /e/m2-verify && dart test test/agent_scheduler_test.dart` | **56/56 通过** | **0** | `.workbuddy/tmp/iso_56.log` |
| 宿主 `flutter test` | `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy flutter test test/agent_scheduler_test.dart` | **56/56 通过** | **0** | `.workbuddy/tmp/host_56.log` |

跑完已 `git checkout --` 还原 4 个被自动改写的生成文件。无 skip、无 flaky。

### 9.6 状态

- **P0-1：已修复，两通道验证通过，待 M0 复核后方可标记关闭**（M0 原话：未完成验证前不得标记关闭；我已完成验证，但复核权在 M0）。
- 原 51 条基线**一条未删、未改**；新增 5 条编号 T-1～T-5。
- `lib/` 改动仅一处新增函数 + 三处序列化调用，**未改任何调度算法**。
- G18 的 `related_task_ids` 归属**仍未裁定**（M0 明确本次授权不代表对归属作决定）。

---

## 十、卷 2（A1 全本）对照与两项回执（2026-11-05 15:20，M1 打包件到达后）

> 触发：M1《CheckD｜M1（A）全部成果打包》（2026-11-05 15:08 +08，library node `6yxIdfFEMFwcG3B5mSAelG`，v1）。该包 §0.1 明确「M2 只需卷 2（A1 全本）作接口边界基准」，故本节点只对 A1 §9 与卷 5 的 R1/R2/R3、D3 做增量核对，不通读全包。

### 10.1 A1 §9.1 十二项：M2 侧现状复核（只列需动作的三项）

A1 §9.1 判定为「一致」的 9 项，M2 现状无变化，不再重复。另 3 项标「需补措辞 / 需修正」，逐项核对：

| # | A1 要求 | M2 现状（源码核实） | 是否已满足 |
|---|---|---|---|
| 2 | `baseVersion` 是服务端生成的不透明值，M2 只透传、不比较、不解析 | `schedule_engine.dart` 全文 **`baseVersion` 出现 0 次**；仅在 `ScheduleInput` 字段与注释里存在。0 次 = 既不比较也不解析，纯透传 | ✅ 已满足（比"补措辞"更强：代码层面就不读） |
| 7 | `requiredMinutes` / `remainingMinutesToday` 必须是服务端可信快照 | contract 两处字段注释已明写「只接受服务端可信快照，不得来自 LLM 估算」 | ✅ 已满足 |
| 11 | 字段名 `notes` 应为 `explanations` | `ScheduleProposal.toJson()` 输出的键已是 `explanations`；`notes` 只是 Dart 内部字段名 | ✅ **A1 该条为误报**，2026-11-03 已回函澄清，无需改码 |

**第 8 项另有一个必须报告的实事（A1 未指出，本轮新查）**：

> `existingPlacements` 在 `schedule_engine.dart` 中出现 **0 次** —— 字段声明存在（contract `SchedulePlacement`），但引擎**从不读取**。repair 走的是 `previous: ScheduleProposal` 参数，不是这个字段。

影响有两面，都属良性但需明示：

1. **不构成违约**：契约未要求 M2 必须消费它；§9.3 责任矩阵也未把它列进 M2 职责。
2. **`input_digest` 语义需服务端注意**：若服务端按 A1 §9.1 #8 把它计入 digest，则会出现「digest 不同但 M2 输出完全相同」的情形——**方向是保守的**（不会产生碰撞，只会让幂等判定偏严）。若希望 digest 精确反映"影响输出的输入"，则不应把它计入。

**建议**：`existingPlacements` 标为「保留字段、当前零消费」，由 M0 决定 ① 保留（接入 profile 时再用）或 ② 从 DTO 删除。M2 不自行删除已在契约侧被引用的字段。

### 10.2 回执 R3：`maxShiftMinutes` —— 已消费，但落点**不是** `ScheduleInput`

A1 卷 5 项 8 写「R3 `maxShiftMinutes`：需 M2 确认是否消费；若 M2 消费，写进 `ScheduleInput`；否则服务端预投影」。

**M2 确认：已消费。但落点是函数可选命名参数，不是 `ScheduleInput` 字段。**

| 项 | 实际值 |
|---|---|
| 签名 | `ScheduleProposal repairSchedule(ScheduleInput input, ScheduleProposal previous, {int? maxShiftMinutes})`（engine L560–564） |
| Dart 默认 | `null` = 无边界（不施加位移上限） |
| 服务层约定 | 显式传 `120`（M0 2026-11-03 裁定） |
| 生效位置 | `_placeNearest`（engine L278）内：`delta > maxShiftMinutes` 的候选被排除，全部被排除时退最早可用 |
| 覆盖用例 | 兜底（test L757）、边界不误杀（L809）、不传参即无边界（L856） |

**为什么不写进 `ScheduleInput`**（三条，供 A1 采纳）：

1. `ScheduleInput` 是**快照的映射**，其字段应全部来源于服务端可信快照；而 `maxShiftMinutes` 是**策略参数**，不是用户数据，混进快照会让 `input_digest` 覆盖一个非数据项。
2. 它是**进程内调用参数**，不跨网络、不进 Proposal、不进任何响应，写进 DTO 等于为一个纯内部旋钮新增契约面。
3. 现有实现已验证可用：不传 = 无边界（第 856 条用例锁死），服务层传 120 即生效，**不需要 A1 的"服务端预投影"**——预投影位移上限会丢失"就近"语义（把位移约束前移到输入侧无法表达"相对原位置的位移"）。

**建议措辞**：`R3 = M2 已消费（repairSchedule 可选参数，默认 null）；服务层显式传 120；不写入 ScheduleInput，不需服务端预投影。`

### 10.3 回执 D3：`availability` —— A1 提的「toJson 归一」风险在 M2 不存在，但语义缺口是真的

A1 卷 5 项 5 的风险描述：「M2 侧若在 `toJson()` 里把 `null` 归一成 `[]`（或反之），这个区分在传输层就丢了」。

**事实更正**：`availability` 是**纯输入字段，从不被序列化**。`grep availability` 在两端 `toJson()` 中命中 **0 次**。因此「toJson 归一」这一风险在 M2 侧**不存在**。

**但语义缺口是真的**，且方向与 A1 假设相反：

| 现状 | 代码事实 |
|---|---|
| 类型 | `final List<ScheduleWindow> availability`（contract L367），**非空**，默认 `const []`（L341） |
| 空数组行为 | `_effectiveAvailability`（engine L63）：`isNotEmpty` 才用，否则**按 preferences 逐日推导** |
| 即 | 当前 `[]` = **「未指定，按偏好推导」**，不是「显式无时间」 |
| `null` | **无法表达**（非空类型） |

所以 A1 建议的 `null`=未指定 / `[]`=显式无时间，在 M2 当前 DTO 上**无处落地**——`[]` 已被"未指定"占用。

**若 M0 裁定采纳 A1 语义，M2 的变更面（已实测，精确到用例）**：

| 改动点 | 内容 | 影响现有用例 |
|---|---|---|
| `ScheduleInput.availability` | `List<ScheduleWindow>` → `List<ScheduleWindow>?`，默认 `null` | **0 条**（现有 56 条用例中，显式传 `availability: []` 的有 **0 条**；48 处 `ScheduleInput(` 构造均传实窗或不传） |
| `_effectiveAvailability`（engine L63） | 加一分支：`null` → 按偏好推导；`[]` → 返回空表 → 全部任务进 unplanned 且 `reason_code = NO_AVAILABILITY` | **0 条**（`未显式给出可用窗口时用 preferences 逐日推导`（test L1068）传的是默认值，改后为 `null`，行为不变） |
| 新增用例 | ① `null` 按偏好推导（沿用既有）；② `[]` → 全部 unplanned + `NO_AVAILABILITY`；③ `toJson()` 不输出 `availability`（守卫，防将来误加） | +2～3 条 |

**结论**：这是**小改动、向后兼容、零既有用例破坏**（因无人显式传 `[]`），但**语义变更须 M0 先裁**，M2 不自行改。

### 10.4 引用口径

本节点所有行号均对 `fix/m2-p0-iso-offset @ e607e67` 的 `schedule_contract.dart` / `schedule_engine.dart` / `test/agent_scheduler_test.dart`。按 M1 §0.4 第一条：引用时须带「行号 + 本版字节/行数 + 指纹前缀」，故本节行号**只在与该 commit 同时引用时有效**。
