import 'package:check_d/app/app.dart';
import 'package:check_d/core/sync/sync_account_service.dart';
import 'package:check_d/core/sync/sync_download_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('first restore keeps the authenticated shell gated', (
    tester,
  ) async {
    await _pumpGate(
      tester,
      const SyncAccountState(
        phase: SyncAccountPhase.restoring,
        userId: 'redacted-user',
        stage: SyncAccountStage.reading,
      ),
    );

    expect(find.text('正在恢复云端数据…'), findsOneWidget);
    expect(find.text('account-local-shell'), findsNothing);
  });

  testWidgets('completed restore checkpoint exposes only the supplied shell', (
    tester,
  ) async {
    await _pumpGate(
      tester,
      const SyncAccountState(
        phase: SyncAccountPhase.syncing,
        userId: 'redacted-user',
        initialRestoreComplete: true,
        stage: SyncAccountStage.upload,
      ),
    );

    expect(find.text('account-local-shell'), findsOneWidget);
    expect(find.text('正在恢复云端数据…'), findsNothing);
  });

  testWidgets('restore failure shows sanitized stage and retry action', (
    tester,
  ) async {
    await _pumpGate(
      tester,
      const SyncAccountState(
        phase: SyncAccountPhase.failed,
        userId: 'must-not-appear',
        message: '读取云端数据超时，请检查网络后重试。',
        stage: SyncAccountStage.reading,
        restoreTable: 'tasks',
        restoreErrorCategory: SyncRestoreErrorCategory.timeout,
        restoreSafeCode: 'timeout',
      ),
    );

    expect(find.textContaining('阶段：读取云端数据'), findsOneWidget);
    expect(find.textContaining('数据表：tasks'), findsOneWidget);
    expect(find.textContaining('原因：请求超时'), findsOneWidget);
    expect(find.text('重新尝试'), findsOneWidget);
    expect(find.textContaining('must-not-appear'), findsNothing);
    expect(find.textContaining('timeout', findRichText: true), findsNothing);
  });
}

Future<void> _pumpGate(WidgetTester tester, SyncAccountState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncAccountStatusProvider.overrideWith(
          () => _FixedStatusController(state),
        ),
      ],
      child: const MaterialApp(
        home: AuthenticatedSyncGate(shell: Text('account-local-shell')),
      ),
    ),
  );
  await tester.pump();
}

class _FixedStatusController extends SyncAccountStatusController {
  _FixedStatusController(this.value);

  final SyncAccountState value;

  @override
  SyncAccountState build() => value;
}
