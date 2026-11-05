# M2 ⇄ M1 接口约定（引擎可调用化）

> 依据：M0 2026-11-05 12:53:27Z《五日冲刺》§2（M2 负责调度引擎可调用化与核心逻辑集成）。
> 作者：B（M2）刘恒瑜　生成：2026-11-05 22:00（+08）
> 状态：**已可用**（服务可启动、三个场景实测通过、`smoke` 36 项全绿、Python 客户端实测通过）。
> 一句话：M1 只要会发 HTTP + JSON，就能拿到引擎的排程结果，**不需要 Dart 环境、不需要读我的源码**。

---

## 一、怎么起服务（M1 只需要这一条）

```bash
cd <repo>            # 分支 feat/m2-engine-service
export PATH="/e/flutter/bin:$PATH"     # 本机 Dart 在 Flutter SDK 里；M1 用自己的 dart 也可
dart run tools/m2-engine/bin/serve.dart
# 默认 http://127.0.0.1:8787；M2_ENGINE_PORT / M2_ENGINE_HOST 可覆盖
```

自检（不需要先起服务，内部自己开临时端口跑真实 HTTP）：

```bash
dart run tools/m2-engine/bin/smoke.dart     # 末行 SMOKE OK，退出码 0
```

> M1 的 Python 服务直接 `requests.post('http://127.0.0.1:8787/generate_schedule', json={...})` 即可。
> 若启动目录不同，`dart run` 必须指向仓库内的那个文件路径，工作目录无所谓（fixtures 用脚本路径定位）。

---

## 二、四个端点（唯一接口，不再加）

| 方法 | 路径 | 入参 | 出参要点 |
|---|---|---|---|
| GET | `/health` | — | `service=m2-engine`、`contract_basis`、`now_source` |
| POST | `/generate_schedule` | `{"input": {...}}` | `proposal`（四键）+ `meta` + 可选 `warnings` |
| POST | `/validate_schedule` | `{"input": {...}, "proposal"?: {...}}` | `valid`、`violations[]`、`counts` |
| POST | `/repair_schedule` | `{"input": {...}, "previous": {...}, "max_shift_minutes"?: int}` | `proposal` + `meta` |

- `input` 字段与契约 §3/§5 一致；**所有时间必须带 `+08:00` 偏移**，否则 400 并指出字段路径。
- `proposal` / `previous` / `max_shift_minutes` 是**壳级兄弟键**，与 `input` 并列，不要塞进 `input` 里。
- `proposal` 的键集合恒为 `{blocks, changes, unplanned_tasks, explanations}`；
  `proposal_id` / `snapshot_ref` / `input_digest` / `generated_at` / `expires_at` / `status` **不会出现**（方案 A），
  这些字段由服务端（M1）补，不要向 M2 索取。

---

## 三、闭环调用顺序（对应 M0 的「至少一个完整纵向闭环」）

```
1) 用户提出任务
2) M1 读任务/课程/日历 → 拼 input（见第四节映射表）
3) POST /generate_schedule            → proposal（blocks/changes/unplanned/explanations）
4) POST /validate_schedule            → valid=true/false；false 时把 violations 给用户看
5) 用户明确确认（确认前不得写入 —— M0 §1.A 硬要求）
6) M1 在**演示库**写入 proposal.changes（不是全局 main 库）
7) M1 重新读取并 readback，比对第 3 步的 blocks/changes
8) 如需调整：POST /repair_schedule（previous = 第 3 步的 proposal，max_shift_minutes 可选）
```

第 4 步的两种用法：

- 只传 `input` → 服务自己生成再校验（等价于「自检」，用于证明引擎输出自相一致）；
- 传 `input` + 第 3 步的 `proposal` → 校验**外部给的**提案（用于「用户手改后再校验」）。

---

## 四、M1 的数据 → M2 input 的字段映射

| M1 侧来源 | M2 字段 | 注意 |
|---|---|---|
| 当前时刻（服务端时钟） | `now` | 必须显式传；引擎不读系统时钟，同一输入必得同一输出 |
| 排程范围（今天/本周） | `horizon_start` / `horizon_end` | 两端都带偏移 |
| 快照版本号 | `base_version` | 原样带回；M2 不生成、不校验 |
| 用户偏好（起止分钟/最短块） | `preferences` | `day_start_minute` ∈ 0..1439，`day_end_minute` ∈ 1..1440 |
| 可用时间段 | `availability` | **三态**：不传 = 允许推导；`[]` = 明确没有时间；非空 = 只用这些 |
| 课程 + 外部会议 | `fixed_blocks` | `owner_type` ∈ `course` / `external_fixed_event`；**不可被移动** |
| 周期任务 / 单次事项 | `demands` | `task_kind` ∈ `recurring` / `one_time` |
| 任务目标时长 | `target_duration_seconds` | 有它 → `duration_source=task_target` |
| 可信快照的当日剩余量 | `remaining_minutes_today` | **只对 `recurring` 有意义**；`0` = 当天已完成（不出块、不进 unplanned、产出 `ALREADY_DONE_TODAY`） |
| 截止 | `deadline` | `{kind:"date_only",date}` 或 `{kind:"exact",at}`，两者不得互串字段 |
| 上一版已排的柔性块 | `existing_placements` | 供 repair 用 |

**不要给 M2 的**：`required_minutes` 只应由服务端的可信快照折算后填（缺省 0 会落到 30 分钟兜底，
响应会在 `warnings` 里点名）；LLM 不得直接提供该值。

---

## 五、谁实现「校验」这件事（避免两套权威）

| 范围 | 权威实现 | 说明 |
|---|---|---|
| 提案静态一致性（8 码） | **契约 §5.8 文本**；当前落地在 `tools/m1-server`（PR #10，已第三方实测） | M2 的 `validate_schedule` 用**同一套码与同一输出顺序**，供闭环自证；两实现并存时以契约文本为准 |
| 落库/readback/审批 | M1 服务端 | M2 不碰数据库 |
| 生成排程 | **M2 引擎** | 唯一实现 |

冲突处理原则：**若两边判定不一致，先看契约原文**；契约没写清的，报 M0 裁定，不在代码里各说各话。

---

## 六、已实测的三个场景（我方证据，可复跑）

| 场景 | fixture | 实测结果 |
|---|---|---|
| 正常排程 | `fixtures/normal.json` | 2 块（08:00–09:30、09:30–10:00）、2 条 change、0 未安排、`planned_minutes=120` |
| 固定日程冲突 | `fixtures/conflict.json` | 任务进 `unplanned_tasks` 并带 `reason_code` |
| 已完成任务 | `fixtures/already_done.json` | 该任务不出块、不进 unplanned、`ALREADY_DONE_TODAY` 带 `related_task_ids` |

`smoke` 另覆盖：无偏移时间被拒（400 + `field=input.now`）、未知路径 404、GET 打业务端点 405、
外部提案的 `FIXED_EVENT_CONFLICT` 先于 `BLOCK_OVERLAP`、`message` 不含裸 ID、真实 HTTP 往返与进程内同结果。

---

## 七、一条必须让 M1 知道的实测坑

`DateTime.parse('2026-11-02T08:00:00+08:00')` 在 Dart 里是 **UTC 瞬时**（`00:00Z`）。
若直接喂给引擎，`minuteOfDay()` 会算出 `0` 而不是 `480`——**落库的 `planned_start_minute` 会错 8 小时**，
解释文案也会写「安排在 00:00–01:30」。适配层已用 `toShanghaiWallClock()` 统一还原，
并由 `smoke` 钉了一条断言（`normal: 解释文案墙钟与 +08:00 一致`）。
M1 若自己拼 `planned_start_minute`，务必按上海墙面时间算。

---

## 八、还没做（下一轮，按需）

- 鉴权（当前无）、限流、请求体大小上限：仅本地演示，不暴露公网。
- `base_version` 过期校验：属服务端职责，M2 只回声。
- 多进程/并发：当前单进程串行，演示够用。

---

## 九、M3 复验三点的定性（2026-11-06 00:30 修订）

M3 在 `93415fff` 上自写 38 条断言全 PASS，同时提出三点「接得上但语义要定」。逐条给结论。

### F-1 信封：本服务是**引擎内表面**，不是契约信封

- 契约 L117-135 的五键信封（`api_version` / `request_id` / `trace_id` / `status` / `error`）
  由 **M1 的服务端**产出；本服务不冒充，也不自行编 `request_id` / `trace_id`（编了就是伪造审计链）。
- 因此「唯一接口」的正确说法是「**引擎侧唯一接口**」；对外唯一入口是 M1 那一层。
- 采纳一条改进：错误体现在带 `retryable`（4xx=false，5xx=true），调用方可机器判定能否重试。
  信封其余四键仍归 M1。

### F-2 `max_shift_minutes`：相对位移上限，且现在会校验

- **语义**（引擎注释原文）：`repairSchedule` 默认在全部候选空档里取**全局最小位移**；
  给了 `max_shift_minutes` 就只在「相对上一版块位移 ≤ 该值」的范围内找。`null` = 不设边界。
  它是**相对位移上限**，不是绝对时刻，也不是容差。
- **校验**（本轮修复）：非整数（含字符串 `"10"`、布尔 `true`、浮点 `10.5`）→ `400`，
  `error.field = "max_shift_minutes"`；负数 → `400`；`0` 合法（表示不许位移）。
  此前这些会被静默当成「没传」，属非法输入静默降级，已改。

### F-3 `availability`：缺字段 fail-closed（400）；显式 null 保留契约三态

M0 2026-11-05 14:34:14Z 裁定要求 fail-closed。落地方式如下（**与契约 §5.2 / 19-C2 一致的那一半守住，不一致的那一半上报**）：

| 入参 | 本服务行为 | 依据 |
|---|---|---|
| **缺字段** | **400**，`error.field = input.availability`，消息写明三种显式写法 | M0 fail-closed：不允许用省略表达「未知」 |
| 显式 `null` | 200；按 `preferences` 推导；`meta.availability_state=null`；**响应带 warnings 提示**「若已确认全忙请传 []」 | 契约 §5.2 / 19-C2 a（M0 2026-11-05 08:19:45Z 裁定）；Python `json.dumps({"availability": None})` 必带真 null |
| `[]` | 200；0 块；全部进 `unplanned_tasks` 且 `reason_code=NO_AVAILABILITY` | 19-C2 b |
| 非空数组 | 200；只用显式窗口 | 19-C2 c |

**尚未解决的分歧（已上报 M0，等一句话）**：M0 14:34Z 的口径含「**null** 也 fail-closed（拒绝或标 unplanned）」；
但这与契约 §5.2 三态、他本人 08:19:45Z 的 C2 裁定、以及 58 条基线中「null → 09:00 有块」的断言直接冲突。
若按新口径改，等于改冻结契约 + 动基线。故本服务当前：**省略必拒、null 照契约**，等 M0 二选一后再动。


---

## 十、与 M1 `tool_server` 的字段映射（真实缺口，不假设引擎有审批）

| M1 侧环节 | 本服务给什么 | 缺口 / 谁补 |
|---|---|---|
| 生成 `proposal` | `proposal{blocks,changes,unplanned_tasks,explanations}` | 服务端字段（`proposal_id`/`snapshot_ref`/`input_digest`/`generated_at`/`expires_at`/`status`）由 M1 补，M2 不产出 |
| 校验 | `/validate_schedule` 的 `violations[]`（8 码、顺序固定） | 权威判定归 M1 的 `tool_server`；M2 这份只作闭环自证，两边都打并记录差异 |
| 审批 `approval` | **不提供** | 完全在 M1 层；G5 真实 `approval_token` 链 BLOCKED |
| 应用 `apply` | **不提供**（不写库） | M1 在隔离演示库执行 `changes` |
| 回读 `readback` | **不提供** | M1 回读后产出 `base_version`/`applied_changes`/`snapshot_ref`/`query_version` |
| 信封 | 引擎内表面（见 F-1） | 五键 + `retryable` 由 M1 包 |

一句话：**M2 只负责「算」，不负责「存、批、读」**。把审批或落库算进引擎，是这轮最容易被误认成"已完成"的地方。

## 十一、坐标报告纪律（M3 2026-11-05 定，本轮起执行）

报本服务坐标必须给**两件**：服务代码四文件 blob + 分支现行 head。
只给 head 会在两次发信之间过期（我 21:10 报 `400b5e2`，21:37 再取已是 `93415fff`）。

---

## 十二、未安排原因码与 action 语义（P0/P1 修复后，给 M1 做映射用）

### 12.1 六个 `reason_code`（前四个是历史码，后两个是 M0 2026-11-05 17:04Z 新增）

| code | 触发条件 | `basis` 里写什么 | 服务端建议呈现 |
|---|---|---|---|
| `UNSCHEDULABLE_OVERDUE` | `deadline.latestEndAt < input.now`，即截止早于调度基准时刻 | 两个时刻：`deadline=… 早于 now=…` | 直说「已逾期，无法再排」；给「改截止 / 标记完成」两个动作 |
| `INSUFFICIENT_TIME_BEFORE_DEADLINE` | 截止未过，但截止前所有空闲分钟数 < 所需 | `截止 … 之前可用 N 分钟，需要 M 分钟` | 说清是**截止**掐死的，不是整体没空 |
| `WINDOW_INSUFFICIENT` | 无截止限制，但整体空闲不够 | 空（或调用方补） | 「今天排不下」，建议拆分或换天 |
| `OVERLAPS_FIXED` | 可用时段被课程/会议占满 | 空 | 指向日历冲突，不是任务本身问题 |
| `NO_AVAILABILITY` | `availability=[]`（显式全忙） | 空 | 提示用户先设可用时段 |
| `PAST_DEADLINE` | **历史码，保留兼容**；新输出不再使用 | 空 | 若收到，按 `UNSCHEDULABLE_OVERDUE` 处理即可 |

每条 unplanned 的 JSON 形状（M0 P0-3 后）：

```json
{
  "task_id": "t_x",
  "remaining_minutes": 90,
  "reason_code": "INSUFFICIENT_TIME_BEFORE_DEADLINE",
  "reason_message": "截止时间前的可用时间不足 90 分钟。",
  "message": "…同上，v1 兼容别名…",
  "basis": "截止 2026-11-05T22:00+08:00 之前可用 60 分钟，需要 90 分钟",
  "suggested_actions": ["缩短本次目标时长，或把它拆成两次较短安排", "把截止时间往后延，腾出足够连续时间"]
}
```

> `message` 与 `reason_message` 同值：前者是契约 §5.7 的既有键，后者是 M0 P0-3 的规范名。
> M1 二选一都能读，但**不要两个都往下游透传**，否则同一条信息会出现两次。

### 12.2 `changes[].action` 只有两个值

| action | 含义 | 判定方式 |
|---|---|---|
| `assign` | 当天原本**没有**该任务的安排，本次是首次指派 | `existing_placements` 里没有 (task, 当天) |
| `reschedule` | 当天**已有**安排，本次是改期 | `existing_placements` 里有 (task, 当天) |

**M1 必须区分**：`assign` 走「新建单日例外」，`reschedule` 走「更新已有例外」。
把两者都当更新，会得到一个字段全空的新记录；都当新建，会产生重复例外。
若你收到的 `existing_override_id` 非空但 action=`assign`，那是我或你的映射有 bug，直接报我。

### 12.3 跨天块没有对应 change 是**设计意图**，不是遗漏

未授权（`authorize_multi_day_overrides` 缺省/false）时：
`blocks` 可以跨多天展示，`changes` 只覆盖**最早一天**。
原因：不给「一次生成就把灵活任务永久钉死在每天同一时刻」开无授权的口子。

服务端应对：
- **readback 以 `changes` 为准**，`blocks` 只用于展示；
- 若看到「有块无单」，正确解释是「其余日期未获授权落库」，不是写入失败；
- 需要全量落库时，调用方显式传 `authorize_multi_day_overrides: true`，并在 UI 上取得用户明确同意。

### 12.4 `priority` 三态

`priority` 缺失或 `null` → 该块输出 `priority_state: "unknown"`，`ordering_reason` 退化为
`stable_input_order`。**不要把它当 0 处理**：0 是一个合法优先级，unknown 是「服务端没给」。


