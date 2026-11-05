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

  stdout.writeln('== 3. 错误路径 ==');
  final noOffset = _body(_fixture('normal.json'));
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
