import 'package:check_d/features/calendar/domain/calendar_occurrence_builder.dart';
import 'package:check_d/features/calendar/domain/calendar_models.dart';
import 'package:check_d/features/tasks/domain/task_models.dart';
import 'package:flutter_test/flutter_test.dart';

TaskDetails _oneOff({
  required String id,
  required DateTime createdAt,
  DateTime? scheduledAt,
  DateTime? availableFrom,
  DateTime? plannedDate,
  TaskDeadline? deadline,
  DateTime? completedAt,
}) => TaskDetails(
  id: id,
  name: id,
  kind: TaskKind.oneTime,
  colorValue: 0xFFEF8FA8,
  status: TaskLifecycle.active,
  createdAt: createdAt,
  updatedAt: createdAt,
  scheduledAt: scheduledAt,
  availableFrom: availableFrom,
  plannedDate: plannedDate,
  deadline: deadline,
  oneTimeExecutionMode: OneTimeExecutionMode.timed,
  oneTimeCompletedAt: completedAt,
);

TaskDetails _recurring(DateTime startsOn) => TaskDetails(
  id: 'recurring',
  name: '周期事项',
  kind: TaskKind.recurring,
  colorValue: 0xFF8BA9F0,
  status: TaskLifecycle.active,
  createdAt: startsOn,
  updatedAt: startsOn,
  recurringMode: RecurringExecutionMode.untimed,
  schedule: TaskScheduleRule(
    preset: SchedulePreset.daily,
    weekdaysMask: WeekdayMask.everyDay,
    startsOn: startsOn,
  ),
);

List<CalendarOccurrence> _for(DateTime date, List<TaskDetails> tasks) =>
    buildCalendarOccurrencesForDate(
      date: date,
      tasks: tasks,
      courses: const [],
      overrides: const [],
    );

void main() {
  final sep18 = DateTime(2026, 9, 18);
  final sep19 = DateTime(2026, 9, 19);
  final sep20 = DateTime(2026, 9, 20);

  test('one-off exact-time item belongs only to its own date', () {
    final item = _oneOff(
      id: 'timed-one-off',
      createdAt: sep18,
      scheduledAt: DateTime(2026, 9, 18, 14),
    );

    expect(_for(sep18, [item]), hasLength(1));
    expect(_for(sep19, [item]), isEmpty);
    expect(_for(sep20, [item]), isEmpty);
  });

  test('unplanned one-off item is not projected into Calendar', () {
    final item = _oneOff(id: 'untimed-one-off', createdAt: sep18);

    expect(_for(sep18, [item]), isEmpty);
    expect(_for(sep19, [item]), isEmpty);
    expect(_for(sep20, [item]), isEmpty);
  });

  test('planned one-off item appears once without an exact time', () {
    final item = _oneOff(
      id: 'planned-one-off',
      createdAt: sep18,
      plannedDate: sep19,
    );

    expect(_for(sep18, [item]), isEmpty);
    final occurrence = _for(sep19, [item]);
    expect(occurrence, hasLength(1));
    expect(occurrence.single.hasTime, isFalse);
    expect(_for(sep20, [item]), isEmpty);
  });

  test('availability and deadline do not create calendar occurrences', () {
    final item = _oneOff(
      id: 'bounded-one-off',
      createdAt: sep18,
      availableFrom: sep18,
      deadline: TaskDeadline.dateOnly(sep20),
    );

    expect(_for(sep18, [item]), isEmpty);
    expect(_for(sep19, [item]), isEmpty);
    expect(_for(sep20, [item]), isEmpty);
  });

  test('completed one-off does not leak to future dates', () {
    final item = _oneOff(
      id: 'completed-one-off',
      createdAt: sep18,
      plannedDate: sep18,
      completedAt: DateTime(2026, 9, 18, 18),
    );

    expect(_for(sep19, [item]), isEmpty);
    expect(_for(sep20, [item]), isEmpty);
    expect(_for(sep18, [item]), hasLength(1));
  });

  test('recurring item still projects on recurrence dates', () {
    final item = _recurring(sep18);

    expect(_for(sep18, [item]), hasLength(1));
    expect(_for(sep19, [item]), hasLength(1));
    expect(_for(sep20, [item]), hasLength(1));
  });
}
