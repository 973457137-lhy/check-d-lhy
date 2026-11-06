# §5.8 增补文字（M0 方案 A 裁定落地用）

> 依据：M0 2026-11-06 06:50:57Z《正式裁定 §5.6/§5.8 单次任务多块按结构错误处理（方案 A）》。
> 作者：B（M2）刘恒瑜。时点：2026-11-06 15:1x（+08）。
>
> **为什么是「文字」而不是「改好的契约文件」**：契约文件 `docs/contracts/agent-api-v1.md` 位于
> `Dai-xx66/check-d`（`upstream/feat/m0-api-contract`），M2 只有 fetch 权限、无 push 权限。
> 因此本文给出**可直接粘贴的增补段落**与**逐字补丁**，由 M0 应用到契约仓库。
> 若希望改由 PR 交付，请告知目标 base 分支，我在 fork 上建同内容分支并发起。

---

## 一、建议插入位置

`docs/contracts/agent-api-v1.md` 的 **§5.8 `violation`** 段内，
紧随下面这句之后（原文）：

> 结构或联合类型错误（例如 `scheduled_at` 与 `planned_date` 跨上海本地日）返回
> `PROPOSAL_INVALID`，不放入 violations。

---

## 二、增补段落（可直接粘贴）

```markdown
「同一单次事项（`task_kind = one_time`）在一个 Proposal 中出现多个可持久化
`schedule_block`」同属**结构错误**，按本节上述规则处理：

- 返回 HTTP `422`，错误码 `PROPOSAL_INVALID`；
- **不写入** `violations`，调用方不得将其解释为某个 violation `code`；
- **不新增** violation code（本节封闭集合保持不变，仍为 8 个值）；
- 该 Proposal 不可进入审批，也不可 apply。

依据 §5.6：「同一单次事项在一个提案中最多出现一个可持久化 block」。

与之相对，以下两种形态**合法**，不得判为结构错误：

- 同一单次事项在整份 Proposal 中只出现一个可持久化 block；
- 同一周期任务（`task_kind = recurring`）在不同本地日各出现一个 block。

说明：`MULTIPLE_BLOCKS_FOR_RECURRING_TASK_DAY` 的语义限定为**周期任务、同一上海本地日**，
不得用于单次事项跨日或单次事项多块的情形；后者的通道是本节的结构错误。
```

---

## 三、逐字补丁（git apply 形式，供 M0 直接应用）

```diff
--- a/docs/contracts/agent-api-v1.md
+++ b/docs/contracts/agent-api-v1.md
@@
 结构或联合类型错误（例如 `scheduled_at` 与 `planned_date` 跨上海本地日）返回
 `PROPOSAL_INVALID`，不放入 violations。结构合法但计划日期早于 `available_from`
 使用 `PLANNED_BEFORE_AVAILABLE_FROM`；晚于 date-only deadline 使用
 `PLANNED_AFTER_DATE_ONLY_DEADLINE`；block 结束晚于精确截止使用
 `BLOCK_AFTER_EXACT_DEADLINE`。
+
+「同一单次事项（`task_kind = one_time`）在一个 Proposal 中出现多个可持久化
+`schedule_block`」同属**结构错误**，按本节上述规则处理：
+
+- 返回 HTTP `422`，错误码 `PROPOSAL_INVALID`；
+- **不写入** `violations`，调用方不得将其解释为某个 violation `code`；
+- **不新增** violation code（本节封闭集合保持不变，仍为 8 个值）；
+- 该 Proposal 不可进入审批，也不可 apply。
+
+依据 §5.6：「同一单次事项在一个提案中最多出现一个可持久化 block」。
+
+与之相对，以下两种形态**合法**，不得判为结构错误：
+
+- 同一单次事项在整份 Proposal 中只出现一个可持久化 block；
+- 同一周期任务（`task_kind = recurring`）在不同本地日各出现一个 block。
+
+说明：`MULTIPLE_BLOCKS_FOR_RECURRING_TASK_DAY` 的语义限定为**周期任务、同一上海本地日**，
+不得用于单次事项跨日或单次事项多块的情形；后者的通道是本节的结构错误。
```

> 注：上下文行若与实际文件有轻微出入，以**增补段落本身**为准，位置在 §5.8 的
> `PROPOSAL_INVALID` 说明之后即可。

---

## 四、实现侧现状（已在 head `7ee2fb4` 生效，无需改动）

| 用例 | 实测 | 断言位置 |
|---|---|---|
| 同一 `one_time` 两个不相邻可持久化块 | **422 `PROPOSAL_INVALID`**，`error.field=proposal.blocks`，消息点名任务与全部 block id | `smoke`：「同一单次事项两块 → 422 PROPOSAL_INVALID」 |
| 同一 `one_time` 一个块 | 200，`valid=true` | `smoke`：「单次事项一块 → 200 valid（对照）」 |
| 同一 `recurring` 跨两日各一块 | 200，`valid=true` | `smoke`：「周期任务跨两日各一块 → 200 valid（对照）」 |

### 实际 422 响应样例（可直接作为契约示例）

```json
{
  "ok": false,
  "error": {
    "code": "PROPOSAL_INVALID",
    "field": "proposal.blocks",
    "message": "契约 §5.6 要求同一单次事项在一个提案中最多一个可持久化 block，以下单次事项出现了多个：t-one（块：b1、b2）。需要拆解的大任务应由上游先产生多个独立 Task，不得把一个 Task 的多块当作现有能力。",
    "retryable": false
  }
}
```

HTTP 状态码 `422`。注意：响应体**没有** `violations` 字段——结构错误不产生 violations，
这是与业务违规（如 `BLOCK_OVERLAP`）在形态上的关键区别。

---

## 五、待 M0 确认的两点

1. **交付方式**：由你把上面的文字/补丁应用到契约仓库，还是我在 fork 上建分支发 PR？
   （我无 upstream push 权限；若要 PR，请指定 base 分支。）
2. **是否同步更新 `agent-api-v1.examples.json`**：若需要，请告知期望的示例键位，
   我可以按上面的 422 样例给出可直接并入的片段（同样以文字/补丁形式交付）。
