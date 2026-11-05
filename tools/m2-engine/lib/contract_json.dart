/// 把 M1/服务端送来的契约 JSON 映射成 M2 调度引擎的输入 DTO。
///
/// 三条硬原则，都是被契约与历史事故逼出来的：
/// 1. **时间必须带偏移**：契约 §3 禁止无偏移时间，这里直接拒绝，不做「猜时区」。
/// 2. **不猜、不补默认**：缺字段就报错并指出字段名；唯一例外是 `required_minutes`
///    允许缺省为 0（引擎会落到「最短块」兜底），但会在响应的 `warnings` 里明写。
/// 3. **只做映射**：这里不实现任何排程语义，语义全部在 domain 引擎里。
library;

import 'package:check_d/features/agent_scheduler/domain/schedule_contract.dart';

/// 请求体不符合契约时的异常。
///
/// 单独建模是为了让 HTTP 层能返回 `400` + 机器可读的 `error.field`，
/// 而不是把异常吞成 `500`。
class ContractFormatException implements Exception {
  ContractFormatException(this.field, this.message);

  /// 出问题的字段路径，例如 `input.demands[2].deadline.date`。
  final String field;
  final String message;

  @override
  String toString() => 'ContractFormatException($field): $message';
}

Never _fail(String field, String message) => throw ContractFormatException(field, message);

Map<String, dynamic> _object(Object? raw, String field) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.map((key, value) => MapEntry('$key', value));
  _fail(field, '必须是 JSON 对象');
}

List<Object?> _array(Object? raw, String field) {
  if (raw is List) return raw;
  _fail(field, '必须是 JSON 数组');
}

String _string(Object? raw, String field) {
  if (raw is String && raw.isNotEmpty) return raw;
  _fail(field, '必须是非空字符串');
}

int _int(Object? raw, String field, {int? min, int? max}) {
  if (raw is int) {
    if (min != null && raw < min) _fail(field, '不得小于 $min');
    if (max != null && raw > max) _fail(field, '不得大于 $max');
    return raw;
  }
  if (raw is num && raw == raw.roundToDouble()) return _int(raw.toInt(), field, min: min, max: max);
  _fail(field, '必须是整数');
}

/// 把解析出的**瞬时**还原成 `Asia/Shanghai` 的墙面时间（同一时刻，换表示）。
///
/// 为什么必须做这一步：`DateTime.parse('...+08:00')` 返回的是 UTC 表示的瞬时，
/// 而 domain 引擎的语义是「按业务时区的墙面时间排程」——它用 `hour`/`day` 这些
/// 字面字段判断日界与截止日。若直接把 UTC 瞬时喂进去：
/// - `07:00+08:00` 会变成前一天 `23:00`，日界整体错一天；
/// - 解释文案里的 HH:MM 会按 UTC 渲染，与 `start_at` 的 `+08:00` 自相矛盾。
///
/// 这里不引入时区库：先归一到 UTC 再加 8 小时，用其字面字段重建本地 DateTime。
/// 于是引擎看到的永远是上海墙面时间，且与本机时区无关。
DateTime toShanghaiWallClock(DateTime value) {
  final shanghai = value.toUtc().add(const Duration(hours: 8));
  return DateTime(
    shanghai.year,
    shanghai.month,
    shanghai.day,
    shanghai.hour,
    shanghai.minute,
    shanghai.second,
    shanghai.millisecond,
    shanghai.microsecond,
  );
}

/// 解析一个**真实时刻**，强制要求带 `Z` 或 `±HH:MM` 偏移，并归一到上海墙面时间。
///
/// 反例（必须被拒）：`2026-11-05T09:00:00` —— 无偏移，落到哪台机器就是哪个时区。
DateTime _instant(Object? raw, String field) {
  final text = _string(raw, field);
  if (!RegExp(r'(?:Z|[+-]\d{2}:\d{2})$').hasMatch(text)) {
    _fail(field, '缺少时区偏移（契约 §3 禁止无偏移时间），示例：2026-11-05T09:00:00+08:00');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) _fail(field, '无法解析为 ISO 8601 时刻');
  return toShanghaiWallClock(parsed);
}

/// 解析一个**日历日**（`YYYY-MM-DD`）。
///
/// 日期型截止的语义是「这一天的结束为止」，不是一个时刻，
/// 所以按字面构造本地零点，不参与时区换算。
DateTime _dateOnly(Object? raw, String field) {
  final text = _string(raw, field);
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  if (match == null) _fail(field, '必须是 YYYY-MM-DD');
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final value = DateTime(year, month, day);
  if (value.year != year || value.month != month || value.day != day) {
    _fail(field, '不是合法日期');
  }
  return value;
}

SchedulePreferences _preferences(Object? raw, String field) {
  if (raw == null) return const SchedulePreferences();
  final json = _object(raw, field);
  return SchedulePreferences(
    dayStartMinute: json.containsKey('day_start_minute')
        ? _int(json['day_start_minute'], '$field.day_start_minute', min: 0, max: 1439)
        : 8 * 60,
    dayEndMinute: json.containsKey('day_end_minute')
        ? _int(json['day_end_minute'], '$field.day_end_minute', min: 1, max: 1440)
        : 22 * 60,
    minimumBlockMinutes: json.containsKey('minimum_block_minutes')
        ? _int(json['minimum_block_minutes'], '$field.minimum_block_minutes', min: 1)
        : 15,
  );
}

ScheduleDeadline? _deadline(Object? raw, String field) {
  if (raw == null) return null;
  final json = _object(raw, field);
  final kind = _string(json['kind'], '$field.kind');
  switch (kind) {
    case 'date_only':
      if (json.containsKey('at')) {
        _fail('$field.at', 'date_only 截止不得携带 at（契约 §3.1）');
      }
      return ScheduleDeadline.dateOnly(_dateOnly(json['date'], '$field.date'));
    case 'exact':
      if (json.containsKey('date')) {
        _fail('$field.date', 'exact 截止不得携带 date（契约 §3.1）');
      }
      return ScheduleDeadline.exact(_instant(json['at'], '$field.at'));
    default:
      _fail('$field.kind', "只接受 'date_only' 或 'exact'");
  }
}

ScheduleTaskKind _taskKind(Object? raw, String field) {
  final code = _string(raw, field);
  return switch (code) {
    'recurring' => ScheduleTaskKind.recurring,
    'one_time' => ScheduleTaskKind.oneTime,
    _ => _fail(field, "只接受 'recurring' 或 'one_time'"),
  };
}

ScheduleOwnerType _ownerType(Object? raw, String field) {
  final code = _string(raw, field);
  return switch (code) {
    'course' => ScheduleOwnerType.course,
    'external_fixed_event' => ScheduleOwnerType.event,
    _ => _fail(field, "只接受 'course' 或 'external_fixed_event'"),
  };
}

/// 映射结果：输入 DTO + 需要告知调用方的非致命提示。
class MappedInput {
  MappedInput(this.input, this.warnings);

  final ScheduleInput input;

  /// 不阻塞执行、但调用方必须知道的事实（例如某任务没有时长依据，用了兜底）。
  final List<String> warnings;
}

/// 把 `generate_schedule` 的契约输入映射成 [ScheduleInput]。
///
/// 接受 `input` 已剥壳后的对象（HTTP 层负责决定是否剥 `{"input": ...}`）。
MappedInput scheduleInputFromJson(Map<String, dynamic> json) {
  final warnings = <String>[];
  final demandsJson = json.containsKey('demands') ? _array(json['demands'], 'input.demands') : const <Object?>[];
  final demands = <ScheduleTaskDemand>[];
  for (var i = 0; i < demandsJson.length; i++) {
    final field = 'input.demands[$i]';
    final item = _object(demandsJson[i], field);
    final taskId = _string(item['task_id'], '$field.task_id');
    final target = item['target_duration_seconds'];
    final remaining = item['remaining_minutes_today'];
    final required = item['required_minutes'];
    final targetSeconds = target == null ? null : _int(target, '$field.target_duration_seconds', min: 0);
    final remainingMinutes = remaining == null ? null : _int(remaining, '$field.remaining_minutes_today', min: 0);
    final requiredMinutes = required == null ? 0 : _int(required, '$field.required_minutes', min: 0);

    if (requiredMinutes <= 0 &&
        (targetSeconds == null || targetSeconds <= 0) &&
        remainingMinutes == null) {
      warnings.add(
        '$field 既无 target_duration_seconds 也无 required_minutes 也无 remaining_minutes_today，'
        '引擎将按 preferences.minimum_block_minutes 与 30 分钟取大者兜底（duration_source=scheduler_estimate）',
      );
    }

    demands.add(
      ScheduleTaskDemand(
        taskId: taskId,
        title: item.containsKey('title') ? _string(item['title'], '$field.title') : taskId,
        requiredMinutes: requiredMinutes,
        taskKind: item.containsKey('task_kind')
            ? _taskKind(item['task_kind'], '$field.task_kind')
            : ScheduleTaskKind.recurring,
        deadline: _deadline(item['deadline'], '$field.deadline'),
        earliestStartAt: item['available_from'] == null
            ? null
            : _instant(item['available_from'], '$field.available_from'),
        priority: item.containsKey('priority') ? _int(item['priority'], '$field.priority') : 0,
        targetDurationSeconds: targetSeconds,
        remainingMinutesToday: remainingMinutes,
      ),
    );
  }

  final fixedJson = json.containsKey('fixed_blocks') ? _array(json['fixed_blocks'], 'input.fixed_blocks') : const <Object?>[];
  final fixedBlocks = <ScheduleFixedBlock>[];
  for (var i = 0; i < fixedJson.length; i++) {
    final field = 'input.fixed_blocks[$i]';
    final item = _object(fixedJson[i], field);
    fixedBlocks.add(
      ScheduleFixedBlock(
        ownerId: _string(item['owner_id'], '$field.owner_id'),
        ownerType: _ownerType(item['owner_type'], '$field.owner_type'),
        startAt: _instant(item['start_at'], '$field.start_at'),
        endAt: _instant(item['end_at'], '$field.end_at'),
        title: item['title'] == null ? null : _string(item['title'], '$field.title'),
      ),
    );
  }

  final placementsJson = json.containsKey('existing_placements')
      ? _array(json['existing_placements'], 'input.existing_placements')
      : const <Object?>[];
  final placements = <SchedulePlacement>[];
  for (var i = 0; i < placementsJson.length; i++) {
    final field = 'input.existing_placements[$i]';
    final item = _object(placementsJson[i], field);
    placements.add(
      SchedulePlacement(
        taskId: _string(item['task_id'], '$field.task_id'),
        startAt: _instant(item['start_at'], '$field.start_at'),
        endAt: _instant(item['end_at'], '$field.end_at'),
      ),
    );
  }

  // availability 三态必须原样保留：
  // - 缺键 或 显式 null = 未提供（允许按 preferences 推导）；
  // - 空数组 = 显式「没有可用时间」；
  // - 非空数组 = 只用显式窗口。
  //
  // 显式 null 必须与缺键等价：Python 侧 json.dumps({"availability": None}) 会带一个
  // 真 null，若在这里按「存在即校验」处理会抛 400，等于把「未提供」判成「格式错误」。
  List<ScheduleWindow>? availability;
  if (json['availability'] != null) {
    final list = _array(json['availability'], 'input.availability');
    availability = <ScheduleWindow>[];
    for (var i = 0; i < list.length; i++) {
      final field = 'input.availability[$i]';
      final item = _object(list[i], field);
      availability.add(
        ScheduleWindow(
          startAt: _instant(item['start_at'], '$field.start_at'),
          endAt: _instant(item['end_at'], '$field.end_at'),
        ),
      );
    }
  }

  final timezone = json.containsKey('timezone') ? _string(json['timezone'], 'input.timezone') : 'Asia/Shanghai';
  if (timezone != 'Asia/Shanghai') {
    // 契约把时区固定为 Asia/Shanghai；M2 不做时区转换，接受但必须报警。
    warnings.add('input.timezone=$timezone，但契约把时区固定为 Asia/Shanghai；引擎不做时区转换。');
  }

  final input = ScheduleInput(
    now: _instant(json['now'], 'input.now'),
    horizonStart: _instant(json['horizon_start'], 'input.horizon_start'),
    horizonEnd: _instant(json['horizon_end'], 'input.horizon_end'),
    baseVersion: _string(json['base_version'], 'input.base_version'),
    timezone: timezone,
    preferences: _preferences(json['preferences'], 'input.preferences'),
    availability: availability,
    fixedBlocks: fixedBlocks,
    demands: demands,
    existingPlacements: placements,
  );

  return MappedInput(input, warnings);
}

/// 把上一版提案 JSON 映射成 [SchedulePlacement] 列表（`repair_schedule` 用）。
///
/// 只取 `blocks`：它们才是可被移动的柔性安排；`changes` 是持久化意图，不是位置。
List<SchedulePlacement> placementsFromProposalJson(Object? raw) {
  if (raw == null) return const [];
  final json = _object(raw, 'previous');
  final blocks = json.containsKey('blocks') ? _array(json['blocks'], 'previous.blocks') : const <Object?>[];
  final result = <SchedulePlacement>[];
  for (var i = 0; i < blocks.length; i++) {
    final field = 'previous.blocks[$i]';
    final item = _object(blocks[i], field);
    result.add(
      SchedulePlacement(
        taskId: _string(item['task_id'], '$field.task_id'),
        startAt: _instant(item['start_at'], '$field.start_at'),
        endAt: _instant(item['end_at'], '$field.end_at'),
      ),
    );
  }
  return result;
}
