import 'package:check_d/app/app.dart';
import 'package:check_d/app/app_providers.dart';
import 'package:check_d/core/config/app_config.dart';
import 'package:check_d/core/database/app_database.dart';
import 'package:check_d/features/tasks/application/task_providers.dart';
import 'package:check_d/features/tasks/domain/task_models.dart';
import 'package:check_d/features/tasks/presentation/one_time_reminder_form_page.dart';
import 'package:check_d/features/tasks/presentation/task_icon_picker.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('zh_CN'));

  testWidgets('creates an untimed recurring task from the add entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(supabaseUrl: '', supabaseAnonKey: ''),
          ),
          appDatabaseProvider.overrideWithValue(database),
          supabaseClientProvider.overrideWithValue(null),
          tasksForDateProvider.overrideWith(
            (ref, date) => Stream.value(const <TaskDetails>[]),
          ),
          dailyTimerStateProvider.overrideWith(
            (ref, date) => Stream.value(
              TaskTimerState(sessions: const [], localDate: date),
            ),
          ),
        ],
        child: const CheckDApp(),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '离线体验'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '周期任务'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '晨间整理');
    await tester.tap(find.byTooltip('阅读'));
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('今日总结'), findsOneWidget);
    final tasks = await database.select(database.localTasks).get();
    expect(tasks.single.name, '晨间整理');
    expect(tasks.single.taskType, TaskKind.recurring.name);
    expect(tasks.single.iconName, TaskIconKey.book);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('one-off form exposes flexible dates and deadline creation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(supabaseUrl: '', supabaseAnonKey: ''),
          ),
          appDatabaseProvider.overrideWithValue(database),
          supabaseClientProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: OneTimeReminderFormPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('可开始日期'), findsOneWidget);
    expect(find.text('安排执行日期'), findsOneWidget);
    expect(find.text('截止时间'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '周末数据库作业');
    await tester.tap(find.widgetWithText(SwitchListTile, '可开始日期'));
    final deadlineSwitch = find.widgetWithText(SwitchListTile, '截止时间');
    await tester.ensureVisible(deadlineSwitch);
    await tester.tap(deadlineSwitch);
    await tester.pumpAndSettle();
    expect(find.textContaining('选择可开始日期'), findsOneWidget);
    expect(find.textContaining('选择截止日期'), findsOneWidget);
    expect(find.text('指定截止时间'), findsOneWidget);

    final saveButton = find.widgetWithText(TextButton, '保存');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    final reminder = await database
        .select(database.oneTimeReminderRecords)
        .getSingle();
    expect(reminder.availableFrom, isNotNull);
    expect(reminder.plannedDate, isNull);
    expect(reminder.hasScheduledDate, isFalse);
    expect(reminder.dueDate, isNotNull);
    expect(reminder.dueAt, isNull);
    expect(tester.takeException(), isNull);
  });
}
