import 'package:check_d/app/app_providers.dart';
import 'package:check_d/core/database/app_database.dart';
import 'package:check_d/core/sync/sync_providers.dart';
import 'package:check_d/core/sync/sync_queue_service.dart';
import 'package:check_d/features/profile/presentation/my_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('My exposes Account & Sync with readable status', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          supabaseClientProvider.overrideWithValue(null),
          syncFailureDiagnosticsProvider.overrideWith(
            (ref) => Stream.value([
              SyncFailureDiagnostic(
                entityType: 'tasks',
                retryCount: 7,
                errorCategory: '上传数据不符合云端约束',
                errorCode: '23514',
                failureStage: 'upsert',
                failureTable: 'long_term_tasks',
                lastFailureAt: DateTime.utc(2026, 10, 9, 8, 30),
              ),
            ]),
          ),
        ],
        child: const MaterialApp(home: MyPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('账号与同步'), findsOneWidget);
    await tester.ensureVisible(find.text('账号与同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账号与同步'));
    await tester.pumpAndSettle();

    expect(find.text('当前账号'), findsOneWidget);
    expect(find.text('等待同步'), findsOneWidget);
    expect(find.text('立即同步'), findsOneWidget);
    expect(find.text('同步诊断（开发）'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('同步诊断（开发）'));
    await tester.tap(find.text('同步诊断（开发）'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('失败操作：tasks'), findsOneWidget);
    expect(find.text('失败阶段：写入云端'), findsOneWidget);
    expect(find.text('失败表名：long_term_tasks'), findsOneWidget);
    expect(find.text('错误代码：23514'), findsOneWidget);
    expect(find.text('错误类别：上传数据不符合云端约束'), findsOneWidget);
    expect(find.textContaining('已重试 7 次'), findsOneWidget);
  });
}
