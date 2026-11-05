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

### 4.3 证据等级声明（M0 2026-11-05 08:19:45Z 要求）

**58/58 是「作者本机双通道实测」，不是 CI 通过。**

| 项 | 事实 |
|---|---|
| 隔离通道 | 本机 `E://m2-verify` 上 `dart test`，非 CI |
| 宿主通道 | 本机仓库上 `flutter test`，非 CI |
| GitHub Actions | **当前无对应 workflow run**；仓库未配置跑 Dart/Flutter 单测的 workflow |
| M0 独立复跑 | 无 |

因此任何引用都不得写成「CI 通过」或「平台验证通过」。等仓库配置了 workflow 之后，这句话才能升级。

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

### 5.3 P0 完整 SHA 与精确定位（M0 第三节要求）

**完整 commit SHA（40 位，非短 SHA）**：

```
e607e6744a0e0bd602ac2048c76296e17cb5f191
```

父提交 `64eb4031f14782ef6da6a3f17d81d2dbea11106a`（= PR #5 head）；本 commit 变更 3 文件：`schedule_contract.dart`(+28/−3)、`agent_scheduler_test.dart`(+99)、接口矩阵文档(+409 新增)。

**行号必须绑版本**（同一文件在两版里行号不同，这是今天的既有教训）：

| 对象 | 在 `e607e67` 内 | 在当前 `0537d8e` 内 | 说明 |
|---|---|---|---|
| `_isoShanghaiInstant` 定义 | `schedule_contract.dart` **L135** | L135 | 未位移 |
| `blocks[].start_at` 调用 | **L432** | L439 | C2 改动把行号推移 7 行 |
| `blocks[].end_at` 调用 | **L433** | L440 | 同上 |
| `changes[].scheduled_at` 调用 | **L478** | L485 | 同上 |
| T-1 blocks 时间格式 | `agent_scheduler_test.dart` **L2172** | L2246 | C2 新增 2 条用例推移 74 行 |
| T-2 scheduled_at 格式 | **L2201** | L2275 | 同上 |
| T-3 UTC instant 不误标 | **L2226** | L2300 | 同上 |

引用规则：说「三处序列化」时用 `e607e67` 那组行号；说「当前分支状态」时用 `0537d8e` 那组。混用会指错。

**P0-1 状态表述纪律**（M0 第三节）：代码审查 PASS，但 PR 未合并 → 只能记「已修复、待集成」，**不得表述为 Production 已修复**。

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

---

## 八、附录：两项待裁事项的影响与最小方案（M0 第五节要求「先单列，不擅自修改」）

### A.1 `related_task_ids` 归属

| 项 | 内容 |
|---|---|
| 契约现状 | §5.7 `explanations` 提到可选携带；§5.8 `violations` 明确有 `related_task_ids` / `related_block_ids` / `related_event_ids` 三组 |
| M2 现状 | `ScheduleNote.toJson()` 在 `taskId` 非空时输出 `related_task_ids: [taskId]`（**恒为单元素**） |
| 若归属 violations（服务端） | M2 现有实现**不构成违约**——多输出的只是一个可选字段，且值合法 |
| 若要求 explanations 支持多元素 | M2 需把 `taskId` 改 `List<String>`，影响 1 处 toJson + 1 条用例 |

**最小方案（二选一）**：

- **A（建议）** 维持「explanations 每条解释至多关联一个任务」，契约写死这一点 → **M2 零改动**。理由：当前引擎是逐任务产出解释，不存在「一条解释覆盖多任务」的路径。
- **B** 改 `List<String>` 支持多任务 → M2 改 1 处 + 1 条用例。触发条件：将来出现聚合型解释（例如一条 `AVAILABILITY_SATURATED` 同时点名多个任务）。

### A.2 `existingPlacements` 保留或删除

| 项 | 内容 |
|---|---|
| 现状 | 字段声明在 `ScheduleInput`，`schedule_engine.dart` **零消费**（grep 0 次）；repair 走的是 `previous: ScheduleProposal` 参数 |
| 保留的后果 | 无害；但若服务端按 A1 §9.1 #8 把它计入 `input_digest`，会出现「digest 不同、M2 输出完全相同」——**方向保守**（不产生碰撞，只让幂等判定偏严） |
| 删除的后果 | DTO 变小；但需先确认服务端未引用该字段，否则会打断接线 |

**最小方案（二选一）**：

- **A（建议）** 保留字段，注释标注「保留字段，当前零消费；服务端若计入 input_digest 需知这是保守选择」→ **M2 只改注释，0 逻辑改动**。
- **B** 删除字段 → M2 删 1 个字段；需 M0 先确认服务端与契约侧无引用。

**我不自行执行任何一种**，等裁定。

---

## 九、边界补充

- 本文件在 2026-11-05 16:25 起含 §4.3 证据等级、§5.3 P0 定位、§八 附录；此前版本的元信息一律作废。
- 未改任何代码；本轮只补文档。

---

## 十、19-C2 的验收口径（M0 2026-11-05 09:27:04Z 最终裁定）

M0 在 P2 / Fixture-C 的最终验收里，对 C2 判据给出了一条**关键定性**：

> 19-C2 三态：Mock 侧记为 **UNVERIFIABLE / 范围外**，不是 FAIL，也不阻塞 P2 PASS。
> **三态语义的验收对象是 M2 引擎及未来服务端**，不应在 Mock 侧伪造通过。

### 10.1 这条定性的直接含义

| 层 | 19-C2 状态 | 原因 |
|---|---|---|
| Mock（`tool_server.py`） | **UNVERIFIABLE / 范围外** | Mock 当前**不读取任务级 `availability`**；没有消费方，就没有可观测行为 |
| **M2 引擎（本文件对象）** | **可验收**——`T-6` / `T-7` 即判据载体 | 三态分支在 `_effectiveAvailability`（engine L63），行为可直接断言 |
| 未来服务端 | 待建 | 服务端才是 `availability` 的**组装方**，负责把快照映射成三态 |

**结论：19-C2 不是「无法验证」，而是「验证对象不在 mock」。** 把 mock 侧的 UNVERIFIABLE 误读成整体不可验收，会让这条判据长期悬空。

### 10.2 可执行的验收路径（供 M3 独立复核时使用）

M2 侧不需要新增任何东西，现有交付即可支撑：

1. 从我的 fork 分支 `feat/m2-availability-tri-state` 取三个文件（`schedule_contract.dart`、`schedule_engine.dart`、`agent_scheduler_test.dart`）；
2. 按 `docs/scheduler/值守规程.md` §六 的隔离方式跑（`package:test` + `dart test`），或直接 `flutter test`；
3. 预期结果：**58/58 通过**，其中 `T-6` 断言三态分叉（`null` 推导 / `[]` 不推导且 `NO_AVAILABILITY` / 非空只用显式）、`T-7` 断言 `availability` 不进 Proposal 序列化；
4. 证据等级按 M0 口径记：**作者本机双通道实测，非 CI**；若 M3 独立复跑，则升为「第三方本机实测」。

### 10.3 不得越界的表述

- 不得把 19-C2 写成「已通过」——它只在 M2 域内通过，服务端组装层尚未存在。
- 不得把 mock 的 UNVERIFIABLE 改写成 FAIL（方向相反，且会误导排期）。
- 与 P2 PASS 无耦合：P2 的 PASS 不含 C2，反之亦然。
