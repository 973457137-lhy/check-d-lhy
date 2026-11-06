// 对**已生成的提案**做静态一致性校验，输出契约 §5.8 词汇表里的 violation。
//
// 定位（先清界，免得被当成第二个权威校验器）：
// - 本文件只判定「给定 input 与 proposal 是否自相一致」，不读数据库、不做审批、
//   不生成 `proposal_id` / `snapshot_ref`。
// - 契约 §5.8 的**权威**校验实现仍在 M1 的 `tools/m1-server`（PR #10 范围、已第三方实测）；
//   两实现并存时以契约文本为准，差异由 M3 的端到端验收暴露。
// - 之所以还要一份：比赛闭环要求「生成 → 校验 → 用户确认」在同一个可调用服务里闭合，
//   且 M1 服务未接通时也能自证。
//
// 消息纪律（PR #8 教训）：公开 `message` 不得内嵌 task_id / block_id，
// 结构化关联一律放 `related_*_ids`。

import '../../../lib/features/agent_scheduler/domain/schedule_contract.dart';

/// 一条 violation。
class Violation {
  const Violation({
    required this.code,
    required this.message,
    this.relatedTaskIds = const [],
    this.relatedBlockIds = const [],
    this.relatedChangeIds = const [],
  });

  final String code;
  final String message;
  final List<String> relatedTaskIds;
  final List<String> relatedBlockIds;
  final List<String> relatedChangeIds;

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (relatedTaskIds.isNotEmpty) 'related_task_ids': relatedTaskIds,
    if (relatedBlockIds.isNotEmpty) 'related_block_ids': relatedBlockIds,
    if (relatedChangeIds.isNotEmpty) 'related_change_ids': relatedChangeIds,
  };
}

/// 校验只关心提案里的这几件事，故用一个极小的视图承载，
/// 既能接 Dart DTO，也能接从 HTTP 收到的 JSON。
class BlockView {
  const BlockView({
    required this.taskId,
    required this.blockId,
    required this.taskKindCode,
    required this.startAt,
    required this.endAt,
  });

  final String taskId;
  final String blockId;
  final String taskKindCode;
  final DateTime startAt;
  final DateTime endAt;

  bool get isRecurring => taskKindCode == 'recurring';
}

class ChangeView {
  const ChangeView({
    required this.taskId,
    required this.changeId,
    this.plannedDate,
  });

  final String taskId;
  final String changeId;

  /// 这条变更作用在哪一天（仅日期，时间部分无意义）。
  ///
  /// 契约 v1 两个子类字段名不同：单次事项用 `planned_date`，单日例外用 `local_date`。
  /// 判「同一任务能否有多条变更」必须按**日期**而不是按任务：
  /// 周期任务跨多日各一条是合法的（P1-1 授权后即如此），同日两条才是重复。
  final DateTime? plannedDate;
}

/// 码的稳定输出顺序（M0 要求 `FIXED_EVENT_CONFLICT` 先于 `BLOCK_OVERLAP`）。
const List<String> codeOrder = <String>[
  'BLOCK_TIME_INVALID',
  'FIXED_EVENT_CONFLICT',
  'PLANNED_BEFORE_AVAILABLE_FROM',
  'PLANNED_AFTER_DATE_ONLY_DEADLINE',
  'BLOCK_AFTER_EXACT_DEADLINE',
  'MULTIPLE_BLOCKS_FOR_RECURRING_TASK_DAY',
  'MULTIPLE_CHANGES_FOR_ONE_TIME_TASK',
  'BLOCK_OVERLAP',
];

/// 校验 Dart DTO 形态的提案。
List<Violation> validateProposal(ScheduleInput input, ScheduleProposal proposal) {
  final blocks = proposal.blocks
      .map(
        (block) => BlockView(
          taskId: block.taskId,
          blockId: block.blockId,
          taskKindCode: block.taskKind.code,
          startAt: block.startAt,
          endAt: block.endAt,
        ),
      )
      .toList();
  final changes = proposal.changes
      .map(
        (change) => ChangeView(
          taskId: taskIdOfChange(change),
          changeId: change.changeId,
          plannedDate: dateOfChange(change) == null ? null : scheduleDayOnly(dateOfChange(change)!),
        ),
      )
      .toList();
  return validateViews(input, blocks, changes);
}

/// 取一条变更归属的任务 id。
///
/// 契约 v1 的字段名不统一：单次事项变更用 `task_id`，单日例外用 `item_id`。
/// 未知子类（将来新增类型）按 `change_id` 占位，保证服务端不因未知类型崩溃。
String taskIdOfChange(ProposedScheduleChange change) {
  if (change is ScheduleOneTimeChange) return change.taskId;
  if (change is UpsertDailyOverrideChange) return change.itemId;
  return change.changeId;
}

/// 取一条变更作用的本地日期（未知子类返回 null，退化为按任务判重）。
DateTime? dateOfChange(ProposedScheduleChange change) {
  if (change is ScheduleOneTimeChange) return change.plannedDate;
  if (change is UpsertDailyOverrideChange) return change.localDate;
  return null;
}

/// 核心校验：与来源无关，只看视图。
List<Violation> validateViews(
  ScheduleInput input,
  List<BlockView> blocks,
  List<ChangeView> changes,
) {
  final violations = <Violation>[];
  final demandByTask = <String, ScheduleTaskDemand>{
    for (final demand in input.demands) demand.taskId: demand,
  };
  final fixedWindows = input.fixedBlocks.map((block) => block.window).toList();

  // 1) 时间区间自洽
  for (final block in blocks) {
    if (!block.endAt.isAfter(block.startAt)) {
      violations.add(
        Violation(
          code: 'BLOCK_TIME_INVALID',
          message: '提案中存在结束时间不晚于开始时间的时间块。',
          relatedTaskIds: [block.taskId],
          relatedBlockIds: [block.blockId],
        ),
      );
    }
  }

  // 2) 与硬约束冲突（必须排在 BLOCK_OVERLAP 之前）
  for (final block in blocks) {
    final window = ScheduleWindow(startAt: block.startAt, endAt: block.endAt);
    if (fixedWindows.any(window.overlaps)) {
      violations.add(
        Violation(
          code: 'FIXED_EVENT_CONFLICT',
          message: '提案时间块与固定日程（课程或外部固定事件）重叠；固定日程不可被移动。',
          relatedTaskIds: [block.taskId],
          relatedBlockIds: [block.blockId],
        ),
      );
    }
  }

  // 3) 早于可用起点
  for (final block in blocks) {
    final earliest = demandByTask[block.taskId]?.earliestStartAt;
    if (earliest != null && block.startAt.isBefore(earliest)) {
      violations.add(
        Violation(
          code: 'PLANNED_BEFORE_AVAILABLE_FROM',
          message: '提案时间块早于该任务的可用起点。',
          relatedTaskIds: [block.taskId],
          relatedBlockIds: [block.blockId],
        ),
      );
    }
  }

  // 4) 截止类型分治：日期型看「当天结束」，精确型看「那一刻」
  for (final block in blocks) {
    final deadline = demandByTask[block.taskId]?.deadline;
    if (deadline == null) continue;
    if (deadline.isDateOnly) {
      final endOfDay = scheduleDayOnly(deadline.dueDateOn!).add(const Duration(days: 1));
      if (block.endAt.isAfter(endOfDay)) {
        violations.add(
          Violation(
            code: 'PLANNED_AFTER_DATE_ONLY_DEADLINE',
            message: '提案时间块超出了日期型截止的当天范围。',
            relatedTaskIds: [block.taskId],
            relatedBlockIds: [block.blockId],
          ),
        );
      }
    } else if (block.endAt.isAfter(deadline.dueAt!)) {
      violations.add(
        Violation(
          code: 'BLOCK_AFTER_EXACT_DEADLINE',
          message: '提案时间块结束晚于精确截止时刻。',
          relatedTaskIds: [block.taskId],
          relatedBlockIds: [block.blockId],
        ),
      );
    }
  }

  // 5) 周期任务同一本地日最多一块
  final perTaskDay = <String, List<BlockView>>{};
  for (final block in blocks) {
    if (!block.isRecurring) continue;
    final day = scheduleDayOnly(block.startAt);
    final key = '${block.taskId}#${day.year}-${day.month}-${day.day}';
    perTaskDay.putIfAbsent(key, () => <BlockView>[]).add(block);
  }
  for (final entry in perTaskDay.entries) {
    if (entry.value.length < 2) continue;
    violations.add(
      Violation(
        code: 'MULTIPLE_BLOCKS_FOR_RECURRING_TASK_DAY',
        message: '同一周期任务在同一本地日出现了多个时间块，应合并为一块。',
        relatedTaskIds: [entry.value.first.taskId],
        relatedBlockIds: entry.value.map((block) => block.blockId).toList(),
      ),
    );
  }

  // 6) 变更重复判定：按**作用范围**判，不是按任务一刀切
  //
  // - 单次事项：整个提案最多一条（它只有一天，多出来必然是重复）；
  // - 周期任务：**同一本地日**最多一条；跨多日各一条是合法的 —— 这正是 P1-1 授权
  //   `authorize_multi_day_overrides=true` 后的正常形态。
  //
  // 上一版这里只要同一任务 ≥2 条就报 MULTIPLE_CHANGES_FOR_ONE_TIME_TASK，
  // 连「周期任务跨两天各一条」也判非法，导致引擎自己产出的授权态提案通不过自己的校验器
  // （生成合法、校验非法）。isOneTime 当时只改了文案、没改判定，是同一处笔误。
  final perTaskChanges = <String, List<ChangeView>>{};
  for (final change in changes) {
    perTaskChanges.putIfAbsent(change.taskId, () => <ChangeView>[]).add(change);
  }
  for (final entry in perTaskChanges.entries) {
    final isOneTime =
        demandByTask[entry.key]?.taskKind == ScheduleTaskKind.oneTime || entry.value.any((c) => c.plannedDate == null);
    if (isOneTime) {
      if (entry.value.length < 2) continue;
      violations.add(
        Violation(
          code: 'MULTIPLE_CHANGES_FOR_ONE_TIME_TASK',
          message: '同一单次事项在一个提案中出现了多条变更，应合并为一条。',
          relatedTaskIds: [entry.key],
          relatedChangeIds: entry.value.map((c) => c.changeId).toList(),
        ),
      );
      continue;
    }
    // 周期任务：按日期分组，同一日期 ≥2 条才算重复
    final perDay = <String, List<ChangeView>>{};
    for (final change in entry.value) {
      final day = scheduleDayOnly(change.plannedDate!).toIso8601String();
      perDay.putIfAbsent(day, () => <ChangeView>[]).add(change);
    }
    for (final sameDay in perDay.values) {
      if (sameDay.length < 2) continue;
      violations.add(
        Violation(
          code: 'MULTIPLE_CHANGES_FOR_ONE_TIME_TASK',
          message: '同一周期任务在同一本地日出现了多条变更，应合并为一条。',
          relatedTaskIds: [entry.key],
          relatedChangeIds: sameDay.map((c) => c.changeId).toList(),
        ),
      );
    }
  }

  // 7) 块之间互相重叠（放最后：通常是前几类问题的次生现象）
  final ordered = blocks.toList()..sort((a, b) => a.startAt.compareTo(b.startAt));
  for (var i = 0; i < ordered.length; i++) {
    for (var j = i + 1; j < ordered.length; j++) {
      if (!ordered[j].startAt.isBefore(ordered[i].endAt)) break;
      violations.add(
        Violation(
          code: 'BLOCK_OVERLAP',
          message: '两个提案时间块互相重叠。',
          relatedTaskIds: [ordered[i].taskId, ordered[j].taskId],
          relatedBlockIds: [ordered[i].blockId, ordered[j].blockId],
        ),
      );
    }
  }

  violations.sort((a, b) => codeOrder.indexOf(a.code).compareTo(codeOrder.indexOf(b.code)));
  return violations;
}
