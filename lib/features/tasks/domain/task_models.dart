enum TaskKind { recurring, oneTime }

enum TaskLifecycle { active, paused, archived }

enum RecurringExecutionMode { timed, untimed }

enum OneTimeExecutionMode { timed, untimed }

enum TimerSessionStatus { running, paused, finished }

/// A task's current timer state. Finished sessions remain in history, while
/// this value describes only the timer controls currently available.
enum TimerStatus { idle, running, paused }

enum CompletionStatus { pending, completed }

enum SchedulePreset { daily, weekdays, weekends, custom }

enum OneTimeTodayState {
  completed,
  notAvailable,
  overdue,
  scheduledToday,
  plannedToday,
  carryOver,
  pendingUnscheduled,
  upcoming,
  legacyUnscheduled,
}

class OneTimeTodayStatus {
  const OneTimeTodayStatus(this.state, {this.overdueDays = 0});

  final OneTimeTodayState state;
  final int overdueDays;

  bool get isVisible => switch (state) {
    OneTimeTodayState.overdue ||
    OneTimeTodayState.scheduledToday ||
    OneTimeTodayState.plannedToday ||
    OneTimeTodayState.carryOver ||
    OneTimeTodayState.pendingUnscheduled => true,
    _ => false,
  };

  bool get belongsInTimeline => state == OneTimeTodayState.scheduledToday;
  bool get belongsInPending => isVisible && !belongsInTimeline;
}

class TaskDeadline {
  const TaskDeadline._({this.date, this.at})
    : assert((date == null) != (at == null));

  factory TaskDeadline.dateOnly(DateTime value) =>
      TaskDeadline._(date: DateTime(value.year, value.month, value.day));

  factory TaskDeadline.exact(DateTime value) => TaskDeadline._(at: value);

  final DateTime? date;
  final DateTime? at;

  bool get isDateOnly => date != null;
  bool get hasTime => at != null;
  DateTime get localDate => dateOnly(date ?? at!.toLocal());
}

abstract final class TaskTimeSemantics {
  static DateTime? effectivePlannedDate({
    DateTime? plannedDate,
    DateTime? scheduledAt,
  }) {
    if (scheduledAt != null) return dateOnly(scheduledAt.toLocal());
    return plannedDate == null ? null : dateOnly(plannedDate);
  }

  static bool isAvailableOn(DateTime date, {DateTime? availableFrom}) {
    return availableFrom == null ||
        !dateOnly(date).isBefore(dateOnly(availableFrom));
  }

  static bool isPastDeadline(DateTime now, TaskDeadline? deadline) {
    if (deadline == null) return false;
    if (deadline.isDateOnly) {
      return dateOnly(now).isAfter(deadline.date!);
    }
    return now.toUtc().isAfter(deadline.at!.toUtc());
  }

  static OneTimeTodayStatus todayStatus({
    required TaskDetails task,
    required DateTime date,
    required DateTime now,
  }) {
    assert(task.kind == TaskKind.oneTime);
    final day = dateOnly(date);
    final createdDay = dateOnly(task.createdAt.toLocal());
    if (task.isCompleted) {
      return const OneTimeTodayStatus(OneTimeTodayState.completed);
    }
    if (task.availableFrom != null &&
        day.isBefore(dateOnly(task.availableFrom!))) {
      return const OneTimeTodayStatus(OneTimeTodayState.notAvailable);
    }
    if (_isPastDeadlineOn(day, now, task.deadline)) {
      return OneTimeTodayStatus(
        OneTimeTodayState.overdue,
        overdueDays: _overdueDays(day, task.deadline!),
      );
    }

    final planned = task.effectivePlannedDate;
    if (planned != null) {
      final plannedDay = dateOnly(planned);
      if (plannedDay == day) {
        return OneTimeTodayStatus(
          task.scheduledAt == null
              ? OneTimeTodayState.plannedToday
              : OneTimeTodayState.scheduledToday,
        );
      }
      if (plannedDay.isBefore(day)) {
        return const OneTimeTodayStatus(OneTimeTodayState.carryOver);
      }
      return const OneTimeTodayStatus(OneTimeTodayState.upcoming);
    }

    if (task.availableFrom == null && day.isBefore(createdDay)) {
      return const OneTimeTodayStatus(OneTimeTodayState.notAvailable);
    }
    if (task.availableFrom != null || task.deadline != null) {
      return const OneTimeTodayStatus(OneTimeTodayState.pendingUnscheduled);
    }
    if (day == createdDay) {
      return const OneTimeTodayStatus(OneTimeTodayState.pendingUnscheduled);
    }
    return const OneTimeTodayStatus(OneTimeTodayState.legacyUnscheduled);
  }

  static bool _isPastDeadlineOn(
    DateTime day,
    DateTime now,
    TaskDeadline? deadline,
  ) {
    if (deadline == null) return false;
    if (deadline.isDateOnly) return day.isAfter(deadline.date!);

    final dueAt = deadline.at!;
    final dueDay = dateOnly(dueAt.toLocal());
    if (day.isBefore(dueDay)) return false;
    if (day.isAfter(dueDay)) return true;
    final today = dateOnly(now.toLocal());
    if (day == today) return now.toUtc().isAfter(dueAt.toUtc());
    return day.isBefore(today);
  }

  static int _overdueDays(DateTime day, TaskDeadline deadline) {
    final dueDay = deadline.localDate;
    return day.difference(dueDay).inDays.clamp(0, 1 << 31);
  }

  static void validate({
    DateTime? availableFrom,
    DateTime? plannedDate,
    DateTime? scheduledAt,
    TaskDeadline? deadline,
    bool allowPlanAfterDeadline = false,
  }) {
    final normalizedPlanned = plannedDate == null
        ? null
        : dateOnly(plannedDate);
    final scheduledDate = scheduledAt == null
        ? null
        : dateOnly(scheduledAt.toLocal());
    if (normalizedPlanned != null &&
        scheduledDate != null &&
        normalizedPlanned != scheduledDate) {
      throw ArgumentError('计划日期必须与具体时间为同一天。');
    }
    if (availableFrom != null &&
        normalizedPlanned != null &&
        normalizedPlanned.isBefore(dateOnly(availableFrom))) {
      throw ArgumentError('计划日期不能早于可开始日期。');
    }
    if (deadline == null) return;

    final deadlineDate = deadline.localDate;
    if (availableFrom != null &&
        dateOnly(availableFrom).isAfter(deadlineDate)) {
      throw ArgumentError('可开始日期不能晚于截止日期。');
    }
    if (!allowPlanAfterDeadline &&
        normalizedPlanned != null &&
        normalizedPlanned.isAfter(deadlineDate)) {
      throw ArgumentError('当前计划时间晚于截止时间，请先调整计划时间。');
    }
    if (!allowPlanAfterDeadline && scheduledAt != null) {
      final exceedsDeadline = deadline.isDateOnly
          ? scheduledDate!.isAfter(deadlineDate)
          : scheduledAt.toUtc().isAfter(deadline.at!.toUtc());
      if (exceedsDeadline) {
        throw ArgumentError('当前计划时间晚于截止时间，请先调整计划时间。');
      }
    }
  }

  static bool sameDeadline(TaskDeadline? first, TaskDeadline? second) {
    if (identical(first, second)) return true;
    if (first == null ||
        second == null ||
        first.isDateOnly != second.isDateOnly) {
      return false;
    }
    return first.isDateOnly
        ? first.date == second.date
        : first.at!.toUtc() == second.at!.toUtc();
  }
}

abstract final class WeekdayMask {
  static const everyDay = 0x7F;
  static const weekdays = 0x1F;
  static const weekends = 0x60;

  static int fromDays(Iterable<int> weekdays) {
    return weekdays.fold(0, (mask, day) => mask | (1 << (day - 1)));
  }

  static Set<int> toDays(int mask) {
    return {
      for (var day = DateTime.monday; day <= DateTime.sunday; day++)
        if (mask & (1 << (day - 1)) != 0) day,
    };
  }

  static bool contains(int mask, int weekday) {
    return mask & (1 << (weekday - 1)) != 0;
  }
}

class TaskScheduleRule {
  const TaskScheduleRule({
    required this.preset,
    required this.weekdaysMask,
    required this.startsOn,
    this.endsOn,
  });

  final SchedulePreset preset;
  final int weekdaysMask;
  final DateTime startsOn;
  final DateTime? endsOn;

  bool isDueOn(DateTime date) {
    final day = dateOnly(date);
    if (day.isBefore(dateOnly(startsOn))) return false;
    if (endsOn != null && day.isAfter(dateOnly(endsOn!))) return false;
    return WeekdayMask.contains(weekdaysMask, day.weekday);
  }
}

class RecurringTaskDraft {
  final String? tagId;
  const RecurringTaskDraft({
    this.tagId,
    required this.name,
    required this.colorValue,
    this.iconName = 'target',
    required this.executionMode,
    required this.schedulePreset,
    required this.weekdays,
    required this.startsOn,
    required this.holidayPause,
    this.notes,
    this.targetDurationSeconds,
    this.targetDays,
    this.endsOn,
    this.scheduledMinuteOfDay,
    this.reminderMinuteOfDay,
  });

  final String name;
  final int colorValue;
  final String iconName;
  final String? notes;
  final RecurringExecutionMode executionMode;
  final int? targetDurationSeconds;
  final int? targetDays;
  final SchedulePreset schedulePreset;
  final Set<int> weekdays;
  final DateTime startsOn;
  final DateTime? endsOn;
  final int? scheduledMinuteOfDay;
  final int? reminderMinuteOfDay;
  final bool holidayPause;
}

class OneTimeReminderDraft {
  final String? tagId;
  const OneTimeReminderDraft({
    this.tagId,
    required this.name,
    required this.colorValue,
    this.iconName = 'event',
    this.scheduledAt,
    this.availableFrom,
    this.plannedDate,
    this.deadline,
    this.executionMode = OneTimeExecutionMode.untimed,
    this.remindBeforeMinutes,
    this.notes,
  });

  factory OneTimeReminderDraft.fromTask(TaskDetails task) {
    if (task.kind != TaskKind.oneTime) {
      throw ArgumentError('只能从单次事项创建编辑草稿。');
    }
    return OneTimeReminderDraft(
      tagId: task.tagId,
      name: task.name,
      colorValue: task.colorValue,
      iconName: task.iconName,
      scheduledAt: task.scheduledAt,
      availableFrom: task.availableFrom,
      plannedDate: task.plannedDate,
      deadline: task.deadline,
      executionMode: task.oneTimeExecutionMode ?? OneTimeExecutionMode.untimed,
      remindBeforeMinutes: task.remindBeforeMinutes,
      notes: task.notes,
    );
  }

  final String name;
  final int colorValue;
  final String iconName;
  final DateTime? scheduledAt;
  final DateTime? availableFrom;
  final DateTime? plannedDate;
  final TaskDeadline? deadline;
  final OneTimeExecutionMode executionMode;
  final int? remindBeforeMinutes;
  final String? notes;

  OneTimeReminderDraft copyWith({
    Object? tagId = _unchangedTaskField,
    String? name,
    int? colorValue,
    String? iconName,
    Object? scheduledAt = _unchangedTaskField,
    Object? availableFrom = _unchangedTaskField,
    Object? plannedDate = _unchangedTaskField,
    Object? deadline = _unchangedTaskField,
    OneTimeExecutionMode? executionMode,
    Object? remindBeforeMinutes = _unchangedTaskField,
    Object? notes = _unchangedTaskField,
  }) {
    return OneTimeReminderDraft(
      tagId: identical(tagId, _unchangedTaskField)
          ? this.tagId
          : tagId as String?,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      iconName: iconName ?? this.iconName,
      scheduledAt: identical(scheduledAt, _unchangedTaskField)
          ? this.scheduledAt
          : scheduledAt as DateTime?,
      availableFrom: identical(availableFrom, _unchangedTaskField)
          ? this.availableFrom
          : availableFrom as DateTime?,
      plannedDate: identical(plannedDate, _unchangedTaskField)
          ? this.plannedDate
          : plannedDate as DateTime?,
      deadline: identical(deadline, _unchangedTaskField)
          ? this.deadline
          : deadline as TaskDeadline?,
      executionMode: executionMode ?? this.executionMode,
      remindBeforeMinutes: identical(remindBeforeMinutes, _unchangedTaskField)
          ? this.remindBeforeMinutes
          : remindBeforeMinutes as int?,
      notes: identical(notes, _unchangedTaskField)
          ? this.notes
          : notes as String?,
    );
  }
}

const Object _unchangedTaskField = Object();

class TaskDetails {
  final String? tagId;
  const TaskDetails({
    this.tagId,
    required this.id,
    required this.name,
    required this.kind,
    required this.colorValue,
    this.iconName = 'target',
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.notes,
    this.recurringMode,
    this.targetDurationSeconds,
    this.targetDays,
    this.holidayPause = false,
    this.scheduledMinuteOfDay,
    this.reminderMinuteOfDay,
    this.schedule,
    this.scheduledAt,
    this.availableFrom,
    this.plannedDate,
    this.deadline,
    this.remindBeforeMinutes,
    this.oneTimeExecutionMode,
    this.oneTimeCompletedAt,
    this.todayProgressPercent = 0,
    this.todayActualDurationSeconds = 0,
    this.todayCompleted = false,
    this.todayTargetReached = false,
  });

  final String id;
  final String name;
  final TaskKind kind;
  final int colorValue;
  final String iconName;
  final TaskLifecycle status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? notes;
  final RecurringExecutionMode? recurringMode;
  final int? targetDurationSeconds;
  final int? targetDays;
  final bool holidayPause;
  final int? scheduledMinuteOfDay;
  final int? reminderMinuteOfDay;
  final TaskScheduleRule? schedule;
  final DateTime? scheduledAt;
  final DateTime? availableFrom;
  final DateTime? plannedDate;
  final TaskDeadline? deadline;
  final int? remindBeforeMinutes;
  final OneTimeExecutionMode? oneTimeExecutionMode;
  final DateTime? oneTimeCompletedAt;
  final double todayProgressPercent;
  final int todayActualDurationSeconds;
  final bool todayCompleted;
  final bool todayTargetReached;

  bool get hasTimer =>
      recurringMode == RecurringExecutionMode.timed ||
      oneTimeExecutionMode == OneTimeExecutionMode.timed;

  bool get hasDurationTarget => targetDurationSeconds != null;

  DateTime? get effectivePlannedDate => TaskTimeSemantics.effectivePlannedDate(
    plannedDate: plannedDate,
    scheduledAt: scheduledAt,
  );

  bool get hasDeadline => deadline != null;
  bool get deadlineIsDateOnly => deadline?.isDateOnly ?? false;

  bool isAvailableOn(DateTime date) =>
      TaskTimeSemantics.isAvailableOn(date, availableFrom: availableFrom);

  bool isPastDeadline(DateTime now) =>
      TaskTimeSemantics.isPastDeadline(now, deadline);

  OneTimeTodayStatus todayStatus(DateTime date, {required DateTime now}) =>
      TaskTimeSemantics.todayStatus(task: this, date: date, now: now);

  bool get isCompleted =>
      kind == TaskKind.oneTime ? oneTimeCompletedAt != null : todayCompleted;

  CompletionStatus get completionStatus =>
      isCompleted ? CompletionStatus.completed : CompletionStatus.pending;
}

class TimerSessionEntry {
  const TimerSessionEntry({
    required this.id,
    required this.taskId,
    required this.startedAt,
    required this.logicalDate,
    required this.durationSeconds,
    required this.status,
    this.endedAt,
  });

  final String id;
  final String taskId;
  final DateTime startedAt;
  final String? logicalDate;
  final DateTime? endedAt;
  final int durationSeconds;
  final TimerSessionStatus status;

  int elapsedSecondsAt(DateTime now) {
    if (status != TimerSessionStatus.running || endedAt != null) {
      return durationSeconds;
    }
    return now.difference(startedAt).inSeconds.clamp(0, 1 << 31);
  }
}

class TaskTimerState {
  const TaskTimerState({required this.sessions, required this.localDate});

  final List<TimerSessionEntry> sessions;
  final DateTime localDate;

  TimerSessionEntry? get latest => sessions.isEmpty ? null : sessions.first;
  bool get isRunning => latest?.status == TimerSessionStatus.running;
  bool get isPaused => latest?.status == TimerSessionStatus.paused;
  bool get canStart => !isRunning && !isPaused;
  TimerStatus get timerStatus => isRunning
      ? TimerStatus.running
      : isPaused
      ? TimerStatus.paused
      : TimerStatus.idle;

  int totalElapsedSecondsAt(DateTime now) => sessions.fold(
    0,
    (total, session) => total + session.elapsedSecondsAt(now),
  );

  int elapsedSecondsAt(DateTime now) {
    final dayStart = dateOnly(localDate);
    final dayEnd = dayStart.add(const Duration(days: 1));
    var total = 0;
    for (final session in sessions) {
      final end = session.status == TimerSessionStatus.running
          ? now
          : session.endedAt ?? session.startedAt;
      final overlapStart = session.startedAt.isAfter(dayStart)
          ? session.startedAt
          : dayStart;
      final overlapEnd = end.isBefore(dayEnd) ? end : dayEnd;
      if (overlapEnd.isAfter(overlapStart)) {
        total += overlapEnd.difference(overlapStart).inSeconds;
      }
    }
    return total;
  }

  double progressAt(DateTime now, int targetDurationSeconds) {
    if (targetDurationSeconds <= 0) return 0;
    return (elapsedSecondsAt(now) / targetDurationSeconds * 100).clamp(0, 100);
  }
}

class CompletionHistoryEntry {
  const CompletionHistoryEntry({
    required this.localDate,
    required this.progressPercent,
    required this.isSuccess,
    required this.actualDurationSeconds,
    required this.targetReached,
    this.completedAt,
  });

  final String localDate;
  final double progressPercent;
  final bool isSuccess;
  final int actualDurationSeconds;
  final bool targetReached;
  final DateTime? completedAt;
}

class CalendarDayData {
  const CalendarDayData({
    required this.date,
    required this.tasks,
    this.recordedTimedSeconds,
  });

  final DateTime date;
  final List<TaskDetails> tasks;
  final int? recordedTimedSeconds;

  int get scheduledCount => tasks.length;
  int get completedCount => tasks.where((task) => task.isCompleted).length;
  int get timedSeconds =>
      recordedTimedSeconds ??
      tasks.fold(0, (total, task) => total + task.todayActualDurationSeconds);
  double get completionPercent {
    if (tasks.isEmpty) return 0;
    return completedCount / tasks.length * 100;
  }
}

class CalendarMonthData {
  CalendarMonthData({
    required this.month,
    required Iterable<CalendarDayData> days,
  }) : days = {for (final day in days) localDateKey(day.date): day};

  final DateTime month;
  final Map<String, CalendarDayData> days;

  CalendarDayData day(DateTime date) {
    return days[localDateKey(date)] ??
        CalendarDayData(date: dateOnly(date), tasks: const []);
  }
}

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String localDateKey(DateTime value) {
  final date = dateOnly(value);
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String formatDuration(int totalSeconds) {
  final safeSeconds = totalSeconds.clamp(0, 1 << 31);
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  final seconds = safeSeconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
