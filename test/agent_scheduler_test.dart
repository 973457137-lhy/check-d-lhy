import 'dart:convert';
import 'dart:io';

import 'package:check_d/features/agent_scheduler/domain/schedule_contract.dart';
import 'package:check_d/features/agent_scheduler/domain/schedule_engine.dart';
import 'package:flutter_test/flutter_test.dart';

// 固定周一，保证测试与运行时无关。
final DateTime _monday = DateTime(2026, 11, 2);

/// 去掉行注释，让模块边界守卫只检查真正的代码。
String stripComments(String source) => source
    .split('\n')
    .map((line) {
      final comment = line.indexOf('//');
      return comment < 0 ? line : line.substring(0, comment);
    })
    .join('\n');

DateTime _at(int dayOffset, int hour, [int minute = 0]) =>
    DateTime(_monday.year, _monday.month, _monday.day + dayOffset, hour, minute);

ScheduleWindow _window(int dayOffset, int startHour, int endHour) =>
    ScheduleWindow(startAt: _at(dayOffset, startHour), endAt: _at(dayOffset, endHour));

bool _overlapsAny(ProposedBlock block, List<ScheduleFixedBlock> blocks) {
  return blocks.map((fixed) => fixed.window).any(block.window.overlaps);
}

bool _endsSameDay(ProposedBlock block) {
  final nextDay = scheduleDayOnly(block.startAt).add(const Duration(days: 1));
  return block.endAt.isBefore(nextDay) ||
      block.endAt.isAtSameMomentAs(nextDay);
}

void main() {
  group('generateSchedule 硬避让', () {
    test('任务必须绕开固定课程', () {
      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v1',
        availability: [_window(0, 8, 22)],
        fixedBlocks: [
          ScheduleFixedBlock(
            ownerId: 'course-1',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(0, 14),
            endAt: _at(0, 16),
            title: '高等数学',
          ),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-review',
            title: '复习线性代数',
            requiredMinutes: 90,
          ),
        ],
      );

      final proposal = generateSchedule(input);

      expect(proposal.blocks, hasLength(1));
      expect(proposal.unplannedTasks, isEmpty);
      final block = proposal.blocks.single;
      expect(block.startAt, _at(0, 8));
      expect(block.endAt, _at(0, 9, 30));
      expect(_overlapsAny(block, input.fixedBlocks), isFalse);
    });

    test('多个课程之间依次避让且不重叠', () {
      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v1',
        availability: [_window(0, 8, 22)],
        fixedBlocks: [
          ScheduleFixedBlock(
            ownerId: 'course-1',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(0, 9),
            endAt: _at(0, 11),
            title: '大学英语',
          ),
          ScheduleFixedBlock(
            ownerId: 'course-2',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(0, 14),
            endAt: _at(0, 16),
            title: '数据结构',
          ),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'report',
            title: '写实验报告',
            requiredMinutes: 120,
          ),
        ],
      );

      final proposal = generateSchedule(input);
      final block = proposal.blocks.single;
      expect(_overlapsAny(block, input.fixedBlocks), isFalse);
      expect(block.minutes, 120);
    });
  });

  group('截止语义', () {
    test('精确截止已过则不再排入', () {
      final input = ScheduleInput(
        now: _at(0, 12),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v1',
        availability: [_window(0, 8, 22)],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-overdue',
            title: '提交作业',
            requiredMinutes: 60,
            deadline: ScheduleDeadline.exact(_at(0, 10)),
          ),
        ],
      );

      final proposal = generateSchedule(input);

      expect(proposal.blocks, isEmpty);
      expect(proposal.unplannedTasks, hasLength(1));
      expect(
        proposal.unplannedTasks.single.reason,
        UnplannedReason.pastDeadline,
      );
      expect(
        proposal.unplannedTasks.single.reason.code,
        'PAST_DEADLINE',
      );
    });

    test('日期型截止整天宽限，不能被当成 23:59 处理', () {
      final input = ScheduleInput(
        now: _at(0, 23, 30),
        horizonStart: _at(0, 0),
        horizonEnd: _at(1, 0),
        baseVersion: 'v1',
        availability: [
          ScheduleWindow(startAt: _at(0, 0), endAt: _at(1, 0)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-tonight',
            title: '背单词',
            requiredMinutes: 15,
            deadline: ScheduleDeadline.dateOnly(_at(0, 0)),
          ),
        ],
      );

      final proposal = generateSchedule(input);

      expect(proposal.unplannedTasks, isEmpty);
      expect(proposal.blocks, hasLength(1));
      expect(proposal.blocks.single.startAt, _at(0, 23, 30));
      expect(proposal.blocks.single.endAt, _at(0, 23, 45));
    });

    test('ScheduleDeadline 两种形态互斥且语义不同', () {
      final dateOnly = ScheduleDeadline.dateOnly(_at(0, 0));
      final exact = ScheduleDeadline.exact(_at(0, 10));

      expect(dateOnly.isDateOnly, isTrue);
      expect(exact.hasTime, isTrue);
      expect(() => dateOnly.isPast(_at(0, 23, 59)), returnsNormally);
      expect(dateOnly.isPast(_at(0, 23, 59)), isFalse);
      expect(dateOnly.isPast(_at(1, 0)), isTrue);
      expect(exact.isPast(_at(0, 10)), isTrue);
      expect(exact.isPast(_at(0, 9, 59)), isFalse);
      expect(dateOnly.latestEndAt.day, _monday.day);
    });
  });

  group('容量与冲突处理', () {
    test('可用时间不足时给出未安排量与机器可读原因', () {
      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 8, 30),
        baseVersion: 'v1',
        availability: [
          ScheduleWindow(startAt: _at(0, 8), endAt: _at(0, 8, 30)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-long',
            title: '读文献',
            requiredMinutes: 120,
          ),
        ],
      );

      final proposal = generateSchedule(input);

      expect(proposal.blocks, isEmpty);
      expect(proposal.unplannedTasks, hasLength(1));
      final unplanned = proposal.unplannedTasks.single;
      expect(unplanned.remainingMinutes, 120);
      expect(unplanned.reason, UnplannedReason.windowInsufficient);
      expect(unplanned.reason.code, 'WINDOW_INSUFFICIENT');
    });

    test('固定项相互重叠时不会通过移动它们来消解冲突', () {
      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v1',
        availability: [_window(0, 8, 22)],
        fixedBlocks: [
          ScheduleFixedBlock(
            ownerId: 'course-1',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(0, 14),
            endAt: _at(0, 16),
            title: '编译原理',
          ),
          ScheduleFixedBlock(
            ownerId: 'event-1',
            ownerType: ScheduleOwnerType.event,
            startAt: _at(0, 15),
            endAt: _at(0, 17),
            title: '班会',
          ),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-report',
            title: '写报告',
            requiredMinutes: 60,
          ),
        ],
      );

      final proposal = generateSchedule(input);

      // 提案里只能出现柔性任务，绝不能出现被搬动的课程或会议。
      expect(proposal.blocks.map((block) => block.taskId), [
        'task-report',
      ]);
      expect(
        proposal.notes.map((note) => note.text).join(),
        contains('重叠'),
      );
      for (final block in proposal.blocks) {
        expect(_overlapsAny(block, input.fixedBlocks), isFalse);
      }
    });

    test('开放时段被占满时报 OVERLAPS_FIXED', () {
      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 12),
        baseVersion: 'v1',
        availability: [_window(0, 8, 12)],
        fixedBlocks: [
          ScheduleFixedBlock(
            ownerId: 'course-1',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(0, 8),
            endAt: _at(0, 12),
            title: '体育课',
          ),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-x',
            title: '自习',
            requiredMinutes: 60,
          ),
        ],
      );

      final proposal = generateSchedule(input);

      expect(proposal.blocks, isEmpty);
      expect(
        proposal.unplannedTasks.single.reason,
        UnplannedReason.overlapsFixed,
      );
    });
  });

  group('确定性与边界', () {
    test('相同输入必须得到完全相同的输出', () {
      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 7),
        horizonEnd: _at(1, 20),
        baseVersion: 'v1',
        availability: [_window(0, 8, 22), _window(1, 8, 20)],
        fixedBlocks: [
          ScheduleFixedBlock(
            ownerId: 'course-1',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(0, 10),
            endAt: _at(0, 12),
            title: '高等数学',
          ),
          ScheduleFixedBlock(
            ownerId: 'event-1',
            ownerType: ScheduleOwnerType.event,
            startAt: _at(0, 15),
            endAt: _at(0, 16, 30),
            title: '社团活动',
          ),
          ScheduleFixedBlock(
            ownerId: 'course-2',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(1, 9),
            endAt: _at(1, 10, 30),
            title: '计算机网络',
          ),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'a-report',
            title: '拆报告框架',
            requiredMinutes: 60,
            deadline: ScheduleDeadline.exact(_at(1, 18)),
            priority: 2,
          ),
          ScheduleTaskDemand(
            taskId: 'b-review',
            title: '复习',
            requiredMinutes: 90,
          ),
          ScheduleTaskDemand(
            taskId: 'c-run',
            title: '跑步',
            requiredMinutes: 45,
            deadline: ScheduleDeadline.dateOnly(_at(0, 0)),
            priority: 1,
          ),
          ScheduleTaskDemand(
            taskId: 'd-read',
            title: '读论文',
            requiredMinutes: 120,
            priority: 3,
          ),
        ],
      );

      final first = generateSchedule(input);
      final second = generateSchedule(input);

      expect(jsonEncode(first.toJson()), jsonEncode(second.toJson()));
      expect(first.proposalId, second.proposalId);
    });

    test('排出来的块不跨自然日', () {
      final input = ScheduleInput(
        now: _at(0, 21),
        horizonStart: _at(0, 21),
        horizonEnd: _at(1, 2),
        baseVersion: 'v1',
        availability: [
          ScheduleWindow(startAt: _at(0, 22), endAt: _at(1, 2)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'short',
            title: '短任务',
            requiredMinutes: 90,
          ),
          ScheduleTaskDemand(
            taskId: 'long',
            title: '长任务',
            requiredMinutes: 180,
          ),
        ],
      );

      final proposal = generateSchedule(input);

      for (final block in proposal.blocks) {
        expect(_endsSameDay(block), isTrue);
      }
      // 180 分钟无法塞进单个自然日的剩余窗口，必须如实报未安排。
      expect(
        proposal.unplannedTasks.map((task) => task.taskId),
        contains('long'),
      );
    });
  });

  group('repairSchedule 最小扰动重排', () {
    test('插入会议只移动冲突的柔性块', () {
      final previous = ScheduleProposal(
        proposalId: 'gen-v1',
        baseVersion: 'v1',
        blocks: [
          ProposedBlock(
            taskId: 'task-a',
            title: '背单词',
            startAt: _at(0, 9),
            endAt: _at(0, 10),
          ),
          ProposedBlock(
            taskId: 'task-b',
            title: '写报告',
            startAt: _at(0, 14),
            endAt: _at(0, 15),
          ),
        ],
      );

      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v2',
        availability: [_window(0, 8, 22)],
        fixedBlocks: [
          ScheduleFixedBlock(
            ownerId: 'event-1',
            ownerType: ScheduleOwnerType.event,
            startAt: _at(0, 13, 30),
            endAt: _at(0, 15),
            title: '临时会议',
          ),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-a',
            title: '背单词',
            requiredMinutes: 60,
          ),
          ScheduleTaskDemand(
            taskId: 'task-b',
            title: '写报告',
            requiredMinutes: 60,
          ),
        ],
      );

      final repaired = repairSchedule(input, previous);

      final kept = repaired.blocks.firstWhere((b) => b.taskId == 'task-a');
      final moved = repaired.blocks.firstWhere((b) => b.taskId == 'task-b');

      expect(kept.startAt, _at(0, 9));
      expect(kept.movedFromPreviousPlan, isFalse);
      expect(moved.movedFromPreviousPlan, isTrue);
      expect(moved.minutes, 60);
      expect(_overlapsAny(moved, input.fixedBlocks), isFalse);
      expect(
        repaired.notes.map((note) => note.text).join(),
        contains('共移动 1 处安排'),
      );
    });

    test('无可排位置时返回未安排量与理由', () {
      final previous = ScheduleProposal(
        proposalId: 'gen-v1',
        baseVersion: 'v1',
        blocks: [
          ProposedBlock(
            taskId: 'task-c',
            title: '大扫除',
            startAt: _at(0, 18),
            endAt: _at(0, 20),
          ),
        ],
      );

      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 9),
        baseVersion: 'v2',
        availability: [
          ScheduleWindow(startAt: _at(0, 8), endAt: _at(0, 9)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-c',
            title: '大扫除',
            requiredMinutes: 120,
          ),
        ],
      );

      final repaired = repairSchedule(input, previous);

      expect(repaired.blocks, isEmpty);
      expect(repaired.unplannedTasks, hasLength(1));
      expect(repaired.unplannedTasks.single.remainingMinutes, 120);
      expect(
        repaired.unplannedTasks.single.reason,
        UnplannedReason.windowInsufficient,
      );
    });

    test('上一版未排进去的任务在重排时会被重新尝试', () {
      final previous = ScheduleProposal(
        proposalId: 'gen-v1',
        baseVersion: 'v1',
        unplannedTasks: [
          UnplannedTask(
            taskId: 'task-d',
            title: '预习',
            remainingMinutes: 60,
            reason: UnplannedReason.windowInsufficient,
            reasonText: '旧窗口不足',
          ),
        ],
      );

      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v2',
        availability: [_window(0, 8, 22)],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-d',
            title: '预习',
            requiredMinutes: 60,
          ),
        ],
      );

      final repaired = repairSchedule(input, previous);

      expect(repaired.blocks.map((b) => b.taskId), ['task-d']);
      expect(repaired.unplannedTasks, isEmpty);
    });
  });

  group('与 M0 v1 契约对齐', () {
    ScheduleInput mixedInput() => ScheduleInput(
      now: _at(0, 7),
      horizonStart: _at(0, 8),
      horizonEnd: _at(0, 22),
      baseVersion: 'v1',
      availability: [_window(0, 8, 22)],
      demands: [
        ScheduleTaskDemand(
          taskId: 'one-time',
          title: '提交作业',
          requiredMinutes: 60,
          taskKind: ScheduleTaskKind.oneTime,
        ),
        ScheduleTaskDemand(
          taskId: 'recurring',
          title: '背单词',
          requiredMinutes: 30,
          taskKind: ScheduleTaskKind.recurring,
        ),
      ],
    );

    test('单次事项与周期任务分别产出各自的白名单变更', () {
      final proposal = generateSchedule(mixedInput());

      expect(proposal.blocks, hasLength(2));
      expect(proposal.changes, hasLength(2));
      expect(
        proposal.changes.map((change) => change.type),
        unorderedEquals(['schedule_one_time', 'upsert_daily_override']),
      );

      final oneTime = proposal.changes.firstWhere(
        (change) => change is ScheduleOneTimeChange,
      ) as ScheduleOneTimeChange;
      expect(oneTime.taskId, 'one-time');
      expect(oneTime.plannedDate, _at(0, 0));
      expect(oneTime.scheduledAt, _at(0, 8));

      final override = proposal.changes.firstWhere(
        (change) => change is UpsertDailyOverrideChange,
      ) as UpsertDailyOverrideChange;
      expect(override.itemKind, ScheduleTaskKind.recurring);
      expect(override.itemId, 'recurring');
      expect(override.action, 'reschedule');
      expect(override.localDate, _at(0, 0));
      expect(override.plannedStartMinute, 9 * 60);
      expect(override.plannedEndMinute, 9 * 60 + 30);
      expect(override.existingOverrideId, isNull);
    });

    test('提案 JSON 字段与契约第 5.7 节一致', () {
      final json = generateSchedule(mixedInput()).toJson();

      expect(json['proposal_id'], isA<String>());
      expect(json['status'], 'draft');
      for (final key in [
        'blocks',
        'changes',
        'unplanned_tasks',
        'explanations',
      ]) {
        expect(json.containsKey(key), isTrue, reason: key);
      }

      final block = (json['blocks'] as List).first as Map<String, dynamic>;
      for (final key in [
        'block_id',
        'task_id',
        'task_kind',
        'start_at',
        'end_at',
        'source',
        'persistable_as',
        'duration_source',
        'duration_seconds',
      ]) {
        expect(block.containsKey(key), isTrue, reason: key);
      }
      expect(block['source'], 'proposal');
      expect(block['persistable_as'], 'one_time_schedule');

      final change = (json['changes'] as List).first as Map<String, dynamic>;
      expect(change['change_id'], isA<String>());
      expect(change['type'], 'schedule_one_time');
    });

    test('未显式给出可用窗口时用 preferences 逐日推导', () {
      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(1, 20),
        baseVersion: 'v1',
        preferences: const SchedulePreferences(
          dayStartMinute: 9 * 60,
          dayEndMinute: 17 * 60,
        ),
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-p',
            title: '自习',
            requiredMinutes: 60,
          ),
        ],
      );

      final proposal = generateSchedule(input);

      expect(proposal.blocks, hasLength(1));
      expect(proposal.blocks.single.startAt, _at(0, 9));
      expect(proposal.blocks.single.endAt, _at(0, 10));
    });

    test('小于最小块长度的碎片不参与排程', () {
      final input = ScheduleInput(
        now: _at(0, 7),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v1',
        preferences: const SchedulePreferences(minimumBlockMinutes: 60),
        availability: [
          ScheduleWindow(startAt: _at(0, 8), endAt: _at(0, 8, 45)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-m',
            title: '零碎任务',
            requiredMinutes: 30,
          ),
        ],
      );

      final proposal = generateSchedule(input);

      expect(proposal.blocks, isEmpty);
      expect(proposal.unplannedTasks, hasLength(1));
    });
  });

  group('冻结目标守卫', () {
    test('时长优先级：任务自带目标优先于调用方给出的时长', () {
      final input = ScheduleInput(
        now: _at(0, 8),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v1',
        availability: [
          ScheduleWindow(startAt: _at(0, 9), endAt: _at(0, 12)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-target',
            title: '练琴',
            // 调用方说 60 分钟，但任务自带目标是 30 分钟。
            requiredMinutes: 60,
            targetDurationSeconds: 1800,
            taskKind: ScheduleTaskKind.recurring,
          ),
        ],
      );

      final proposal = generateSchedule(input);
      final block = proposal.blocks.single;

      expect(block.minutes, 30);
      expect(block.durationSource, 'task_target');
      expect(
        jsonDecode(jsonEncode(proposal.toJson()))['blocks'].first['duration_seconds'],
        1800,
      );
    });

    test('周期任务同一本地日最多一个 block，且同一 (任务, 日期) 只产出一条变更', () {
      final input = ScheduleInput(
        now: _at(0, 8),
        horizonStart: _at(0, 8),
        horizonEnd: _at(2, 22),
        baseVersion: 'v1',
        availability: [
          ScheduleWindow(startAt: _at(0, 9), endAt: _at(0, 12)),
          ScheduleWindow(startAt: _at(1, 9), endAt: _at(1, 12)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'recurring-one',
            title: '每日复现练琴',
            requiredMinutes: 60,
            taskKind: ScheduleTaskKind.recurring,
          ),
        ],
      );

      final proposal = generateSchedule(input);

      final keyed = <String>{};
      for (final change in proposal.changes) {
        final json = change.toJson();
        final key = '${json['item_id'] ?? json['task_id']}@'
            '${json['local_date'] ?? json['planned_date']}';
        expect(keyed.add(key), isTrue, reason: '同一任务同一日期重复： $key');
      }
      // 本次只排首日：同一 proposal 内不会自动把同一周期任务铺开到多天。
      expect(keyed, hasLength(1));
      expect(proposal.changes.single.toJson()['change_id'], isNotNull);
    });

    test('reason_code 取值必须落在封闭枚举内', () {
      final input = ScheduleInput(
        now: _at(0, 8),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 9),
        baseVersion: 'v1',
        availability: [
          ScheduleWindow(startAt: _at(0, 8), endAt: _at(0, 8, 10)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'too-long',
            title: '放不下的任务',
            requiredMinutes: 120,
          ),
        ],
      );

      final proposal = generateSchedule(input);
      final allowed = UnplannedReason.values.map((reason) => reason.code).toSet();

      for (final task in proposal.unplannedTasks) {
        expect(allowed, contains(task.reason.code), reason: task.taskId);
      }
      expect(proposal.unplannedTasks, isNotEmpty);
    });

    test('explanations 元素结构统一，且不带额外字段', () {
      final input = ScheduleInput(
        now: _at(0, 8),
        horizonStart: _at(0, 8),
        horizonEnd: _at(0, 22),
        baseVersion: 'v1',
        // 两条硬约束互相重叠，用于产生一条解释。
        fixedBlocks: [
          ScheduleFixedBlock(
            ownerId: 'course-a',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(0, 9),
            endAt: _at(0, 10),
          ),
          ScheduleFixedBlock(
            ownerId: 'course-b',
            ownerType: ScheduleOwnerType.course,
            startAt: _at(0, 9, 30),
            endAt: _at(0, 10, 30),
          ),
        ],
        availability: [
          ScheduleWindow(startAt: _at(0, 8), endAt: _at(0, 22)),
        ],
        demands: [
          ScheduleTaskDemand(
            taskId: 'task-note',
            title: '复习',
            requiredMinutes: 30,
          ),
        ],
      );

      final proposal = generateSchedule(input);
      final json = jsonDecode(jsonEncode(proposal.toJson())) as Map<String, dynamic>;
      final explanations = json['explanations'] as List<dynamic>;

      expect(explanations, isNotEmpty);
      for (final item in explanations) {
        final map = item as Map<String, dynamic>;
        // 结构冻结：每个元素只有 task_id 与 text 两个键，缺一不可。
        expect(map.keys.toSet(), {'task_id', 'text'});
        expect(map['text'], isA<String>());
      }
    });
  });

  group('模块边界', () {
    test('调度模块不得访问数据库或任何应用层代码', () {
      for (final path in [
        'lib/features/agent_scheduler/domain/schedule_contract.dart',
        'lib/features/agent_scheduler/domain/schedule_engine.dart',
      ]) {
        // 只扫描代码：本模块的文档注释里本就会出现这些名字（用于说明"不得依赖"），
        // 若连注释一起匹配，守卫会被自己绊倒。
        final code = stripComments(File(path).readAsStringSync());
        expect(code, isNot(contains('package:drift')), reason: path);
        expect(code, isNot(contains('package:supabase')), reason: path);
        expect(code, isNot(contains('task_repository')), reason: path);
        expect(code, isNot(contains('app_database')), reason: path);
        expect(code, isNot(contains('DateTime.now()')), reason: path);
      }
    });
  });
}
