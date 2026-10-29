import 'package:check_d/core/database/app_database.dart';
import 'package:check_d/core/sync/sync_bootstrap_service.dart';
import 'package:check_d/core/sync/sync_download_service.dart';
import 'package:check_d/core/sync/sync_queue_service.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const userId = 'user-1';
  late AppDatabase database;
  late SyncQueueService queue;
  late SyncBootstrapService bootstrap;
  late OfflineDataMergeService merge;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    queue = SyncQueueService(database);
    bootstrap = SyncBootstrapService(database, queue);
    merge = OfflineDataMergeService(database, queue);
  });

  tearDown(() => database.close());

  test(
    'historical authenticated entity without outbox is bootstrapped once',
    () async {
      await _insertTask(database, id: 'historical', owner: userId);

      final first = await bootstrap.bootstrap(userId);
      final second = await bootstrap.bootstrap(userId);

      expect(first.operationsCreated, 1);
      expect(second.alreadyCompleted, isTrue);
      final operations = await database.select(database.syncOperations).get();
      expect(operations, hasLength(1));
      expect(operations.single.entityType, 'tasks');
      expect(operations.single.entityId, 'historical');
    },
  );

  test(
    'bootstrap failure rolls back operations and does not write marker',
    () async {
      await _insertTask(database, id: 'historical', owner: userId);
      await database
          .into(database.appSettings)
          .insert(
            AppSettingsCompanion.insert(
              key: 'reminder-defaults:$userId',
              value: '{invalid-json',
              updatedAt: DateTime.utc(2030),
            ),
          );

      await expectLater(bootstrap.bootstrap(userId), throwsFormatException);

      expect(await database.select(database.syncOperations).get(), isEmpty);
      final markers = await database
          .customSelect(
            "SELECT key FROM app_settings WHERE key LIKE 'sync-bootstrap:%'",
          )
          .get();
      expect(markers, isEmpty);
    },
  );

  test('offline data is never automatically bootstrapped', () async {
    await _insertTask(database, id: 'offline-task', owner: offlineDataOwner);

    final result = await bootstrap.bootstrap(offlineDataOwner);

    expect(result.operationsCreated, 0);
    expect(await database.select(database.syncOperations).get(), isEmpty);
    expect(
      (await database.select(database.localTasks).getSingle()).userId,
      offlineDataOwner,
    );
  });

  test('deferring offline data leaves owner and rows unchanged', () async {
    await _insertTask(database, id: 'offline-task', owner: offlineDataOwner);

    final summary = await merge.summary();

    expect(summary.tasks, 1);
    expect(
      (await database.select(database.localTasks).getSingle()).userId,
      offlineDataOwner,
    );
    expect(await database.select(database.syncOperations).get(), isEmpty);
  });

  test(
    'offline merge preserves ids, changes owner, and creates outbox',
    () async {
      await _insertTask(database, id: 'offline-task', owner: offlineDataOwner);
      await _insertLongTermGraph(database, 'offline-task', offlineDataOwner);

      final result = await merge.mergeInto(userId);

      expect(result.operationsCreated, 1);
      final task = await database.select(database.localTasks).getSingle();
      expect(task.id, 'offline-task');
      expect(task.userId, userId);
      expect(
        (await database.select(database.longTermTaskRecords).getSingle())
            .userId,
        userId,
      );
      final operation = await database
          .select(database.syncOperations)
          .getSingle();
      expect(operation.userId, userId);
      expect(operation.entityId, 'offline-task');
    },
  );

  test(
    'merge transaction failure leaves no partially migrated state',
    () async {
      await database
          .into(database.tagRecords)
          .insert(
            TagRecordsCompanion.insert(
              id: 'offline-tag',
              userId: offlineDataOwner,
              name: '标签',
              colorValue: 1,
              createdAt: DateTime.utc(2030),
              updatedAt: DateTime.utc(2030),
            ),
          );
      await _insertTask(database, id: 'offline-task', owner: offlineDataOwner);
      await database.customStatement(
        'CREATE TRIGGER stop_merge BEFORE UPDATE OF user_id ON local_tasks '
        "BEGIN SELECT RAISE(ABORT, 'stop merge'); END",
      );

      await expectLater(merge.mergeInto(userId), throwsA(anything));

      expect(
        (await database.select(database.tagRecords).getSingle()).userId,
        offlineDataOwner,
      );
      expect(
        (await database.select(database.localTasks).getSingle()).userId,
        offlineDataOwner,
      );
      expect(await database.select(database.syncOperations).get(), isEmpty);
    },
  );

  test('bootstrap never crosses owners between account A and B', () async {
    await _insertTask(database, id: 'task-a', owner: 'user-a');
    await _insertTask(database, id: 'task-b', owner: 'user-b');

    await bootstrap.bootstrap('user-b');

    final operations = await database.select(database.syncOperations).get();
    expect(operations, hasLength(1));
    expect(operations.single.userId, 'user-b');
    expect(operations.single.entityId, 'task-b');
  });

  test('offline merge aborts before mutation on remote id conflict', () async {
    await _insertTask(database, id: 'shared-id', owner: offlineDataOwner);
    final guardedMerge = OfflineDataMergeService(
      database,
      queue,
      remoteReader: _ConflictRemoteReader(),
    );

    await expectLater(
      guardedMerge.mergeInto(userId),
      throwsA(isA<OfflineDataConflict>()),
    );

    final task = await database.select(database.localTasks).getSingle();
    expect(task.userId, offlineDataOwner);
    expect(await database.select(database.syncOperations).get(), isEmpty);
  });
}

class _ConflictRemoteReader implements SyncRemoteReader {
  @override
  Future<List<Map<String, Object?>>> readTable(
    String table, {
    required String userId,
  }) async {
    if (table != 'tasks') return const [];
    return [
      {'id': 'shared-id', 'user_id': userId},
    ];
  }
}

Future<void> _insertTask(
  AppDatabase database, {
  required String id,
  required String owner,
}) {
  final now = DateTime.utc(2030);
  return database
      .into(database.localTasks)
      .insert(
        LocalTasksCompanion.insert(
          id: id,
          userId: Value(owner),
          name: id,
          taskType: 'recurring',
          colorValue: 1,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _insertLongTermGraph(
  AppDatabase database,
  String taskId,
  String owner,
) async {
  final now = DateTime.utc(2030);
  await database
      .into(database.longTermTaskRecords)
      .insert(
        LongTermTaskRecordsCompanion.insert(
          taskId: taskId,
          userId: owner,
          checkMode: 'timed',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await database
      .into(database.taskScheduleRecords)
      .insert(
        TaskScheduleRecordsCompanion.insert(
          id: 'schedule-$taskId',
          taskId: taskId,
          userId: owner,
          scheduleType: 'daily',
          weekdaysMask: 127,
          startsOn: '2030-01-01',
          createdAt: now,
          updatedAt: now,
        ),
      );
}
