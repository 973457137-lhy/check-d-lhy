# M2 视角验收矩阵（错误码与状态可达性）

> 日期：2026-10-31　负责人：B（M2）
> 对照版本：M1 PR #3 `bbf0992307531f8945fe5ac25107e2da79dc0e76`
> 契约对齐：`upstream/feat/m0-api-contract` @ `2c48579`（v1 CANDIDATE 收口版，
> 对齐记录见 `docs/scheduler/alignment-v1-candidate-2c48579.md`）
>
> **纪律：本矩阵不记录任何我没有真正执行过的运行结果。**
> 判定列只有四种取值：
> - `已自有证据`：M2 侧有可执行测试通过（附测试名）
> - `静态结论`：仅阅读源码得出，未在我本机执行
> - `未覆盖`：当前实现没有触及这条路径
> - `BLOCKED`：依赖本机不具备的条件（实机 / 真实审批 / 真实数据库）
>
> M0 发布新契约 commit 后，**只做一次增量复审**：确认下表的每一行都「可测试」，
> 不重新通读全部文档。

## 一、四项判定口径

C 的判定口径是「**响应码 + 状态 + 数据 + 实际写入次数**」四项。
M2 能为其中两项提供确定性依据：

| 判定项 | M2 能否提供依据 | 依据 |
|---|---|---|
| 响应码 | 否（归 M0/M1 服务端） | — |
| 状态 | 部分 | M2 的 proposal 恒为 `draft`（`ScheduleProposalStatus`），由纯函数保证 |
| 数据 | **是** | blocks / changes / unplanned_tasks / explanations 结构与枚举全部由测试锁定 |
| **写入次数** | **是** | 见下面第 3 条：M2 保证「一个 (item_id, local_date) 至多一条变更」，因此期望写入次数可从提案直接推算，无需猜 |

## 二、错误码与状态矩阵

| # | 条目 | 触发条件 | 当前判定 | 证据 / 说明 |
|---|---|---|---|---|
| 1 | Proposal/Approval 状态机 | proposal 与审批两个子状态机组合 | 静态结论：§5.7 有 Proposal 8 态图，但缺 5 处 | Approval 无迁移图、`applying` 无出边到 expired、`readback_pending` 无出边、`failed` 后不可重试、无 Proposal×Approval 组合表 → 详见状态机复审文档 G1–G5 |
| 2 | `readback_pending` | 写入成功但回读尚未确认 | 条款：同幂等键闭合；**换幂等键未定义** | 必修：Proposal 处于 `applying`/`readback_pending` 时换键可能二次写入（状态机复审文档 X1）。Mock 侧仍是 daily_override 一条没回读却标 `readback_verified: true` |
| 3 | `PROPOSAL_EXPIRED` | 提案超过 `expires_at` | 契约层可达 | §6.5 / §6.7 判定顺序第 3 步；前提是服务端**惰性置位**：任何读取路径发现过期即视为 expired，不依赖定时任务 |
| 4 | `APPROVAL_EXPIRED` | 审批超过有效期 | 契约层可达，但与第 3 项幂等规则冲突 | Token 过期后要重走审批，而 §6.5 要求返回同一 `approval_id` → 死锁（状态机复审文档 R1） |
| 5 | `ALREADY_APPLIED` | 同一提案重复 apply | **契约层可达；M1 mock 不可达属实现缺陷** | §6.7 已写死判定顺序：幂等记录 → 是否已 applied → TTL → base_version → Token。C 上轮的发现在这里已闭环 |
| 6 | `APPROVAL_CONSUMED` | token 被二次使用 | 契约层可达 | §6.7「Token 已消费且不存在相同幂等记录时返回」，顺序正确就不会被 `ALREADY_APPLIED` 抢先 |
| 7 | daily override 回读 | `upsert_daily_override` 写后再读回比对 | 条款明确 + M2 侧新增字段守卫 | §6.7 七个必核字段；**缺「唯一键下有效记录数恰为 1」断言**；M2 侧已保证字段齐全（新用例） |
| 8 | item 不存在 | 变更引用的 task/course 不存在 | 静态结论：会崩 | mock 里 `STATE["tasks"][task_id]` 直接下标，KeyError 未被 `ToolError` 捕获，应返回 `NOT_FOUND` |
| 9 | `SNAPSHOT_CONFLICT` | 输入摘要与当前快照不一致 | 条款：零写入 ✅；**证据 BLOCKED** | §7.2 明写 `base_version` 当前 BLOCKED、Task 3 保持 `WRITE_BLOCKED`，M3 不得标通过 |
| 10 | `WRITE_BLOCKED` | 无法证明原子性 | BLOCKED | 幂等介质、并发锁、崩溃恢复均未实现 |
| 11 | violation code（`FIXED_EVENT_CONFLICT` 等） | validate 检出提案违规 | 静态结论：契约仍未定义 | 码需要进 §4.1 附属表，C 才能判定 |
| 12 | 单次事项旧 `scheduled_at` | 省略/保留现值跨日造成假成功 | **M2 侧已自有证据** | M2 永远显式给同本地日 `scheduled_at`，从不走"保留现值"分支（本轮新用例）；剩余风险只落在 `base_version` 侧 |
| 13 | 单日例外唯一键 | `user+item_type+item_id+local_date` 重复 | 条款明确；M2 侧提案内唯一 | §5.7 冲突 → `SNAPSHOT_CONFLICT` 零写入；M2 保证同一提案不重复，服务端只会被**并发**触发而非被提案自身触发 |
| 14 | `READBACK_MISMATCH` | 写后回读与批准内容不一致 | 静态结论：契约已与 `READBACK_PENDING` 分列 | §4.1：前者 502（**已确认不一致**），后者 503（**未知是否写入**）。两者不得互换，也不得合并成一个码——合并会把"不知道"和"知道错了"混成同一条证据 |
| 15 | `PROPOSAL_NOT_APPROVABLE` | 对非 `pending_approval` 的 Proposal 请求审批 | **契约尚未采用**（@2c48579 全文 0 次） | 属 M1 提议。B 的增量判断与可达测试输入见 `reviews/proposal-not-approvable-incremental.md`；**未写入 Schema**，也未加入 M2 任何 DTO |

> **七工具口径（2026-10-31 对齐后）**：`list_tasks`、`get_calendar_events`、`generate_schedule`、
> `validate_schedule`、`request_approval`、`get_approval_status`、`apply_approved_changes`
> **七个全部是 v1 CANDIDATE**，不再有"5 个 v1 + 2 个候选扩展"的说法。

## 三、M2 侧提供的确定性保障（可直接执行，非静态结论）

| 保障 | 作用 | 测试名 |
|---|---|---|
| 提案恒为 `draft` | 「状态」判定项有唯一取值，服务端不得由模型构造终态 | 契约对齐类用例 + 纯函数 `status` 默认值 |
| 一个 `(item_id, local_date)` 至多一条变更 | 「**写入次数**」判定项可推算：期望写入次数 = `changes.length`，不需要执行才知道 | `冻结目标守卫 · 周期任务同一本地日最多一个 block` |
| `change_id` 全局唯一且带日期 | 服务端逐条回执可定位到具体变更 | 同上用例的断言 |
| changes 只含白名单两种 type（`action` 恒为 `reschedule`） | 越权写入在纯函数层就被阻断 | `与 M0 v1 契约对齐 · 单次事项与周期任务分别产出各自的白名单变更`、`冻结目标守卫 · 写入次数可推算` |
| 提案 `status` 恒为 `draft`，`snapshot_ref`/`input_digest` 不构造 | 「状态」判定项有唯一取值，服务端字段不由模型伪造 | 同上用例 |
| block 不跨本地日 | 从源头消解一类 `BLOCK_TIME_INVALID` | `确定性与边界 · 排出来的块不跨自然日` |
| `reason_code` 封闭枚举 | 「数据」判定项取值有限，C 可穷举校验 | `冻结目标守卫 · reason_code 取值必须落在封闭枚举内` |
| `explanations` 元素恒为 `{code, message, related_task_ids?}` | 结构形状不会在合并时炸掉 | `冻结目标守卫 · explanations 元素结构统一` |
| `schedule_one_time` 必带同本地日 `scheduled_at` | 消除「写入成功但计划日期仍来自旧值」的假成功路径 | `冻结目标守卫 · 单次事项必须显式带与 planned_date 同日的 scheduled_at` |
| `upsert_daily_override` 七字段齐全 + `0 <= start < 1440 < end <= 1440` + `item_type` 不含 course + `existing_override_id` 恒 null | 服务端回读不会因为提案侧缺字段而失败；也不靠猜 override id 制造重复记录 | `冻结目标守卫 · 单日例外变更字段齐全、分钟合法，且同一唯一键在提案内只出现一次` |
| 同一提案内 `(item_type, item_id, local_date)` 与 `(task_id, planned_date)` 唯一 | 服务端的 `SNAPSHOT_CONFLICT` 只会被**并发**触发，不会被提案自撞触发；「写入次数」= `changes.length` 保持成立 | 同上用例 |

## 四、C 的 Proposal / Approval 增量复审清单（10 项）判定

详细条款依据见 `docs/scheduler/reviews/incremental-review-m2-state-machine.md`。

| # | C 的条目 | B 的判定 | 归属 |
|---|---|---|---|
| 1 | Proposal 与 Approval 状态迁移是否完整 | **不完整**，5 处缺口（G1–G5） | M0 补图 |
| 2 | 5 个错误码是否可达 | PROPOSAL_EXPIRED / APPROVAL_PENDING / APPROVAL_EXPIRED / APPROVAL_CONSUMED **条款可达**；ALREADY_APPLIED **条款可达**（mock 不可达是实现缺陷） | M0 已闭环 / M1 改实现 |
| 3 | 重复 `request_approval` 的幂等规则 | 规则在，但 **Token 过期重走审批 ↔ 返回同一 approval_id 死锁（必修 R1）**；另有 3 处未明写 | M0 必修 / OQ5 |
| 4 | 同幂等键重放与换键重复 apply 的判定顺序 | §6.7 顺序**写得对且零写入声明明确** ✅；唯一漏洞在第 7 项 | M0 已闭环 |
| 5 | Proposal 30 分钟、Token 5 分钟边界 | 数值对，边界口径缺 3 条（`>=` vs `>`、`token_expires_at` 截断、时钟源） | M0 补口径 |
| 6 | 版本冲突是否保证零写入 | 条款承诺零写入 ✅；但 §7.2 `base_version` **BLOCKED**，M3 不得标通过 | M0 / 服务端证据 |
| 7 | `readback_pending` 只回读禁重写 | 同键 ✅；**换键未定义 → 唯一一条可能二次写入的通道（必修 X1）** | M0 必修 |
| 8 | 单次事项旧 `scheduled_at` 冲突防护 | 条款清楚 ✅；**M2 侧已用可执行守卫消除该路径** | M2 已交 / 服务端补 `base_version` |
| 9 | daily override 唯一键与完整回读字段 | 条款正确 ✅；缺「记录数恰为 1」断言；回读路径未定（OQ3） | M0 补 / M1 补断言 |
| 10 | 四项判定口径继续生效 | **接受**。M2 侧的「写入次数」= `changes.length`，见第三节 | 全员 |

## 五、下次契约更新只增量看这些

1. 第 3 项 R1 与第 7 项 X1 是否被写入正式条款（这两条不补，「错误码可达」与「零写入」两栏就有一条是假的）。
2. 状态机图是否补上 `applying → expired`、`readback_pending → applied/failed`，以及 Approval 迁移图。
3. 过期边界 `>=` 与 `token_expires_at` 截断算法是否与 M2 的 `ScheduleDeadline.isPast` 同口径。
4. violation code 是否单列一张表（表二第 11 行）。

其余内容不再重新审阅。
