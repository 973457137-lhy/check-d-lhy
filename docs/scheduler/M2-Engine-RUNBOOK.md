# M2 引擎 RUNBOOK（运维与消费方须知）

> 作者：B（M2）刘恒瑜。时点：2026-11-06 15:2x（+08）。
> 适用：head `3c8c464` 及之后的引擎交付。
> 依据：M0 2026-11-06 06:57:59Z《11-10 最终交付冲刺》§二.5。

---

## 一、启动与停止

```bash
# 方式 A：直接跑源码（每次冷启动要编译，约 15–20 秒）
/opt/flutter/bin/dart tools/m2-engine/bin/serve.dart

# 方式 B（推荐，容器每 10–25 分钟重启的场合）：先 AOT，再跑二进制
/opt/flutter/bin/dart compile exe tools/m2-engine/bin/serve.dart -o engine_bin   # 实测 2 秒
./engine_bin                                                                     # 启动瞬时
```

- 默认监听 `127.0.0.1:8787`；`M2_ENGINE_PORT` / `M2_ENGINE_HOST` 可覆盖。
- **不要监听公网**：本服务无鉴权、无 TLS，只应由同容器的 `tool_server` 通过回环调用。
- 停止：向进程发 `SIGTERM` 或直接 kill；引擎无状态，不持有任何数据库连接，不需要优雅关闭流程。

---

## 二、版本自证：先看 `/health`，再谈结论

```bash
curl -s http://127.0.0.1:8787/health
```

关键字段：

| 字段 | 用途 |
|---|---|
| `semantics_stamp` | 语义版本戳，形如 `m2-engine/2026-11-06T05:15Z`。**行为变了它就变** |
| `semantics` | 10 个布尔开关。**全为 `true` 才等于当前 head 的行为** |
| `contract_basis` | 契约基准，当前 `39f7f965` |

**判别旧进程的一条命令**：`/health` 里没有 `semantics` 字段 → 你打到的是旧代码，重启后再验。
`dart run` / 直接执行都**不热重载**，进程启动那一刻的代码就是它永远的行为。

---

## 三、【M0 §二.5】recurring 任务「落点」怎么读：`list_tasks` 为空是**有意设计**

### 现象

`list_tasks` 返回的周期任务（`task_kind = recurring`）通常**没有确定的时间落点**——
`scheduled_minute` / 计划时刻为空。消费方据此无法知道「这个任务今天几点做」。

### 结论：这是**契约的有意设计**，不是当前实现的限制

契约 §5.4 原文：

> `list_tasks` 返回去重的 Task 定义：同一 `task_id` 在一个响应中最多出现一次。
> **逐日是否发生、当天生效时间以及单日例外后的结果由 `get_calendar_events.events` 表达**；
> 周期任务不能因为查询跨多天而重复返回多份 Task 定义。

也就是说契约明确把「定义」与「逐日落地」分成了两个工具：

| 想知道什么 | 该问谁 |
|---|---|
| 这个任务是什么、多久做一次、目标时长多少 | `list_tasks` |
| **今天/某天几点到几点做**（含单日例外调整后的结果） | `get_calendar_events` |
| 这一天是被谁改过的（单日例外） | `get_calendar_events` 里的 `daily_overrides`（§5.5） |

**为什么这样设计**（而不是缺陷）：

1. 周期任务是**规则**，不是事件。一条规则在 30 天里会产生 30 个落点，
   若塞进 `list_tasks` 会让同一个 `task_id` 重复出现多次——直接违反 §5.4「最多出现一次」。
2. 落点会随**单日例外**变化（某天临时改到 20:00）。若把落点固化成 Task 的字段，
   每次例外都要回写 Task，等于用「定义」承载「状态」，AGENTS.md 里明令禁止这类混用。
3. 因此 `get_calendar_events` 才是落点的唯一权威来源，`list_tasks` 只给定义。

### 消费方（M1）应该怎么写

```
1) list_tasks            → 拿到 Task 定义（含 task_kind、duration 目标、priority）
2) get_calendar_events   → 拿到指定日期范围内的 events（含每个 occurrence 的实际时段）
                           以及 daily_overrides（哪些日期被单日例外改过、改成什么）
3) 两者按 task_id / item_id 关联，得到「某任务在某天的实际落点」
```

**反例（不要这么做）**：拿 `list_tasks` 里为空的时刻字段去推断「今天没安排」。
「没有固定时刻」与「今天不安排」是两件事：后者要由 `get_calendar_events` 是否返回该日 occurrence 来判断。

### 与 M2 引擎的关系

M2 的 `generate_schedule` 消费的 `existing_placements` 就是上面第 3 步的结果——
**由服务端（M1）把 `get_calendar_events` 的落点整理成 placements 传进来**，
引擎自身不读 `list_tasks`、也不读 `get_calendar_events`（它没有数据访问能力，见接口文档 §十）。

---

## 四、常见故障与处置

| 现象 | 可能原因 | 处置 |
|---|---|---|
| `curl` 连接被拒 | 还在编译（源码模式 15–20 秒） | 轮询 `/health` 再放流量；或改用 AOT |
| `/health` 无 `semantics` 字段 | 进程是旧代码 | 重启；AOT 模式需重新 `compile exe` |
| 422 `PROPOSAL_INVALID` | 提案结构错误（块跨午夜、单次事项多块等） | **不要重试**，`retryable=false`；按 `error.message` 修提案 |
| 400 `INVALID_ARGUMENT` | 输入字段缺失/类型错/时间无偏移 | 按 `error.field` 修输入；同样 `retryable=false` |
| 500 `INTERNAL_ERROR` | 引擎内部异常 | `retryable=true`，可重试一次；持续失败请附 `engine.log` 找我 |
| `DEPENDENCY_UNAVAILABLE` | 引擎没起来 | 这是**预期行为**：不得静默回退 Mock，先把引擎拉起来 |

---

## 五、给人看的坐标（每次交付必带）

- head（完整 SHA）
- 七个交付文件的 blob
- 测试结果：域测试双通道 N/N、自检 M/M
- 2.17.6 证据：analyze 结果、AOT 编译成功、2.17 下自检通过

**只给 head 不够**：head 会前进，blob 才是「这份代码没变」的证据。
