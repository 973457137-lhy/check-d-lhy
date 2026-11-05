# M2 ⇄ M1 接口约定（引擎可调用化）

> 依据：M0 2026-11-05 12:53:27Z《五日冲刺》§2（M2 负责调度引擎可调用化与核心逻辑集成）。
> 作者：B（M2）刘恒瑜　生成：2026-11-05 22:00（+08）
> 状态：**已可用**（服务可启动、三个场景实测通过、`smoke` 30 项全绿）。
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
