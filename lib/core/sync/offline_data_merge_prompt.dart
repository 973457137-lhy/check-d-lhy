import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sync_account_service.dart';
import 'sync_bootstrap_service.dart';
import 'sync_providers.dart';

class OfflineDataMergePrompt extends ConsumerStatefulWidget {
  const OfflineDataMergePrompt({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<OfflineDataMergePrompt> createState() =>
      _OfflineDataMergePromptState();
}

class _OfflineDataMergePromptState
    extends ConsumerState<OfflineDataMergePrompt> {
  final Set<String> _promptedUsers = <String>{};
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<SyncAccountState>(syncAccountStatusProvider, (_, next) {
      if (next.initialRestoreComplete &&
          next.phase != SyncAccountPhase.restoring) {
        _check(next.userId);
      }
    });
    return widget.child;
  }

  Future<void> _check(String? userId) async {
    if (!mounted ||
        _checking ||
        userId == null ||
        _promptedUsers.contains(userId)) {
      return;
    }
    _checking = true;
    try {
      final summary = await ref.read(offlineDataMergeServiceProvider).summary();
      if (!mounted || summary.isEmpty) return;
      _promptedUsers.add(userId);
      final merge = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('发现此设备上有未同步的数据'),
          content: _OfflineSummary(summary: summary),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('暂不处理'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('合并到当前账号'),
            ),
          ],
        ),
      );
      if (merge != true || !mounted) return;
      try {
        await ref.read(offlineDataMergeServiceProvider).mergeInto(userId);
        ref.invalidate(offlineDataSummaryProvider);
        await ref.read(syncAccountCoordinatorProvider)?.syncNow(userId);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('本机数据已合并并进入同步队列。')));
        }
      } on OfflineDataConflict catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.message)));
        }
      } on Object {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('合并没有完成，本机原数据保持不变。')));
        }
      }
    } finally {
      _checking = false;
    }
  }
}

class _OfflineSummary extends StatelessWidget {
  const _OfflineSummary({required this.summary});

  final OfflineDataSummary summary;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('合并会保留原有 ID，并把这些本机数据归入当前账号：'),
      const SizedBox(height: 12),
      if (summary.courses > 0) Text('课程 ${summary.courses}'),
      if (summary.tasks > 0) Text('任务 ${summary.tasks}'),
      if (summary.timerSessions > 0) Text('计时记录 ${summary.timerSessions}'),
      if (summary.completions > 0) Text('完成记录 ${summary.completions}'),
      if (summary.otherRecords > 0) Text('其他关联记录 ${summary.otherRecords}'),
      const SizedBox(height: 12),
      const Text('暂不处理不会上传、删除或修改这些数据。'),
    ],
  );
}
