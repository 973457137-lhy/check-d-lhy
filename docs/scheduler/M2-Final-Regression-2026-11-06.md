# M2 引擎最终回归报告（11 项逐条对照）

> 依据：M0 2026-11-06 06:57:59Z《11-10 最终交付冲刺》§二.4 列的 11 项。
> 作者：B（M2）刘恒瑜。时点：2026-11-06 15:2x（+08）。
> 代码坐标：head `3c8c464`（引擎文件自 `f68a424` 起未再变动，见文末 blob）。
> 证据等级：**作者本机实测，非 CI**；两个套件分开跑、分开计分。

---

## 一、总览

| 套件 | 用例数 | 结果 | 日志 |
|---|---:|---|---|
| 域测试 · 宿主 `flutter test` | 69 | **69 passed / 0 skipped，exit 0** | `reports/2026-11-06-host-final.log`（7,521 B / sha256 `cb6af3ad…`） |
| 域测试 · 隔离 `dart test`（Dart 3.13.7） | 69 | **69 passed / 0 skipped，exit 0** | `reports/2026-11-06-isolated-final.log`（9,705 B / sha256 `8e68ca8b…`） |
| 适配层自检 `smoke` | 91 | **91 passed / 0 failed，exit 0** | `reports/2026-11-06-smoke-91.log`（6,536 B / sha256 `6b73384f…`） |
| 真 Dart 2.17.6 · analyze | — | 0 error 0 warning（2 info） | 见 §四 |
| 真 Dart 2.17.6 · `compile exe` | — | 成功 | 见 §四 |
| 真 Dart 2.17.6 · `smoke` | 91 | **91/91** | 见 §四 |

> 两个域测试通道**不合并计分**；自检与域测试也是不同层次，不能相加成「160 条」。
>
> **一个额外佐证**：本轮在最终 head 上重跑域测试，两份日志的 sha256
> 与早先兼容化那次**逐字节相同**（`cb6af3ad…` / `8e68ca8b…`）。
> 这独立印证了「域代码自兼容化后一个字节未改」——与三个域文件 blob 未变互相印证，
> 不是我自己声称「没改」而已。

---

## 二、M0 列的 11 项逐条对照

| # | M0 要求项 | 覆盖用例（域 / 烟） | 结果 |
|---|---|---|---|
| 1 | 逾期前置过滤 | 域：`精确截止已过则不再排入`、`精确截止已过：进 unplanned 且码为 UNSCHEDULABLE_OVERDUE，带判定依据与建议`、`日期型截止已过：同样 UNSCHEDULABLE_OVERDUE，且原 deadline 未被改写` | **PASS** |
| 2 | unplanned 四字段 | 域：`未安排项带 reason_code、remaining_minutes 与 message`、`reason_code 取值必须落在封闭枚举内`、`无可排位置时返回未安排量与理由`；烟：`conflict: unplanned 带机器可读 reason_code`、`availability=[]: 全部进 unplanned 且 reason_code=NO_AVAILABILITY` | **PASS** |
| 3 | priority unknown / stable_input_order | 域：`未提供 priority：标 unknown，不推测成 0`、`时长优先级：任务自带目标优先于调用方给出的时长` | **PASS** |
| 4 | ordering_reason | 域：`有截止的任务：ordering_reason 记为 deadline_first`、`确定性排序：打乱输入列表顺序不改变任何输出字节`、`同等约束下的兜底排序键是 taskId 字典序` | **PASS** |
| 5 | assign / reschedule | 域：`首次指派是 assign，不是 reschedule`、`当天已有安排才算改期：reschedule`；烟：`无既有安排 → action=assign`、`同一天有既有安排 → action=reschedule`、**`别的日期有既有安排 → 仍 assign`**、`repair 缺 existing_placements: warnings 说明 action 会全是 assign` | **PASS** |
| 6 | 多日 override 授权 | 域：`未授权多日覆盖时，周期任务只在最早一天生成单日例外`、`显式授权后，多日单日例外才全部生成`、`单日例外不触碰 recurrence 语义`；烟：`多日未授权: 2 块仍展示，但只出 1 条 change`、`多日已授权: 2 块 + 2 条 change`、`authorize_multi_day_overrides="true" 被拒` | **PASS** |
| 7 | 起点钳 now | 烟：`块起点不得早于 now：now=11:44 的 4 小时任务必须从 11:44 起`、`剩余时间不足时进 unplanned` | **PASS** |
| 8 | 固定课程冲突 | 域：`任务必须绕开固定课程`、`多个课程之间依次避让且不重叠`、`固定项相互重叠时不会通过移动它们来消解冲突`、`开放时段被占满时报 OVERLAPS_FIXED`；烟：`validate(外部提案): 含 FIXED_EVENT_CONFLICT`、`FIXED_EVENT_CONFLICT 先于 BLOCK_OVERLAP` | **PASS** |
| 9 | 单次任务多块 | 烟：`同一单次事项两块 → 422 PROPOSAL_INVALID`、`单次事项一块 → 200 valid（对照）`、`周期任务跨两日各一块 → 200 valid（对照）` | **PASS** |
| 10 | 跨午夜边界 | 烟：`真跨午夜的块（23:00→次日01:00）必须 422 PROPOSAL_INVALID`、`end_at 恰为次日 00:00:00 必须放行（半开语义）`、`生成器排到 24:00 的提案回喂校验器必须 200 valid`、`引擎可把任务排到 23:00–24:00`、`date_only=今天 59 分钟…必须可排` | **PASS** |
| 11 | 错误 fail-closed | 烟：`availability 缺失: 400 且 field 指向该字段`、`max_shift_minutes=10/true/-30/10.5 被拒（400）`、`max_shift_minutes=0 被接受`、`错误体带 retryable=false`、`非法 JSON: 400 且 retryable 是 bool false`、`真跨午夜…422 PROPOSAL_INVALID`、`单次事项两块 → 422` | **PASS** |

### 关于第 9、10 项的两条对照用例（重要）

它们的作用是**证明规则没被误扩大到合法形态**，不是凑数：

- 第 9 项：若只验「多块 → 422」，一个「把所有多块都拒掉」的实现也会绿。
  所以必须有 `one_time 一块 → 200 valid` 与 `recurring 跨两日各一块 → 200 valid` 两条对照。
- 第 10 项同理：`end_at == 次日 00:00:00` 必须**放行**，否则「23:00–24:00 窗口 + 60 分钟任务」
  会变成排不下（少 1 分钟）。生成器排到 24:00 的提案回喂校验器必须 200 valid，
  这条专门防「生成合法、校验非法」的死循环。

---

## 三、明确不在本次回归覆盖内的（不掩饰）

| 项 | 状态 | 原因 |
|---|---|---|
| 公网部署后的引擎行为 | **未验** | 属 M1 部署件，M2 不持有公网凭据；不得以本地结果代替 |
| 审批链 / apply / readback | **不属 M2** | 契约 §5.7 方案 A：这三步由服务端包装层实现，M2 只算不存不批不读 |
| `availability` 缺字段/`null` 的最终口径 | **待 M0 裁定** | 当前实现：缺字段→400、显式 `null`→200 + `state=null`；见 §五 |
| 并发/多进程 | 未测 | 单进程串行，演示规模够用；契约未要求 |

---

## 四、真 Dart 2.17.6 证据（M1 容器版本）

在 `Dart SDK version: 2.17.6 (stable) ... windows_x64` 上：

| 检查 | 命令 | 结果 |
|---|---|---|
| 静态检查 | `dart analyze .` | 2 issues，均为 info（`engine:135` 已知误报、`smoke` 一处只写不读的局部变量），**0 error 0 warning** |
| AOT 编译 | `dart compile exe tools/m2-engine/bin/serve.dart` | 成功，产物 5,656,576 B |
| 自检 | `dart run tools/m2-engine/bin/smoke.dart` | **91 项 / 0 失败 / SMOKE OK** |
| 二进制运行 | 运行产物后 `curl /health` | 200，`semantics_stamp` 正确 |

> 容器是 linux_x64，我本机是 windows_x64，`dart compile exe` 不能跨平台编译，
> 所以**容器内的 AOT 产物必须由 M1 侧生成**（实测只需 2 秒）。源码兼容性已由上述四项证明。

---

## 五、`availability` 待裁项的现状与影响（M0 §二.6 要求单列）

| 输入 | 当前行为 | 依据 |
|---|---|---|
| 字段缺失 | **400** `INVALID_ARGUMENT`，`error.field=input.availability` | M0 2026-11-05 14:34Z「缺失不得推断为全空闲」 |
| 显式 `null` | **200**，按 `preferences` 推导可用时间，`meta.availability_state="null"`，并带 warning | 契约 §5.2 / 19-C2 a（null = 未提供，允许推导） |
| `[]` | **200**，0 块，全部进 `unplanned_tasks`，`reason_code=NO_AVAILABILITY` | 19-C2 b（显式全忙，不得回退推导） |
| 非空数组 | 200，只用显式窗口 | 19-C2 c |

**影响说明**：若把显式 `null` 也改成 400，则 Python `json.dumps({"availability": None})`
（会带真 null）会被判格式错误；且基线用例 T-6（`null → 09:00 有块`）需同步改写，
属契约级变更。**建议维持现状**，把「不得把未知当全空闲」落到调用方纪律：
服务端已确认全忙时必须传 `[]`，不得省略、也不得传 `null`。

**当前不阻塞主链路**：M1 只要按上表传值即可，三种形态都有确定行为与可判定回显。

---

## 六、坐标（发信前重算）

head `3c8c464`（完整 SHA 见邮件）。七个交付文件 blob：

| 文件 | blob |
|---|---|
| `tools/m2-engine/bin/serve.dart` | `b7d68ab9b8373ac0acdcb749a31942b6bb97d5c6` |
| `tools/m2-engine/bin/smoke.dart` | `1a1f9ee8c1286cd92a57e41969e0c729db6a2773` |
| `tools/m2-engine/lib/contract_json.dart` | `0c36312d2b413b31161954b230c36262aba1507b` |
| `tools/m2-engine/lib/handler.dart` | `d5500f22353053a4167738e39835535d48169817` |
| `tools/m2-engine/lib/validate.dart` | `ebf779fd37b46c3e2e6149ee23ce83ab735e7d5d` |
| `lib/features/agent_scheduler/domain/schedule_contract.dart` | `e3f22323e2cb5bc6405a792097ccb6dd2ad36157` |
| `lib/features/agent_scheduler/domain/schedule_engine.dart` | `ec70b639c1ee514c0e85813b807dd96a96c4506b` |
