import 'package:check_d/features/tasks/domain/task_models.dart';
import 'package:check_d/features/today/domain/today_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Today timeline contains only one-offs scheduled for selected date', () {
    final today = DateTime(2026, 9, 23);
    final createdAt = DateTime(2026, 9, 20);
    final carried = _oneTime(
      id: 'carried',
      createdAt: createdAt,
      scheduledAt: DateTime(2026, 9, 22, 20),
    );
    final scheduledToday = _oneTime(
      id: 'today',
      createdAt: createdAt,
      scheduledAt: DateTime(2026, 9, 23, 14),
    );
    final flexible = _oneTime(
      id: 'flexible',
      createdAt: createdAt,
      availableFrom: DateTime(2026, 9, 21),
      deadline: TaskDeadline.dateOnly(DateTime(2026, 9, 27)),
    );

    final snapshot = TodaySnapshot(
      date: today,
      now: DateTime(2026, 9, 23, 10),
      tasks: [carried, scheduledToday, flexible],
      courses: const [],
      overrides: const [],
    );

    expect(
      snapshot.timeline.whereType<TodayTaskItem>().map((item) => item.task.id),
      ['today'],
    );
    expect(
      carried.todayStatus(today, now: snapshot.now).state,
      OneTimeTodayState.carryOver,
    );
    expect(
      flexible.todayStatus(today, now: snapshot.now).belongsInPending,
      isTrue,
    );
  });
}

TaskDetails _oneTime({
  required String id,
  required DateTime createdAt,
  DateTime? scheduledAt,
  DateTime? availableFrom,
  TaskDeadline? deadline,
}) => TaskDetails(
  id: id,
  name: id,
  kind: TaskKind.oneTime,
  colorValue: 1,
  status: TaskLifecycle.active,
  createdAt: createdAt,
  updatedAt: createdAt,
  scheduledAt: scheduledAt,
  availableFrom: availableFrom,
  deadline: deadline,
  oneTimeExecutionMode: OneTimeExecutionMode.untimed,
);
