/// M2 调度引擎的 HTTP 入口（纯 Dart，`dart:io`，无 Flutter、无第三方依赖）。
///
/// 启动：
///   cd E:/Projects/check-d-lhy
///   dart run tools/m2-engine/bin/serve.dart
///   # 可选：M2_ENGINE_PORT=9000 M2_ENGINE_HOST=0.0.0.0
///
/// 只有三个业务端点：/generate_schedule、/validate_schedule、/repair_schedule，
/// 外加 /health。语义全部在 domain 引擎里，本文件只做 HTTP 编解码与日志。
library;

import 'dart:convert';
import 'dart:io';

import '../lib/handler.dart';

Future<void> main(List<String> args) async {
  final port = int.tryParse(Platform.environment['M2_ENGINE_PORT'] ?? '') ?? 8787;
  final host = Platform.environment['M2_ENGINE_HOST'] ?? '127.0.0.1';

  final server = await HttpServer.bind(host, port);
  server.autoCompress = true;

  stdout.writeln('[m2-engine] listening on http://$host:$port');
  stdout.writeln('[m2-engine] version=$serviceVersion contract_basis=$contractBasis');
  stdout.writeln('[m2-engine] endpoints: GET /health | POST /generate_schedule | POST /validate_schedule | POST /repair_schedule');
  stdout.writeln('[m2-engine] 提示：body 可写 {"input": {...}} 或直接 {...}；时间必须带 +08:00 偏移');

  await for (final request in server) {
    final stopwatch = Stopwatch()..start();
    final response = request.response;
    response.headers.set('content-type', 'application/json; charset=utf-8');
    response.headers.set('access-control-allow-origin', '*');
    response.headers.set('access-control-allow-headers', 'content-type');
    response.headers.set('access-control-allow-methods', 'GET, POST, OPTIONS');

    HandlerResult result;
    try {
      if (request.method == 'OPTIONS') {
        result = const HandlerResult(204, {'ok': true});
      } else {
        final raw = await utf8.decoder.bind(request).join();
        // 解码逻辑放在 lib/handler.dart 里，与自检共用同一份实现。
        // 留在这里的话，自检只能再抄一份才能验「非法 JSON 也带 retryable」，
        // 于是测的是副本、跑的是另一份——本项目反复踩过的假通过形态。
        Object? body;
        final decodeError = decodeBodyOrError(raw, onDecoded: (value) => body = value);
        if (decodeError != null) {
          result = decodeError;
          await _write(response, result, request, stopwatch);
          continue;
        }
        result = handleRequest(request.method, request.uri.path, body);
      }
    } catch (error, stack) {
      stderr.writeln('[m2-engine] unhandled: $error\n$stack');
      // 5xx 才可重试；4xx 一律 retryable=false（M3 F-1）。同样复用统一构造。
      result = HandlerResult(
        500,
        errorBody(
          code: 'INTERNAL_ERROR',
          field: 'server',
          message: '引擎内部错误：$error',
          retryable: true,
        ),
      );
    }
    await _write(response, result, request, stopwatch);
  }
}

Future<void> _write(
  HttpResponse response,
  HandlerResult result,
  HttpRequest request,
  Stopwatch stopwatch,
) async {
  response.statusCode = result.status;
  if (result.status != 204) {
    response.write(jsonEncode(result.body));
  }
  await response.close();
  stdout.writeln(
    '[m2-engine] ${request.method} ${request.uri.path} -> ${result.status} in ${stopwatch.elapsedMilliseconds}ms',
  );
}
