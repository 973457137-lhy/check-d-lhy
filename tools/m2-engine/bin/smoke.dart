/// 适配层自检：不开框架、不装依赖，`dart run tools/m2-engine/bin/smoke.dart` 直接跑。
///
/// 覆盖两类通道：
/// 1. 进程内调用 `handleRequest`（与 HTTP 层同一函数）；
/// 2. 真起一个 HttpServer，用 HttpClient 打一轮（证明网络链路、编码、状态码都对）。
///
/// 退出码 0 = 全绿；1 = 有断言失败（会打印实际值，不打印「应该没问题」）。
library;

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
