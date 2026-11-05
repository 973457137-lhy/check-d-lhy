# A1 × A2 集成审查 · 调度引擎 ↔ 服务端接口统一

> 依据：M0 2026-11-03 11:04 邮件《A1 × A2 集成审查与统一接口决策清单》。
> 性质：只读审查。未改代码/契约/Mock/测试，未提交、未推送、未建 PR、未合并。
> 审查基准：契约 `39f7f965`（唯一规范基准）；M2 A2 蓝图 `a-track-integration-map.md` + domain 代码（head `070fb6e`）；M1 A1 蓝图 §9（10:47Z 收尾封）。

---

## 一、结论速览

| 项 | 结论 |
|---|---|
| M1 §9 的 12 项回应 | **9 项一致、1 项误报、1 项半一致、1 项真实语义差异** |
| 方向性冲突 | **0 处** |
| 需 M0 裁定 | **2 项**（availability 语义 + repair 码过滤分工确认） |
| 关键澄清 | M1 的「字段名 notes→explanations」是误报，M2 `toJson()` 已是 `explanations` |

---

## 二、M1 §9 的 12 项回应逐项核对

| # | M1 观点（A1） | M2 现状（A2） | 结论 |
|---|---|---|---|
| ① now/horizon 由服务端时钟 | `ScheduleInput.now` 必填输入，引擎不调 `DateTime.now()`（engine:9） | **一致** |
| ② baseVersion 不透明值只透传 | `ScheduleInput.baseVersion` 注释「生产须可信服务产生」（contract:331-335） | **一致** |
| ③ timezone 服务层转换 | `ScheduleInput.timezone` 默认 Asia/Shanghai，引擎未消费；映射 R8 | **一致** |
| ④ preferences | `SchedulePreferences`（contract:83） | **一致** |
| ⑤ availability 空数组 vs null | 见 D3，**真实语义差异** | **差异** |
| ⑥ fixedBlocks 硬约束不可移 | `ScheduleFixedBlock` 永不可移（contract:8） | **一致** |
| ⑦ demands 取可信快照 | `requiredMinutes`/`remainingMinutesToday` 注释已限定（contract:253-258,276-288） | **一致** |
| ⑧ existingPlacements 计入 input_digest | `ScheduleInput.existingPlacements`（contract:352）；input_digest 服务端算，M2 不产出 | **一致**（服务端职责） |
| ⑨ blocks/changes 白名单两 type | `ScheduleOneTimeChange`/`UpsertDailyOverrideChange`（contract:432/463） | **一致** |
| ⑩ unplannedTasks 四值 | `UnplannedReason` 4 值（contract:124-146） | **一致** |
| ⑪ notes→explanations + repair 码 | 见 D1、D2 | **误报 + 半一致** |
| ⑫ 6 权威字段断言 | 方案 A，`toJson()` 只四部分（contract:624-629） | **一致** |

---

## 三、差异清单（逐项：契约依据 / A1 / A2 / 是否冲突 / 建议 / 是否需裁定）

### D1. 字段名「notes vs explanations」—— M1 误报，非冲突

- **契约依据**：§5.7 `explanations`：对象数组（L316）。
- **A1 观点**：M2 输出字段名是 `notes`，需改为 `explanations`，否则契约校验失败。
- **A2 事实**：`ScheduleProposal` 的 **Dart 内部字段**叫 `notes`（contract:612），但 `toJson()` 输出的 JSON 键已经是 `explanations`（contract:628：`'explanations': notes.map(...)`）。M1 大概率看到的是 M2 早先草案里的 `notes` 字样。
- **是否冲突**：否（误报）。M2 序列化已对齐契约。
- **建议**：无需改代码。M1 侧核对 M2 `toJson()` 键名即可消除此差异。
- **是否需 M0 裁定**：否。

### D2. repair 专用码的过滤分工 —— 半一致，需明确「谁过滤」

- **契约依据**：§5.7「`DISPLACED_BY_FIXED` 与 `REPAIR_SUMMARY` 仅供 M2 内部 repair 逻辑使用，禁止出现在 v1 公开 Proposal、Mock 或远程响应中」。
- **A1 观点**：这两个码禁止进 v1；若要进，属公开枚举扩展，需 M0 新裁定。
- **A2 事实**：M2 已实现隔离——`kRepairOnlyExplanationCodes`（contract:557-560）+ `publicExplanations` getter（contract:620-621，过滤 `isPublic=false` 的码）。**但** `toJson()`（contract:628）输出的是**全部 notes（含 repair 码）**，因为方案 A 下 `toJson()` 是「内部四部分」，不是 v1 响应。
- **是否冲突**：半冲突。M1 的「禁止进 v1」与 M2 的「已隔离」方向一致，但**过滤的落点**没写清。
- **风险**：若服务端直接取 `proposal.toJson()['explanations']` 组装 v1，repair 码会漏进响应。契约 §5.7 会拒绝。
- **建议**：服务端组装 v1 时必须用 `proposal.publicExplanations`（已过滤），**不能**用 `toJson()['explanations']`。M2 侧可考虑给 `toJson()` 增加一个可选 `{bool publicOnly = false}` 参数，或在文档注释里把这条分工钉死。
- **是否需 M0 裁定**：建议裁定「过滤责任归服务端序列化层（用 publicExplanations），M2 的 toJson() 维持输出内部全集」。若 M0 希望 M2 的 toJson() 默认就只输出公共码，则需改 `toJson()` 默认行为（会影响现有 48 条测试里对内部码的断言）。

### D3. availability 空数组 vs null 语义 —— 真实差异 + 契约空白

- **契约依据**：§6.3 `generate_schedule` 请求 `input` 只有 `date_range`（必填）、`external_fixed_events`（可选）、`preferences`（可选）。**契约远程接口里没有 `availability` 字段**。§1 表 `timezone` 固定 `Asia/Shanghai`（L103）。
- **A1 观点**：建议 `availability=null` = 未指定、按偏好推导；`availability=[]`（空数组）= 用户明确没有可用时间 → 全部 unplanned 且 `reason_code=NO_AVAILABILITY`。
- **A2 事实**：`ScheduleInput.availability` 是 **non-nullable `List<ScheduleWindow>`**，默认 `const []`（contract:319）。`_effectiveAvailability`（engine:63-64）把「空」一律当成「按 preferences 的 dayStartMinute/dayEndMinute 推导」。**当前无法表达「null=未指定」与「[]=明确没有」的区分**。
- **是否冲突**：是（语义差异）。M1 的 null 语义在 M2 当前 DTO 里**不可表达**（字段非空）。且契约 §6.3 根本没有「用户明确今天无可用时间」的输入表达——这是**契约空白**，不是 M2 单方能定的。
- **建议方案**（供 M0 选）：
  - 方案 A：`availability` 保持非空，语义维持「空=按偏好推导」；「明确没有时间」由服务端用 `preferences` 之外的信号表达（当前契约无此字段，需 M0 决定是否新增）。
  - 方案 B：`availability` 改为 `List<ScheduleWindow>?`（nullable），null=按偏好推导、[]=明确没有（M1 建议）。改动 M2 DTO + 补用例。
- **是否需 M0 裁定**：**是**。这是唯一需要 M0 拍板的真实语义差异（其余 9 项全一致）。

---

## 四、统一字段映射表 + 责任矩阵

### 4.1 ScheduleInput 字段映射（M2 DTO ↔ 契约）

| M2 DTO 字段 | 契约出处 | 远程 vs 内部 | 备注 |
|---|---|---|---|
| `now` | （内部） | 内部（服务端注入） | 契约远程输入无 now，服务端组装时给 |
| `horizonStart/horizonEnd` | `date_range`（§6.3） | 远程→内部 | 服务端由 date_range 折算 |
| `baseVersion` | `base_version`（§5.7） | 服务端产生 | M2 只透传 |
| `timezone` | §1 固定 Asia/Shanghai | 内部默认值 | 引擎不消费，服务层转换 |
| `preferences` | `preferences`（§6.3 可选） | 远程→内部 | day_start/day_end/min_block |
| `availability` | **无契约对应**（§6.3 无此字段） | 仅内部 | 见 D3，待裁定 |
| `fixedBlocks` | `external_fixed_events` + 课程 | 远程→内部 | 服务端由快照映射 |
| `demands` | Task DTO（内部） | 内部 | requiredMinutes/remainingMinutesToday 只可信快照 |
| `existingPlacements` | 上一版 proposal.blocks | 内部 | repair 用，计入 input_digest |

### 4.2 ScheduleProposal 输出映射（方案 A）

| M2 输出 | 契约字段 | 服务端处理 |
|---|---|---|
| `blocks` | `blocks` | 直接组装 |
| `changes` | `changes` | 直接组装 |
| `unplannedTasks` | `unplanned_tasks` | 直接组装 |
| `notes`（全部） | `explanations` | **须用 `publicExplanations` 过滤 repair 码** |
| （无） | proposal_id/snapshot_ref/base_version/input_digest/generated_at/expires_at/status | 服务端生成 |

### 4.3 责任矩阵（M1 §9.3 已确认，M2 复认）

| 职责 | 归属 |
|---|---|
| 调度计算、DTO 形状、确定性输出 | M2（domain） |
| violations 八值、6 权威字段、幂等/事务/readback | M1（服务端） |
| IdP / 审计 / 双人复核 | M1（服务端） |
| 时区转换 | 服务端（M2 不消费 timezone） |
| scheduling_weight 折算 | 服务端（折算进 priority，M2 不消费） |
| maxShiftMinutes=120 | 服务层注入（M2 domain 默认 null） |
| validate_schedule | 服务端；M2 内部守卫（块间不重叠等）两边都做 |

---

## 五、调用时序（generate / repair / validate / apply）

```
[服务端] 可信快照 → 组装 ScheduleInput（date_range→horizon，快照→demands/fixedBlocks）
   ↓
[M2] generateSchedule(input) / repairSchedule(input, prev, maxShiftMinutes:120)
   → 内部四部分 blocks/changes/unplanned_tasks/explanations（含 repair 码）
   ↓
[服务端] publicExplanations 过滤 → 补 6 权威字段 → 序列化完整 Proposal
   ↓
[服务端] validate_schedule（§5.8 八值，violations 走 HTTP 200 + validation_status=invalid）
   ↓
[服务端] apply 事务内四步权威复核（§9.5）：快照=base_version → 摘要=change_digest → owner=sub → 八值重判
```

---

## 六、需 M0 决策的问题（一页）

| # | 问题 | A1 观点 | A2 现状 | 建议 | 不裁定的阻塞 |
|---|---|---|---|---|---|
| D2 | repair 码过滤落点 | 服务端过滤 | M2 提供 publicExplanations | 过滤归服务端，toJson 维持全集 | 服务端误用 toJson 会漏 repair 码，§5.7 拒绝 |
| D3 | availability 语义 | null/[] 区分 | 非空 List，空=按偏好 | 方案 A（保持）或 B（改 nullable） | 契约无「明确无时间」表达，NO_AVAILABILITY 触发语义不确定 |
| R2 | scheduling_weight 层级 | 服务端折算进 priority | §5.2 BLOCKED 不消费 | 服务端折算（M1 已认同） | 排序缺 weight 一级 |
| R1 | 时区转换 | 服务端转换 | 引擎不消费 timezone | 服务端转本地时间 | 跨时区判定不定 |

（其余 R3-R7、Q1-Q3、M-1~M-4 已在 M1 §14 汇总，M2 无新增，不再重复。）

---

## 附：审查边界

- 只读，零写操作。未改代码/契约/Mock/测试。
- 未提交、未推送、未建 PR、未合并。PR #2/#3/#4 head 未动。
- 审查基准：契约 `39f7f965`、M2 head `070fb6e`、M1 代码 `7e1367c2`。
- 未替 M0 做规则选择；D2/D3 只列选项与阻塞点。
