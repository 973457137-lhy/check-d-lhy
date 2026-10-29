import 'dart:io';

import 'package:check_d/core/database/app_database.dart';
import 'package:check_d/core/sync/sync_queue_service.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late SyncQueueService queue;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    queue = SyncQueueService(database);
  });

  tearDown(() => database.close());

  test(
    'diagnostics only expose failed operations for the requested UID',
    () async {
      final own = await _failedOperation(
        database,
        userId: 'user-a',
        entityType: 'tasks',
        error: 'PostgrestException(message: private, code: 22003)',
      );
      await _failedOperation(
        database,
        userId: 'user-b',
        entityType: 'plans',
        error: 'PostgrestException(message: private, code: 42501)',
      );
      await queue.enqueue(
        entityType: 'courses',
        entityId: 'pending-course',
        operation: SyncOperationType.upsert,
        payload: const {'secret': 'must-not-appear'},
        userId: 'user-a',
      );

      final diagnostics = await queue
          .watchFailureDiagnosticsForUser('user-a')
          .first;

      expect(diagnostics, hasLength(1));
      expect(diagnostics.single.entityType, 'tasks');
      expect(diagnostics.single.errorCode, '22003');
      expect(diagnostics.single.retryCount, 3);
      expect(diagnostics.single.errorCategory, '数值超出云端字段范围');
      expect(diagnostics.single.lastFailureAt, own.updatedAt);
    },
  );

  test(
    'diagnostics redact URLs, keys, tokens, UUIDs and raw messages',
    () async {
      const secret =
          'https://secret.supabase.co apikey=secret-key '
          'Bearer secret.jwt.token user=123e4567-e89b-12d3-a456-426614174000 '
          'code=oauth-secret-value';
      await _failedOperation(
        database,
        userId: 'user-a',
        entityType: 'tasks',
        error: 'ClientException: connection reset $secret',
      );

      final item =
          (await queue.watchFailureDiagnosticsForUser('user-a').first).single;
      final visible =
          '${item.entityType} ${item.errorCategory} ${item.errorCode}';

      expect(item.errorCategory, '网络连接失败');
      expect(visible, isNot(contains('supabase.co')));
      expect(visible, isNot(contains('secret-key')));
      expect(visible, isNot(contains('secret.jwt.token')));
      expect(visible, isNot(contains('123e4567')));
      expect(visible, isNot(contains('oauth-secret-value')));
    },
  );

  test(
    'reading diagnostics never changes or clears failed operations',
    () async {
      final before = await _failedOperation(
        database,
        userId: 'user-a',
        entityType: 'plans',
        error: 'PostgrestException(code: 22003)',
      );

      await queue.watchFailureDiagnosticsForUser('user-a').first;
      final after = await (database.select(
        database.syncOperations,
      )..where((row) => row.id.equals(before.id))).getSingle();

      expect(after.status, 'failed');
      expect(after.retryCount, before.retryCount);
      expect(after.lastError, before.lastError);
      expect(after.updatedAt, before.updatedAt);
    },
  );

  test(
    'structured diagnostics retain safe stage table and error code',
    () async {
      const cases = <String, String>{
        '23502': '云端必填字段缺失',
        '23503': '云端关联数据缺失',
        '23514': '上传数据不符合云端约束',
        '42804': '云端字段类型不匹配',
        '42703': '云端字段尚未对齐',
        '42P01': '云端数据表不存在',
        '22007': '日期或时间格式不匹配',
        '22008': '日期或时间格式不匹配',
        '08006': '云端数据库连接失败',
      };
      var index = 0;
      for (final entry in cases.entries) {
        await _failedOperation(
          database,
          userId: 'user-a',
          entityType: 'tasks_$index',
          error: SyncFailureDetails(
            stage: 'upsert',
            table: 'table_$index',
            kind: 'postgrest',
            code: entry.key,
          ).encode(),
        );
        index++;
      }

      final diagnostics = await queue
          .watchFailureDiagnosticsForUser('user-a')
          .first;

      expect(diagnostics, hasLength(cases.length));
      for (final item in diagnostics) {
        expect(item.failureStage, 'upsert');
        expect(item.failureTable, startsWith('table_'));
        expect(item.errorCategory, cases[item.errorCode]);
      }
    },
  );

  test('opaque legacy errors are not assigned invented diagnostics', () async {
    await _failedOperation(
      database,
      userId: 'user-a',
      entityType: 'tasks',
      error: 'Exception: legacy opaque failure',
    );

    final item =
        (await queue.watchFailureDiagnosticsForUser('user-a').first).single;

    expect(item.failureStage, isNull);
    expect(item.failureTable, isNull);
    expect(item.errorCode, isNull);
    expect(item.errorCategory, '历史错误信息不足');
  });

  test('color bigint migration is guarded and non-destructive', () {
    final sql = File(
      'supabase/migrations/202610080001_stage_14e_sync_color_bigint.sql',
    ).readAsStringSync();

    expect(RegExp("table_name = 'tasks'").allMatches(sql), hasLength(1));
    expect(RegExp("table_name = 'plans'").allMatches(sql), hasLength(1));
    expect(RegExp("data_type = 'integer'").allMatches(sql), hasLength(2));
    expect(
      RegExp('alter column color type bigint').allMatches(sql),
      hasLength(2),
    );
    expect(sql, isNot(contains('drop table')));
    expect(sql, isNot(contains('drop column')));
    expect(sql, isNot(contains('delete from')));
    expect(sql, isNot(contains('truncate')));
  });
}

Future<SyncOperation> _failedOperation(
  AppDatabase database, {
  required String userId,
  required String entityType,
  required String error,
}) async {
  final now = DateTime.utc(2026, 10, 8, 10);
  final id = '$userId-$entityType-${now.microsecondsSinceEpoch}';
  await database
      .into(database.syncOperations)
      .insert(
        SyncOperationsCompanion.insert(
          id: id,
          userId: Value(userId),
          entityType: entityType,
          entityId: '$entityType-id',
          operation: SyncOperationType.upsert.name,
          payloadJson: '{}',
          status: const Value('failed'),
          retryCount: const Value(3),
          lastError: Value(error),
          createdAt: now,
          updatedAt: now,
        ),
      );
  return (database.select(
    database.syncOperations,
  )..where((row) => row.id.equals(id))).getSingle();
}
