// 适配层自检：不开框架、不装依赖，`dart run tools/m2-engine/bin/smoke.dart` 直接跑。
//
// 覆盖两类通道：
// 1. 进程内调用 `handleRequest`（与 HTTP 层同一函数）；
// 2. 真起一个 HttpServer，用 HttpClient 打一轮（证明网络链路、编码、状态码都对）。
//
// 退出码 0 = 全绿；1 = 有断言失败（会打印实际值，不打印「应该没问题」）。

import 'dart:convert';
import 'dart:io';

import '../lib/handler.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void _check(String name, bool condition, [String? detail]) {
  if (condition) {
    _passed++;
    stdout.writeln('  PASS  $name');
  } else {
    _failures.add(name);
    stdout.writeln('  FAIL  $name${detail == null ? '' : ' -> $detail'}');
  }
}

Map<String, dynamic> _fixture(String name) {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final file = File('$root/fixtures/$name');
  if (!file.existsSync()) {
    stderr.writeln('fixture 缺失：${file.path}');
    exit(2);
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _body(Map<String, dynamic> fixture) => {'input': fixture['input'] as Map<String, dynamic>};

List<Map<String, dynamic>> _notes(Map<String, dynamic> proposal) =>
    ((proposal['explanations'] as List?) ?? const []).cast<Map<String, dynamic>>();

void main() async {
  stdout.writeln('== 1. 进程内调用：三个场景 ==');

  final normal = handleRequest('POST', '/generate_schedule', _body(_fixture('normal.json')));
  _check('normal: 200', normal.status == 200, '${normal.status} ${normal.body['error']}');
  // /health 必须能自证「你打到的这一版有哪些行为」——否则验收方无法区分
  // 「代码没修」和「进程是旧的」。曾因此被误判为「M2 零修复」并上报 M0。
  final healthRes = handleRequest('GET', '/health', null);
  final semantics = (healthRes.body['semantics'] as Map?)?.cast<String, bool>() ?? const <String, bool>{};
  _check(
    '/health 暴露 semantics_stamp（可判断进程版本）',
    '${healthRes.body['semantics_stamp'] ?? ''}'.isNotEmpty,
    '${healthRes.body['semantics_stamp']}',
  );
  _check(
    '/health 的 semantics 全为 true 且条数够（有 false 即表示旧进程）',
    semantics.isNotEmpty && semantics.values.every((v) => v == true),
    '$semantics',
  );

  final normalProposal = (normal.body['proposal'] as Map).cast<String, dynamic>();
  final normalBlocks = (normalProposal['blocks'] as List).cast<Map<String, dynamic>>();
  _check('normal: 至少两块', normalBlocks.length >= 2, '实际 ${normalBlocks.length}');
  _check('normal: 无未安排任务', (normalProposal['unplanned_tasks'] as List).isEmpty, '${normalProposal['unplanned_tasks']}');
  _check(
    'normal: 有 SCHEDULED 解释',
    _notes(normalProposal).any((note) => note['code'] == 'SCHEDULED'),
    '${_notes(normalProposal).map((note) => note['code']).toList()}',
  );
  _check(
    'normal: 块时间带 +08:00',
    normalBlocks.every((block) => '${block['start_at']}'.endsWith('+08:00') && '${block['end_at']}'.endsWith('+08:00')),
    '${normalBlocks.map((block) => block['start_at']).toList()}',
  );
  // 文案里的 HH:MM 必须与 start_at 的 +08:00 墙钟一致（曾因 UTC 瞬时直通引擎而显示 00:00）。
  final scheduledText = _notes(normalProposal)
      .where((note) => note['code'] == 'SCHEDULED' && ((note['related_task_ids'] as List?) ?? const []).contains('t_eng'))
      .map((note) => '${note['message']}')
      .join();
  _check('normal: 解释文案墙钟与 +08:00 一致', scheduledText.contains('08:00'), scheduledText);

  final conflict = handleRequest('POST', '/generate_schedule', _body(_fixture('conflict.json')));
  final conflictProposal = (conflict.body['proposal'] as Map).cast<String, dynamic>();
  final unplanned = (conflictProposal['unplanned_tasks'] as List).cast<Map<String, dynamic>>();
  _check('conflict: 200', conflict.status == 200, '${conflict.status}');
  _check('conflict: 任务进 unplanned', unplanned.isNotEmpty, 'unplanned=${unplanned.length}');
  _check(
    'conflict: unplanned 带机器可读 reason_code',
    unplanned.isNotEmpty && '${unplanned.first['reason_code']}'.isNotEmpty,
    '${unplanned.isEmpty ? 'n/a' : unplanned.first['reason_code']}',
  );

  final done = handleRequest('POST', '/generate_schedule', _body(_fixture('already_done.json')));
  final doneProposal = (done.body['proposal'] as Map).cast<String, dynamic>();
  final doneBlocks = (doneProposal['blocks'] as List).cast<Map<String, dynamic>>();
  final doneNotes = _notes(doneProposal);
  _check('already_done: 200', done.status == 200, '${done.status}');
  _check(
    'already_done: 已完成任务不出块',
    doneBlocks.every((block) => block['task_id'] != 't_done'),
    '${doneBlocks.map((block) => block['task_id']).toList()}',
  );
  _check(
    'already_done: 产出 ALREADY_DONE_TODAY',
    doneNotes.any((note) => note['code'] == 'ALREADY_DONE_TODAY'),
    '${doneNotes.map((note) => note['code']).toList()}',
  );
  _check(
    'already_done: 解释带 related_task_ids',
    doneNotes.any((note) => note['code'] == 'ALREADY_DONE_TODAY' && (note['related_task_ids'] as List?)?.contains('t_done') == true),
    '${doneNotes.where((note) => note['code'] == 'ALREADY_DONE_TODAY').toList()}',
  );
  _check(
    'already_done: 另一任务照常排',
    doneBlocks.any((block) => block['task_id'] == 't_keep'),
    '${doneBlocks.map((block) => block['task_id']).toList()}',
  );

  stdout.writeln('== 2. 校验端点 ==');
  final selfCheck = handleRequest('POST', '/validate_schedule', _body(_fixture('normal.json')));
  _check('validate(引擎自产): 200', selfCheck.status == 200, '${selfCheck.status}');
  _check('validate(引擎自产): 无 violation', selfCheck.body['valid'] == true, '${selfCheck.body['violations']}');
  _check('validate(引擎自产): source=engine-generated', selfCheck.body['proposal_source'] == 'engine-generated', '${selfCheck.body['proposal_source']}');

  // 生成器 ↔ 校验器同源：把引擎自己产出的提案原样送去校验，必须 valid。
  // 这是 M0 P0-1 第五条「生成器与校验器必须使用一致的截止判断逻辑」的可执行证据。
  for (final name in ['normal.json', 'conflict.json', 'already_done.json']) {
    final generated = handleRequest('POST', '/generate_schedule', _body(_fixture(name)));
    final backCheck = handleRequest('POST', '/validate_schedule', <String, dynamic>{
      'input': _fixture(name)['input'],
      'proposal': (generated.body['proposal'] as Map).cast<String, dynamic>(),
    });
    final codes = ((backCheck.body['violations'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((violation) => '${violation['code']}')
        .toList();
    _check(
      '生成器产物再校验必须 valid（$name）',
      backCheck.status == 200 && backCheck.body['valid'] == true,
      '${backCheck.status} ${backCheck.body['valid']} codes=$codes',
    );
  }

  // 显式全忙（availability=[]）时也必须是 valid 的空提案：不是「零块=出错」。
  final emptyInputForValidate = Map<String, dynamic>.from(_fixture('normal.json')['input'] as Map);
  emptyInputForValidate['availability'] = <Object?>[];
  final emptyGenerated = handleRequest('POST', '/generate_schedule', {'input': emptyInputForValidate});
  final emptyBackCheck = handleRequest('POST', '/validate_schedule', <String, dynamic>{
    'input': emptyInputForValidate,
    'proposal': (emptyGenerated.body['proposal'] as Map).cast<String, dynamic>(),
  });
  _check(
    '全忙时的空提案也是 valid（0 块不等于非法）',
    emptyBackCheck.status == 200 && emptyBackCheck.body['valid'] == true,
    '${emptyBackCheck.status} ${emptyBackCheck.body['valid']} ${emptyBackCheck.body['violations']}',
  );

  final badProposal = {
    'blocks': [
      {
        'block_id': 'blk-bad-1',
        'task_id': 't_eng',
        'task_kind': 'recurring',
        'start_at': '2026-11-02T10:15:00+08:00', // 落在课程内
        'end_at': '2026-11-02T11:00:00+08:00',
      },
      {
        'block_id': 'blk-bad-2',
        'task_id': 't_read',
        'task_kind': 'one_time',
        'start_at': '2026-11-02T10:45:00+08:00', // 与上一块及课程都重叠
        'end_at': '2026-11-02T11:15:00+08:00',
      },
    ],
    'changes': [],
  };
  final badBody = <String, dynamic>{
    'input': _fixture('normal.json')['input'],
    'proposal': badProposal,
  };
  final bad = handleRequest('POST', '/validate_schedule', badBody);
  final badCodes = ((bad.body['violations'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map((violation) => '${violation['code']}')
      .toList();
  _check('validate(外部提案): 判定为不通过', bad.body['valid'] == false, '${bad.body['valid']}');
  _check('validate(外部提案): 含 FIXED_EVENT_CONFLICT', badCodes.contains('FIXED_EVENT_CONFLICT'), '$badCodes');
  _check('validate(外部提案): 含 BLOCK_OVERLAP', badCodes.contains('BLOCK_OVERLAP'), '$badCodes');
  _check(
    'validate(外部提案): FIXED_EVENT_CONFLICT 先于 BLOCK_OVERLAP',
    badCodes.indexOf('FIXED_EVENT_CONFLICT') < badCodes.indexOf('BLOCK_OVERLAP'),
    '$badCodes',
  );
  _check(
    'validate: message 不内嵌裸 ID',
    ((bad.body['violations'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .every((violation) => !'${violation['message']}'.contains('t_eng') && !'${violation['message']}'.contains('blk-')),
    '${(bad.body['violations'] as List?)?.map((violation) => violation['message']).toList()}',
  );

  stdout.writeln('== 2b. 三态过线 / 确定性 / 重排 ==');
  // availability=[] 必须原样过线：空数组是「显式没有时间」，不得回退偏好推导。
  final emptyInput = Map<String, dynamic>.from(_fixture('normal.json')['input'] as Map);
  emptyInput['availability'] = <Object?>[];
  final emptyRes = handleRequest('POST', '/generate_schedule', {'input': emptyInput});
  final emptyProposal = (emptyRes.body['proposal'] as Map).cast<String, dynamic>();
  final emptyUnplanned = (emptyProposal['unplanned_tasks'] as List).cast<Map<String, dynamic>>();
  _check('availability=[]: 0 块', (emptyProposal['blocks'] as List).isEmpty, '${(emptyProposal['blocks'] as List).length}');
  _check(
    'availability=[]: 全部进 unplanned 且 reason_code=NO_AVAILABILITY',
    emptyUnplanned.isNotEmpty && emptyUnplanned.every((task) => '${task['reason_code']}' == 'NO_AVAILABILITY'),
    '${emptyUnplanned.map((task) => task['reason_code']).toList()}',
  );
  _check(
    'availability=[]: meta 标 empty（与缺键的 null 区分）',
    emptyRes.body['meta']['availability_state'] == 'empty',
    '${emptyRes.body['meta']['availability_state']}',
  );

  // 确定性：引擎不读系统时钟，同输入两次必须逐字节相同。
  final again = handleRequest('POST', '/generate_schedule', _body(_fixture('normal.json')));
  _check(
    '同输入两次输出逐字节相同',
    jsonEncode(again.body) == jsonEncode(normal.body),
    '两次结果不一致',
  );

  final repaired = handleRequest('POST', '/repair_schedule', <String, dynamic>{
    'input': _fixture('normal.json')['input'],
    'previous': normalProposal,
  });
  final repairedProposal = (repaired.body['proposal'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  _check('repair_schedule: 200', repaired.status == 200, '${repaired.status} ${repaired.body['error']}');
  _check(
    'repair_schedule: 仍产出块',
    ((repairedProposal['blocks'] as List?) ?? const []).isNotEmpty,
    '${repairedProposal['blocks']}',
  );

  stdout.writeln('== 2c. M3 复验三点（F-1/F-2/F-3）==');
  // F-3（M0 fail-closed 令）：不允许靠省略 availability 表达「未知」
  final missingInput = Map<String, dynamic>.from(_fixture('normal.json')['input'] as Map);
  missingInput.remove('availability');
  final missingRes = handleRequest('POST', '/generate_schedule', {'input': missingInput});
  _check(
    'availability 缺失: 400 且 field 指向该字段（fail-closed）',
    missingRes.status == 400 && '${(missingRes.body['error'] as Map?)?['field']}' == 'input.availability',
    '${missingRes.status} ${missingRes.body['error']}',
  );

  // F-3：显式 null 必须能收（Python json.dumps({"availability": None}) 就带真 null），
  // 且必须与 [] 区分：null 推导出块，[] 一块不出。
  final nullInput = Map<String, dynamic>.from(_fixture('normal.json')['input'] as Map);
  nullInput['availability'] = null;
  final nullRes = handleRequest('POST', '/generate_schedule', {'input': nullInput});
  _check('availability=null: 200（不当作格式错误）', nullRes.status == 200, '${nullRes.status} ${nullRes.body['error']}');
  _check(
    'availability=null: 与缺键不同，按 preferences 推导出块',
    nullRes.status == 200 &&
        ((nullRes.body['proposal'] as Map)['blocks'] as List).length == normalBlocks.length &&
        nullRes.body['meta']['availability_state'] == 'null',
    '${nullRes.status == 200 ? (nullRes.body['proposal'] as Map)['blocks'] : null}',
  );
  _check(
    'availability=null: 响应带 warnings 提醒可改为 []',
    nullRes.status == 200 &&
        ((nullRes.body['warnings'] as List?) ?? const []).any((w) => '$w'.contains('已确认今天全忙')),
    '${nullRes.body['warnings']}',
  );

  // F-2：max_shift_minutes 非法输入必须 400，不得静默当没传
  for (final bad in <Object>['10', true, -30, 10.5]) {
    final res = handleRequest('POST', '/repair_schedule', <String, dynamic>{
      'input': _fixture('normal.json')['input'],
      'previous': normalProposal,
      'max_shift_minutes': bad,
    });
    final error = (res.body['error'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    _check(
      'max_shift_minutes=$bad 被拒（400 + 指向该字段）',
      res.status == 400 && error['field'] == 'max_shift_minutes',
      '${res.status} ${res.body['error']}',
    );
  }
  final zeroShift = handleRequest('POST', '/repair_schedule', <String, dynamic>{
    'input': _fixture('normal.json')['input'],
    'previous': normalProposal,
    'max_shift_minutes': 0,
  });
  _check('max_shift_minutes=0 被接受（0 合法，表示不许位移）', zeroShift.status == 200, '${zeroShift.status}');

  // F-1：错误体必须带机器可判定的 retryable
  final errorEnvelope = handleRequest('POST', '/generate_schedule', <String, dynamic>{'input': <String, dynamic>{}});
  _check(
    '错误体带 retryable=false（4xx 不可重试）',
    errorEnvelope.status == 400 && '${(errorEnvelope.body['error'] as Map?)?['retryable']}' == 'false',
    '${errorEnvelope.status} ${errorEnvelope.body['error']}',
  );

  // D-1：多日覆盖开关必须**真改变输出**，不能「传了 true 却仍只落一天」。
  // 用 2 天 previous（同任务两个块）走 repair：未授权只出 1 条 change，授权后出 2 条。
  Map<String, dynamic> twoDayBody({required bool authorize}) => {
        'input': <String, dynamic>{
          'now': '2026-11-02T08:00:00+08:00',
          'horizon_start': '2026-11-02T00:00:00+08:00',
          'horizon_end': '2026-11-03T23:00:00+08:00',
          'base_version': 'v1',
          'availability': <Map<String, String>>[
            {'start_at': '2026-11-02T08:00:00+08:00', 'end_at': '2026-11-02T18:00:00+08:00'},
            {'start_at': '2026-11-03T08:00:00+08:00', 'end_at': '2026-11-03T18:00:00+08:00'},
          ],
          'demands': <Map<String, Object>>[
            {'task_id': 't-multi', 'title': '每日背单词', 'required_minutes': 30},
          ],
          if (authorize) 'authorize_multi_day_overrides': true,
        },
        'previous': <String, dynamic>{
          'blocks': <Map<String, String>>[
            {
              'task_id': 't-multi',
              'block_id': 'b1',
              'start_at': '2026-11-02T10:00:00+08:00',
              'end_at': '2026-11-02T10:30:00+08:00',
            },
            {
              'task_id': 't-multi',
              'block_id': 'b2',
              'start_at': '2026-11-03T10:00:00+08:00',
              'end_at': '2026-11-03T10:30:00+08:00',
            },
          ],
        },
      };
  final gateOff = handleRequest('POST', '/repair_schedule', twoDayBody(authorize: false));
  final gateOn = handleRequest('POST', '/repair_schedule', twoDayBody(authorize: true));
  final offBlocks = ((gateOff.body['proposal'] as Map?)?['blocks'] as List?) ?? const [];
  final offChanges = ((gateOff.body['proposal'] as Map?)?['changes'] as List?) ?? const [];
  final onBlocks = ((gateOn.body['proposal'] as Map?)?['blocks'] as List?) ?? const [];
  final onChanges = ((gateOn.body['proposal'] as Map?)?['changes'] as List?) ?? const [];
  _check(
    '多日未授权: 2 块仍展示，但只出 1 条 change（不把灵活任务钉死多日）',
    offBlocks.length == 2 && offChanges.length == 1,
    'blocks=${offBlocks.length} changes=${offChanges.length}',
  );
  _check(
    '多日已授权: 2 块 + 2 条 change（开关真生效，不是被静默忽略）',
    onBlocks.length == 2 && onChanges.length == 2,
    'blocks=${onBlocks.length} changes=${onChanges.length}',
  );

  // 生成器产物必须能通过自己的校验器 —— 「块多于单」与「跨多日各一条」都属合法形态。
  // 这条是真抓过缺陷的：上一版只要同一任务 ≥2 条 change 就判 MULTIPLE_CHANGES_FOR_ONE_TIME_TASK，
  // 于是引擎在授权态下自产的提案被自己的校验器判非法（生成合法、校验非法）。
  final gateOffBack = handleRequest('POST', '/validate_schedule', <String, dynamic>{
    'input': twoDayBody(authorize: false)['input'],
    'proposal': gateOff.body['proposal'],
  });
  _check(
    '未授权态自产提案再校验必须 valid（2 块 / 1 条 change）',
    gateOffBack.status == 200 && gateOffBack.body['valid'] == true,
    '${gateOffBack.body['valid']} ${gateOffBack.body['violations']}',
  );
  final gateOnBack = handleRequest('POST', '/validate_schedule', <String, dynamic>{
    'input': twoDayBody(authorize: true)['input'],
    'proposal': gateOn.body['proposal'],
  });
  _check(
    '授权态自产提案再校验必须 valid（2 块 / 2 条 change，跨两天各一条）',
    gateOnBack.status == 200 && gateOnBack.body['valid'] == true,
    '${gateOnBack.body['valid']} ${gateOnBack.body['violations']}',
  );

  // 反向控制：规则必须还在，否则上面两条只是把校验关掉了。
  final dupInput = <String, dynamic>{
    'now': '2026-11-02T08:00:00+08:00',
    'horizon_start': '2026-11-02T00:00:00+08:00',
    'horizon_end': '2026-11-02T22:00:00+08:00',
    'base_version': 'v1',
    'availability': <Map<String, String>>[
      {'start_at': '2026-11-02T08:00:00+08:00', 'end_at': '2026-11-02T18:00:00+08:00'},
    ],
    'demands': <Map<String, Object>>[
      {'task_id': 't-rec', 'title': '周期任务', 'required_minutes': 30, 'task_kind': 'recurring'},
    ],
  };
  final sameDayDup = handleRequest('POST', '/validate_schedule', <String, dynamic>{
    'input': dupInput,
    'proposal': <String, dynamic>{
      'blocks': <Map<String, String>>[
        {
          'task_id': 't-rec',
          'block_id': 'b1',
          'task_kind': 'recurring',
          'start_at': '2026-11-02T09:00:00+08:00',
          'end_at': '2026-11-02T09:30:00+08:00',
        },
      ],
      'changes': <Map<String, Object>>[
        {
          'change_id': 'c1',
          'type': 'upsert_daily_override',
          'item_type': 'recurring',
          'item_id': 't-rec',
          'local_date': '2026-11-02',
          'action': 'assign',
          'planned_start_minute': 540,
          'planned_end_minute': 570,
        },
        {
          'change_id': 'c2',
          'type': 'upsert_daily_override',
          'item_type': 'recurring',
          'item_id': 't-rec',
          'local_date': '2026-11-02',
          'action': 'assign',
          'planned_start_minute': 600,
          'planned_end_minute': 630,
        },
      ],
    },
  });
  _check(
    '同一周期任务同一天两条变更仍必须判非法（反向控制，规则没被关掉）',
    sameDayDup.status == 200 &&
        sameDayDup.body['valid'] == false &&
        ((sameDayDup.body['violations'] as List?) ?? const [])
            .any((v) => '${(v as Map)['code']}' == 'MULTIPLE_CHANGES_FOR_ONE_TIME_TASK'),
    '${sameDayDup.body['valid']} ${sameDayDup.body['violations']}',
  );

  // date_only 截止的跨午夜边界：M0 待裁的「23:59:59 vs 次日 00:00」到底差多少。
  // 结论先行：分钟粒度下两种写法**完全等价**——唯一的分界点就是次日 00:00，两边都拒；
  // 23:59 两边都放。真正要防的是「因为怕跨午夜而把合法块也拒了」，故下面四条成对验证。
  Map<String, dynamic> midnightBody({required int minutes, String? deadlineDate}) => {
        'input': <String, dynamic>{
          'now': '2026-11-02T20:00:00+08:00',
          'horizon_start': '2026-11-02T00:00:00+08:00',
          'horizon_end': '2026-11-03T06:00:00+08:00',
          'base_version': 'v1',
          'availability': <Map<String, String>>[
            {'start_at': '2026-11-02T23:00:00+08:00', 'end_at': '2026-11-03T00:00:00+08:00'},
          ],
          'demands': <Map<String, Object>>[
            {
              'task_id': 't',
              'title': '任务',
              'required_minutes': minutes,
              if (deadlineDate != null) 'deadline': {'kind': 'date_only', 'date': deadlineDate},
            },
          ],
        },
      };
  List<Map<String, dynamic>> blocksOf(HandlerResult res) =>
      (((res.body['proposal'] as Map?)?['blocks'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
  String? unplannedCodeOf(HandlerResult res) {
    final list = ((res.body['proposal'] as Map?)?['unplanned_tasks'] as List?) ?? const [];
    if (list.isEmpty) return null;
    return '${(list.first as Map)['reason_code']}';
  }

  final todayFull = handleRequest('POST', '/generate_schedule', midnightBody(minutes: 60, deadlineDate: '2026-11-02'));
  _check(
    'date_only=今天：60 分钟排在 23:00 会跨到次日 00:00 → 必须不可排',
    blocksOf(todayFull).isEmpty && unplannedCodeOf(todayFull) == 'INSUFFICIENT_TIME_BEFORE_DEADLINE',
    'blocks=${blocksOf(todayFull).length} code=${unplannedCodeOf(todayFull)}',
  );
  final todayFit = handleRequest('POST', '/generate_schedule', midnightBody(minutes: 59, deadlineDate: '2026-11-02'));
  _check(
    'date_only=今天：59 分钟排在 23:00 结束 23:59 → 必须可排（不是一刀切禁跨午夜）',
    blocksOf(todayFit).length == 1 &&
        '${blocksOf(todayFit).first['end_at']}' == '2026-11-02T23:59:00+08:00',
    '${blocksOf(todayFit).map((b) => b['end_at']).toList()} code=${unplannedCodeOf(todayFit)}',
  );
  final tomorrowFull = handleRequest('POST', '/generate_schedule', midnightBody(minutes: 60, deadlineDate: '2026-11-03'));
  _check(
    'date_only=明天：同样 23:00–次日 00:00 → 必须可排（截止不是今天就不该拦）',
    blocksOf(tomorrowFull).length == 1 &&
        '${blocksOf(tomorrowFull).first['end_at']}' == '2026-11-03T00:00:00+08:00',
    '${blocksOf(tomorrowFull).map((b) => b['end_at']).toList()} code=${unplannedCodeOf(tomorrowFull)}',
  );
  final noDeadline = handleRequest('POST', '/generate_schedule', midnightBody(minutes: 60));
  _check(
    '无截止：23:00–次日 00:00 必须可排（跨午夜本身不是错）',
    blocksOf(noDeadline).length == 1,
    '${blocksOf(noDeadline).map((b) => b['end_at']).toList()} code=${unplannedCodeOf(noDeadline)}',
  );
  final badMultiDay = Map<String, dynamic>.from(_fixture('normal.json')['input'] as Map)
    ..['authorize_multi_day_overrides'] = 'true';
  final badMultiDayRes = handleRequest('POST', '/generate_schedule', {'input': badMultiDay});
  _check(
    'authorize_multi_day_overrides="true" 被拒（字符串不等于布尔，不得静默当 false）',
    badMultiDayRes.status == 400 &&
        '${(badMultiDayRes.body['error'] as Map?)?['field']}' == 'input.authorize_multi_day_overrides',
    '${badMultiDayRes.status} ${badMultiDayRes.body['error']}',
  );

  // D-2：未知键必须报警，否则拼错一个字母的开关会被静默丢弃。
  final typoInput = Map<String, dynamic>.from(_fixture('normal.json')['input'] as Map)
    ..['authorize_multiday_overrides'] = true;
  final typoRes = handleRequest('POST', '/generate_schedule', {'input': typoInput});
  _check(
    '未知 input 键: 200 但 warnings 点名该键',
    typoRes.status == 200 &&
        ((typoRes.body['warnings'] as List?) ?? const [])
            .any((w) => '$w'.contains('authorize_multiday_overrides')),
    '${typoRes.status} ${typoRes.body['warnings']}',
  );

  // D-3：repair 未传 existing_placements 时，action 会恒为 assign —— 必须报出来，不静默。
  final repairNoPlacement = handleRequest('POST', '/repair_schedule', <String, dynamic>{
    'input': _fixture('normal.json')['input'],
    'previous': normalProposal,
  });
  _check(
    'repair 缺 existing_placements: warnings 说明 action 会全是 assign',
    repairNoPlacement.status == 200 &&
        ((repairNoPlacement.body['warnings'] as List?) ?? const [])
            .any((w) => '$w'.contains('assign')),
    '${repairNoPlacement.status} ${repairNoPlacement.body['warnings']}',
  );

  // max_shift_minutes 是**搜索边界**不是硬约束：边界内无解会退「最早可用」，排出超限位移。
  // 调用方很容易把它读成保证，故必须报出来；同时要有「不超限就不报」的对照，
  // 否则「永远告警」的实现也能骗过上面那条。
  Map<String, dynamic> farShiftBody({int? maxShift}) => {
        'input': <String, dynamic>{
          'now': '2026-11-02T07:00:00+08:00',
          'horizon_start': '2026-11-02T00:00:00+08:00',
          'horizon_end': '2026-11-02T22:00:00+08:00',
          'base_version': 'v1',
          'availability': <Map<String, String>>[
            {'start_at': '2026-11-02T08:00:00+08:00', 'end_at': '2026-11-02T09:00:00+08:00'},
          ],
          'demands': <Map<String, Object>>[
            {'task_id': 't-a', 'title': '任务A', 'required_minutes': 30},
          ],
        },
        'previous': <String, dynamic>{
          'blocks': <Map<String, String>>[
            {
              'task_id': 't-a',
              'block_id': 'b1',
              'task_kind': 'recurring',
              'start_at': '2026-11-02T15:00:00+08:00',
              'end_at': '2026-11-02T15:30:00+08:00',
            },
          ],
        },
        if (maxShift != null) 'max_shift_minutes': maxShift,
      };
  bool hasShiftOverrunWarning(HandlerResult res) =>
      ((res.body['warnings'] as List?) ?? const [])
          .any((w) => '$w'.contains('未能满足') && '$w'.contains('位移'));

  final tinyShift = handleRequest('POST', '/repair_schedule', farShiftBody(maxShift: 10));
  _check(
    'max_shift_minutes=10 但实际要挪 420 分钟: 仍 200，且 warnings 点名超限',
    tinyShift.status == 200 && hasShiftOverrunWarning(tinyShift),
    '${tinyShift.status} ${tinyShift.body['warnings']}',
  );
  _check(
    'max_shift_minutes=10: warnings 里带真实位移数字（420）便于核对',
    ((tinyShift.body['warnings'] as List?) ?? const []).any((w) => '$w'.contains('420')),
    '${tinyShift.body['warnings']}',
  );
  final wideShift = handleRequest('POST', '/repair_schedule', farShiftBody(maxShift: 600));
  _check(
    'max_shift_minutes=600 且位移 420 未超限: 不得误报（对照）',
    wideShift.status == 200 && !hasShiftOverrunWarning(wideShift),
    '${wideShift.body['warnings']}',
  );

  // 错误体必须**处处**带 retryable（M3 F-1），包括「请求体根本不是合法 JSON」这条分支。
  // 这条分支原先在 serve.dart 里手搓错误体，漏了 retryable：调用方按 .error.retryable 读，
  // 在别的错误上拿到 bool、在这条上拿到 null，于是「重试逻辑时灵时不灵」。
  for (final malformed in <String>['{not json', '{"a":', '<<<']) {
    Object? decoded;
    final err = decodeBodyOrError(malformed, onDecoded: (value) => decoded = value);
    final errorMap = (err?.body['error'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    _check(
      '非法 JSON（$malformed）: 400 且 error.retryable 是 bool false',
      err != null && err.status == 400 && errorMap['retryable'] is bool && errorMap['retryable'] == false,
      'status=${err?.status} retryable=${errorMap['retryable']} type=${errorMap['retryable'].runtimeType}',
    );
  }
  Object? okDecoded;
  final okErr = decodeBodyOrError('{"x":1}', onDecoded: (value) => okDecoded = value);
  _check(
    '合法 JSON: 不返回错误，正常解码（对照，证明上面不是恒报错）',
    okErr == null && okDecoded is Map,
    'err=${okErr?.status} decoded=$okDecoded',
  );
  Object? emptyDecoded;
  final emptyErr = decodeBodyOrError('   ', onDecoded: (value) => emptyDecoded = value);
  _check(
    '空请求体: 不在这里报错，交给 handleRequest 统一判（避免两处口径）',
    emptyErr == null && emptyDecoded == null,
    'err=${emptyErr?.status}',
  );

  // action 的判据必须是「同任务 **且同一天** 是否有既有安排」。
  // 只验「有安排→reschedule」不够：若实现漏了日期维度，所有跨天情况都会被误标成改期，
  // 结果是把「新建」当「更新」写进库，静默覆盖别的日期。
  Map<String, dynamic> placementBody({String? placementDay}) => {
        'input': <String, dynamic>{
          'now': '2026-11-02T08:00:00+08:00',
          'horizon_start': '2026-11-02T00:00:00+08:00',
          'horizon_end': '2026-11-02T22:00:00+08:00',
          'base_version': 'v1',
          'availability': <Map<String, String>>[
            {'start_at': '2026-11-02T08:00:00+08:00', 'end_at': '2026-11-02T18:00:00+08:00'},
          ],
          'demands': <Map<String, Object>>[
            {'task_id': 't-x', 'title': '任务X', 'required_minutes': 30},
          ],
          if (placementDay != null)
            'existing_placements': <Map<String, String>>[
              {
                'task_id': 't-x',
                'start_at': '${placementDay}T14:00:00+08:00',
                'end_at': '${placementDay}T14:30:00+08:00',
              },
            ],
        },
      };
  String? actionOf(HandlerResult res) {
    final changes = ((res.body['proposal'] as Map?)?['changes'] as List?) ?? const [];
    if (changes.isEmpty) return null;
    return '${(changes.first as Map)['action']}';
  }

  _check(
    '无既有安排 → action=assign（首次指派）',
    actionOf(handleRequest('POST', '/generate_schedule', placementBody())) == 'assign',
    '${actionOf(handleRequest('POST', '/generate_schedule', placementBody()))}',
  );
  _check(
    '同一天有既有安排 → action=reschedule（改期）',
    actionOf(handleRequest('POST', '/generate_schedule', placementBody(placementDay: '2026-11-02'))) ==
        'reschedule',
    '${actionOf(handleRequest('POST', '/generate_schedule', placementBody(placementDay: '2026-11-02')))}',
  );
  _check(
    '别的日期有既有安排 → 仍 action=assign（日期维度不得漏，否则把新建当更新）',
    actionOf(handleRequest('POST', '/generate_schedule', placementBody(placementDay: '2026-11-03'))) ==
        'assign',
    '${actionOf(handleRequest('POST', '/generate_schedule', placementBody(placementDay: '2026-11-03')))}',
  );

  // M3 2026-11-06 03:46Z 报「生成器候选起点未钳到 now，4 小时任务被排成 08:00-12:00」。
  // 我方实测不成立：起点钳到 now。此断言把它钉死，防止将来退化。
  final clampBody = <String, dynamic>{
    'input': <String, dynamic>{
      'now': '2026-11-02T11:44:00+08:00',
      'horizon_start': '2026-11-02T00:00:00+08:00',
      'horizon_end': '2026-11-02T22:00:00+08:00',
      'base_version': 'v1',
      'availability': <Map<String, String>>[
        {'start_at': '2026-11-02T08:00:00+08:00', 'end_at': '2026-11-02T18:00:00+08:00'},
      ],
      'demands': <Map<String, Object>>[
        {'task_id': 't-long', 'title': '4小时任务', 'required_minutes': 240},
      ],
    },
  };
  final clamped = handleRequest('POST', '/generate_schedule', clampBody);
  final clampedBlocks = ((clamped.body['proposal'] as Map?)?['blocks'] as List?) ?? const [];
  _check(
    '块起点不得早于 now：now=11:44 的 4 小时任务必须从 11:44 起，不是 08:00',
    clampedBlocks.isNotEmpty &&
        '${(clampedBlocks.first as Map)['start_at']}' == '2026-11-02T11:44:00+08:00',
    '${clampedBlocks.map((b) => (b as Map)['start_at']).toList()}',
  );
  final tooLate = Map<String, dynamic>.from(clampBody);
  (tooLate['input'] as Map<String, dynamic>)['now'] = '2026-11-02T14:44:00+08:00';
  final tooLateRes = handleRequest('POST', '/generate_schedule', tooLate);
  final tooLateUnplanned = ((tooLateRes.body['proposal'] as Map?)?['unplanned_tasks'] as List?) ?? const [];
  _check(
    '剩余时间不足时进 unplanned（now=14:44 只剩 3h16m，4 小时任务排不下）',
    tooLateUnplanned.isNotEmpty &&
        '${(tooLateUnplanned.first as Map)['reason_code']}' == 'WINDOW_INSUFFICIENT',
    '${tooLateUnplanned.map((u) => (u as Map)['reason_code']).toList()}',
  );

  // 契约 §5.6：block 的 start_at 与 end_at 必须同属一个上海本地日。
  // 结构错误按 §5.8 走 PROPOSAL_INVALID(422)，不进 violations。
  // 边界采用半开语义：允许 end_at 恰为次日 00:00:00（当日排到结束），只拒真正越零点的。
  Map<String, dynamic> midBody({required String endAt}) => {
        'input': <String, dynamic>{
          'now': '2026-11-02T20:00:00+08:00',
          'horizon_start': '2026-11-02T00:00:00+08:00',
          'horizon_end': '2026-11-03T06:00:00+08:00',
          'base_version': 'v1',
          'availability': <Map<String, String>>[
            {'start_at': '2026-11-02T20:00:00+08:00', 'end_at': '2026-11-03T06:00:00+08:00'},
          ],
          'demands': <Map<String, Object>>[
            {'task_id': 't', 'title': '任务', 'required_minutes': 120},
          ],
        },
        'proposal': <String, dynamic>{
          'blocks': <Map<String, String>>[
            {
              'task_id': 't',
              'block_id': 'b1',
              'task_kind': 'recurring',
              'start_at': '2026-11-02T23:00:00+08:00',
              'end_at': endAt,
            },
          ],
        },
      };
  final spanningRes = handleRequest('POST', '/validate_schedule', midBody(endAt: '2026-11-03T01:00:00+08:00'));
  _check(
    '真跨午夜的块（23:00→次日01:00）必须 422 PROPOSAL_INVALID',
    spanningRes.status == 422 &&
        '${(spanningRes.body['error'] as Map?)?['code']}' == 'PROPOSAL_INVALID',
    '${spanningRes.status} ${spanningRes.body['error']}',
  );
  _check(
    '跨午夜错误的 retryable 必须是 bool false（结构错误重试无用）',
    (spanningRes.body['error'] as Map?)?['retryable'] is bool &&
        (spanningRes.body['error'] as Map)['retryable'] == false,
    '${(spanningRes.body['error'] as Map?)?['retryable']}',
  );
  final dayEndRes = handleRequest('POST', '/validate_schedule', midBody(endAt: '2026-11-03T00:00:00+08:00'));
  _check(
    'end_at 恰为次日 00:00:00 必须放行（半开语义：当日排到结束，不是跨午夜）',
    dayEndRes.status == 200 && dayEndRes.body['valid'] == true,
    '${dayEndRes.status} ${dayEndRes.body['valid']} ${dayEndRes.body['violations']}',
  );

  // 生成器与校验器必须同口径：引擎自己排到 24:00 的块，回喂校验器不得被拒。
  final genToMidnight = handleRequest('POST', '/generate_schedule', <String, dynamic>{
    'input': <String, dynamic>{
      'now': '2026-11-02T20:00:00+08:00',
      'horizon_start': '2026-11-02T00:00:00+08:00',
      'horizon_end': '2026-11-03T06:00:00+08:00',
      'base_version': 'v1',
      'availability': <Map<String, String>>[
        {'start_at': '2026-11-02T23:00:00+08:00', 'end_at': '2026-11-03T00:00:00+08:00'},
      ],
      'demands': <Map<String, Object>>[
        {'task_id': 't', 'title': '任务', 'required_minutes': 60},
      ],
    },
  });
  final midnightBlocks = ((genToMidnight.body['proposal'] as Map?)?['blocks'] as List?) ?? const [];
  _check(
    '引擎可把任务排到 23:00–24:00（60 分钟窗口放满，不被截成 59 分钟）',
    midnightBlocks.length == 1 &&
        '${(midnightBlocks.first as Map)['end_at']}' == '2026-11-03T00:00:00+08:00',
    '${midnightBlocks.map((b) => (b as Map)['end_at']).toList()}',
  );
  final selfRoundTrip = handleRequest('POST', '/validate_schedule', <String, dynamic>{
    'input': <String, dynamic>{
      'now': '2026-11-02T20:00:00+08:00',
      'horizon_start': '2026-11-02T00:00:00+08:00',
      'horizon_end': '2026-11-03T06:00:00+08:00',
      'base_version': 'v1',
      'availability': <Map<String, String>>[
        {'start_at': '2026-11-02T23:00:00+08:00', 'end_at': '2026-11-03T00:00:00+08:00'},
      ],
      'demands': <Map<String, Object>>[
        {'task_id': 't', 'title': '任务', 'required_minutes': 60},
      ],
    },
    'proposal': genToMidnight.body['proposal'],
  });
  _check(
    '生成器排到 24:00 的提案回喂校验器必须 200 valid（口径不得自相矛盾）',
    selfRoundTrip.status == 200 && selfRoundTrip.body['valid'] == true,
    '${selfRoundTrip.status} ${selfRoundTrip.body['valid']} ${selfRoundTrip.body['error']}',
  );

  // 契约 §5.6 另一句：同一单次事项在一个提案中最多一个可持久化 block。
  // §5.8 封闭码集里只有 RECURRING 那条多块码，无单次事项多块码 → 走结构错误 422。
  Map<String, dynamic> oneTimeBody(List<Map<String, String>> blocks) => {
        'input': <String, dynamic>{
          'now': '2026-11-02T08:00:00+08:00',
          'horizon_start': '2026-11-02T00:00:00+08:00',
          'horizon_end': '2026-11-03T22:00:00+08:00',
          'base_version': 'v1',
          'availability': <Map<String, String>>[
            {'start_at': '2026-11-02T08:00:00+08:00', 'end_at': '2026-11-02T18:00:00+08:00'},
            {'start_at': '2026-11-03T08:00:00+08:00', 'end_at': '2026-11-03T18:00:00+08:00'},
          ],
          'demands': <Map<String, Object>>[
            {'task_id': 't-one', 'title': '单次', 'required_minutes': 30, 'task_kind': 'one_time'},
            {'task_id': 't-rec', 'title': '周期', 'required_minutes': 30, 'task_kind': 'recurring'},
          ],
        },
        'proposal': <String, dynamic>{'blocks': blocks},
      };
  final twoOneTime = handleRequest('POST', '/validate_schedule', oneTimeBody(<Map<String, String>>[
    {
      'task_id': 't-one',
      'block_id': 'b1',
      'task_kind': 'one_time',
      'start_at': '2026-11-02T09:00:00+08:00',
      'end_at': '2026-11-02T09:30:00+08:00',
    },
    {
      'task_id': 't-one',
      'block_id': 'b2',
      'task_kind': 'one_time',
      'start_at': '2026-11-02T14:00:00+08:00',
      'end_at': '2026-11-02T14:30:00+08:00',
    },
  ]));
  _check(
    '同一单次事项两块 → 422 PROPOSAL_INVALID（§5.6，码集无对应码故走结构错误）',
    twoOneTime.status == 422 && '${(twoOneTime.body['error'] as Map?)?['code']}' == 'PROPOSAL_INVALID',
    '${twoOneTime.status} ${twoOneTime.body['error']}',
  );
  final oneOneTime = handleRequest('POST', '/validate_schedule', oneTimeBody(<Map<String, String>>[
    {
      'task_id': 't-one',
      'block_id': 'b1',
      'task_kind': 'one_time',
      'start_at': '2026-11-02T09:00:00+08:00',
      'end_at': '2026-11-02T09:30:00+08:00',
    },
  ]));
  _check(
    '单次事项一块 → 200 valid（对照，证明上面不是把单次事项一律拒掉）',
    oneOneTime.status == 200 && oneOneTime.body['valid'] == true,
    '${oneOneTime.status} ${oneOneTime.body['valid']} ${oneOneTime.body['error']}',
  );
  final twoRecurring = handleRequest('POST', '/validate_schedule', oneTimeBody(<Map<String, String>>[
    {
      'task_id': 't-rec',
      'block_id': 'b1',
      'task_kind': 'recurring',
      'start_at': '2026-11-02T09:00:00+08:00',
      'end_at': '2026-11-02T09:30:00+08:00',
    },
    {
      'task_id': 't-rec',
      'block_id': 'b2',
      'task_kind': 'recurring',
      'start_at': '2026-11-03T09:00:00+08:00',
      'end_at': '2026-11-03T09:30:00+08:00',
    },
  ]));
  _check(
    '周期任务跨两日各一块 → 200 valid（对照，新守卫不得误杀合法跨日）',
    twoRecurring.status == 200 && twoRecurring.body['valid'] == true,
    '${twoRecurring.status} ${twoRecurring.body['valid']} ${twoRecurring.body['error']}',
  );

  stdout.writeln('== 3. 错误路径 ==');  final noOffset = _body(_fixture('normal.json'));
  (noOffset['input'] as Map<String, dynamic>)['now'] = '2026-11-02T08:00:00';
  final rejected = handleRequest('POST', '/generate_schedule', noOffset);
  _check('无偏移时间被拒: 400', rejected.status == 400, '${rejected.status}');
  _check(
    '无偏移时间被拒: 指向 input.now',
    '${(rejected.body['error'] as Map?)?['field']}' == 'input.now',
    '${rejected.body['error']}',
  );

  final unknown = handleRequest('GET', '/nope', null);
  _check('未知路径: 404', unknown.status == 404, '${unknown.status}');
  final wrongMethod = handleRequest('GET', '/generate_schedule', null);
  _check('GET 打业务端点: 405', wrongMethod.status == 405, '${wrongMethod.status}');

  stdout.writeln('== 4. 真实 HTTP 往返 ==');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  server.listen((request) async {
    final raw = await utf8.decoder.bind(request).join();
    final result = handleRequest(request.method, request.uri.path, raw.trim().isEmpty ? null : jsonDecode(raw));
    request.response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    request.response.statusCode = result.status;
    request.response.write(jsonEncode(result.body));
    await request.response.close();
  });

  final client = HttpClient();
  try {
    final healthRequest = await client.getUrl(Uri.parse('$base/health'));
    final healthResponse = await healthRequest.close();
    final healthBody = jsonDecode(await utf8.decoder.bind(healthResponse).join()) as Map<String, dynamic>;
    _check('HTTP /health: 200', healthResponse.statusCode == 200, '${healthResponse.statusCode}');
    _check('HTTP /health: service=m2-engine', healthResponse.statusCode == 200 && healthBody['service'] == 'm2-engine', '${healthBody['service']}');

    final generateRequest = await client.postUrl(Uri.parse('$base/generate_schedule'));
    generateRequest.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    generateRequest.write(jsonEncode(_body(_fixture('normal.json'))));
    final generateResponse = await generateRequest.close();
    final generateBody = jsonDecode(await utf8.decoder.bind(generateResponse).join()) as Map<String, dynamic>;
    final httpBlocks = ((generateBody['proposal'] as Map?)?['blocks'] as List?) ?? const [];
    _check('HTTP /generate_schedule: 200', generateResponse.statusCode == 200, '${generateResponse.statusCode}');
    _check('HTTP /generate_schedule: 与进程内结果同块数', httpBlocks.length == normalBlocks.length, '${httpBlocks.length} vs ${normalBlocks.length}');
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }

  stdout.writeln('');
  stdout.writeln('通过 $_passed 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    stdout.writeln('失败清单：${_failures.join(' | ')}');
    exit(1);
  }
  stdout.writeln('SMOKE OK');
}
