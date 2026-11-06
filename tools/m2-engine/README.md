# M2 调度引擎 · 可调用服务（m2-engine）

把已经通过 58 条纯函数测试的调度引擎，包成一个**任何语言都能调**的 HTTP 服务。
纯 Dart（`dart:io`），无 Flutter、无数据库、无第三方依赖。

> 里程碑对应：M0 2026-11-05 12:53Z《五日冲刺》§2.A/§2.B，11-06 12:00 前交「可调用引擎入口和接口样例」。

## 启动

```bash
cd E:/Projects/check-d-lhy
export PATH="/e/flutter/bin:$PATH"      # 本机 Dart 在 Flutter SDK 里
dart run tools/m2-engine/bin/serve.dart
# 默认 http://127.0.0.1:8787
# 可选环境变量：M2_ENGINE_PORT=9000  M2_ENGINE_HOST=0.0.0.0
```

自检（不需要起服务，内部会自己起一个临时端口跑一轮真实 HTTP）：

```bash
dart run tools/m2-engine/bin/smoke.dart
# 末行 SMOKE OK，退出码 0；当前 91 项断言
```

## 端点

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/health` | 存活与版本，返回契约基准与 `now` 来源说明 |
| POST | `/generate_schedule` | 生成提案（引擎 `generateSchedule`） |
| POST | `/validate_schedule` | 校验提案；不传 `proposal` 时先自己生成再校验 |
| POST | `/repair_schedule` | 最小扰动重排（引擎 `repairSchedule`），需带 `previous` |

### 请求壳

两种都收：

```json
{ "input": { ...契约输入... } }        // 推荐，便于将来加同级字段
{ ...契约输入... }                       // 裸 input
```

**同级字段属于壳，不属于 input**：`proposal`（校验用）、`previous`（重排用）、
`max_shift_minutes`（重排用）放在壳里，与 `input` 并列。

### 输入字段（与契约 §3/§5 一致）

| 字段 | 必填 | 说明 |
|---|---|---|
| `now` | ✅ | 排程基准时刻，**必须带偏移**；引擎不读系统时钟 |
| `horizon_start` / `horizon_end` | ✅ | 排程视界 |
| `base_version` | ✅ | 原样带回，不生成、不校验 |
| `timezone` | ⬜ | 固定 `Asia/Shanghai`；传别的值会进 `warnings`（引擎不做时区转换） |
| `preferences` | ⬜ | `day_start_minute` / `day_end_minute` / `minimum_block_minutes` |
| `availability` | ✅ | **必填且三态**：`[]` = 已确认今天全忙（不推导）；`null` = 调用方未提供（按 preferences 推导，响应带 `warnings`）；非空数组 = 只用显式窗口。**省略该字段直接 400**（省略无法与「全忙」区分） |
| `fixed_blocks` | ⬜ | 课程/外部固定事件，`owner_type` ∈ `course` / `external_fixed_event` |
| `demands` | ⬜ | 任务需求；`task_kind` ∈ `recurring` / `one_time`；`deadline` 为 `{kind:date_only,date}` 或 `{kind:exact,at}` |
| `existing_placements` | ⬜ | 上一版已存在的柔性安排 |

**缺字段不猜、不补默认**：除 `required_minutes`（缺省 0）外，缺哪个字段就返回
`400` 并给出字段路径，例如：

```json
{"ok":false,"error":{"code":"INVALID_ARGUMENT","field":"input.now","message":"缺少时区偏移（契约 §3 禁止无偏移时间），示例：2026-11-05T09:00:00+08:00"}}
```

### 响应（`/generate_schedule`）

`proposal` 就是 `ScheduleProposal.toJson()`，键集合恰为
`{blocks, changes, unplanned_tasks, explanations}`，不加服务端字段（方案 A）。

```json
{
  "ok": true,
  "proposal": { "blocks": [...], "changes": [...], "unplanned_tasks": [], "explanations": [...] },
  "meta": {
    "blocks": 2, "changes": 2, "unplanned_tasks": 0, "explanations": 3,
    "planned_minutes": 120,
    "now_echo": "2026-11-02T08:00:00+08:00",
    "base_version_echo": "fixture-normal-v1",
    "availability_state": "explicit"
  },
  "warnings": ["…仅在有非致命提示时出现…"]
}
```

`meta` 是**调用方的便利字段**，不属于契约；服务端落库时只应取 `proposal`。

### 响应（`/validate_schedule`）

```json
{
  "ok": true,
  "valid": false,
  "proposal_source": "caller-supplied",   // 或 engine-generated
  "violations": [
    {"code": "FIXED_EVENT_CONFLICT", "message": "提案时间块与固定日程（课程或外部固定事件）重叠；固定日程不可被移动。",
     "related_task_ids": ["t_eng"], "related_block_ids": ["blk-t_eng"]}
  ],
  "counts": {"total": 1, "by_code": {"FIXED_EVENT_CONFLICT": 1}}
}
```

- 码集合：`BLOCK_TIME_INVALID` / `FIXED_EVENT_CONFLICT` / `PLANNED_BEFORE_AVAILABLE_FROM` /
  `PLANNED_AFTER_DATE_ONLY_DEADLINE` / `BLOCK_AFTER_EXACT_DEADLINE` /
  `MULTIPLE_BLOCKS_FOR_RECURRING_TASK_DAY` / `MULTIPLE_CHANGES_FOR_ONE_TIME_TASK` / `BLOCK_OVERLAP`
- **输出顺序固定**，`FIXED_EVENT_CONFLICT` 先于 `BLOCK_OVERLAP`（M0 2026-11-05 要求）
- **`message` 不内嵌任何裸 ID**，关联关系只在 `related_*_ids`（PR #8 教训）

## 三个可直接跑的场景（fixtures/）

| 文件 | 场景 | 期望 |
|---|---|---|
| `normal.json` | 两个任务 + 一节课程 | 2 块、无未安排、有 `SCHEDULED` |
| `conflict.json` | 可用窗口 60 分钟、课程占 30 分钟、任务要 90 分钟 | 任务进 `unplanned_tasks` 并带 `reason_code` |
| `already_done.json` | 周期任务当天剩余 0 分钟 | 不出块、不进 unplanned、产出 `ALREADY_DONE_TODAY` + `related_task_ids` |

```bash
curl -s -X POST http://127.0.0.1:8787/generate_schedule \
  -H 'content-type: application/json' \
  -d @tools/m2-engine/fixtures/normal.json
```

（本机有 `http_proxy` 时加 `--noproxy '*'`，否则 curl 会走代理连不上 127.0.0.1。）

## M1 侧调用示例（Python，仅标准库）

`examples/call_engine.py` 只用 `urllib`，**不需要 pip install**，并显式禁用代理：

```bash
python tools/m2-engine/examples/call_engine.py health
python tools/m2-engine/examples/call_engine.py generate tools/m2-engine/fixtures/normal.json
python tools/m2-engine/examples/call_engine.py validate tools/m2-engine/fixtures/normal.json
```

实测输出（Dart 3.13.7 + Python 3.13.14，日志 `docs/scheduler/reports/2026-11-05-python-client.log`）：

```
generate normal    → blocks=2 changes=2 unplanned=0 planned_minutes=120，exit 0
generate conflict  → blocks=0 changes=0 unplanned=1（WINDOW_INSUFFICIENT），exit 0
validate normal    → valid=True violations=0，exit 0
```

Python 侧只需把 `BASE` 改成实际地址；`validate` 退出码约定：`0` = 通过，`1` = 有不通过项或调用失败，便于 CI/脚本串起来。

## 五条口径（踩过坑，写下来省下一次扯皮）

1. **时间必须带偏移**。`DateTime.parse('+08:00')` 得到的是 UTC 瞬时，而引擎的语义是
   「上海墙面时间」；适配层统一用 `toShanghaiWallClock()` 还原后再进引擎。
   不做这一步的后果是实测到的：`planned_start_minute` 会从 `480` 变成 `0`，
   解释文案会写「安排在 00:00–01:30」——**落库的分钟数会错**。
2. **availability 三态不可合并**：缺键 ≠ `[]`。缺键允许推导，`[]` 是「明确没有时间」。
3. **`required_minutes` 是服务端可信快照字段**，不接受 LLM 直接给；缺省为 0 时引擎会
   落到 30 分钟兜底，响应 `warnings` 会点名是哪一个 demand。
4. **`base_version` 只回声**，不生成、不校验；`proposal_id` / `snapshot_ref` / `input_digest` /
   `generated_at` / `expires_at` / `status` 一律不产出（方案 A）。
5. **本服务不写任何数据库**。`changes` 只是「允许落库的意图」，真正落库与 readback 属 M1 的服务端。

## 与 M1 服务端的边界（别做成两套权威）

| 能力 | 权威实现 | 本服务的角色 |
|---|---|---|
| 生成排程 | **本服务**（引擎） | 权威 |
| 提案校验（8 码） | 契约 §5.8；当前落地在 `tools/m1-server`（PR #10 已第三方实测） | 提供一份**同词汇表**的静态一致性校验，供闭环自证；两实现并存以契约文本为准 |
| 落库 / readback / 审批 | M1 服务端（演示环境） | 不参与 |
| 鉴权 / 并发 | 都没有 | 仅本地演示，不暴露公网 |

## 已知限制（诚实清单）

- 无鉴权、无 TLS、单进程串行处理；不要暴露到公网。
- 没有请求体大小上限与限流（演示用）。
- `repair_schedule` 的 `previous` 只读 `blocks`；`title` 从 `demands` 回填（提案块 JSON 本身不带 title）。
- 不做时区转换：`timezone` 非 `Asia/Shanghai` 会被接受但进 `warnings`。
- 不校验 `base_version` 是否过期（版本校验属服务端）。
