# A1 × A2 接口交叉审查报告（完整版）

> 依据：M0 2026-11-03 11:41Z 邮件《启动 A1 §9 × A2 接口交叉审查｜一次性交付完整报告》。
> 性质：只读审查。未改代码/契约/Mock/测试，未提交、未推送、未建 PR、未合并。
> 审查基准：契约 `39f7f965`（唯一规范基准）；A1 §9（M1 10:47Z 收尾封正文）；A2 蓝图 `a-track-blueprint-a2.md` + `a-track-integration-map.md` + domain 代码（head `070fb6e`）+ 48 条测试。
> 标注体系：**[已证实]** = 契约原文/代码/测试可复核；**[邮件自述待核]** = 对方邮件陈述、未见源码级证据；**[待 M0 裁定]** = 需 M0 拍板；**[真实资源验证]** = 需真实后端/数据库/IdP 才能验证。

---

## 0. 结论速览

| 维度 | 结论 |
|---|---|
| M1 §9 的 12 项回应 | 9 一致、1 误报（notes→explanations）、1 半一致（repair 码过滤落点）、1 真实冲突（availability 语义） |
| 方向性冲突 | 0 处（唯一冲突 D3 是契约空白，非双方理解分歧） |
| 需 M0 裁定 | 4 项核心（D2/D3/R1/R2）+ 关联 Q2/Q3/M-1~M-4 |
| 待 M1 补核 | A1 §10-§13、§15 完整正文（M0 已令 M1 补齐，到后只做差异补核） |

---

## 1. ScheduleInput / ScheduleProposal 字段逐项映射

### 1.1 ScheduleInput（M2 DTO）

| 字段 | 类型 | 必填 | null/空数组语义 | 时间/时区/版本 | 标注 |
|---|---|---|---|---|---|
| `now` | DateTime | 是 | 非空 | 服务端注入，引擎不读系统时钟 | [已证实] |
| `horizonStart` | DateTime | 是 | 非空 | — | [已证实] |
| `horizonEnd` | DateTime | 是 | 非空 | — | [已证实] |
| `baseVersion` | String | 是 | 非空 | 服务端可信版本，M2 只透传不比较 | [已证实] |
| `timezone` | String | 默认 Asia/Shanghai | 默认值 | 引擎**未消费**，服务层转换 | [待 M0 裁定 R1] |
| `preferences` | SchedulePreferences | 默认值 | 默认 480/1320/15 | — | [已证实] |
| `availability` | List\<ScheduleWindow\> | 默认空 | **空=按偏好推导；null 不可表达**（non-nullable） | — | [待 M0 裁定 D3] |
| `fixedBlocks` | List\<ScheduleFixedBlock\> | 默认空 | 空=无硬约束 | — | [已证实] |
| `demands` | List\<ScheduleTaskDemand\> | 默认空 | 空=无任务 | — | [已证实] |
| `existingPlacements` | List\<SchedulePlacement\> | 默认空 | 空=无上一版 | repair 用，须计入 input_digest | [已证实] |

### 1.2 ScheduleTaskDemand

| 字段 | 类型 | 必填 | null 语义 | 标注 |
|---|---|---|---|---|
| `taskId`/`title` | String | 是 | — | [已证实] |
| `requiredMinutes` | int | 是 | 只取服务端可信快照 | [已证实] |
| `taskKind` | enum | 默认 recurring | — | [已证实] |
| `deadline` | ScheduleDeadline? | 否 | null=无截止 | [已证实] |
| `earliestStartAt` | DateTime? | 否 | null=无限制 | [已证实] |
| `priority` | int | 默认 0 | — | [已证实] |
| `targetDurationSeconds` | int? | 否 | null=无目标 | [已证实] |
| `remainingMinutesToday` | int? | 否 | null=按 target；0=已完成；>0=排该量 | [已证实] |

### 1.3 ScheduleProposal 输出（方案 A，契约 §5.7）

M2 只输出四部分 `blocks/changes/unplanned_tasks/explanations`；**不产出** 6 服务端权威字段（proposal_id/snapshot_ref/base_version/input_digest/generated_at/expires_at/status）。[已证实，contract:624-629 + 48 条测试 ㊳㊸]

---

## 2. 职责边界（domain vs service vs 权威字段）

| 职责 | M2 domain | M1 服务端 | 标注 |
|---|---|---|---|
| 调度计算 + DTO 形状 + 确定性 | ✅ | — | [已证实] |
| violations（§5.8 八值） | ❌ | ✅ validate_schedule | [已证实] |
| 6 服务端权威字段 | ❌ | ✅ 生成/持久化 | [已证实 §5.7 方案 A] |
| 时区转换 | ❌（引擎未消费 timezone） | ✅ | [待 M0 裁定 R1] |
| scheduling_weight 折算 | ❌（不消费） | ✅ 折算进 priority | [待 M0 裁定 R2] |
| maxShiftMinutes=120 | 参数已实现，默认 null | ✅ 服务层注入 | [已证实 + 待 M0 裁定 R3] |
| 幂等/事务/readback | ❌ | ✅ | [契约已支持 §6.5/§6.7] |
| IdP/审计/双人复核 | ❌ | ✅ | [邮件自述待核，A1 §15] |

---

## 3. generate / repair / validate 调用层与失败边界

| 函数 | 调用层 | 输入 | 输出 | 失败边界 | 标注 |
|---|---|---|---|---|---|
| generateSchedule | 服务端包装层 | ScheduleInput | 内部四部分 | 无窗口→NO_AVAILABILITY_WINDOW；占满→AVAILABILITY_SATURATED | [已证实] |
| repairSchedule | 服务端包装层 | ScheduleInput + previous + maxShiftMinutes:120 | 内部四部分 | 就近无解退最早可用；无可排→unplanned | [已证实] |
| validate_schedule | 服务端 | 完整 Proposal | violations[]（八值）| HTTP 200 + validation_status=invalid，非 4xx/5xx | [契约已支持 §6.4] |

分界：M2 负责「算得合不合理」（内部守卫，如块间不重叠），服务端负责「按契约判定并落状态」（八值 + 状态迁移）。重叠部分两边都做。[已证实，M1 §9.4 明确认可]

---

## 4. 8 态 Proposal 状态机与 A2 一致性

契约状态机（§5.7）：draft → pending_approval → applying → applied / readback_pending / rejected / expired / failed（8 态）。

- A2 **不产出 status**（方案 A）；M2 proposal 恒为 draft 语义的「内部四部分」。[已证实]
- rejected/expired 两个终态 + readback_pending 中间态**均由服务端推进**，A2 不涉及，**无遗漏**（A2 只负责 draft 语义的确定性计算）。[已证实]
- 一致性结论：8 态状态机完全在服务端，A2 零耦合，无冲突。[已证实]

---

## 5. 幂等 / 并发 / 事务 / 版本 / 快照 / readback 责任分工

| 项 | 责任方 | A2 是否承担 | 标注 |
|---|---|---|---|
| 幂等键 approval_id | 服务端 | ❌ | [契约已支持 §6.5] |
| 并发锁（行锁/唯一索引） | 服务端 + DB | ❌ | [真实资源验证] |
| 事务原子写入 | 服务端 + DB | ❌ | [真实资源验证] |
| base_version 产生/核验 | 服务端 + 事务 | ❌（只透传） | [契约已支持 §7.2] |
| 权威快照 | 服务端 | ❌（只消费快照折算的 DTO） | [真实资源验证] |
| readback_pending 恢复 | 服务端 | ❌ | [契约已支持 §6.7] |
| recovery_evidence | 服务端 | ❌ | [邮件自述待核，A1 §9.5 四步复核] |

---

## 6. §4.1 21 码 vs §5.8 八值的边界

| 闭集 | 位置 | 值数 | 承载 | 归属 |
|---|---|---|---|---|
| §4.1 错误码 | §4.1 | 21 | 4xx/5xx 失败响应 error.code | 服务端 HTTP |
| §5.8 violation code | §5.8 | 8 | HTTP 200 + validation_status=invalid 的 data.violations[].code | 服务端校验 |

- 两闭集**零交集**（M1 §14.4 实测 0/8）。violation 不是 HTTP 错误；HTTP 错误码不得降级成 violations。[已证实，契约 §6.4]
- BLOCK_OVERLAP 属 §5.8，M2 输出构造性不重叠（内部守卫），服务端权威判定一次。[已证实]

---

## 7. R1–R7 / Q2/Q3 / M-1~M-4 关联

| 编号 | 事项 | 类型 | 标注 |
|---|---|---|---|
| R1 时区 | 服务层转换 vs 引擎解析 | 工程建议（服务层转换） | [待 M0 裁定] |
| R2 scheduling_weight | 服务端折算进 priority | 工程建议 | [待 M0 裁定，§5.2 BLOCKED] |
| R3 maxShift=120 入口 | domain 常量 + 服务层接线 | 工程建议 | [待 M0 裁定] |
| R4 = Q2 签发方 | 外部 IdP | **M0 决策，不得代定** | [待 M0 裁定] |
| R5 = Q3 双人复核 | 高风险才复核 | **M0 决策，不得代定** | [待 M0 裁定] |
| R6 retryable 18 码 | 采纳 M1 §14.5 表 | 契约补白 | [待 M0 裁定] |
| R7 error.details 承载 | 允许复用 8 值 | 契约补白 | [待 M0 裁定] |
| M-1~M-4 | HTTP 强制/反向索引/retryable/details | 契约补句 | [待 M0 裁定，M1 §14.6] |

Q2、R4 明确**不代 M0 决定**（M0 已点名）。其余为工程建议 + 契约补白。

---

## 8. 测试映射（设计层 vs 源码级验证）

| 层 | A2 侧 | A1 侧 | 关系 |
|---|---|---|---|
| 源码/测试级（可复核） | 48 条（test/agent_scheduler_test.dart，符号/行号已交付 M3） | M1 服务端用例 29 条 | 互不重叠、互为补充 |
| 设计层（审查结论） | A2 蓝图 8 项能力盘点 | A1 §9 12 项回应 | 本报告逐项核对 |

**明确**：不能按 29/48 数量推断覆盖——29 条是服务端验收（基础设施/审批/readback），48 条是纯函数验收（确定性/约束/序列化），两个维度不互相背书。[已证实]

---

## 9. 统一接口表 + 调用时序 + 责任矩阵 + 冲突/缺失/建议

### 9.1 调用时序（端到端）

```
可信快照 → 组装 ScheduleInput（date_range→horizon，快照→demands/fixedBlocks）
  → generate/repair（domain 纯函数，repair 带 maxShiftMinutes:120）
  → 内部四部分 → publicExplanations 过滤 repair 码 → 补 6 权威字段 → 序列化完整 Proposal
  → validate_schedule（§5.8 八值，HTTP 200）→ request_approval（幂等）→ apply（事务 + 四步复核）→ readback
```

### 9.2 冲突清单（3 条，仅 D3 真实冲突）

| # | 冲突 | A1 观点 | A2 事实 | 判定 |
|---|---|---|---|---|
| D1 | notes vs explanations | 需改字段名 | toJson 已是 explanations | M1 误报 |
| D2 | repair 码过滤落点 | 禁止进 v1 | 已提供 publicExplanations | 半一致，须明确服务端用 publicExplanations |
| D3 | availability null vs 空数组 | null/[] 区分 | non-nullable，空=按偏好 | 真实冲突 + 契约空白 |

### 9.3 缺失证据清单

- A1 §10-§13、§15 完整正文（M0 已令 M1 补齐，到后补核）[邮件自述待核]
- recovery_evidence 的字段定义（A1 §9.5 四步复核提到，未见契约原文）[邮件自述待核]
- 真实资源类（IdP/DB/TLS/多实例）全部 [真实资源验证]

### 9.4 建议修订项

- D2：服务端组装 v1 必须用 `publicExplanations`，M2 可加 `toJson({bool publicOnly=false})` 参数。
- D3：按 M0 裁定后（方案 A 保持 / 方案 B 改 nullable）落地，M2 补用例。

---

## 附：一页《M0 必须裁定事项》

| # | 事项 | 选项 | 不裁定的阻塞 |
|---|---|---|---|
| D2 | repair 码过滤落点 | ①服务端过滤（用 publicExplanations）②M2 toJson 默认只出公共码 | 服务端误用 toJson 会漏 repair 码，§5.7 拒 |
| D3 | availability null/[] 语义 | ①保持非空（空=按偏好）②改 nullable（null=按偏好、[]=明确没有） | 契约「明确无时间」无表达，NO_AVAILABILITY 触发语义不定 |
| R1 | 时区转换 | ①服务层转本地②引擎解析③固定 Asia/Shanghai | 跨时区块不跨日/截止判定无法写用例 |
| R2 | scheduling_weight 层级 | ①服务端折算进 priority②截止后 priority 前③priority 后 taskId 前 | §5.2 BLOCKED，排序缺一级 |
| R3 | maxShift=120 入口归属 | ①domain 常量+服务层②服务端自建 | 120 待接入，默认路径测试无法写 |
| Q2/R4 | Token 签发方 | ①M2 侧（排除，纯函数）②M0 侧③外部 IdP | T-3.4 全组 BLOCKED，A 轨无法闭环 |
| Q3/R5 | 双人复核覆盖面 | ①全面强制②高风险才复核 | T-3.9 BLOCKED |
| R6 | retryable 18 码补值 | ①采纳 M1 §14.5 表②逐码另定 | 18 码 retryable 无契约值，验收无法判对错 |
| R7/M-4 | error.details 承载 violation | ①允许复用 8 值②不承载 | 502 后无法定位具体违规块 |

（M-1/M-2/M-3 已在 M1 §14.6，属低优先级契约补句，本表从略，见 M1 原文。）

---

## 附：审查边界

- 只读，零写操作。未改代码/契约/Mock/测试。未提交推送建 PR。
- PR #2/#3/#4 head 未动；冻结基线（录制 7e1367c2 + 契约 39f7f965）未动。
- 未替 M0 做任何规则决定；Q2/R4 明确标注「不得代定」。
