/// M2 智能调度在确定提案阶段使用的数据结构。
///
/// 这里是纯粹的提案形状（DTO），不是数据库表，也不对应任何 Drift 实体。
/// M0 负责把真实的 Task / Course / Calendar / 单日例外映射成这里的结构，
/// 本模块只负责计算。
///
/// 团队 Global Constraints 在本模块中的落点：
/// - Course 与会议属于硬约束，[ScheduleFixedBlock] 永远不可被移动。
/// - 日期型截止与精确截止分别建模（[ScheduleDeadline]），
///   绝不为「只有日期」的截止伪造一个 23:59 的时刻。
/// - [ProposedBlock] 只表示未来安排的建议，永远不是 TimerSession 事实，
///   也不代表手动完成。
/// - 引擎不得读取当前时间，所有时间基准来自 [ScheduleInput.now]，
///   这保证相同输入必然得到相同输出。
library;

/// 硬约束的来源类型。
enum ScheduleOwnerType {
  /// 课程。课程只是日程状态，不参与打卡，也不进入专注时长。
  course,

  /// 外部固定事件，例如突发会议。对应契约中的 `external_fixed_event`。
  event,
}

/// [ScheduleOwnerType] 的契约编码。
extension ScheduleOwnerTypeCode on ScheduleOwnerType {
  String get code => switch (this) {
    ScheduleOwnerType.course => 'course',
    ScheduleOwnerType.event => 'external_fixed_event',
  };
}

/// 任务类型，取值与契约 `task_kind` 一致。
enum ScheduleTaskKind {
  /// 周期任务
  recurring,

  /// 单次事项
  oneTime,
}

/// [ScheduleTaskKind] 的契约编码。
extension ScheduleTaskKindCode on ScheduleTaskKind {
  String get code => switch (this) {
    ScheduleTaskKind.recurring => 'recurring',
    ScheduleTaskKind.oneTime => 'one_time',
  };
}

/// 提案状态机，取值与契约 `schedule_proposal.status` 一致。
///
/// 方案 A（c53b1a9 起）：`status` 是**服务端权威字段**，M2 纯调度函数不产出、
/// 不序列化它。这里保留枚举只是作为契约状态机的进程内参照（例如给服务端包装层
/// 或验收矩阵对齐状态名），[ScheduleProposal] 本身不再携带 `status`。
enum ScheduleProposalStatus {
  draft,
  pendingApproval,
  applying,
  readbackPending,
  applied,
  rejected,
  expired,
  failed,
}

extension ScheduleProposalStatusCode on ScheduleProposalStatus {
  String get code => switch (this) {
    ScheduleProposalStatus.draft => 'draft',
    ScheduleProposalStatus.pendingApproval => 'pending_approval',
    ScheduleProposalStatus.applying => 'applying',
    ScheduleProposalStatus.readbackPending => 'readback_pending',
    ScheduleProposalStatus.applied => 'applied',
    ScheduleProposalStatus.rejected => 'rejected',
    ScheduleProposalStatus.expired => 'expired',
    ScheduleProposalStatus.failed => 'failed',
  };
}

/// 调度偏好。对应契约 `generate_schedule.input.preferences`。
///
/// 偏好只能约束纯粹属于用户意愿的部分，**永远不能覆盖硬约束**。
class SchedulePreferences {
  const SchedulePreferences({
    this.dayStartMinute = 8 * 60,
    this.dayEndMinute = 22 * 60,
    this.minimumBlockMinutes = 15,
  });

  /// 每天允许排程的最早分钟数，0..1439。
  final int dayStartMinute;

  /// 每天允许排程的最晚分钟数，1..1440，必须晚于开始。
  final int dayEndMinute;

  /// 少于该长度的碎片不再参与排程。
  final int minimumBlockMinutes;
}

/// 截止时间的契约联合类型。
///
/// `date_only` 只能带 `date`，`exact` 只能带 `at`，
/// 与契约第 3.1 节完全一致。
extension ScheduleDeadlineJson on ScheduleDeadline {
  Map<String, dynamic> toJson() => isDateOnly
      ? {
          'kind': 'date_only',
          'date': _isoDate(dueDateOn!),
        }
      : {
          'kind': 'exact',
          'at': dueAt!.toIso8601String(),
        };
}

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

/// 把一个**真实时刻（instant）**转换到固定业务时区 `Asia/Shanghai` 后序列化。
///
/// 契约 §3 明文：精确时间必须是 RFC 3339 / ISO 8601 字符串并带明确偏移，
/// **禁止无偏移时间**。Dart 的 `DateTime.toIso8601String()` 只能产出
/// 「无偏移的本地时间」或「带 Z 的 UTC」两种形态，**无法直接输出 `+08:00`**，
/// 因此这里手写格式化。
///
/// **语义前提**：入参是 instant，即时间轴上的一个点，而不是「上海墙上时间的字面值」。
/// 所以先 `toUtc()` 归一到 UTC，再加 8 小时得到上海墙上时间，末尾固定拼 `+08:00`。
///
/// 反例（调用方语义错误，不是本函数错误）：在非 `+08:00` 机器上用
/// `DateTime(2026, 11, 5, 9, 40)` 表达"上海 9:40"——它实际表示的是该机器本地
/// 9:40 对应的那一刻，转换后可能得到 `17:40+08:00`。要表达上海时刻，应使用
/// `DateTime.parse('2026-11-05T09:40:00+08:00')` 或 `DateTime.utc(...)`。
String _isoShanghaiInstant(DateTime value) {
  final shanghai = value.toUtc().add(const Duration(hours: 8));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${shanghai.year.toString().padLeft(4, '0')}-${two(shanghai.month)}-'
      '${two(shanghai.day)}T${two(shanghai.hour)}:${two(shanghai.minute)}:'
      '${two(shanghai.second)}+08:00';
}

/// 任务没能被排进去的机器可读原因。
///
/// C 的验收表和 A 的差异文案都依赖这个枚举，不能退化成一句中文描述。
enum UnplannedReason {
  /// 找不到足够长的连续空闲窗口。
  windowInsufficient,

  /// 截止时间已过。
  pastDeadline,

  /// 可用区间被硬约束占满。
  overlapsFixed,

  /// 输入没有给出任何可用窗口。
  noAvailability,

  /// **已逾期**：截止时刻已经早于调度基准时刻 [ScheduleInput.now]，
  /// 无论怎么排都不可能合法（M0 2026-11-05 17:04Z P0-1）。
  ///
  /// 与 [pastDeadline] 的区别：后者是历史码，保留用于兼容；
  /// 新输出一律用本值，语义更窄——「这条发生项本身已经废了」。
  unschedulableOverdue,

  /// **截止前时间不够**：截止尚未过，但截止之前的所有空闲时段加起来
  /// 仍不足任务所需分钟数（M0 2026-11-05 17:04Z P0-3）。
  ///
  /// 与 [windowInsufficient] 的区别：后者是「整体空闲不够」，
  /// 本值专指「截止这条约束把可用时间掐没了」。
  insufficientTimeBeforeDeadline,
}

/// [UnplannedReason] 的 JSON 编码，供 M0 v1 契约使用。
extension UnplannedReasonCode on UnplannedReason {
  String get code => switch (this) {
    UnplannedReason.windowInsufficient => 'WINDOW_INSUFFICIENT',
    UnplannedReason.pastDeadline => 'PAST_DEADLINE',
    UnplannedReason.overlapsFixed => 'OVERLAPS_FIXED',
    UnplannedReason.noAvailability => 'NO_AVAILABILITY',
    UnplannedReason.unschedulableOverdue => 'UNSCHEDULABLE_OVERDUE',
    UnplannedReason.insufficientTimeBeforeDeadline => 'INSUFFICIENT_TIME_BEFORE_DEADLINE',
  };
}

DateTime scheduleDayOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 一段连续时间区间的公共形状。
class ScheduleWindow {
  const ScheduleWindow({required this.startAt, required this.endAt});

  final DateTime startAt;
  final DateTime endAt;

  bool contains(DateTime instant) =>
      !instant.isBefore(startAt) && instant.isBefore(endAt);

  bool overlaps(ScheduleWindow other) =>
      startAt.isBefore(other.endAt) && other.startAt.isBefore(endAt);

  Duration get duration => endAt.difference(startAt);

  bool get isEmpty => !endAt.isAfter(startAt);
}

/// 截止时间。
///
/// 两种形态互斥，语义与 `TaskTimeSemantics` / `TaskDeadline` 保持一致：
/// - [dateOnly]：只到某一天，那一天结束前都算没有逾期。
/// - [exact]：精确到某个时刻，过点即为逾期。
class ScheduleDeadline {
  const ScheduleDeadline._({this.dueDateOn, this.dueAt})
    : assert((dueDateOn == null) != (dueAt == null));

  factory ScheduleDeadline.dateOnly(DateTime day) =>
      ScheduleDeadline._(dueDateOn: scheduleDayOnly(day));

  factory ScheduleDeadline.exact(DateTime instant) =>
      ScheduleDeadline._(dueAt: instant);

  final DateTime? dueDateOn;
  final DateTime? dueAt;

  bool get isDateOnly => dueDateOn != null;
  bool get hasTime => dueAt != null;

  /// 排程意义上的最晚结束时刻。
  ///
  /// 日期型截止的含义是「当天结束前都算赶上」，
  /// 所以最晚可以排到当天最后一刻；这不等于宣称它的截止时刻被记录为 23:59。
  DateTime get latestEndAt {
    final exact = dueAt;
    if (exact != null) return exact;
    return scheduleDayOnly(dueDateOn!)
        .add(const Duration(days: 1))
        .subtract(const Duration(milliseconds: 1));
  }

  /// 是否已在 [now] 过期。
  ///
  /// 日期型：过了那一天才算逾期。
  /// 精确型：到达该时刻即逾期（`now == dueAt` 时截止已经生效）。
  bool isPast(DateTime now) {
    if (isDateOnly) {
      return scheduleDayOnly(now).isAfter(scheduleDayOnly(dueDateOn!));
    }
    return !now.toUtc().isBefore(dueAt!.toUtc());
  }
}

/// 不可移动的占用区间：课程或会议。
class ScheduleFixedBlock {
  const ScheduleFixedBlock({
    required this.ownerId,
    required this.ownerType,
    required this.startAt,
    required this.endAt,
    this.title,
  });

  final String ownerId;
  final ScheduleOwnerType ownerType;
  final DateTime startAt;
  final DateTime endAt;
  final String? title;

  ScheduleWindow get window => ScheduleWindow(startAt: startAt, endAt: endAt);
}

/// 一条待排的任务需求。
///
/// 由 M0 从周期任务或单次事项映射而来；本模块不区分二者，
/// 只用 [requiredMinutes] 与截止条件来决定怎么排。
class ScheduleTaskDemand {
  const ScheduleTaskDemand({
    required this.taskId,
    required this.title,
    required this.requiredMinutes,
    this.taskKind = ScheduleTaskKind.recurring,
    this.deadline,
    this.earliestStartAt,
    this.priority,
    this.targetDurationSeconds,
    this.remainingMinutesToday,
  });

  final String taskId;
  final String title;

  /// 服务端**可信快照**给出的估算分钟数，是契约时长优先级的第二级。
  ///
  /// 这个值只能由服务端包装层从一致性快照折算后填入，**不接受 LLM 直接提供的
  /// 伪可信估算**（M0 2026-10-31 决定）。它是进程内 DTO 字段，
  /// **不是** `generate_schedule` 远程请求参数。
  final int requiredMinutes;

  /// 周期任务与单次事项分别建模，它决定区块最终能怎么持久化。
  final ScheduleTaskKind taskKind;

  /// 为空表示没有截止限制。
  final ScheduleDeadline? deadline;

  /// 早于该时刻不可开始，通常由 `availableFrom` 映射而来。
  final DateTime? earliestStartAt;

  /// 服务端给出的优先级；**null = 未提供**，不得自行推测成 0（M0 2026-11-05 17:04Z P1-3）。
  ///
  /// 排序时：提供了 priority 的排在未提供的前面（同截止条件下），
  /// 未提供的按 taskId 稳定排序，并在输出里标 `priority_state=unknown`。
  final int? priority;

  /// 任务自带时长目标。只有传入它，`duration_source` 才是 `task_target`；
  /// 否则调度器给出的是估算，不得被描述成任务固有属性。
  final int? targetDurationSeconds;

  /// 当天剩余待做量（分钟），对应契约 `remaining_minutes_today`。
  ///
  /// **只属于服务端可信调度快照**，是进程内 DTO 字段，
  /// **不得作为 `generate_schedule` 的 LLM 远程请求参数**（M0 2026-10-31 决定）。
  ///
  /// 仅对周期任务有意义，且只能由服务端可信快照给出：
  /// `= 0` 是特殊情况，**不走时长兜底**（兜底只补给"没有任何时长依据"的任务，
  /// 而这里恰恰是"已经做完"）。
  /// - 非空且 > 0：本次就排这么多，优先于 [targetDurationSeconds]；
  /// - 等于 0：当天不再排程（已做完），不生成 block，
  ///   也不进入 `unplanned_tasks`——未安排不等于完成，这里恰恰是完成；
  /// - 为空：按完整的 [targetDurationSeconds] 排。
  final int? remainingMinutesToday;
}

/// 上一版提案中已存在的柔性安排。
///
/// [repairSchedule] 用它来判断哪些块可以被保留，从而实现最小扰动。
class SchedulePlacement {
  const SchedulePlacement({
    required this.taskId,
    required this.startAt,
    required this.endAt,
  });

  final String taskId;
  final DateTime startAt;
  final DateTime endAt;

  int get minutes => endAt.difference(startAt).inMinutes;
}

/// 排程输入。
///
/// [now] 必须显式传入，引擎内部不允许自行读取系统时间。
class ScheduleInput {
  const ScheduleInput({
    required this.now,
    required this.horizonStart,
    required this.horizonEnd,
    required this.baseVersion,
    this.timezone = 'Asia/Shanghai',
    this.preferences = const SchedulePreferences(),
    this.availability,
    this.fixedBlocks = const [],
    this.demands = const [],
    this.existingPlacements = const [],
    this.authorizeMultiDayOverrides = false,
  });

  /// 排程基准时刻：任何块都不能排在它之前。
  final DateTime now;

  final DateTime horizonStart;
  final DateTime horizonEnd;

  /// 提案所依据的数据版本，用于承接 M0 的版本校验。
  ///
  /// 生产环境的 `base_version` 必须由可信服务产生，
  /// 进程内调用传入的值只用于测试，不得被当作可信版本使用。
  final String baseVersion;

  final String timezone;

  /// 每天允许排程的时间段等纯偏好。不能覆盖硬约束。
  final SchedulePreferences preferences;

  /// 用户允许被排程的时间窗口。
  ///
  /// **三态语义（M0 2026-11-05 裁定，不可合并）**：
  /// - `null`：调用方未显式提供，允许按 [preferences] 的
  ///   `dayStartMinute` / `dayEndMinute` 逐日推导；
  /// - **空数组**：调用方显式声明「没有可用时间」，**不得**回退到偏好推导，
  ///   全部任务进入 `unplanned_tasks` 且 `reason_code = NO_AVAILABILITY`；
  /// - 非空数组：只使用显式提供的时间段，不推导。
  ///
  /// 该字段是纯输入字段，**不进任何序列化输出**。
  final List<ScheduleWindow>? availability;

  /// 硬约束：课程与会议。
  final List<ScheduleFixedBlock> fixedBlocks;

  final List<ScheduleTaskDemand> demands;

  final List<SchedulePlacement> existingPlacements;

  /// 是否授权把周期任务的安排**批量写成多日单日例外**（默认 false）。
  ///
  /// M0 2026-11-05 17:04Z P1-1：默认不得未经授权把灵活任务永久钉死在固定时间。
  /// 关闭时：`blocks` 仍可跨多日展示，但 `changes` 只对**最早一天**生成，
  /// 其余日期没有可落库变更——服务端据此就不会把整个视界写死。
  final bool authorizeMultiDayOverrides;
}

/// 提案中的一块展示用安排。未被批准前它只是建议。
///
/// 对应契约第 5.6 节的 `schedule_block`。它**只是提案 DTO**，
/// 不代表数据库里存在 ScheduleBlock 表，也不是持久化的目标形状。
/// 真正能落库的形态见 [ScheduleOneTimeChange] 与 [UpsertDailyOverrideChange]。
class ProposedBlock {
  const ProposedBlock({
    required this.taskId,
    required this.title,
    required this.startAt,
    required this.endAt,
    this.taskKind = ScheduleTaskKind.recurring,
    this.movedFromPreviousPlan = false,
    this.hasDurationTarget = false,
    this.orderingReason,
    this.priorityState = 'unknown',
  });

  final String taskId;
  final String title;
  final DateTime startAt;
  final DateTime endAt;

  /// 周期任务或单次事项。它决定本块最终用哪种 change 持久化。
  final ScheduleTaskKind taskKind;

  /// 相对上一版提案是否被重排过，供 A 展示差异时使用。
  final bool movedFromPreviousPlan;

  /// 时长是否来自任务自身的 `duration_target_seconds`。
  final bool hasDurationTarget;

  /// 排程依据：为什么**这块**排在这个位置（M0 2026-11-05 17:04Z P1-2/P1-3）。
  ///
  /// 取值是稳定标识而不是自由文本，便于机器比对：
  /// `earliest_free_slot`（最早可用）、`deadline_first`（截止更早者优先）、
  /// `priority_order`（同截止下优先级更高者优先）、`stable_input_order`（并列时按 taskId 稳定）。
  final String? orderingReason;

  /// `provided` = 服务端给了 priority；`unknown` = 没给，引擎**不推测**。
  final String priorityState;

  int get minutes => endAt.difference(startAt).inMinutes;

  int get durationSeconds => endAt.difference(startAt).inSeconds;

  ScheduleWindow get window => ScheduleWindow(startAt: startAt, endAt: endAt);

  /// 提案内部 ID，不是数据库 ID。同一任务在一个提案中最多一块，故用任务 ID 派生。
  String get blockId => 'blk-$taskId';

  /// 契约固定值。
  String get source => 'proposal';

  /// 本块能怎么落库：单次事项走 `one_time_schedule`，周期任务走 `daily_override`。
  String get persistableAs => taskKind == ScheduleTaskKind.oneTime
      ? 'one_time_schedule'
      : 'daily_override';

  /// 时长是任务自带目标还是调度估算。估算不得被写回或描述成任务固有属性。
  String get durationSource =>
      hasDurationTarget ? 'task_target' : 'scheduler_estimate';

  Map<String, dynamic> toJson() => {
    'block_id': blockId,
    'task_id': taskId,
    'task_kind': taskKind.code,
    'start_at': _isoShanghaiInstant(startAt),
    'end_at': _isoShanghaiInstant(endAt),
    'source': source,
    'persistable_as': persistableAs,
    'duration_source': durationSource,
    'duration_seconds': durationSeconds,
    if (orderingReason != null) 'ordering_reason': orderingReason,
    'priority_state': priorityState,
  };
}

/// 白名单变更的共同形状：永远带 `change_id` 与 `type`。
abstract class ProposedScheduleChange {
  const ProposedScheduleChange();

  String get changeId;
  String get type;
  Map<String, dynamic> toJson();
}

/// 设置单次事项的唯一计划日期，并可设置同日的具体时间。
///
/// 契约约束：Task 必须是 `one_time`，具体时间必须与计划日期同日，
/// 一个提案中同一 Task 最多一条。
class ScheduleOneTimeChange extends ProposedScheduleChange {
  const ScheduleOneTimeChange({
    required this.changeId,
    required this.taskId,
    required this.plannedDate,
    this.scheduledAt,
  });

  @override
  final String changeId;

  final String taskId;
  final DateTime plannedDate;
  final DateTime? scheduledAt;

  @override
  String get type => 'schedule_one_time';

  @override
  Map<String, dynamic> toJson() => {
    'change_id': changeId,
    'type': type,
    'task_id': taskId,
    'planned_date': _isoDate(plannedDate),
    if (scheduledAt != null) 'scheduled_at': _isoShanghaiInstant(scheduledAt!),
  };
}

/// 为一个周期任务或单次事项在单个日期写入 `reschedule` 例外及分钟范围。
///
/// 契约 v1 暂定只允许 `reschedule`，不得用它修改课程规则或长期周期规则。
class UpsertDailyOverrideChange extends ProposedScheduleChange {
  const UpsertDailyOverrideChange({
    required this.changeId,
    required this.itemKind,
    required this.itemId,
    required this.localDate,
    required this.plannedStartMinute,
    required this.plannedEndMinute,
    this.existingOverrideId,
    this.action = 'reschedule',
  });

  @override
  final String changeId;

  final ScheduleTaskKind itemKind;
  final String itemId;
  final DateTime localDate;
  final int plannedStartMinute;
  final int plannedEndMinute;

  /// 只能由可信读取服务提供，模型不得猜测。
  final String? existingOverrideId;

  @override
  String get type => 'upsert_daily_override';

  /// `assign` = 该任务当天原本没有安排，这是**首次指派**；
  /// `reschedule` = 当天已有安排，本次是**改期**。
  ///
  /// M0 2026-11-05 17:04Z P1-1：无固定时刻的任务不得被错误表达成 reschedule。
  /// 取值只允许这两个，由引擎按 `existingPlacements` 判定后传入。
  final String action;

  /// 允许的 action 取值（封闭集）。
  static const Set<String> allowedActions = <String>{'assign', 'reschedule'};

  @override
  Map<String, dynamic> toJson() => {
    'change_id': changeId,
    'type': type,
    'item_type': itemKind.code,
    'item_id': itemId,
    'local_date': _isoDate(localDate),
    'action': action,
    'planned_start_minute': plannedStartMinute,
    'planned_end_minute': plannedEndMinute,
    if (existingOverrideId != null) 'existing_override_id': existingOverrideId,
  };
}

/// 没能排进去的任务及其原因。
class UnplannedTask {
  const UnplannedTask({
    required this.taskId,
    required this.title,
    required this.remainingMinutes,
    required this.reason,
    required this.reasonText,
    this.basis,
    this.suggestedActions = const [],
  });

  final String taskId;
  final String title;

  /// 还剩多少分钟没有被安排。
  final int remainingMinutes;

  final UnplannedReason reason;
  final String reasonText;

  /// 判定依据：把「为什么判成这样」写成可复核的事实句（不是形容词）。
  ///
  /// 例如「截止 2026-11-05T12:00:00+08:00 早于 now 2026-11-05T18:00:00+08:00」。
  /// 契约 v1 没有这个键，属 M0 2026-11-05 17:04Z P0-3 要求的新增字段。
  final String? basis;

  /// 建议动作：给用户/服务端的可执行下一步，不承诺一定可行。
  final List<String> suggestedActions;

  /// 契约第 5.7 节要求每项至少含 `task_id`、`reason_code`、`remaining_minutes`
  /// 与 `message`。这里的键集合在 M0 2026-11-05 17:04Z P0-3 后扩展为：
  /// `task_id` / `remaining_minutes` / `reason_code` / `reason_message`
  /// / `basis` / `suggested_actions`。
  ///
  /// `message` 保留为 v1 兼容别名（与 `reason_message` 同值），避免打断 M1 现有映射。
  /// `title` 仍不进 JSON：契约未列出，`additionalProperties: false` 时会整份被拒。
  Map<String, dynamic> toJson() => {
    'task_id': taskId,
    'remaining_minutes': remainingMinutes,
    'reason_code': reason.code,
    'message': reasonText,
    'reason_message': reasonText,
    if (basis != null) 'basis': basis,
    if (suggestedActions.isNotEmpty) 'suggested_actions': suggestedActions,
  };
}

/// 一条解释。
///
/// 契约第 5.7 节：`explanations` 是**对象数组**，每项含机器可读 `code` 与
/// 安全的 `message`，可选 `related_task_ids`。不再允许字符串与对象混用。
/// [taskId] 非空时会被映射成单元素 `related_task_ids`。
/// M0 2026-10-31 定下的 v1 **公共** `explanations[].code` 枚举（封闭）。
///
/// 只有落在这个集合里的码才允许出现在 v1 远程响应中。
const Set<String> kPublicExplanationCodes = <String>{
  'PRESERVED_FIXED_EVENTS',
  'ESTIMATED_DURATION',
  'FIXED_BLOCKS_OVERLAP',
  'NO_AVAILABILITY_WINDOW',
  'AVAILABILITY_SATURATED',
  'ALREADY_DONE_TODAY',
  'SCHEDULED',
};

/// 只允许出现在**进程内 repair 结果**里的码，未经批准不得进入 v1 远程响应。
///
/// 服务端序列化 Proposal 时（方案 A）必须先把这些码滤掉。
const Set<String> kRepairOnlyExplanationCodes = <String>{
  'DISPLACED_BY_FIXED',
  'REPAIR_SUMMARY',
};

class ScheduleNote {
  const ScheduleNote({
    required this.code,
    required this.message,
    this.taskId,
  });

  final String code;
  final String message;

  /// 该解释关联的任务；为空表示这是全局说明，此时不输出 `related_task_ids`。
  final String? taskId;

  /// 该码是否允许进入 v1 远程响应。
  bool get isPublic => kPublicExplanationCodes.contains(code);

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (taskId != null) 'related_task_ids': <String>[taskId!],
  };
}

/// 提案。它永远不会直接改写任何任务、日历、计时或完成记录。
///
/// 与契约第 5.7 节的对应关系：
/// - [blocks] 是可展示但**不可直接持久化**的时间块；
/// - [changes] 才是允许落库的白名单变更，只有两种形态。
///
/// **方案 A（M0 2026-10-31 决定，c53b1a9 起明确写进契约 §5.7）**：
/// 完整 Proposal 由服务端序列化。M2 纯调度函数**只输出内部调度结果**，
/// 即 `blocks` / `changes` / `unplanned_tasks` / `explanations` 四部分；
/// 不得生成或输出 `proposal_id`、`snapshot_ref`、`base_version`、
/// `input_digest`、`generated_at`、`expires_at`、`status` 等服务端权威字段。
/// 服务端包装层负责生成并持久化这些字段，再把内部四部分组装成完整 Proposal。
class ScheduleProposal {
  const ScheduleProposal({
    this.blocks = const [],
    this.changes = const [],
    this.unplannedTasks = const [],
    this.notes = const [],
  });

  /// 展示用时间块，对应 `blocks`。
  final List<ProposedBlock> blocks;

  /// 允许持久化的白名单变更，对应 `changes`。
  final List<ProposedScheduleChange> changes;

  final List<UnplannedTask> unplannedTasks;
  final List<ScheduleNote> notes;

  int get totalPlannedMinutes =>
      blocks.fold(0, (total, block) => total + block.minutes);

  /// 允许进入 v1 远程响应的解释：滤掉 repair 专用码与任何枚举外的码。
  ///
  /// 服务端序列化 Proposal（方案 A）时应以这个列表为准。
  List<ScheduleNote> get publicExplanations =>
      notes.where((note) => note.isPublic).toList();

  /// 方案 A 下 M2 只序列化内部四部分，服务端权威字段一律不输出。
  ///
  /// **这是内部结果，不得直接当作 v1 公开响应**（M0 2026-11-05 裁定 C1）：
  /// 其中的 `explanations` 含 repair 专用码，对外必须改用 [publicExplanations]。
  Map<String, dynamic> toJson() => {
    'blocks': blocks.map((block) => block.toJson()).toList(),
    'changes': changes.map((change) => change.toJson()).toList(),
    'unplanned_tasks': unplannedTasks.map((task) => task.toJson()).toList(),
    'explanations': notes.map((note) => note.toJson()).toList(),
  };
}

/// 当天从 00:00 起算的分钟数，用于生成 `planned_start_minute` 等契约字段。
int minuteOfDay(DateTime value) => value.hour * 60 + value.minute;
