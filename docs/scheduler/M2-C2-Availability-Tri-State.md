# M2 · C2 `availability` 三态语义落地报告

> **裁定来源**：M0 2026-11-05 08:01:41Z《PR #4 条件 C1/C2 正式定案》第二节
> **执行人**：B（M2）刘恒瑜　**时间**：2026-11-05 16:15（+08）
> **性质**：实现 + 测试。**未合并、未开 PR**；落点待 M0 确认。

---

## 一、裁定原文（三态，不可合并）

| 取值 | 语义 |
|---|---|
| `null` | 调用方未显式提供可用时间 → **允许**按用户 `preferences` 推导 |
| `[]` | 调用方**显式**提供空集合 → **没有可用时间段**，**不得**回退推导 |
| 非空数组 | 只使用显式提供的时间段 |

---

## 二、改动面（3 文件，2 处代码 + 1 处注释 + 2 条测试）

| # | 文件 | 位置 | 改动 | 性质 |
|---|---|---|---|---|
| 1 | `schedule_contract.dart` | `ScheduleInput` 构造 | `this.availability = const []` → `this.availability`（默认 `null`） | 类型 |
| 2 | 同上 | 字段声明 | `List<ScheduleWindow>` → `List<ScheduleWindow>?`；补三态文档注释 | 类型 + 注释 |
| 3 | 同上 | `toJson()` 文档注释 | 按 C1 裁定补一句：内部结果不得直接作 v1 公开响应，对外用 `publicExplanations` | 注释 |
| 4 | `schedule_engine.dart` | `_effectiveAvailability`（L63） | `if (input.availability.isNotEmpty)` → `final explicit = input.availability; if (explicit != null) return explicit.toList();` | 逻辑（唯一一处） |
| 5 | `test/agent_scheduler_test.dart` | 新增 2 条 | 见第四节 | 测试 |

**序列化影响：0 处改动。** `availability` 是纯输入字段，两端 `toJson()` 中命中 0 次；新增守卫用例把这一点钉死（防将来误加）。

**算法策略影响：0 处改动。** `_placeDemand` / `_placeNearest` / 排序 / 时长三级优先级全部未动。

### 2.1 为什么这一处改动就够

空表会在既有路径上自然走到「无可用窗口」分支：`_usableWindows` 返回空 → `generateSchedule` 的 `usable.isEmpty` 分支（原 L404 起）直接产出 `NO_AVAILABILITY_WINDOW` 解释 + 全部任务 `UnplannedReason.noAvailability`。**不需要新增分支、不需要新增 reason code。**

---

## 三、C1 实现核对（M0 第一节要求「M2 确认当前实现与分工一致」）

| M0 裁定 | M2 现状 | 一致性 |
|---|---|---|
| 内部 `toJson()` 可保留完整 explanations | 输出全部 `notes`（含 repair 码） | ✅ 一致 |
| 对外组装 v1 必须用 `publicExplanations` | getter 存在，按 `isPublic` 过滤（滤掉 repair 码**与**枚举外码） | ✅ 一致 |
| 服务端不得直接取 `toJson()['explanations']` | M2 无服务端；代码注释已明写「对外必须改用 `publicExplanations`」 | ✅ 一致（本轮把注释补强） |
| 契约正文须明确过滤责任 | 属 M3 契约侧，M2 不越界 | 已转由 M3 执行 |

**无不一致项，无需要报告的位置偏差。**

---

## 四、测试（56 → 58）

| 编号 | 用例 | 断言要点 |
|---|---|---|
| T-6 | `availability 三态：null 推导、空数组不推导、非空只用显式` | 同一 fixture 三种取值：① `null` → 块落 09:00–10:00、无未安排；② `[]` → **0 块**、1 条未安排、`reason_code=NO_AVAILABILITY`、解释含 `NO_AVAILABILITY_WINDOW`；③ `[10:00–11:00]` → 块落 **10:00**（不是 09:00，证明未回退推导）。每条断言带 `reason`，失败时能定位是哪个态错 |
| T-7 | `availability 是纯输入字段：Proposal 序列化里不出现该键` | `toJson()` 键集合恰为 `{blocks, changes, unplanned_tasks, explanations}`，且不含 `availability` |

**为什么用「同 fixture 三态对照」而不是三条独立用例**：三态是**互斥语义**，写在同一处才能证明「同一输入只改这一个字段、产出必须分叉」；拆成三条会失去这个对照关系。

### 4.1 运行结果（两通道分开，不互相背书）

| 通道 | 命令 | 结果 | 退出码 | 日志 |
|---|---|---|---|---|
| 隔离 `dart test` | `cd /e/m2-verify && dart test test/agent_scheduler_test.dart` | **58/58 通过** | 0 | `.workbuddy/tmp/iso_58.log` |
| 宿主 `flutter test` | `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy flutter test test/agent_scheduler_test.dart` | **58/58 通过** | 0 | `.workbuddy/tmp/host_58.log` |

无 skip、无 flaky；宿主跑完已还原 4 个自动改写的生成文件。

### 4.2 既有用例零破坏（这是本次最需要证明的一条）

现存的 **0 条**用例显式传 `availability: []`，48 处 `ScheduleInput(` 构造要么传实窗、要么不传（改后为 `null`）。因此 `[]` 语义收紧**不影响任何既有断言**——58 条全绿即为证据。

---

## 五、分支依赖与提交落点（M0 要求「先确认…再决定提交落点」）

### 5.1 当前位置

| 项 | 值 |
|---|---|
| 分支 | `feat/m2-availability-tri-state`（**新建，未开 PR**） |
| commit | `88a41a1` |
| 父分支 | `fix/m2-p0-iso-offset` @ `73d3ac1` |
| 相对 PR #5 head `64eb403` | **6 commits** |
| 推送状态 | 已推 fork（**未推 main、未建 PR、未改任何已有 PR**） |

### 5.2 三个可选落点（请 M0 指定）

| 选项 | 做法 | 优点 | 代价 |
|---|---|---|---|
| **A（推荐）** | 保持叠在 `fix/m2-p0-iso-offset` 之上，等 PR #2 → PR #5 合并后，整条链 rebase 到 main，一次性开「P0 + C2」干净 PR | 改动集中一次评审；不与无关 PR 混 | 依赖前置合并链 |
| B | 从 PR #5 head `64eb403` 另开一条独立分支，只含 C2 | 与 P0 完全解耦，可并行评审 | 与 `fix` 分支在 `schedule_contract.dart` 上会冲突（同文件不同区域），需手工解一次 |
| C | 等 PR #2/#5 合并后，从 main 单开 C2 分支 | 历史最干净 | 要等，且会拖到 11-06 之后 |

**我倾向 A**：C2 与 P0 都改 `schedule_contract.dart`，同链可避免解冲突；且两者都是「契约裁定的落地」，语义上属同一批。

---

## 六、接单确认（按 M0 第五节格式）

| 项 | 内容 |
|---|---|
| 接单 | C1 核对、C2 实现、PR #4 定点复审（M2 部分）均已接单 |
| 已完成 | C1 核对（无不一致）；C2 实现 + 58/58 两通道；PR #4 定点复审（`73d3ac1`） |
| 预计交付 | C2 已交付；PR #4 复审已交付。无剩余工作在 11-06 之后 |
| 无法在冻结边界内完成 | ① 真实审批链 / readback / 幂等（服务端 + 真实资源，M2 无义务亦无能力）；② `scheduling_weight` 层级（§5.2 仍 BLOCKED）；③ 服务层默认 `maxShiftMinutes=120` 的真实接入（全仓无调用方） |
| 需 M0 决策 | ① 提交落点选 A/B/C；② P0-1 复核结论（决定能否标关闭）；③ `related_task_ids` 归属（violations 还是 explanations 也带）；④ `existingPlacements` 保留还是删除 |

---

## 七、边界

- 未合并任何 PR；未改 PR base；未推 main；未开新 PR。
- 未改契约本体（C1 的契约补句属 M3）；未动 Mock；未碰 M1/M3 文件。
- 未跑 58 条以外的测试；未改任何调度算法策略。
