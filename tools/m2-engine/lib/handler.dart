// 纯函数式请求处理层：只吃 `(method, path, body)`，不碰 socket。
//
// 这样 HTTP 层（`bin/serve.dart`）与自检脚本（`bin/smoke.dart`）走**同一套**逻辑，
// 不会出现「curl 通了但脚本走另一条分支」的假通过。

import 'dart:convert';
import '../../../lib/features/agent_scheduler/domain/schedule_contract.dart';
import '../../../lib/features/agent_scheduler/domain/schedule_engine.dart';

import 'contract_json.dart';
import 'validate.dart';

/// 处理结果：状态码 + JSON 体。
class HandlerResult {
  const HandlerResult(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
}

const String serviceVersion = '1.0.0';

/// 语义版本戳：**只要引擎行为变了就必须改这一行**。
///
/// 起因是一次真实误判：M3 拿一个早已启动、从未重启的 8787 进程做验收，
/// 那个进程加载的是修复前的代码，于是她得出「M2 对 c5 与 P0 零修复」并上报 M0。
/// `dart run` 不会热重载，进程启动那一刻的代码就是它永远的行为，但 `/health` 当时
/// 不暴露任何版本信息，双方都无法自证「你打的是哪一版」。
///
/// 约定：`semantics` 里每个布尔值对应一条**已被测过**的行为；改了行为就改它，
/// 并同步 [serviceVersion]。这样任何人 `curl /health` 就能判断该进程是否含某项修复。
const String semanticsStamp = 'm2-engine/2026-11-06T05:15Z';

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
        'semantics_stamp': semanticsStamp,
        'contract_basis': contractBasis,
        'endpoints': ['GET /health', 'POST /generate_schedule', 'POST /validate_schedule', 'POST /repair_schedule'],
        'now_source': 'request-provided（服务端/Agent 显式传 now，引擎不读系统时钟）',
        // 行为开关表：用来判断「你打到的这个进程」有没有某项修复。
        // 全为 true 才等于当前 head 的行为；有 false 说明进程是旧代码，必须重启再验收。
        'semantics': <String, bool>{
          'overdue_prefilter': true, // P0-1：逾期任务不进 blocks
          'overdue_reason_codes': true, // P0-3：UNSCHEDULABLE_OVERDUE / INSUFFICIENT_TIME_BEFORE_DEADLINE
          'unplanned_four_fields': true, // P0-3：reason_code/reason_message/basis/suggested_actions
          'action_assign_reschedule': true, // P1-1：首次指派 assign、改期 reschedule
          'multi_day_gate': true, // P1-1：未授权只落最早一天
          'ordering_reason_priority_state': true, // P1-2/P1-3
          'generator_self_validates': true, // 自产提案回喂校验器必须 valid
          'error_body_always_retryable': true, // 所有错误体恒带 retryable
          'unknown_input_keys_warned': true, // 未知 input 键进 warnings
          'starts_clamped_to_now': true, // 块起点不得早于 now
        },
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
    switch (route) {
      case '/generate_schedule':
        return _generate(payload);
      case '/validate_schedule':
        return _validate(envelope, payload);
      case '/repair_schedule':
        return _repair(envelope, payload);
      default:
        return HandlerResult(404, _error('NOT_FOUND', 'path', '未知路径：$route'));
    }
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

/// 构造统一错误体。
///
/// 必须**唯一**：只要有一处错误体是手搓的，就会出现「有的错误有 retryable、有的没有」，
/// 调用方按 `.error.retryable` 读就会在某些分支上拿到 null 甚至崩溃。
Map<String, dynamic> _error(String code, String field, String message, {bool retryable = false}) =>
    errorBody(code: code, field: field, message: message, retryable: retryable);

/// 对外公开的错误体构造（HTTP 层的 JSON 解析失败等分支也复用它，不得另写一份）。
Map<String, dynamic> errorBody({
  required String code,
  required String field,
  required String message,
  bool retryable = false,
}) =>
    {
      'ok': false,
      'error': {
        'code': code,
        'field': field,
        'message': message,
        // 调用方要能机器判定能否重试（M3 F-1）：4xx 一律不可重试，5xx 才可重试。
        'retryable': retryable,
      },
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
    final blocks = _blockViewsFromJson(rawProposal['blocks']);

    // 契约 §5.6：「每个 block 的 start_at 与 end_at 必须属于同一个上海本地日，不能跨午夜」。
    // 违反属**结构错误**，按 §5.8 走 `PROPOSAL_INVALID`（422），不进 violations。
    //
    // 判定采用**半开区间**语义：允许 end_at **恰等于**次日 00:00:00
    // （即 23:00–24:00 这种"排到当天结束"），只有真正越过零点才拒。
    // 理由是可验证的：若把 end==次日00:00 也判非法，则「可用 23:00–24:00、任务 60 分钟」
    // 会变成无法安排（最多只能放到 23:59），而这是完全正常的排程需求。
    // 该口径已上报 M0 待确认，见接口文档 §十八。
    final spanning = <String>[];
    for (final block in blocks) {
      final dayEnd = scheduleDayOnly(block.startAt).add(const Duration(days: 1));
      if (block.endAt.isAfter(dayEnd)) {
        spanning.add('${block.blockId}（${_isoInstant(block.startAt)} → ${_isoInstant(block.endAt)}）');
      }
    }
    // 契约 §5.6 另一句：「同一单次事项在一个提案中最多出现一个可持久化 block」。
    // 这里同样按结构错误处理（422 PROPOSAL_INVALID），原因见下：
    // §5.8 的 violation 码是**封闭 8 值**，其中只有 MULTIPLE_BLOCKS_FOR_RECURRING_TASK_DAY
    // 与多块有关，且名字明确限定 recurring；为单次事项复用它会让消费方误判任务类型，
    // 自造新码又违反「未知 code 必须按 PROPOSAL_INVALID 拒绝」。
    // 故：规则有、码没有 —— 只能走 §5.8 的结构错误通道。该契约缺口已上报 M0/M3。
    final oneTimeBlocks = <String, List<String>>{};
    for (final block in blocks) {
      if (block.taskKindCode != 'one_time') continue;
      oneTimeBlocks.putIfAbsent(block.taskId, () => <String>[]).add(block.blockId);
    }
    final multiOneTime = oneTimeBlocks.entries.where((e) => e.value.length > 1).toList();
    if (multiOneTime.isNotEmpty) {
      final detail = multiOneTime
          .map((e) => '${e.key}（块：${e.value.join('、')}）')
          .join('；');
      return HandlerResult(
        422,
        errorBody(
          code: 'PROPOSAL_INVALID',
          field: 'proposal.blocks',
          message: '契约 §5.6 要求同一单次事项在一个提案中最多一个可持久化 block，'
              '以下单次事项出现了多个：$detail。'
              '需要拆解的大任务应由上游先产生多个独立 Task，不得把一个 Task 的多块当作现有能力。',
        ),
      );
    }

    if (spanning.isNotEmpty) {
      return HandlerResult(
        422,
        errorBody(
          code: 'PROPOSAL_INVALID',
          field: 'proposal.blocks',
          message: '契约 §5.6 要求 block 的 start_at 与 end_at 属于同一上海本地日，'
              '以下块跨过了零点：${spanning.join('、')}。'
              '允许 end_at 恰为次日 00:00:00（当日排到结束），但不允许越过。',
        ),
      );
    }

    violations = validateViews(
      mapped.input,
      blocks,
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

  // max_shift_minutes 必须显式校验：M3 F-2 实测「字符串 "10" 与 true 被当成没传、-30 被接受」，
  // 调用方分不清「没传」和「传错」——非法输入不得静默降级。
  final rawShift = envelope['max_shift_minutes'];
  int? maxShift;
  if (rawShift != null) {
    if (rawShift is! int) {
      return HandlerResult(
        400,
        _error(
          'INVALID_ARGUMENT',
          'max_shift_minutes',
          '必须是整数分钟数；收到 ${rawShift.runtimeType}。省略该字段表示不设位移边界。',
        ),
      );
    }
    if (rawShift < 0) {
      return HandlerResult(
        400,
        _error('INVALID_ARGUMENT', 'max_shift_minutes', '不得为负数；收到 $rawShift。'),
      );
    }
    maxShift = rawShift;
  }
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
  final proposal = repairSchedule(
    mapped.input,
    previous,
    maxShiftMinutes: maxShift,
  );
  // action 的判定依据是 `input.existing_placements`（服务端已知的既有安排），**不是 previous**：
  // previous 只是「上一版提案」，它是否已落库只有服务端知道。二者都为空时所有 change 会写成
  // `assign`（首次指派）；若上一版其实已落库，这会变成重复创建。引擎不替调用方猜，但要报出来。
  final warnings = <String>[...mapped.warnings];
  if (mapped.input.existingPlacements.isEmpty && previous.blocks.isNotEmpty) {
    warnings.add(
      'repair_schedule 未收到 input.existing_placements，而 previous 含 ${previous.blocks.length} 个块：'
      '本次所有 upsert_daily_override 的 action 都会是 assign（首次指派）。'
      '若上一版提案已写入数据库，请传 existing_placements，否则会把「改期」误标成「新建」。',
    );
  }

  // max_shift_minutes 是**搜索边界**而不是硬约束：边界内无解时引擎退「最早可用」，
  // 会排出超过该上限的位移且不报错。调用方（和它背后的用户）很容易把它读成保证，
  // 故此处把实际超限的块逐个点名——不改变引擎行为，只让违反可见。
  if (maxShift != null) {
    final overruns = <String>[];
    for (final block in proposal.blocks) {
      final before = _previousStartOf(previous.blocks, block.taskId, block.startAt);
      if (before == null) continue;
      final delta = toShanghaiWallClock(block.startAt).difference(before).inMinutes.abs();
      if (delta > maxShift) {
        overruns.add('${block.taskId}（位移 $delta 分钟 > 上限 $maxShift）');
      }
    }
    if (overruns.isNotEmpty) {
      warnings.add(
        'max_shift_minutes=$maxShift 未能满足：${overruns.join('、')}。'
        '该参数只是搜索边界，边界内无解时引擎退「最早可用」，不会拒排也不会报错；'
        '若这些块不允许这样移动，请改由服务端拒绝该提案。',
      );
    }
  }
  return HandlerResult(200, {
    'ok': true,
    'proposal': proposal.toJson(),
    'meta': {
      'blocks': proposal.blocks.length,
      'changes': proposal.changes.length,
      'unplanned_tasks': proposal.unplannedTasks.length,
      'explanations': proposal.notes.length,
      'max_shift_minutes': maxShift,
    },
    if (warnings.isNotEmpty) 'warnings': warnings,
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
    // 日期用于判「同一任务能否有多条变更」：单次事项 planned_date，单日例外 local_date。
    final rawDate = item['local_date'] ?? item['planned_date'];
    result.add(
      ChangeView(
        taskId: taskId,
        changeId: changeId,
        plannedDate: rawDate == null ? null : DateTime.tryParse('$rawDate'),
      ),
    );
  }
  return result;
}

String _isoInstant(DateTime value) {
  final shanghai = value.toUtc().add(const Duration(hours: 8));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${shanghai.year.toString().padLeft(4, '0')}-${two(shanghai.month)}-${two(shanghai.day)}'
      'T${two(shanghai.hour)}:${two(shanghai.minute)}:${two(shanghai.second)}+08:00';
}

/// 在上一版提案里找「同一任务、同一天」那个块的开始时刻（用于算实际位移）。
///
/// 只认同一天：跨天比较没有意义（跨天是重新安排另一天，不是把这块挪过去）。
DateTime? _previousStartOf(List<ProposedBlock> previous, String taskId, DateTime newStart) {
  final newDay = scheduleDayOnly(toShanghaiWallClock(newStart));
  DateTime? found;
  for (final block in previous) {
    if (block.taskId != taskId) continue;
    final start = toShanghaiWallClock(block.startAt);
    if (scheduleDayOnly(start) != newDay) continue;
    if (found == null || start.isBefore(found)) found = start;
  }
  return found;
}

/// 把 HTTP 原始请求体解码成 `handleRequest` 的入参，**失败时返回现成的 400 结果**。
///
/// 抽到这里的目的只有一条：让「非法 JSON 也带 retryable」这件事能被自检直接测到。
/// 若把它留在 `bin/serve.dart` 里，自检只能再抄一份解码逻辑才能验——那就变成
/// 「测的是副本、跑的是另一份」，正是本项目反复踩过的假通过。
///
/// 返回 null 表示解码成功，结果写回 [decoded]。
HandlerResult? decodeBodyOrError(String raw, {required void Function(Object? body) onDecoded}) {
  if (raw.trim().isEmpty) {
    onDecoded(null);
    return null;
  }
  try {
    onDecoded(jsonDecode(raw));
    return null;
  } on FormatException catch (error) {
    return HandlerResult(
      400,
      errorBody(
        code: 'INVALID_ARGUMENT',
        field: 'body',
        message: '不是合法 JSON：${error.message}',
      ),
    );
  }
}
