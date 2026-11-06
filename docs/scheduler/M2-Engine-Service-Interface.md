# M2 ⇄ M1 接口约定（引擎可调用化）

> 依据：M0 2026-11-05 12:53:27Z《五日冲刺》§2（M2 负责调度引擎可调用化与核心逻辑集成）。
> 作者：B（M2）刘恒瑜。初版 2026-11-05 22:00，**末次修订 2026-11-06 05:1x**（随 `0c40adf` + 后续）。
> 状态：**已可用**。适配层自检 **73 项 / 0 失败 / exit 0**；域测试双通道 **69/69**（Dart 3.13.7，非 CI）。
> 一句话：M1 只要会发 HTTP + JSON，就能拿到引擎的排程结果，**不需要 Dart 环境、不需要读我的源码**。

---

## 〇、速查：你只关心这 12 件事（其余章节按需查）

| # | 事项 | 一句话 |
|---|---|---|
| 1 | 启动 | `dart run tools/m2-engine/bin/serve.dart`，默认 `127.0.0.1:8787`；无 pubspec、无第三方依赖、不用 Docker |
| 2 | 端点 | `GET /health`、`POST /generate_schedule`、`/validate_schedule`、`/repair_schedule`，**不再增加** |
| 3 | 请求壳 | `proposal` / `previous` / `max_shift_minutes` 是**与 `input` 并列的兄弟键**，不要塞进 `input` |
| 4 | 时间 | 一律带 `+08:00`；无偏移直接 400 并指出字段路径 |
| 5 | `availability` | **必填**。`[]` = 确认全忙；`null` = 未提供（按偏好推导）；数组 = 显式窗口。省略字段 = 400 |
| 6 | `action` | `assign`（首次指派）/ `reschedule`（改期）；判据是**同任务且同一天**有既有安排 |
| 7 | 跨天无 change | 未传 `authorize_multi_day_overrides=true` 时，多日只对**最早一天**出 change——是设计，不是漏 |
| 8 | `max_shift_minutes` | 是**搜索边界不是硬约束**：边界内无解会退「最早可用」，排出超限位移；超限会进 `warnings` |
| 9 | `priority` | 缺失或 `null` → `priority_state=unknown`，**不要当 0** |
| 10 | 错误体 | 恒为 `{ok:false, error:{code, field, message, retryable}}`；4xx 一律 `retryable=false`，5xx 才 `true` |
| 11 | `warnings` | 请**打到日志**。它是「你写错了但没报错」的唯一通道（未知键、超限、action 误判风险都在这里） |
| 12 | 坐标 | 报坐标必须给「服务代码四文件 blob + 现行 head」两件，只给 head 会过期 |

> 契约信封（`request_id` / `snapshot_ref` / `base_version` 等五键）由**你**补，本服务不冒充——
> 详见 §九 F-1。本服务只算不存、不批、不读（详见 §十）。

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

上表只列**业务场景**。`smoke`（73 项，末行 `SMOKE OK` / exit 0）另覆盖六大类，跑一次几分钟：

| 类别 | 覆盖点（举例） |
|---|---|
| 输入边界 | 无偏移时间被拒（400 + `field=input.now`）；`availability` 三态；`max_shift_minutes` 非法类型/负数 |
| 语义正确性 | 逾期不进 blocks；`assign`/`reschedule` 三分支；多日授权开关 on/off 行为差异 |
| 自洽性 | **引擎自产提案回喂校验器必须 valid**（含授权态「跨两天各一条 change」） |
| 反向控制 | 同任务同日两条 change 仍判非法；上限未超限时不得误报 |
| 错误体一致性 | 所有 4xx 的 `error.retryable` 是 `bool false`；畸形 JSON 也是 400 不是 500 |
| 传输一致性 | 真实 HTTP 往返与进程内调用同结果 |

> 这些不是「跑过一次就算」：每条都有对应的反向用例，防止把校验删掉后仍然全绿。

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

### 12.5 `action` 的判据是「同任务 **且同一天** 有既有安排」（2026-11-06 04:5x 三条实测）

| `existing_placements` 情况 | 结果 | 为什么 |
|---|---|---|
| 没有该任务的安排 | `assign` | 首次指派 |
| 该任务**同一天**有安排 | `reschedule` | 改期 |
| 该任务**别的日期**有安排 | `assign` | 那天是新建，不是改期 |

第三行是最容易写错的：只按任务匹配、漏掉日期维度的话，跨天情况会全被判成改期，
于是「新建」被当成「更新」写库，静默覆盖别的日期。三条都已入自检。

所以你传 `existing_placements` 时**必须逐条带上正确的日期**（`start_at` 的本地日即为判定日），
不要把「这个任务历史上出现过」当成「今天已有安排」。

## 十三、三个「静默失败」已封死（2026-11-06 03:2x，给 M1 接之前必读）

这三条都是同一个失败形态：**调用方以为生效了，服务端拿到的却是另一回事**，而且中间不报错。

### 13.1 `authorize_multi_day_overrides` 以前是「传了不生效」

本轮之前该键**根本没被解析**：传 `true` 照样只对最早一天生成单日例外，且无任何提示。
现在：

- `true` / `false` → 正常生效（实测 2 天 previous：`false` 出 1 条 change，`true` 出 2 条）；
- 字符串 `"true"`、数字 `1` → **400**，`error.field = input.authorize_multi_day_overrides`；
- 省略 → 默认 `false`（只落最早一天）。

**你要全量落库就必须显式传 `true`**，且应先在 UI 上取得用户同意——这是「不把灵活任务永久钉死」的开关，不是性能选项。

### 13.2 未知 `input` 键现在会进 `warnings`

手写 JSON 时把 `authorize_multi_day_overrides` 拼成 `authorize_multiday_overrides`，
以前是静默丢弃。现在响应里会出现：

```
warnings: ["input 含未知键并被忽略：authorize_multiday_overrides。若为拼写错误，……"]
```

不因为未知键而 400（契约可能先行扩展，硬拒会挡死后续字段），但**一定看得见**。
接进来后请把 `warnings` 打到日志，别丢。

### 13.3 `repair_schedule` 的 `action` 只看 `existing_placements`，不看 `previous`

判定 `assign` / `reschedule` 的依据是 **`input.existing_placements`**（服务端已知的既有安排），
**不是 `previous`**——`previous` 只是「上一版提案」，它究竟有没有落库，只有你那边知道，引擎不猜。

后果：`repair_schedule` 只传 `previous`、不传 `existing_placements` 时，所有 change 都会是
`assign`（首次指派）。若上一版其实已写入数据库，这就退化成「重复新建」。

现在遇到这种组合会返回 warning：

```
warnings: ["repair_schedule 未收到 input.existing_placements，而 previous 含 N 个块：……会把「改期」误标成「新建」"]
```

**正确做法**：调用 `repair_schedule` 时，把数据库里这些任务当天的既有安排一并放进
`input.existing_placements`；`previous` 只用于「原来排在哪、要挪多少」。

### 13.4 第四条（2026-11-06 04:3x 补）：非法 JSON 的错误体曾漏 `retryable`

真实 HTTP 实测发现：**请求体不是合法 JSON 时，返回的 400 里没有 `retryable` 字段**，
而其他所有错误都有。原因是这条分支在 `bin/serve.dart` 里手工拼了一份错误体，没走统一构造。

后果对你不小：客户端若写 `if (!resp.error.retryable) 放弃重试`，遇到这条分支会读到 `null`，
在动态语言里直接当 `false` 用还好，在强类型语言/严格解析里会抛异常，
表现为「重试逻辑时灵时不灵」，而且只在传坏 JSON 时触发，很难复现。

已改为**全服务只有一个错误体构造**（`errorBody`），HTTP 层的 JSON 解析分支也复用它。
零散的手搓错误体在代码里已经清零（`grep "'error':"` 只剩定义那一处）。

顺带把请求体解码抽成了 `decodeBodyOrError`，放在 `lib/handler.dart`：
这样自检能直接测这条分支，而不必在脚本里再抄一份解码逻辑
（抄一份就是「测的是副本、跑的是另一份」，本项目反复踩过的假通过）。

约定：**任何 4xx 的 `error.retryable` 都是 `false`，5xx 才是 `true`**，无一例外。

## 十四、一条已被修掉的「自产提案通不过自己校验」（2026-11-06 03:3x）

`MULTIPLE_CHANGES_FOR_ONE_TIME_TASK` 这条规则的判定以前**写错了作用范围**：
只要同一任务出现 ≥2 条 change 就报，`isOneTime` 只改了文案、没改判定。
后果是——你打开 `authorize_multi_day_overrides=true` 之后，引擎产出的
「周期任务跨两天各一条 change」会被**引擎自己的校验器判非法**。

现在的判定按作用范围分层：

| 任务类型 | 允许的变更数 | 违反时报什么 |
|---|---|---|
| 单次事项 `one_time` | 整个提案最多 1 条 | `MULTIPLE_CHANGES_FOR_ONE_TIME_TASK` |
| 周期任务 `recurring` | **每个本地日**最多 1 条；跨多日各一条合法 | 同上（仅同一天 ≥2 条时） |

对你的实际影响：

- 不要因为「同一任务有多条 change」就判我错——先看 `local_date` 是否相同；
- 你自己拼装提案时若给同一周期任务同一天写了两条，会被这条规则拦下，这是对的；
- 反向控制已进自检：同一天两条仍必须判非法，规则没被关掉。

## 十五、`date_only` 截止「23:59:59 vs 次日 00:00」实测：**两种写法等价，不必裁定**

M0 一直待裁的一条是「`date_only` 截止是到 23:59:59 还是到当天结束」。我用四个用例把它测成了事实，
结论是**在分钟粒度下两者输出完全一致**，这条不需要任何人再拍。

可用窗口固定为 `23:00–次日 00:00`，任务从 23:00 开始排：

| 用例 | 结束时刻 | 引擎结果 | 23:59:59 口径会是 | 一致？ |
|---|---|---|---|---|
| 今天截止 · 60 分钟 | 次日 00:00 | 不可排（`INSUFFICIENT_TIME_BEFORE_DEADLINE`） | 不可排 | ✅ |
| 今天截止 · 59 分钟 | 23:59 | 可排 | 可排 | ✅ |
| 明天截止 · 60 分钟 | 次日 00:00 | 可排 | 可排 | ✅ |
| 无截止 · 60 分钟 | 次日 00:00 | 可排 | 可排 | ✅ |

**一处必须更正的表述（2026-11-06 14:1x 补）**：两者在「哪些任务能排得下」上等价，
但在「产出的 `end_at` 长什么样」上**不等价**——24:00 口径允许产出 `end_at = 次日 00:00:00`，
23:59:59 口径最多只能到 `23:59`。这不是可忽略的差异，因为它直接触发契约 §5.6 的跨午夜判定，
详见 §十八。上一版我写「两种写法输出完全一致」是过头了，现予更正。

为什么等价（**仅就可排性而言**）：引擎的块是**分钟粒度**，结束时刻只可能是 `23:59` 或 `次日 00:00`，没有中间值。
`23:59:59` 与 `次日 00:00 − 1ms` 的差别落在 `(23:59:00, 次日00:00)` 这个区间，
而一分钟粒度的块根本落不进去。

**唯一需要双方口头对齐的一句**（比争 23:59:59 还是 24:00 重要得多）：

> 结束时刻**等于**次日 `00:00:00` 视为超出当天截止；`23:59` 视为未超出。

我这边已经是这个行为，且**不会误杀正常跨午夜**——第 3、4 行就是反例控制：截止不是今天、
或根本没有截止时，`23:00–次日 00:00` 正常排出。

M1 侧只需保证：不要用「`end_at <= 当天 23:59:59`」这种方式去卡「明天截止」的块，
否则会把第 3 行那种合法块判成非法。



## 十六、`max_shift_minutes` 是**搜索边界**，不是硬约束（2026-11-06 04:1x 实测定性）

这条会咬人，所以写死：**`max_shift_minutes` 不保证位移不超过该值。**

引擎的语义是「只在边界内找最近位置；边界内无解 → 退最早可用」。也就是说：

| 你传 | previous 在 15:00、本次可用只有 08:00–09:00（必须挪 420 分钟） | 结果 |
|---|---|---|
| 省略 | 找全局最近 → 08:30–09:00 | 挪 420 分钟 |
| `10` | 10 分钟内无解 → 退最早可用 → 08:00–08:30 | **仍挪 420 分钟** |
| `600` | 边界内有解 → 08:30–09:00 | 挪 420 分钟（未超限） |

注意中间那行：传了 10，实际挪了 420 分钟。**它不会拒排，也不会因此报错**——这是既定设计，
不是 bug（引擎注释原文：「边界内无解返回 null，由调用方退最早可用」）。

### 我做了什么（不改引擎，只让违反可见）

`repair_schedule` 在满足以下两条时，会在 `warnings` 里逐个点名超限的块：

1. 传了 `max_shift_minutes`；
2. 某块相对 `previous` 里「同任务同一天」的块，实际位移 > 该上限。

实测文案：

```
max_shift_minutes=10 未能满足：t-a（位移 420 分钟 > 上限 10）。该参数只是搜索边界，
边界内无解时引擎退「最早可用」，不会拒排也不会报错；若这些块不允许这样移动，请改由服务端拒绝该提案。
```

### 你需要做的判断

「位移超限」到底该不该算失败，是**产品语义**，不是引擎能替你定的：

- 若「不许挪超过 N 分钟」是硬要求 → 你看到这条 warning 就该**整份拒绝**，别落库；
- 若只是「尽量别挪太远」→ 可以落库，但建议把 warning 透给用户看。

不要因为它返回 200 就认为约束满足了——200 只说明「排出来了」，不说明「按你的边界排的」。

## 十七、Dart 版本兼容：源码已降到 2.17 可编译（2026-11-06 12:5x）

M1 实测容器内 Dart SDK = **2.17.0**（linux_x64），我的 Dart 3 语法编不过，卡住「引擎同容器托管」。
他给了三条绕法（AOT 二进制 / 每次冷启动下载 SDK / 我改源码），倾向第 1 条。

**我的选择是第三条**，理由：

- `dart compile exe` **不能跨平台编译**：我在 Windows 只能产出 Windows 可执行文件，容器是 linux_x64；
- 二进制入库会带来「源码改了忘重编」的静默背离——这正是本项目反复踩过的「两份副本」类问题；
- 实际代价很小：全仓 Dart 3 专属语法只有 **13 处**，改完两边都能编，**一套源码**，M1 什么都不用做。

| 项 | 位置 | 处理 |
|---|---|---|
| `switch` 表达式 ×7 | contract 4（枚举→码表）、contract_json 2、handler 1 | 改为 `switch` 语句 + `return`，语义逐字对应 |
| record 类型 ×1 | engine `_durationOf` 的返回 `({int minutes, bool fromTarget})` | 改为私有小类 `_DurationInfo`，字段名不变 |
| `library;` 指令 ×5 | 两个域文件 + 三个适配层文件 | 删除（该指令 2.19 才有）；文件头 `///` 改 `//`，避免悬空文档注释 |

### 怎么验证「真的能在 2.17 下编」（无需装旧 SDK）

Dart 支持按文件标注语言版本。把文件复制出来、首行加 `// @dart=2.17`，再用当前 SDK 分析：

```
mkdir -p .compat-probe/domain
{ echo '// @dart=2.17'; cat lib/.../schedule_contract.dart; } > .compat-probe/domain/schedule_contract.dart
dart analyze .compat-probe/domain      # 预期：No issues（或仅剩已知误报）
```

这一步抓到了我肉眼扫漏的两处：**record 类型**与 **`library;`**。只看 `switch` 是不够的。

### 语义未变的证据

- 宿主 `flutter test`：**69/69，exit 0**
- 隔离 `dart test`（Dart 3.13.7）：**69/69，exit 0**
- 适配层 `smoke`：**77 项 / 0 失败 / exit 0**

改动是**纯语法降级**：没有任何断言被改、没有被跳过的用例。

### 给 M1 的结论

**三条绕法都不用做。** 直接跑现有源码即可（你已改成直接执行而非 `dart run`，这是对的：
`dart run` 会去找 package config 而失败）。若你仍想要 AOT 二进制，
请在容器里用 Dart 3 编一次（我这边编不出 linux 产物），并把二进制的 sha256 回传给我登记。

### 17.1 真 SDK 复核（2026-11-06 13:5x）：不是「应该能编」，是「已编过并跑过」

上一节用的是 `// @dart=2.17` 语言版本标注，属**近似**验证（分析器用当前 SDK 的核心库）。
本轮直接下了 **Dart 2.17.6（stable, windows_x64）** 做真机复核：

| 检查 | 结果 |
|---|---|
| `dart analyze`（2.17.6） | 2 条 info（engine:135 已知误报、smoke 一处只写不读），**0 error 0 warning** |
| `dart compile exe serve.dart` | **成功**，exit 0，产物 5,656,576 B |
| 用 2.17.6 跑 `smoke.dart` | **77 项 / 0 失败 / SMOKE OK** |
| 运行编出的二进制 | `/health` 200（semantics_stamp 正确）、`/generate_schedule` 200（块 08:00–09:30） |

也就是说：**编译、运行、全部断言**三层都在真 2.17 下过了。上一节的近似验证结论与真机一致。

> **复验（2026-11-06 14:1x，head `bb23616`）**：上面这次初验跑在 Dart 2.17 兼容化完成的
> 那一刻；此后 `handler.dart` 又改过两次（/health 语义表、跨午夜结构校验），已在新 head 上
> **整套重跑**：analyze 0 error 0 warning、`dart compile exe` 成功、`smoke` **82/82**、
> 编出的二进制 `/health` 返回 200。
> 结论：兼容性不只对某一个提交成立，对当前 head 仍成立。
> 规矩：**凡再动这 6 个文件，就必须重跑一次 2.17 复核**，不能拿旧结论继续对外承诺。

### 17.2 一个新的、更省事的部署选项（实测编译只要 **2 秒**）

我原本让 M1「直接跑源码」。实测后这条建议可以优化——**用容器自带的 2.17 做一次 AOT**：

| 方式 | 每次冷启动成本 | 需要下载 SDK |
|---|---|---|
| 跑源码（`dart serve.dart`） | 每次都要 JIT/kernel 编译，约 15–20 秒 | 否 |
| **容器内 `dart compile exe`（推荐）** | **编译一次 2 秒**，之后启动瞬时 | **否**——用容器自带的 2.17 |
| M1 最初设想的 AOT | 一次性 ~5 分钟 | 是（下载 Dart 3） |

他的容器每 10–25 分钟重启一次，所以「每次冷启动编译 15–20 秒」是持续成本；
而「2 秒编一次、产物进部署包」只有一次性成本，且**不需要任何下载**。

命令（在容器里，源码布局不变）：

```bash
cd <workspace>
/opt/flutter/bin/dart compile exe tools/m2-engine/bin/serve.dart -o engine_bin
./engine_bin            # 默认 127.0.0.1:8787，M2_ENGINE_PORT 可覆盖
```

产物约 5.7 MB，自包含，不依赖容器内 Dart 是否还在。

## 十八、块跨午夜：契约 §5.6 的硬约束，此前**两边都没实现**（2026-11-06 14:1x）

### 契约原文

§5.6：**「每个 block 的 `start_at` 与 `end_at` 必须属于同一个上海本地日，不能跨午夜。」**
§5.8 同时规定：结构/类型类错误走 `PROPOSAL_INVALID`，**不放进 `violations`**；
§4.1 给出 `PROPOSAL_INVALID` 对应 HTTP **422**。

### 实测发现（两个都成立）

| 检查 | 修前结果 |
|---|---|
| 手工构造 `23:00 → 次日 01:00` 的块送去校验 | **`valid=true`，零 violations** —— 我的校验器根本没检查这条 |
| 生成器在「可用 23:00–24:00、任务 60 分钟」下 | 产出 `end_at = 次日 00:00:00`，`start_at` 与 `end_at` 不在同一本地日 |

第二条尤其麻烦：如果我按字面做「日期相等」判定，**引擎自己的合法产出会被自己的校验器拒掉**——
又是一次「生成合法、校验非法」。

### 现采用的口径：半开区间

- **允许** `end_at` **恰等于**次日 `00:00:00` —— 这表示「当天排到结束」，区间 `[23:00, 24:00)` 完全在当天内；
- **拒绝**真正越过零点的（`end_at > 次日 00:00:00`），返回 **422 `PROPOSAL_INVALID`**，`error.field = proposal.blocks`，消息里点名每个越界块。

为什么不能简单地把 `end == 次日00:00` 也判非法：可用窗口 `23:00–24:00`、任务需要 60 分钟时，
若最多只能放到 `23:59`，这个任务就变成**排不下**（少 1 分钟），而它本该完整放下。
这是可见的功能退化，不是洁癖问题。

### 需要 M0 一句话（两种口径二选一）

- **A（我现采用）**：半开区间，允许 `end_at == 次日 00:00:00`；
- **B**：严格按字面，`end_at` 的本地日必须等于 `start_at` 的本地日，
  则引擎必须把当日最后可用分钟压到 `23:59`，`duration_seconds` 会少 60 秒。

选 B 我要同步改生成器的可用窗口裁剪，并明确「23:00–24:00 窗口只能放 59 分钟」这一退化。
在 M0 回话前我按 A 执行。

### 对 M1 的硬要求（这条会直接撞车）

**你的校验器不要用「`start_at` 的日期 == `end_at` 的日期」这种严格比较**。
我按 A 口径会合法产出 `end_at = 次日 00:00:00`，严格比较会把它判非法，形成「我生成的你不认」。
请按半开语义判：`end_at > 当天 24:00` 才算跨午夜。

### 18.1 另一句同样被漏掉：单次事项多块（并暴露出契约自身缺口）

§5.6 还有一句：**「同一单次事项在一个提案中最多出现一个可持久化 block。」**

我的校验器原来对多块的判重写的是 `if (!block.isRecurring) continue;` ——
**单次事项被整个跳过**。实测：一个 `one_time` 任务带两个不相邻的块，返回 `valid=true`、零 violations。

### 这里撞到一个契约缺口：规则有，码没有

§5.8 的 violation 码是**封闭 8 值**，与「多块」有关的只有 `MULTIPLE_BLOCKS_FOR_RECURRING_TASK_DAY`：

- 复用它 → 名字明确写 `RECURRING`，会让消费方误判任务类型，属语义错误的报告；
- 自造新码 → 违反「未知 `code` 必须以 `PROPOSAL_INVALID` 拒绝」；
- 所以只能按 §5.8 的结构错误通道走 **422 `PROPOSAL_INVALID`**。

这属于契约需要补的地方（要么加一个码，要么在 §5.8 明说该情形走 `PROPOSAL_INVALID`）。
已上报 M0 / M3，不自行改契约。

### 现在的行为（三条都已入自检）

| 提案内容 | 结果 |
|---|---|
| 同一 `one_time` 两块 | **422 `PROPOSAL_INVALID`**，消息点名任务与全部块 id |
| 同一 `one_time` 一块 | 200 `valid=true`（对照） |
| 同一 `recurring` 跨两日各一块 | 200 `valid=true`（对照：新守卫不得误杀合法跨日） |

## 十九、时长来源优先级：逐条实测与契约一致（2026-11-06 14:4x，未发现缺陷）

§5.6 对时长来源的规定是**有序且固定**的，我一向凭印象实现、从未逐条对过。本轮补上，结论是——**已实现且与契约一致**。
这不是白查：它把下面这张表变成了可回归的断言，以后谁改动 `_durationOf` 都会立刻红。

| 输入 | 契约要求 | 实测 |
|---|---|---|
| 周期任务 `remaining_minutes_today = 0` | **不生成 block**（"已做完"不是"排不下"） | 无块、也不进 `unplanned_tasks` ✅ |
| 周期任务 `remaining = 45`、`target = 3600s` | 按 45 分钟排，`task_target` | `08:00–08:45`、2700 秒、`task_target` ✅ |
| 仅 `target = 3600s` | 60 分钟，`task_target` | `08:00–09:00`、3600 秒、`task_target` ✅ |
| 无任何时长依据、`minimum_block_minutes = 45` | 45 分钟，`scheduler_estimate` | 2700 秒、`scheduler_estimate` ✅ |
| 无任何时长依据、`minimum_block_minutes = 10` | `max(10, 30) = 30` 分钟（**下限 30 不能被杀低**） | 1800 秒 ✅ |
| 任意情形 | `duration_seconds` = `end_at − start_at`，正整数 | 逐例实算一致 ✅ |

### 给你（M1）的两个使用要点

1. **`remaining_minutes_today` 只对周期任务生效**，且必须由你从可信快照给出——它优先于 `duration_target_seconds`。
   传 `0` 的语义是「今天已经做完了」：我不会出块、也不会把它塞进未安排列表，只给一条 `ALREADY_DONE_TODAY` 解释。
2. **估算不得写成任务固有属性**：`duration_source = scheduler_estimate` 的块，不要回写到 Task 的持久化时长字段
   （契约 §5.6 明文：任何估算都不得写回 Task 持久化字段）。只有 `task_target` 才代表任务自带目标。

## 二十、容器部署的真正卡点是 pubspec，不是源码（2026-11-06 16:5x，M3 诊断 + 我方实测确认）

### 现象分层

M1 报「容器 Dart 2.17 编不过」时，其实卡了**两层**，我最初只解决了第一层：

| 层 | 问题 | 状态 |
|---|---|---|
| 代码层 | Dart 3 语法（switch 表达式 / record / `library;`） | 已修（head `0c56f91`/`ce1df28`），真 2.17.6 编过 |
| **包层** | 引擎包若沿用仓库根 `pubspec.yaml`（`sdk >=3.9.0` + flutter/drift/supabase/qr） | **Dart 2.17 在 pub 解析阶段就拒，根本轮不到编代码** |

第一层修完为什么还是跑不起来：`dart run` 会向上找 package config，找不到就用上层 pubspec；
容器里那一层要么缺失、要么就是仓库根那个高版本约束。

### 修法：零依赖最小 pubspec

`tools/m2-engine/deploy/pubspec.engine-pack.yaml`（复制为包根 `pubspec.yaml`）：

```yaml
name: check_d_engine_pack
publish_to: none
environment:
  sdk: ">=2.17.0 <4.0.0"
```

无任何 `dependencies`——引擎只用 `dart:core/async/io/convert`。
`dart pub get` 只生成 package config，不下载任何包。

### 真 Dart 2.17.6 下四项实测

| 步骤 | 结果 |
|---|---|
| `dart pub get` | **Got dependencies!** exit 0 |
| `dart analyze .` | 0 error / 0 warning（2 条 info） |
| `dart run tools/m2-engine/bin/smoke.dart` | **91 项 / 0 失败 / SMOKE OK** |
| `dart run tools/m2-engine/bin/serve.dart` | 起服务，`/health` **200** |

**副作用（正面）**：有了 pubspec，`dart run` 也正常了——M1 之前遇到的「dart run 找 package config 失败、
只能改成直接执行」随之解决，不必再绕。

### 关于 `// @dart=2.17` 首行标注：本轮不加

M3 建议给 7 个 dart 文件首行加语言版本标注。不加的两个理由：

1. 那行是给 **Dart 3 分析器**看的保护栏；**容器是 2.17，在那里是空操作**，对能不能跑毫无影响；
2. 改 7 个文件会换 blob，而 M0 明确要求「交付后除非阻断缺陷不再改引擎坐标」。
   实测已用真 2.17.6 验过，加标注不提高「能不能编」的确定性，只会多一轮坐标变更。

若 M0/M3 认为必须加，我加并同步新坐标——但需要他们明确要求，我不自作主张动坐标。
