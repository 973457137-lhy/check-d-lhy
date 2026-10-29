import 'package:check_d/core/database/app_database.dart';
import 'package:check_d/core/sync/sync_queue_service.dart';
import 'package:check_d/features/tasks/data/task_repository.dart';
import 'package:check_d/features/tasks/domain/task_models.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late TaskRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TaskRepository(
      database: database,
      syncQueue: SyncQueueService(database),
      userId: 'user-1',
    );
  });

  tearDown(() => database.close());

  test('creates both task types for today', () async {
    final day = DateTime(2026, 9, 2);
    await repository.saveRecurringTask(_untimedDraft(day));
    await repository.saveOneTimeReminder(
      OneTimeReminderDraft(
        name: '项目会议',
        colorValue: 0xFFE69545,
        scheduledAt: DateTime(2026, 9, 2, 14),
        remindBeforeMinutes: 30,
      ),
    );

    final tasks = await repository.watchTasksForDate(day).first;

    expect(tasks, hasLength(2));
    expect(tasks.map((task) => task.name), containsAll(['英语听力', '项目会议']));
    expect(tasks.map((task) => task.kind), {
      TaskKind.recurring,
      TaskKind.oneTime,
    });
  });

  test('untimed one-off stays on its own calendar date', () async {
    final sep18 = DateTime(2026, 9, 18);
    final taskId = await repository.saveOneTimeReminder(
      OneTimeReminderDraft(
        name: '时间未定事项',
        colorValue: 0xFFE69545,
        executionMode: OneTimeExecutionMode.untimed,
      ),
    );

    final stored = await repository.getTask(taskId);
    expect(stored, isNotNull);

    // The current no-date form stores the item's ownership day as its
    // creation day; use a direct local row update to model Sep 18 precisely.
    await (database.update(database.localTasks)
          ..where((row) => row.id.equals(taskId)))
        .write(LocalTasksCompanion(createdAt: Value(sep18)));

    expect(await repository.watchTasksForDate(sep18).first, hasLength(1));
    expect(
      await repository
          .watchTasksForDate(sep18.add(const Duration(days: 1)))
          .first,
      isEmpty,
    );
  });

  test(
    'flexible one-off stays visible across days as one stored task',
    () async {
      final monday = DateTime(2026, 9, 21);
      final sunday = DateTime(2026, 9, 27);
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '数据库作业',
          colorValue: 1,
          availableFrom: monday,
          deadline: TaskDeadline.dateOnly(sunday),
        ),
      );

      final mondayTasks = await repository.watchTasksForDate(monday).first;
      final tuesdayTasks = await repository
          .watchTasksForDate(monday.add(const Duration(days: 1)))
          .first;
      expect(mondayTasks.single.id, taskId);
      expect(tuesdayTasks.single.id, taskId);
      expect(await database.select(database.localTasks).get(), hasLength(1));

      final calendar = await repository.watchCalendarMonth(monday).first;
      expect(calendar.day(monday).tasks, isEmpty);
      expect(calendar.day(monday.add(const Duration(days: 1))).tasks, isEmpty);
    },
  );

  test('planned and scheduled carry-over preserves original values', () async {
    final tuesday = DateTime(2026, 9, 22);
    final wednesday = DateTime(2026, 9, 23);
    final plannedId = await repository.saveOneTimeReminder(
      OneTimeReminderDraft(
        name: '论文',
        colorValue: 1,
        plannedDate: tuesday,
        deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 27)),
      ),
    );
    final scheduledAt = DateTime(2026, 9, 22, 20);
    final scheduledId = await repository.saveOneTimeReminder(
      OneTimeReminderDraft(
        name: '小组会议',
        colorValue: 1,
        scheduledAt: scheduledAt,
        deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 27)),
      ),
    );

    final tasks = await repository.watchTasksForDate(wednesday).first;
    expect(tasks.map((task) => task.id), containsAll([plannedId, scheduledId]));
    final planned = tasks.singleWhere((task) => task.id == plannedId);
    final scheduled = tasks.singleWhere((task) => task.id == scheduledId);
    expect(
      planned.todayStatus(wednesday, now: wednesday).state,
      OneTimeTodayState.carryOver,
    );
    expect(planned.plannedDate, tuesday);
    expect(
      scheduled.todayStatus(wednesday, now: wednesday).state,
      OneTimeTodayState.carryOver,
    );
    expect(scheduled.scheduledAt, scheduledAt);
  });

  test('future availability hides task until the available day', () async {
    final wednesday = DateTime(2026, 9, 23);
    final taskId = await repository.saveOneTimeReminder(
      OneTimeReminderDraft(
        name: '实验报告',
        colorValue: 1,
        availableFrom: wednesday,
      ),
    );

    expect(
      await repository
          .watchTasksForDate(wednesday.subtract(const Duration(days: 1)))
          .first,
      isEmpty,
    );
    expect(
      (await repository.watchTasksForDate(wednesday).first).single.id,
      taskId,
    );
  });

  test(
    'undo completion restores overdue state without moving deadline',
    () async {
      final due = DateTime(2026, 9, 21);
      final later = DateTime(2026, 9, 23);
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '逾期作业',
          colorValue: 1,
          availableFrom: due,
          deadline: TaskDeadline.dateOnly(due),
        ),
      );

      await repository.toggleOneTimeCompletion(taskId);
      expect(await repository.watchTasksForDate(later).first, isEmpty);
      await repository.toggleOneTimeCompletion(taskId);
      final restored = (await repository.watchTasksForDate(later).first).single;
      expect(
        restored.todayStatus(later, now: later).state,
        OneTimeTodayState.overdue,
      );
      expect(restored.deadline!.date, due);
    },
  );

  test('untimed completion toggles without deleting history', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(_untimedDraft(day));

    await repository.toggleRecurringCompletion(taskId, day);
    expect((await repository.getTask(taskId, date: day))!.isCompleted, isTrue);

    await repository.toggleRecurringCompletion(taskId, day);
    final task = await repository.getTask(taskId, date: day);
    final completions = await database
        .select(database.taskCompletionRecords)
        .get();

    expect(task!.isCompleted, isFalse);
    expect(completions, hasLength(1));
    expect(completions.single.progressPercent, 0);
    expect(completions.single.isSuccess, isFalse);
  });

  test('custom schedule only returns tasks on selected weekdays', () async {
    final monday = DateTime(2026, 8, 31);
    final tuesday = DateTime(2026, 9, 1);
    await repository.saveRecurringTask(
      RecurringTaskDraft(
        name: '周一阅读',
        colorValue: 0xFF3D73E8,
        executionMode: RecurringExecutionMode.untimed,
        schedulePreset: SchedulePreset.custom,
        weekdays: const {DateTime.monday},
        startsOn: monday,
        holidayPause: false,
      ),
    );

    expect(await repository.watchTasksForDate(monday).first, hasLength(1));
    expect(await repository.watchTasksForDate(tuesday).first, isEmpty);
  });

  test('editing keeps task identity and adds a revision', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(_untimedDraft(day));

    await repository.saveRecurringTask(
      RecurringTaskDraft(
        name: '英语精听',
        colorValue: 0xFF45A77A,
        executionMode: RecurringExecutionMode.untimed,
        targetDays: 100,
        schedulePreset: SchedulePreset.weekdays,
        weekdays: const {
          DateTime.monday,
          DateTime.tuesday,
          DateTime.wednesday,
          DateTime.thursday,
          DateTime.friday,
        },
        startsOn: day,
        holidayPause: false,
      ),
      taskId: taskId,
    );

    final tasks = await database.select(database.localTasks).get();
    final revisions = await database.select(database.taskRevisionRecords).get();
    expect(tasks, hasLength(1));
    expect(tasks.single.id, taskId);
    expect(tasks.single.name, '英语精听');
    expect(revisions, hasLength(2));
  });

  test('one-time completion and undo are preserved as revisions', () async {
    final taskId = await repository.saveOneTimeReminder(
      OneTimeReminderDraft(
        name: '体检',
        colorValue: 0xFFD96060,
        scheduledAt: DateTime(2026, 9, 2, 9),
      ),
    );

    await repository.toggleOneTimeCompletion(taskId);
    expect((await repository.getTask(taskId))!.isCompleted, isTrue);
    await repository.toggleOneTimeCompletion(taskId);

    expect((await repository.getTask(taskId))!.isCompleted, isFalse);
    final revisions = await database.select(database.taskRevisionRecords).get();
    expect(revisions, hasLength(3));
  });

  test(
    'one-time scheduling and deadline fields round-trip independently',
    () async {
      final initial = OneTimeReminderDraft(
        name: '论文初稿',
        colorValue: 0xFFE69545,
        availableFrom: DateTime(2026, 9, 18),
        plannedDate: DateTime(2026, 9, 19),
        deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 20)),
        executionMode: OneTimeExecutionMode.timed,
      );
      final taskId = await repository.saveOneTimeReminder(initial);

      var task = await repository.getTask(taskId);
      expect(task!.availableFrom, DateTime(2026, 9, 18));
      expect(task.plannedDate, DateTime(2026, 9, 19));
      expect(task.scheduledAt, isNull);
      expect(task.deadline!.date, DateTime(2026, 9, 20));
      expect(task.deadline!.at, isNull);

      await repository.saveOneTimeReminder(
        initial.copyWith(
          scheduledAt: DateTime(2026, 9, 19, 14, 30),
          deadline: TaskDeadline.exact(DateTime(2026, 9, 19, 18)),
        ),
        taskId: taskId,
      );
      task = await repository.getTask(taskId);
      expect(task!.availableFrom, DateTime(2026, 9, 18));
      expect(task.plannedDate, DateTime(2026, 9, 19));
      expect(task.scheduledAt, DateTime(2026, 9, 19, 14, 30));
      expect(task.deadline!.date, isNull);
      expect(task.deadline!.at, DateTime(2026, 9, 19, 18));
    },
  );

  test(
    'one-time completion preserves scheduling and deadline fields',
    () async {
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '申请材料',
          colorValue: 0xFFE69545,
          plannedDate: DateTime(2026, 9, 19),
          deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 20)),
        ),
      );

      await repository.toggleOneTimeCompletion(taskId);
      final completed = await repository.getTask(taskId);
      expect(completed!.isCompleted, isTrue);
      expect(completed.plannedDate, DateTime(2026, 9, 19));
      expect(completed.deadline!.date, DateTime(2026, 9, 20));

      await repository.toggleOneTimeCompletion(taskId);
      final reopened = await repository.getTask(taskId);
      expect(reopened!.isCompleted, isFalse);
      expect(reopened.plannedDate, DateTime(2026, 9, 19));
      expect(reopened.deadline!.date, DateTime(2026, 9, 20));
    },
  );

  test('contradictory one-time timing fields are rejected', () async {
    await expectLater(
      repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '冲突事项',
          colorValue: 1,
          plannedDate: DateTime(2026, 9, 19),
          scheduledAt: DateTime(2026, 9, 20, 10),
        ),
      ),
      throwsArgumentError,
    );
    expect(await database.select(database.localTasks).get(), isEmpty);
  });

  test(
    'calendar projects a planned one-time item on exactly one day',
    () async {
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '论文初稿',
          colorValue: 1,
          availableFrom: DateTime(2026, 9, 18),
          plannedDate: DateTime(2026, 9, 19),
          deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 20)),
        ),
      );

      final month = await repository
          .watchCalendarMonth(DateTime(2026, 9))
          .first;
      expect(month.day(DateTime(2026, 9, 18)).tasks, isEmpty);
      expect(month.day(DateTime(2026, 9, 19)).tasks.single.id, taskId);
      expect(month.day(DateTime(2026, 9, 20)).tasks, isEmpty);
    },
  );

  test('archive hides task and preserves revisions', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(_untimedDraft(day));

    await repository.archiveTask(taskId);

    expect(await repository.watchTasksForDate(day).first, isEmpty);
    expect(
      await repository.watchTasksByStatus(TaskLifecycle.archived).first,
      hasLength(1),
    );
    final revisions = await database.select(database.taskRevisionRecords).get();
    expect(revisions, hasLength(2));
    final task = await (database.select(
      database.localTasks,
    )..where((row) => row.id.equals(taskId))).getSingle();
    expect(task.status, TaskLifecycle.archived.name);
  });

  test('running timer derives elapsed time from its start timestamp', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(_timerDraft(day));

    await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 10));
    final timer = await repository.watchTimerState(taskId, day).first;

    expect(timer.isRunning, isTrue);
    expect(timer.elapsedSecondsAt(DateTime(2026, 9, 2, 10, 7)), 420);
  });

  test('reaching the duration target does not complete the task', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(_timerDraft(day));

    await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 10));
    await repository.pauseTimer(taskId, now: DateTime(2026, 9, 2, 10, 4));
    expect(
      (await repository.watchTimerState(taskId, day).first).isPaused,
      isTrue,
    );
    await repository.resumeTimer(taskId, now: DateTime(2026, 9, 2, 10, 10));
    await repository.endTimer(taskId, now: DateTime(2026, 9, 2, 10, 16));

    final timer = await repository.watchTimerState(taskId, day).first;
    final completion = await database
        .select(database.taskCompletionRecords)
        .getSingle();
    expect(timer.canStart, isTrue);
    expect(timer.sessions, hasLength(2));
    expect(timer.elapsedSecondsAt(DateTime(2026, 9, 2, 11)), 600);
    expect(completion.actualDurationSeconds, 600);
    expect(completion.progressPercent, 100);
    expect(completion.targetReached, isTrue);
    expect(completion.isSuccess, isFalse);
    expect((await repository.getTask(taskId, date: day))!.isCompleted, isFalse);

    await repository.toggleRecurringCompletion(taskId, day);

    expect((await repository.getTask(taskId, date: day))!.isCompleted, isTrue);
  });

  test(
    'completion is independent from running and paused timer sessions',
    () async {
      final day = DateTime(2026, 9, 2);
      final taskId = await repository.saveRecurringTask(_timerDraft(day));

      await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 10));
      await repository.toggleRecurringCompletion(taskId, day);

      expect(
        (await repository.watchTimerState(taskId, day).first).isRunning,
        isTrue,
      );
      expect(
        (await repository.getTask(taskId, date: day))!.isCompleted,
        isTrue,
      );

      await repository.toggleRecurringCompletion(taskId, day);
      await repository.pauseTimer(taskId, now: DateTime(2026, 9, 2, 10, 5));
      await repository.toggleRecurringCompletion(taskId, day);

      expect(
        (await repository.watchTimerState(taskId, day).first).isPaused,
        isTrue,
      );
      expect(
        (await repository.getTask(taskId, date: day))!.isCompleted,
        isTrue,
      );
    },
  );

  test('partial timer duration is retained as proportional progress', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(_timerDraft(day));

    await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 8));
    await repository.endTimer(taskId, now: DateTime(2026, 9, 2, 8, 5));

    final completion = await database
        .select(database.taskCompletionRecords)
        .getSingle();
    expect(completion.actualDurationSeconds, 300);
    expect(completion.progressPercent, 50);
    expect(completion.targetReached, isFalse);
    expect(completion.isSuccess, isFalse);
  });

  test('timed recurring task without a target records time only', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(
      RecurringTaskDraft(
        name: '整理资料',
        colorValue: 0xFF3D73E8,
        executionMode: RecurringExecutionMode.timed,
        schedulePreset: SchedulePreset.daily,
        weekdays: WeekdayMask.toDays(WeekdayMask.everyDay),
        startsOn: day,
        holidayPause: false,
      ),
    );

    await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 9));
    await repository.endTimer(taskId, now: DateTime(2026, 9, 2, 9, 12));

    final task = await repository.getTask(taskId, date: day);
    final completion = await database
        .select(database.taskCompletionRecords)
        .getSingle();
    expect(task!.hasDurationTarget, isFalse);
    expect(task.todayActualDurationSeconds, 720);
    expect(task.todayTargetReached, isFalse);
    expect(task.completionStatus, CompletionStatus.pending);
    expect(completion.progressPercent, 0);
    expect(completion.isSuccess, isFalse);
  });

  test('blank task names are rejected by the data layer', () async {
    final day = DateTime(2026, 9, 2);
    await expectLater(
      repository.saveRecurringTask(
        RecurringTaskDraft(
          name: '   ',
          colorValue: 0xFF3D73E8,
          executionMode: RecurringExecutionMode.untimed,
          schedulePreset: SchedulePreset.daily,
          weekdays: WeekdayMask.toDays(WeekdayMask.everyDay),
          startsOn: day,
          holidayPause: false,
        ),
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '   ',
          colorValue: 0xFF3D73E8,
          scheduledAt: day,
        ),
      ),
      throwsArgumentError,
    );
  });

  test(
    'timer crossing midnight remains on its logical occurrence day',
    () async {
      final firstDay = DateTime(2026, 9, 2);
      final taskId = await repository.saveRecurringTask(_timerDraft(firstDay));

      await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 23, 55));
      await repository.endTimer(taskId, now: DateTime(2026, 9, 3, 0, 10));

      final completions = await (database.select(
        database.taskCompletionRecords,
      )..orderBy([(row) => OrderingTerm.asc(row.localDate)])).get();
      expect(completions, hasLength(1));
      expect(completions[0].localDate, '2026-09-02');
      expect(completions[0].actualDurationSeconds, 900);
    },
  );

  test('invalid timer transitions are rejected', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(_timerDraft(day));

    await expectLater(
      repository.pauseTimer(taskId, now: day),
      throwsStateError,
    );
    await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 9));
    await expectLater(
      repository.startTimer(taskId, now: DateTime(2026, 9, 2, 9, 1)),
      throwsStateError,
    );
  });

  test(
    'different tasks can run in parallel while one task stays unique',
    () async {
      final day = DateTime(2026, 9, 2);
      final firstId = await repository.saveRecurringTask(_timerDraft(day));
      final secondId = await repository.saveRecurringTask(
        RecurringTaskDraft(
          name: '运动',
          colorValue: 0xFF45A77A,
          executionMode: RecurringExecutionMode.timed,
          targetDurationSeconds: 1200,
          schedulePreset: SchedulePreset.daily,
          weekdays: WeekdayMask.toDays(WeekdayMask.everyDay),
          startsOn: day,
          holidayPause: false,
        ),
      );

      await repository.startTimer(firstId, now: DateTime(2026, 9, 2, 9));
      await repository.startTimer(secondId, now: DateTime(2026, 9, 2, 9, 1));

      var unfinished = await repository.getUnfinishedTimers();
      expect(unfinished, hasLength(2));
      expect(
        unfinished.where((timer) => timer.status == TimerSessionStatus.running),
        hasLength(2),
      );
      await expectLater(
        repository.startTimer(firstId, now: DateTime(2026, 9, 2, 9, 2)),
        throwsStateError,
      );

      await repository.pauseTimer(firstId, now: DateTime(2026, 9, 2, 9, 5));
      unfinished = await repository.getUnfinishedTimers();
      expect(
        unfinished.singleWhere((timer) => timer.taskId == firstId).status,
        TimerSessionStatus.paused,
      );
      expect(
        unfinished.singleWhere((timer) => timer.taskId == secondId).status,
        TimerSessionStatus.running,
      );

      await repository.endTimer(secondId, now: DateTime(2026, 9, 2, 9, 10));
      expect(await repository.getUnfinishedTimers(), hasLength(1));
      await repository.resumeTimer(firstId, now: DateTime(2026, 9, 2, 9, 12));
      await repository.endTimer(firstId, now: DateTime(2026, 9, 2, 9, 15));
      expect(await repository.getUnfinishedTimers(), isEmpty);
    },
  );

  test('archiving a running timer closes its active session', () async {
    final now = DateTime.now();
    final taskId = await repository.saveRecurringTask(
      _timerDraft(dateOnly(now)),
    );
    await repository.startTimer(
      taskId,
      now: now.subtract(const Duration(minutes: 2)),
    );

    await expectLater(
      () => repository.archiveTask(taskId),
      throwsA(isA<StateError>()),
    );
    await repository.archiveTask(taskId, endUnfinishedTimer: true);

    final session = await database
        .select(database.timerSessionRecords)
        .getSingle();
    expect(session.state, TimerSessionStatus.finished.name);
    expect(session.endedAt, isNotNull);
    expect(session.durationSeconds, greaterThanOrEqualTo(120));
  });

  test(
    'a recurring timer crossing midnight belongs to its start date',
    () async {
      final taskId = await repository.saveRecurringTask(
        _timerDraft(DateTime(2026, 9, 2)),
      );

      await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 23, 50));
      await repository.endTimer(taskId, now: DateTime(2026, 9, 3, 0, 20));

      final startedDay = await repository.getTask(
        taskId,
        date: DateTime(2026, 9, 2),
      );
      final nextDay = await repository.getTask(
        taskId,
        date: DateTime(2026, 9, 3),
      );
      expect(startedDay!.todayActualDurationSeconds, 30 * 60);
      expect(nextDay!.todayActualDurationSeconds, 0);

      final completions = await database
          .select(database.taskCompletionRecords)
          .get();
      expect(completions.map((item) => item.localDate), [
        localDateKey(DateTime(2026, 9, 2)),
      ]);
    },
  );

  test('calendar month combines partial timers and completed tasks', () async {
    final day = DateTime(2026, 9, 2);
    final simpleId = await repository.saveRecurringTask(_untimedDraft(day));
    final timerId = await repository.saveRecurringTask(_timerDraft(day));
    final reminderId = await repository.saveOneTimeReminder(
      OneTimeReminderDraft(
        name: '项目会议',
        colorValue: 0xFFE69545,
        scheduledAt: DateTime(2026, 9, 2, 14),
      ),
    );
    await repository.toggleRecurringCompletion(simpleId, day);
    await repository.startTimer(timerId, now: DateTime(2026, 9, 2, 8));
    await repository.endTimer(timerId, now: DateTime(2026, 9, 2, 8, 5));
    await repository.toggleOneTimeCompletion(reminderId);

    final month = await repository.watchCalendarMonth(day).first;
    final details = month.day(day);

    expect(details.scheduledCount, 3);
    expect(details.completedCount, 2);
    expect(details.timedSeconds, 300);
    expect(details.completionPercent, closeTo(66.67, 0.01));
  });

  test(
    'timed task without a target records time and requires manual completion',
    () async {
      final day = DateTime(2026, 9, 2);
      final taskId = await repository.saveRecurringTask(
        RecurringTaskDraft(
          name: '写作业',
          colorValue: 0xFF3D73E8,
          executionMode: RecurringExecutionMode.timed,
          schedulePreset: SchedulePreset.daily,
          weekdays: WeekdayMask.toDays(WeekdayMask.everyDay),
          startsOn: day,
          holidayPause: false,
        ),
      );

      await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 18));
      await repository.endTimer(taskId, now: DateTime(2026, 9, 2, 18, 40));

      final completion = await database
          .select(database.taskCompletionRecords)
          .getSingle();
      expect(completion.actualDurationSeconds, 2400);
      expect(completion.targetReached, isFalse);
      expect(completion.isSuccess, isFalse);

      await repository.toggleRecurringCompletion(taskId, day);
      expect(
        (await repository.getTask(taskId, date: day))!.isCompleted,
        isTrue,
      );
    },
  );

  test(
    'timed one-time reminder shares timer without auto completion',
    () async {
      final day = DateTime(2026, 9, 2);
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '完成数据库作业',
          colorValue: 0xFFE69545,
          scheduledAt: DateTime(2026, 9, 2, 20),
          executionMode: OneTimeExecutionMode.timed,
        ),
      );

      await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 18));
      await repository.pauseTimer(taskId, now: DateTime(2026, 9, 2, 18, 40));
      await repository.resumeTimer(taskId, now: DateTime(2026, 9, 2, 19));
      await repository.endTimer(taskId, now: DateTime(2026, 9, 2, 19, 50));

      final task = await repository.getTask(taskId, date: day);
      expect(task!.hasTimer, isTrue);
      expect(task.todayActualDurationSeconds, 5400);
      expect(task.isCompleted, isFalse);
      expect(
        await database.select(database.taskCompletionRecords).get(),
        isEmpty,
      );

      await repository.toggleOneTimeCompletion(taskId);
      expect((await repository.getTask(taskId))!.isCompleted, isTrue);
    },
  );

  test('calendar excludes non-scheduled weekdays', () async {
    final monday = DateTime(2026, 8, 3);
    await repository.saveRecurringTask(
      RecurringTaskDraft(
        name: '周一阅读',
        colorValue: 0xFF3D73E8,
        executionMode: RecurringExecutionMode.untimed,
        schedulePreset: SchedulePreset.custom,
        weekdays: const {DateTime.monday},
        startsOn: monday,
        holidayPause: false,
      ),
    );

    final month = await repository.watchCalendarMonth(monday).first;

    expect(month.day(monday).scheduledCount, 1);
    expect(month.day(DateTime(2026, 8, 4)).scheduledCount, 0);
  });

  test('time on a future reminder counts on the day it was spent', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveOneTimeReminder(
      OneTimeReminderDraft(
        name: '未来事项',
        colorValue: 0xFF3D73E8,
        scheduledAt: DateTime(2026, 9, 5),
        executionMode: OneTimeExecutionMode.timed,
      ),
    );
    await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 10));
    await repository.endTimer(taskId, now: DateTime(2026, 9, 2, 10, 15));
    final month = await repository.watchCalendarMonth(day).first;
    expect(month.day(day).scheduledCount, 0);
    expect(month.day(day).timedSeconds, 900);
    expect(month.day(day).completedCount, 0);
    final timer = await repository.watchTimerState(null, day).first;
    expect(timer.elapsedSecondsAt(DateTime(2026, 9, 2, 11)), 900);
  });

  test('further timer sessions preserve manual completion and undo', () async {
    final day = DateTime(2026, 9, 2);
    final taskId = await repository.saveRecurringTask(_timerDraft(day));
    await repository.toggleRecurringCompletion(taskId, day);
    await repository.startTimer(taskId, now: DateTime(2026, 9, 2, 10));
    await repository.endTimer(taskId, now: DateTime(2026, 9, 2, 10, 20));
    expect((await repository.getTask(taskId, date: day))!.isCompleted, isTrue);
    await repository.toggleRecurringCompletion(taskId, day);
    final task = await repository.getTask(taskId, date: day);
    expect(task!.isCompleted, isFalse);
    expect(task.todayTargetReached, isTrue);
    expect(task.todayActualDurationSeconds, 1200);
  });

  test('calendar retains an archived task on its historical dates', () async {
    final today = dateOnly(DateTime.now());
    final taskId = await repository.saveRecurringTask(_untimedDraft(today));
    await repository.toggleRecurringCompletion(taskId, today);
    await repository.archiveTask(taskId);

    final month = await repository.watchCalendarMonth(today).first;

    expect(month.day(today).tasks.single.id, taskId);
    expect(month.day(today).tasks.single.isCompleted, isTrue);
  });

  test(
    'date-only reschedule clears old exact time and preserves deadline',
    () async {
      final base = DateTime(DateTime.now().year + 1, 5, 10);
      final deadline = TaskDeadline.dateOnly(base.add(const Duration(days: 5)));
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '数据库作业',
          colorValue: 1,
          scheduledAt: DateTime(base.year, base.month, base.day, 20),
          plannedDate: base,
          deadline: deadline,
        ),
      );

      final nextDay = base.add(const Duration(days: 1));
      await repository.planOneTimeTask(taskId, nextDay);
      final task = await repository.getTask(taskId);

      expect(task!.id, taskId);
      expect(task.plannedDate, nextDay);
      expect(task.scheduledAt, isNull);
      expect(task.deadline!.date, deadline.date);
    },
  );

  test(
    'exact scheduling stays consistent and cancel keeps task facts',
    () async {
      final day = DateTime(DateTime.now().year + 1, 6, 12);
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '实验报告',
          colorValue: 1,
          availableFrom: day.subtract(const Duration(days: 2)),
          deadline: TaskDeadline.dateOnly(day.add(const Duration(days: 4))),
          executionMode: OneTimeExecutionMode.timed,
        ),
      );
      final scheduledAt = DateTime(day.year, day.month, day.day, 18, 30);

      await repository.scheduleOneTimeTask(taskId, scheduledAt);
      var task = await repository.getTask(taskId);
      expect(task!.plannedDate, dateOnly(scheduledAt));
      expect(task.scheduledAt, scheduledAt);
      expect(
        await database.select(database.reminderRuleRecords).get(),
        isEmpty,
      );

      await repository.cancelOneTimeSchedule(taskId);
      task = await repository.getTask(taskId);
      expect(task!.plannedDate, isNull);
      expect(task.scheduledAt, isNull);
      expect(task.availableFrom, day.subtract(const Duration(days: 2)));
      expect(task.deadline!.date, day.add(const Duration(days: 4)));
    },
  );

  test(
    'deadline supports both shapes and removal without 23:59 sentinel',
    () async {
      final day = DateTime(DateTime.now().year + 1, 7, 20);
      final taskId = await repository.saveOneTimeReminder(
        const OneTimeReminderDraft(name: '申请材料', colorValue: 1),
      );

      await repository.updateOneTimeDeadline(
        taskId,
        TaskDeadline.dateOnly(day),
      );
      var task = await repository.getTask(taskId);
      expect(task!.deadline!.date, day);
      expect(task.deadline!.at, isNull);

      final exact = DateTime(day.year, day.month, day.day, 18);
      await repository.updateOneTimeDeadline(taskId, TaskDeadline.exact(exact));
      task = await repository.getTask(taskId);
      expect(task!.deadline!.date, isNull);
      expect(task.deadline!.at, exact);

      await repository.updateOneTimeDeadline(
        taskId,
        TaskDeadline.dateOnly(day),
      );
      expect((await repository.getTask(taskId))!.deadline!.at, isNull);
      await repository.updateOneTimeDeadline(taskId, null);
      expect((await repository.getTask(taskId))!.deadline, isNull);
    },
  );

  test(
    'new deadline conflict and availability conflict are rejected',
    () async {
      final today = dateOnly(DateTime.now());
      final planned = today.add(const Duration(days: 5));
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(name: '论文答辩', colorValue: 1, plannedDate: planned),
      );

      await expectLater(
        repository.updateOneTimeDeadline(
          taskId,
          TaskDeadline.dateOnly(today.add(const Duration(days: 2))),
        ),
        throwsArgumentError,
      );
      expect((await repository.getTask(taskId))!.deadline, isNull);
      await expectLater(
        repository.saveOneTimeReminder(
          OneTimeReminderDraft(
            name: '冲突日期',
            colorValue: 1,
            availableFrom: today.add(const Duration(days: 3)),
            plannedDate: today.add(const Duration(days: 2)),
          ),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'overdue task can be planned for recovery and remains overdue',
    () async {
      final today = dateOnly(DateTime.now());
      final deadline = today.subtract(const Duration(days: 1));
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(
          name: '逾期论文',
          colorValue: 1,
          availableFrom: deadline.subtract(const Duration(days: 2)),
          deadline: TaskDeadline.dateOnly(deadline),
        ),
      );

      final tomorrow = today.add(const Duration(days: 1));
      await repository.planOneTimeTask(taskId, tomorrow);
      final task = await repository.getTask(taskId);
      expect(task!.plannedDate, tomorrow);
      expect(task.deadline!.date, deadline);
      expect(
        task.todayStatus(today, now: DateTime.now()).state,
        OneTimeTodayState.overdue,
      );
    },
  );

  test(
    'reschedule moves one Calendar occurrence without copying task',
    () async {
      final first = DateTime(DateTime.now().year + 1, 8, 10);
      final second = first.add(const Duration(days: 1));
      final taskId = await repository.saveOneTimeReminder(
        OneTimeReminderDraft(name: '小组展示', colorValue: 1, plannedDate: first),
      );
      await repository.planOneTimeTask(taskId, second);

      final month = await repository.watchCalendarMonth(first).first;
      expect(month.day(first).tasks, isEmpty);
      expect(month.day(second).tasks.single.id, taskId);
      expect(await database.select(database.localTasks).get(), hasLength(1));
    },
  );
}

RecurringTaskDraft _untimedDraft(DateTime startsOn) {
  return RecurringTaskDraft(
    name: '英语听力',
    colorValue: 0xFF3D73E8,
    executionMode: RecurringExecutionMode.untimed,
    targetDays: 365,
    schedulePreset: SchedulePreset.daily,
    weekdays: const {
      DateTime.monday,
      DateTime.tuesday,
      DateTime.wednesday,
      DateTime.thursday,
      DateTime.friday,
      DateTime.saturday,
      DateTime.sunday,
    },
    startsOn: startsOn,
    holidayPause: true,
  );
}

RecurringTaskDraft _timerDraft(DateTime startsOn) {
  return RecurringTaskDraft(
    name: '英语听力',
    colorValue: 0xFF3D73E8,
    executionMode: RecurringExecutionMode.timed,
    targetDurationSeconds: 600,
    targetDays: 365,
    schedulePreset: SchedulePreset.daily,
    weekdays: const {
      DateTime.monday,
      DateTime.tuesday,
      DateTime.wednesday,
      DateTime.thursday,
      DateTime.friday,
      DateTime.saturday,
      DateTime.sunday,
    },
    startsOn: startsOn,
    holidayPause: true,
  );
}
