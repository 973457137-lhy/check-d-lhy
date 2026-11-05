# M2 · PR #4 定点复审（39f7f965）— 调度模块

> **复审人**：B（M2）刘恒瑜　**时间**：2026-11-05 16:00（+08）
> **复审对象**：PR #4 当前 head `39f7f96559abac9d4bc59d5c560e6a706ec19946`（`upstream/feat/m0-api-contract` 实测 tip 与之一致）
> **方法**：只核本次版本**实际新增/修改**的内容。基线 `2c48579a6f0ab2b9181a9246f893c1c0a8dce7c6` → `39f7f965` 全量 diff 为 2 文件 / +1,058 / −32，逐 hunk 判断是否落在 M2 模块；未重开全量审计，未沿用 `2c48579` 的未闭合项直接判缺陷。

---

## 一、固定审查 SHA 与变更范围

| 项 | 值 |
|---|---|
| 审查 SHA | `39f7f96559abac9d4bc59d5c560e6a706ec19946` |
| 基线 SHA | `2c48579a6f0ab2b9181a9246f893c1c0a8dce7c6` |
| diff 规模 | `agent-api-v1.md` +208/−? · `agent-api-v1.examples.json` +882 · 合计 **+1,058 / −32** |
| M2 相关变更 | 4 处：§5 内部调度 Fixture（新增）、§5.7 explanations 闭集与方案 A（新增）、§5.7 结构/联合类型错误归属（新增）、§5.8 violation 结构（新增，边界） |
| M2 无关变更 | §4.1 错误码语义与防枚举、§6 readback 三态转移、§7 digest 覆盖面（服务端职责） |

---

## 二、实际检查的文件 / 章节

| 文件 | 章节 | 检查方式 |
|---|---|---|
| `docs/contracts/agent-api-v1.md` | §3 时间语义 | 逐字比对（无偏移禁令） |
| 同上 | §5「内部调度 Fixture」 | 新增段落逐字读，对 M2 测试断言 |
| 同上 | §5.7 `explanations` | 七值闭集逐字比对代码常量 |
| 同上 | §5.7 方案 A 序列化 | 逐字比对 `toJson()` 输出键集合 |
| 同上 | §5.8 `violation` | 八值闭集与对象结构（M2 不产出，仅核边界） |
| 同上 | §6 状态机 / §4.1 | 确认与 M2 无交集 |
| `lib/.../schedule_contract.dart` | 常量与 `toJson()` | 实测集合与键 |
| `test/agent_scheduler_test.dart` | 56 条 | 定位对应断言用例 |

---

## 三、结论：**有条件通过**（M2 模块，共 3 个条件）

契约在 M2 侧的四处新增/修改，与现有实现**逐项对齐**，无一条需要 M2 改代码。但存在 3 个未闭合条件（2 个待 M0 裁定、1 个待复核），故不写「通过」。

---

## 四、逐项核对（附代码证据）

### 4.1 §5「内部调度 Fixture」（本次新增）

契约原文要求两个独立 Fixture，并明确 `remaining_minutes_today` **不得出现在 `generate_schedule` 远程请求**里。

| 契约要求 | M2 实现 | 证据 |
|---|---|---|
| `=0`：不生成 block、不进 `unplanned_tasks`、仅产 `ALREADY_DONE_TODAY`，不得进最低时长兜底 | 已实现 | `test:1369`「P3 样例一：remaining=0 不排程、不算未安排、产出 ALREADY_DONE_TODAY」 |
| `=40` 且 `duration_target_seconds=7200`：只排 40 分钟、`duration_seconds=2400`、`duration_source=task_target` | 已实现 | `test:1401`「P3 样例二」+ 断言 `duration_seconds == 2400` |
| 该字段属内部 DTO，不进远程请求 | 已实现 | `ScheduleTaskDemand` 为进程内 DTO，`toJson()` 无该字段（`test:1548`「内部调度 DTO 递归不含任何服务端字段」） |

**判定：通过。**

### 4.2 §5.7 `explanations` 七值闭集（本次新增）

契约列出的 7 个公开码：`SCHEDULED`、`ESTIMATED_DURATION`、`ALREADY_DONE_TODAY`、`FIXED_BLOCKS_OVERLAP`、`NO_AVAILABILITY_WINDOW`、`AVAILABILITY_SATURATED`、`PRESERVED_FIXED_EVENTS`。

M2 `kPublicExplanationCodes` 实测为同一 7 个（顺序不同，集合相等）；`kRepairOnlyExplanationCodes` = {`DISPLACED_BY_FIXED`, `REPAIR_SUMMARY`}，与契约「禁止出现在 v1 公开 Proposal、Mock 或远程响应」的对象一致。

**判定：通过。**

### 4.3 §5.7 方案 A 序列化职责（本次新增）

| 契约要求 | M2 实现 | 证据 |
|---|---|---|
| 只输出内部 blocks/changes/unplanned/explanations 四部分 | 是 | `toJson()` 键集合断言（`test:1548`） |
| 不输出 6 权威字段（`proposal_id`/`snapshot_ref`/`base_version`/`input_digest`/`generated_at`/`expires_at`） | 递归断言不存在 | 同上 |
| `status` 亦不输出 | 是 | 同上 |

**判定：通过**（但有条件，见 C1）。

### 4.4 §5.8 `violation`（本次新增，边界核对）

契约把 `violations` 定义为 `validate_schedule` 的响应，八值闭集，且「未知 `code` 必须以 `PROPOSAL_INVALID` 拒绝」。M2 不产出 `violations`（责任矩阵已定），故无实现义务。

**边界确认**：`violations`（8 值）与 `explanations`（7 值）是两个不同闭集，M2 只碰后者。**判定：通过（无 M2 义务）。**

---

## 五、三个条件（这是不写「通过」的原因）

### C1 · repair 码过滤的落点，契约只写了「禁止」，没写「谁滤」

- **证据**：§5.7 新增句「`DISPLACED_BY_FIXED` 与 `REPAIR_SUMMARY` … 禁止出现在 v1 公开 Proposal、Mock 或远程响应中」。
- **现状**：M2 的 `ScheduleProposal.toJson()` 输出**内部全集**（含 repair 码），这是方案 A 的语义（它输出的是"内部四部分"，不是 v1 响应）；M2 另提供 `publicExplanations` getter，已过滤。
- **风险**：服务端若直接取 `toJson()['explanations']` 组装 v1，repair 码会漏进公开响应，命中 §5.7 禁令。
- **状态**：M0 已于 2026-11-04 裁定「服务端用 `publicExplanations` 过滤，`toJson()` 保留内部全集」。**契约正文仍未写「谁滤」**，属契约留白，不是 M2 缺陷。
- **需要**：M0 确认契约是否补一句；不补则此约定只存在于裁定记录里。

### C2 · `availability` 的 `null` / `[]` 语义仍待裁定

- **证据**：§5 未定义 `availability` 字段（它是 M2 内部 DTO，不进远程请求）。
- **现状**：非空 `List`、默认 `const []`，`[]` 当前表示「未指定 → 按 preferences 推导」；**「显式无时间」无法表达**。
- **影响**：`NO_AVAILABILITY` 语义二义，集成后返工。
- **状态**：A1 §9.1 #5 / A1 §9.2 #2 已提，M0 未裁。M2 不自行改 DTO。

### C3 · P0-1 时间序列化修复待 M0 复核

- **证据**：`e607e67` 修三处（`blocks[].start_at` / `end_at`、`changes[].scheduled_at`），统一走 `_isoShanghaiInstant`：`toUtc()` 归一 instant → +8h → 固定拼 `+08:00`。
- **运行证据**：隔离 `dart test` **56/56**、宿主 `flutter test` **56/56**，退出码 0。
- **状态**：已修复、**待复核**，不标关闭（按 M0 口径）。

---

## 六、静态检查 / 真实运行 / 仍 BLOCKED（按 M0 第五节要求分栏）

| 类别 | 内容 |
|---|---|
| **静态契约检查**（仅比对文本与代码，无运行） | §5 内部调度 Fixture 条款、§5.7 七码闭集、§5.7 方案 A 键集合、§5.8 八值与 M2 边界 |
| **已有真实运行证据** | P0-1 时间偏移修复（`e607e67`，两通道 56/56，本机实跑）；`remaining=0/40` 两条 Fixture（56 条用例中实跑通过） |
| **仍 BLOCKED** | ① `availability` null/[]（C2，等裁定）；② repair 码过滤落点入契约（C1，等裁定）；③ 服务层默认 `maxShiftMinutes=120` 的真实接入（全仓无调用方）；④ `scheduling_weight` 层级（§5.2 仍 BLOCKED）；⑤ 真实审批链/readback/幂等（服务端 + 真实资源，M2 无义务也无能力验证） |

**明确不写的话**：本文没有把「文档定义完整」写成「真实平台已验证」，也没有把「Mock 通过」写成「真实审批链通过」。

---

## 七、PR 依赖关系与建议合并顺序（M0 第三节第 4 条要求）

### 7.1 现状（实测）

| 分支 | head | 相对 `upstream/main` 提交数 | 是否已开 PR |
|---|---|---|---|
| `feat/m2-scheduler-basic` | `070fb6e` | **27** | PR #2 |
| `feat/m2-a2-traceability` | `64eb403` | **28**（= PR #2 的 27 + 1） | PR #5 |
| `fix/m2-p0-iso-offset` | `a83f3c0` | **32**（= PR #5 的 28 + 4） | **未开** |

三条是**线性堆叠**关系，不是并行分支：`git merge-base --is-ancestor` 实测确认 fix 分支基于 PR #5 之上。

### 7.2 建议顺序（M2 建议，不自行执行）

1. **先合 PR #2** → main。合完后 PR #5 的 diff 自动收缩为 **1 commit / 3 files**（`64eb403`：测试 48→51 + 两份文档）。
2. **再合 PR #5** → main。合完后 `fix/m2-p0-iso-offset` 相对 main 只剩 **4 commits / 4 files**（`e607e67`/`ac52fb9`/`f698028`/`a83f3c0`）。
3. **最后为 fix 分支开一个干净 PR** → main：那时 diff 只含 P0 修复 + 两份文档增量，不再是"28 个提交的大 PR"。
4. 若不按此序，而是先合 PR #5，则 PR #2 会被 PR #5 包含，需关闭 PR #2，历史提交重复记录 —— **不建议**。

### 7.3 我不做的事

不改 PR base、不合并、不推 main、不关 PR。以上仅为顺序建议。

---

## 八、边界声明

- 本轮**零代码改动**、零提交（复审性质）；分支 head 保持 `a83f3c0`，PR #2/#5 未动。
- 未修改冻结契约、未动 Mock、未跑 48/56 条以外的测试。
- 未对 M1/M3 模块作任何判定。
