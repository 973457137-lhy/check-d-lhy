# M2 视角验收矩阵（错误码与状态可达性）

> 日期：2026-10-31　负责人：B（M2）
> 对照版本：M1 PR #3 `bbf0992307531f8945fe5ac25107e2da79dc0e76`
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
| 1 | Proposal/Approval 状态机 | proposal 与审批两个子状态机组合 | 未覆盖 | M2 侧恒出 `draft`；**契约缺组合语义表**（见评审文档 §2 缺口 1）。两个工具的等待 M0 决定是否进正文 |
| 2 | `readback_pending` | 写入成功但回读尚未确认 | BLOCKED | 依赖真实数据库写后回读流程；mock 无此中间态，且 daily_override **一条都没回读**却标 `readback_verified: true` |
| 3 | `PROPOSAL_EXPIRED` | 提案超过 `expires_at` | 未覆盖 | mock 两处硬编码 `2026-10-30T23:59`（已过期）且无判过期代码，当前不可达 |
| 4 | `APPROVAL_EXPIRED` | 审批超过有效期 | 未覆盖 | 同上，审批记录虽有 `expires_at` 但无代码置位 expired |
| 5 | `ALREADY_APPLIED` | 同一提案重复 apply | 未覆盖 | 判定顺序导致不可达（C 发现，我复核属实）；且码本身不在 §4.1 |
| 6 | `APPROVAL_CONSUMED` | token 被二次使用 | 未覆盖 | 码存在但不在 §4.1；二次轮询返回 `approval_token: null` 且无错误码 |
| 7 | daily override 回读 | `upsert_daily_override` 写后再读回比对 | 静态结论：仅 `schedule_one_time` 有回读 | 这是本轮唯一会直接写进比赛材料的假成功，必须修 |
| 8 | item 不存在 | 变更引用的 task/course 不存在 | 静态结论：会崩 | `STATE["tasks"][task_id]` 直接下标，KeyError 未被 `ToolError` 捕获，应返回 `NOT_FOUND` |
| 9 | `SNAPSHOT_CONFLICT` | 输入摘要与当前快照不一致 | 未覆盖 | validate 从不重算 `input_digest`，该码在 mock 中不可达 |
| 10 | `WRITE_BLOCKED` | 无法证明原子性 | 未覆盖 | apply 逐条写无回滚，且没有这条分支 |
| 11 | violation code（`FIXED_EVENT_CONFLICT` 等） | validate 检出提案违规 | 静态结论：契约未定义 | 码需要进 §4.1 附属表，C 才能判定 |

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
| `explanations` 元素恒为 `{task_id, text}` | 结构形状不会在合并时炸掉 | `冻结目标守卫 · explanations 元素结构统一` |

## 四、增量复审清单（M0 发新契约后只看这 4 项）

1. 表二第 1–11 行里标「未覆盖」的条目，是否在新契约里都给了**可达路径**（不只是列名存在）。
2. 第 5、6、10 行的三个码是否真正写入 §4.1，violation code 是否单列一张表。
3. `readback_pending` 是否定义为一个**显式状态**而非布尔字段——否则「写入次数」判定项无法区分「未写入」与「写入待确认」。
4. 第 7、8 行是否修完并可产生对应的失败用例；M2 侧届时不重跑 M1 mock，只确认 field 与自己的 Proposal 输出一致。

其余内容不再重新审阅。
