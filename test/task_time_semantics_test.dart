import 'package:check_d/features/tasks/domain/task_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TaskTimeSemantics', () {
    test('planned date and exact schedule remain independent semantics', () {
      final planned = DateTime(2026, 9, 20, 18);
      final scheduled = DateTime(2026, 9, 20, 9, 30);

      expect(
        TaskTimeSemantics.effectivePlannedDate(plannedDate: planned),
        DateTime(2026, 9, 20),
      );
      expect(
        TaskTimeSemantics.effectivePlannedDate(
          plannedDate: planned,
          scheduledAt: scheduled,
        ),
        DateTime(2026, 9, 20),
      );
      expect(
        TaskTimeSemantics.effectivePlannedDate(scheduledAt: scheduled),
        DateTime(2026, 9, 20),
      );
    });

    test('availability begins on its calendar date', () {
      final available = DateTime(2026, 9, 20);

      expect(
        TaskTimeSemantics.isAvailableOn(
          DateTime(2026, 9, 19, 23, 59),
          availableFrom: available,
        ),
        isFalse,
      );
      expect(
        TaskTimeSemantics.isAvailableOn(
          DateTime(2026, 9, 20),
          availableFrom: available,
        ),
        isTrue,
      );
    });

    test('date-only deadline never synthesizes an end-of-day instant', () {
      final deadline = TaskDeadline.dateOnly(DateTime(2026, 9, 20, 23, 59));

      expect(deadline.date, DateTime(2026, 9, 20));
      expect(deadline.at, isNull);
      expect(
        TaskTimeSemantics.isPastDeadline(
          DateTime(2026, 9, 20, 23, 59, 59),
          deadline,
        ),
        isFalse,
      );
      expect(
        TaskTimeSemantics.isPastDeadline(DateTime(2026, 9, 21), deadline),
        isTrue,
      );
    });

    test('date-only values keep calendar components across time zones', () {
      final deadline = TaskDeadline.dateOnly(DateTime.utc(2026, 9, 21));

      expect(deadline.date, DateTime(2026, 9, 21));
      expect(deadline.date!.isUtc, isFalse);
      expect(deadline.date!.toIso8601String(), '2026-09-21T00:00:00.000');
    });

    test('exact deadline compares actual instants', () {
      final deadline = TaskDeadline.exact(DateTime.utc(2026, 9, 20, 8));

      expect(
        TaskTimeSemantics.isPastDeadline(
          DateTime.utc(2026, 9, 20, 7, 59),
          deadline,
        ),
        isFalse,
      );
      expect(
        TaskTimeSemantics.isPastDeadline(
          DateTime.utc(2026, 9, 20, 8, 1),
          deadline,
        ),
        isTrue,
      );
    });

    test('validates independent combinations and rejects contradictions', () {
      expect(
        () => TaskTimeSemantics.validate(
          availableFrom: DateTime(2026, 9, 18),
          plannedDate: DateTime(2026, 9, 19),
          scheduledAt: DateTime(2026, 9, 19, 9),
          deadline: TaskDeadline.exact(DateTime(2026, 9, 19, 10)),
        ),
        returnsNormally,
      );
      expect(
        () => TaskTimeSemantics.validate(
          plannedDate: DateTime(2026, 9, 19),
          scheduledAt: DateTime(2026, 9, 20, 9),
        ),
        throwsArgumentError,
      );
      expect(
        () => TaskTimeSemantics.validate(
          scheduledAt: DateTime(2026, 9, 19, 11),
          deadline: TaskDeadline.exact(DateTime(2026, 9, 19, 10)),
        ),
        throwsArgumentError,
      );
      expect(
        () => TaskTimeSemantics.validate(
          availableFrom: DateTime(2026, 9, 21),
          deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 20)),
        ),
        throwsArgumentError,
      );
      expect(
        () => TaskTimeSemantics.validate(
          availableFrom: DateTime(2026, 9, 21),
          plannedDate: DateTime(2026, 9, 20),
        ),
        throwsArgumentError,
      );
    });

    test('overdue recovery may keep the original past deadline', () {
      expect(
        () => TaskTimeSemantics.validate(
          plannedDate: DateTime(2026, 9, 23),
          deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 21)),
          allowPlanAfterDeadline: true,
        ),
        returnsNormally,
      );
    });

    test('copyWith updates and clears timing fields independently', () {
      final initial = OneTimeReminderDraft(
        name: '作业',
        colorValue: 1,
        availableFrom: DateTime(2026, 9, 18),
        deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 20)),
      );

      final planned = initial.copyWith(plannedDate: DateTime(2026, 9, 19));
      expect(planned.availableFrom, initial.availableFrom);
      expect(planned.deadline, same(initial.deadline));
      expect(planned.plannedDate, DateTime(2026, 9, 19));

      final cleared = planned.copyWith(deadline: null);
      expect(cleared.deadline, isNull);
      expect(cleared.plannedDate, DateTime(2026, 9, 19));
    });
  });

  group('one-time Today state', () {
    final monday = DateTime(2026, 9, 21);
    final tuesday = DateTime(2026, 9, 22);
    final wednesday = DateTime(2026, 9, 23);
    final sunday = DateTime(2026, 9, 27);

    test(
      'available flexible task remains pending without changing identity',
      () {
        final task = _oneTime(
          availableFrom: monday,
          deadline: TaskDeadline.dateOnly(sunday),
        );

        expect(
          task.todayStatus(monday, now: monday).state,
          OneTimeTodayState.pendingUnscheduled,
        );
        expect(
          task.todayStatus(tuesday, now: tuesday).state,
          OneTimeTodayState.pendingUnscheduled,
        );
        expect(task.todayStatus(monday, now: monday).isVisible, isTrue);
      },
    );

    test('planned and scheduled tasks carry over without moving fields', () {
      final planned = _oneTime(
        plannedDate: tuesday,
        deadline: TaskDeadline.dateOnly(sunday),
      );
      final scheduledAt = DateTime(2026, 9, 22, 20);
      final scheduled = _oneTime(
        scheduledAt: scheduledAt,
        deadline: TaskDeadline.dateOnly(sunday),
      );

      expect(
        planned.todayStatus(tuesday, now: tuesday).state,
        OneTimeTodayState.plannedToday,
      );
      expect(
        planned.todayStatus(wednesday, now: wednesday).state,
        OneTimeTodayState.carryOver,
      );
      expect(planned.plannedDate, tuesday);
      expect(
        scheduled.todayStatus(tuesday, now: tuesday).state,
        OneTimeTodayState.scheduledToday,
      );
      expect(
        scheduled.todayStatus(wednesday, now: wednesday).state,
        OneTimeTodayState.carryOver,
      );
      expect(scheduled.scheduledAt, scheduledAt);
    });

    test('date-only deadline is valid all day and overdue next local day', () {
      final task = _oneTime(
        availableFrom: monday,
        deadline: TaskDeadline.dateOnly(sunday),
      );

      expect(
        task.todayStatus(sunday, now: DateTime(2026, 9, 27, 23, 59, 59)).state,
        OneTimeTodayState.pendingUnscheduled,
      );
      final overdue = task.todayStatus(
        DateTime(2026, 9, 28),
        now: DateTime(2026, 9, 28),
      );
      expect(overdue.state, OneTimeTodayState.overdue);
      expect(overdue.overdueDays, 1);
    });

    test('exact deadline uses a strict after-boundary comparison', () {
      final dueAt = DateTime(2026, 9, 21, 18);
      final task = _oneTime(
        availableFrom: monday,
        deadline: TaskDeadline.exact(dueAt),
      );

      expect(
        task.todayStatus(monday, now: DateTime(2026, 9, 21, 17, 59)).state,
        OneTimeTodayState.pendingUnscheduled,
      );
      expect(
        task.todayStatus(monday, now: dueAt).state,
        OneTimeTodayState.pendingUnscheduled,
      );
      final after = task.todayStatus(monday, now: DateTime(2026, 9, 21, 18, 1));
      expect(after.state, OneTimeTodayState.overdue);
      expect(after.overdueDays, 0);
    });

    test('future availability and future plans stay hidden', () {
      final unavailable = _oneTime(availableFrom: wednesday);
      final upcoming = _oneTime(plannedDate: wednesday);

      expect(
        unavailable.todayStatus(monday, now: monday).state,
        OneTimeTodayState.notAvailable,
      );
      expect(
        unavailable.todayStatus(wednesday, now: wednesday).state,
        OneTimeTodayState.pendingUnscheduled,
      );
      expect(
        upcoming.todayStatus(monday, now: monday).state,
        OneTimeTodayState.upcoming,
      );
      expect(upcoming.todayStatus(monday, now: monday).isVisible, isFalse);
    });

    test('legacy unscheduled item is visible only on its creation day', () {
      final legacy = _oneTime(createdAt: monday);

      expect(
        legacy.todayStatus(monday, now: monday).state,
        OneTimeTodayState.pendingUnscheduled,
      );
      expect(
        legacy.todayStatus(tuesday, now: tuesday).state,
        OneTimeTodayState.legacyUnscheduled,
      );
      expect(legacy.todayStatus(tuesday, now: tuesday).isVisible, isFalse);
    });

    test('completed always wins over overdue', () {
      final task = _oneTime(
        availableFrom: monday,
        deadline: TaskDeadline.dateOnly(monday),
        completedAt: tuesday,
      );

      final status = task.todayStatus(wednesday, now: wednesday);
      expect(status.state, OneTimeTodayState.completed);
      expect(status.isVisible, isFalse);
    });
  });
}

TaskDetails _oneTime({
  DateTime? createdAt,
  DateTime? scheduledAt,
  DateTime? availableFrom,
  DateTime? plannedDate,
  TaskDeadline? deadline,
  DateTime? completedAt,
}) {
  final created = createdAt ?? DateTime(2026, 9, 20);
  return TaskDetails(
    id: 'task-1',
    name: '数据库作业',
    kind: TaskKind.oneTime,
    colorValue: 1,
    status: TaskLifecycle.active,
    createdAt: created,
    updatedAt: created,
    scheduledAt: scheduledAt,
    availableFrom: availableFrom,
    plannedDate: plannedDate,
    deadline: deadline,
    oneTimeExecutionMode: OneTimeExecutionMode.timed,
    oneTimeCompletedAt: completedAt,
  );
}
