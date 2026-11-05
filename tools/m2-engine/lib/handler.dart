/// 纯函数式请求处理层：只吃 `(method, path, body)`，不碰 socket。
///
/// 这样 HTTP 层（`bin/serve.dart`）与自检脚本（`bin/smoke.dart`）走**同一套**逻辑，
/// 不会出现「curl 通了但脚本走另一条分支」的假通过。
library;

import 'package:check_d/features/agent_scheduler/domain/schedule_contract.dart';
import 'package:check_d/features/agent_scheduler/domain/schedule_engine.dart';

import 'contract_json.dart';
import 'validate.dart';

/// 处理结果：状态码 + JSON 体。
class HandlerResult {
  const HandlerResult(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
}

const String serviceVersion = '1.0.0';

/// 契约基准（M2 侧认定的冻结组合），仅作标识，不参与计算。
const String contractBasis = '39f7f965';

HandlerResult handleRequest(String method, String path, Object? body) {
  final route = path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;

  if (method == 'GET') {
    if (route == '/health' || route == '/') {
      return HandlerResult(200, {
        'ok': true,
        'service': 'm2-engine',
        'version': serviceVersion,
        'contract_basis': contractBasis,
        'endpoints': ['GET /health', 'POST /generate_schedule', 'POST /validate_schedule', 'POST /repair_schedule'],
        'now_source': 'request-provided（服务端/Agent 显式传 now，引擎不读系统时钟）',
      });
    }
    if (_postRoutes.contains(route)) {
      return HandlerResult(405, _error('METHOD_NOT_ALLOWED', 'method', '该端点是 POST：$route'));
    }
    return HandlerResult(404, _error('NOT_FOUND', 'path', '未知路径：$route'));
  }

  if (method != 'POST') {
    return HandlerResult(405, _error('METHOD_NOT_ALLOWED', 'method', '只接受 GET /health 与 POST 调用'));
  }

  if (body is! Map) {
    return HandlerResult(400, _error('INVALID_ARGUMENT', 'body', '请求体必须是 JSON 对象，且包含 input'));
  }
  final envelope = body.map((key, value) => MapEntry('$key', value));
  final payload = _inputOf(envelope);
  if (payload == null) {
    return HandlerResult(400, _error('INVALID_ARGUMENT', 'input', '缺少 input 对象'));
  }

  try {
    return switch (route) {
      '/generate_schedule' => _generate(payload),
      '/validate_schedule' => _validate(envelope, payload),
      '/repair_schedule' => _repair(envelope, payload),
      _ => HandlerResult(404, _error('NOT_FOUND', 'path', '未知路径：$route')),
    };
  } on ContractFormatException catch (error) {
    return HandlerResult(400, _error('INVALID_ARGUMENT', error.field, error.message));
  }
}

const Set<String> _postRoutes = <String>{'/generate_schedule', '/validate_schedule', '/repair_schedule'};

/// 取 input：优先 `{"input": {...}}`，没有壳时整包当 input。
///
/// **不能**把整包直接当 input 又不保留同级键——`proposal` / `previous` /
/// `max_shift_minutes` 是 envelope 级的兄弟键，丢了它们校验端点会静默走错分支。
Map<String, dynamic>? _inputOf(Map<String, dynamic> envelope) {
  final inner = envelope['input'];
  if (inner is Map) return inner.map((key, value) => MapEntry('$key', value));
  if (envelope.containsKey('now')) return envelope;
  return null;
}

Map<String, dynamic> _error(String code, String field, String message) => {
  'ok': false,
  'error': {'code': code, 'field': field, 'message': message},
};

HandlerResult _generate(Map<String, dynamic> payload) {
  final mapped = scheduleInputFromJson(payload);
  final proposal = generateSchedule(mapped.input);
  return HandlerResult(200, {
    'ok': true,
    'proposal': proposal.toJson(),
    'meta': {
      'blocks': proposal.blocks.length,
      'changes': proposal.changes.length,
      'unplanned_tasks': proposal.unplannedTasks.length,
      'explanations': proposal.notes.length,
      'planned_minutes': proposal.totalPlannedMinutes,
      'now_echo': _isoInstant(mapped.input.now),
      'base_version_echo': mapped.input.baseVersion,
      'availability_state': mapped.input.availability == null ? 'null' : (mapped.input.availability!.isEmpty ? 'empty' : 'explicit'),
    },
    if (mapped.warnings.isNotEmpty) 'warnings': mapped.warnings,
  });
}

HandlerResult _validate(Map<String, dynamic> envelope, Map<String, dynamic> payload) {
  final mapped = scheduleInputFromJson(payload);
  final rawProposal = envelope['proposal'];

  List<Violation> violations;
  String source;
  if (rawProposal is Map) {
    violations = validateViews(
      mapped.input,
      _blockViewsFromJson(rawProposal['blocks']),
      _changeViewsFromJson(rawProposal['changes']),
    );
    source = 'caller-supplied';
  } else {
    final proposal = generateSchedule(mapped.input);
    violations = validateProposal(mapped.input, proposal);
    source = 'engine-generated';
  }

  final byCode = <String, int>{};
  for (final violation in violations) {
    byCode[violation.code] = (byCode[violation.code] ?? 0) + 1;
  }

  return HandlerResult(200, {
    'ok': true,
    'valid': violations.isEmpty,
    'proposal_source': source,
    'violations': violations.map((violation) => violation.toJson()).toList(),
    'counts': {'total': violations.length, 'by_code': byCode},
    if (mapped.warnings.isNotEmpty) 'warnings': mapped.warnings,
  });
}

HandlerResult _repair(Map<String, dynamic> envelope, Map<String, dynamic> payload) {
  final mapped = scheduleInputFromJson(payload);
  final previousJson = envelope['previous'];
  if (previousJson is! Map) {
    return HandlerResult(
      400,
      _error('INVALID_ARGUMENT', 'previous', 'repair_schedule 需要上一版提案 JSON（previous）'),
    );
  }
  final titleByTask = {for (final demand in mapped.input.demands) demand.taskId: demand.title};
  final previous = ScheduleProposal(
    blocks: _blockViewsFromJson(previousJson['blocks'])
        .map(
          (view) => ProposedBlock(
            taskId: view.taskId,
            // 提案块的 JSON 不带 title；repair 只用时间与任务 id，故按需求表回填。
            title: titleByTask[view.taskId] ?? view.taskId,
            startAt: view.startAt,
            endAt: view.endAt,
            taskKind: view.taskKindCode == 'one_time' ? ScheduleTaskKind.oneTime : ScheduleTaskKind.recurring,
          ),
        )
        .toList(),
  );
  final maxShift = envelope['max_shift_minutes'];
  final proposal = repairSchedule(
    mapped.input,
    previous,
    maxShiftMinutes: maxShift is int ? maxShift : null,
  );
  return HandlerResult(200, {
    'ok': true,
    'proposal': proposal.toJson(),
    'meta': {
      'blocks': proposal.blocks.length,
      'changes': proposal.changes.length,
      'unplanned_tasks': proposal.unplannedTasks.length,
      'explanations': proposal.notes.length,
      'max_shift_minutes': maxShift is int ? maxShift : null,
    },
    if (mapped.warnings.isNotEmpty) 'warnings': mapped.warnings,
  });
}

List<BlockView> _blockViewsFromJson(Object? raw) {
  if (raw is! List) return const [];
  final result = <BlockView>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) {
      throw ContractFormatException('proposal.blocks[$i]', '必须是 JSON 对象');
    }
    final taskId = '${item['task_id'] ?? ''}';
    if (taskId.isEmpty) {
      throw ContractFormatException('proposal.blocks[$i].task_id', '必须是非空字符串');
    }
    final start = DateTime.tryParse('${item['start_at'] ?? ''}');
    final end = DateTime.tryParse('${item['end_at'] ?? ''}');
    if (start == null || end == null) {
      throw ContractFormatException(
        'proposal.blocks[$i]',
        'start_at / end_at 必须是带偏移的 ISO 8601 字符串',
      );
    }
    result.add(
      BlockView(
        taskId: taskId,
        blockId: '${item['block_id'] ?? 'blk-$taskId'}',
        taskKindCode: '${item['task_kind'] ?? 'recurring'}',
        // 与 input 同样归一到上海墙面时间，否则校验时的日界与截止比较会错一天。
        startAt: toShanghaiWallClock(start),
        endAt: toShanghaiWallClock(end),
      ),
    );
  }
  return result;
}

List<ChangeView> _changeViewsFromJson(Object? raw) {
  if (raw is! List) return const [];
  final result = <ChangeView>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) {
      throw ContractFormatException('proposal.changes[$i]', '必须是 JSON 对象');
    }
    final taskId = '${item['task_id'] ?? item['item_id'] ?? ''}';
    final changeId = '${item['change_id'] ?? ''}';
    if (taskId.isEmpty || changeId.isEmpty) {
      throw ContractFormatException(
        'proposal.changes[$i]',
        '必须同时带 task_id（或 item_id）与 change_id',
      );
    }
    result.add(ChangeView(taskId: taskId, changeId: changeId));
  }
  return result;
}

String _isoInstant(DateTime value) {
  final shanghai = value.toUtc().add(const Duration(hours: 8));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${shanghai.year.toString().padLeft(4, '0')}-${two(shanghai.month)}-${two(shanghai.day)}'
      'T${two(shanghai.hour)}:${two(shanghai.minute)}:${two(shanghai.second)}+08:00';
}
