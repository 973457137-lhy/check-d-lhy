# M2 · 模块边界守卫修复 · 交付证据

> 授权：M0 2026-11-05 10:27:44Z《18:26 即时裁定》§四（批准最小测试健壮性修复）+ §五（回报纪律）；M3 2026-11-05 10:28:37Z 两条硬化。
> 作者：B（M2）刘恒瑜　生成：2026-11-05 18:45（+08）
> 状态：**代码修复已提交 `85867ecd4bbc4ffda945b2142b9a9de3f14e1d02`（父 `f929c0c1`）、已推 fork**；该 commit 只含 `test/agent_scheduler_test.dart`（M0 2026-11-05 10:41:22Z 批准，1 file / +76 −12）。本文与两份日志随后以**独立 docs-only commit** 入库（见 `git log`），不与该代码 commit 混在一起。

---

## 一、范围（严格限定：只改测试，不改业务逻辑）

| 项 | 结果 |
|---|---|
| 改动文件 | 仅 `test/agent_scheduler_test.dart` |
| diff | 1 file / **+76 −12** |
| `schedule_contract.dart` blob | `f0e690bd…` → **未变** |
| `schedule_engine.dart` blob | `1b060827…` → **未变** |
| 新增测试 | 0 条（仍是 58 条，改的是守卫实现，不是覆盖面） |
| rebase / force-push / PR | 均未做 |

---

## 二、完整 diff

```diff
diff --git a/test/agent_scheduler_test.dart b/test/agent_scheduler_test.dart
index 1e50bc3..dd15a48 100644
--- a/test/agent_scheduler_test.dart
+++ b/test/agent_scheduler_test.dart
@@ -18,6 +18,30 @@ String stripComments(String source) => source
     })
     .join('\n');
 
+/// 在 [root] 下按 basename 递归查找候选源码文件（路径排序后返回；根不存在返回空）。
+///
+/// 用 basename 而不是硬编码相对路径，是为了让宿主工程
+/// （`lib/features/agent_scheduler/domain/`）与隔离验证工程
+/// （源码拷到 `lib/` 顶层）都能定位到同一份被测源码。
+List<String> _findSourceCandidates(String root, String basename) {
+  final dir = Directory(root);
+  if (!dir.existsSync()) return const <String>[];
+  final hits = <String>[];
+  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
+    if (entity is! File) continue;
+    final segments = entity.uri.pathSegments;
+    if (segments.isNotEmpty && segments.last == basename) {
+      hits.add(entity.path);
+    }
+  }
+  hits.sort();
+  return hits;
+}
+
+/// 归一换行后再比较：autocrlf 造成的 CRLF/LF 差异不是内容差异，
+/// 不该让守卫误报「两份源码不一致」。
+String _normalizeNewlines(String source) => source.replaceAll('\r\n', '\n');
+
 DateTime _at(int dayOffset, int hour, [int minute = 0]) =>
     DateTime(_monday.year, _monday.month, _monday.day + dayOffset, hour, minute);
 
@@ -2340,19 +2364,59 @@ void main() {
   });
 
   group('模块边界', () {
+    // 被测源码按 basename 在 `lib/` 下递归定位，不写死相对路径：
+    // 否则隔离验证工程（源码拷到 `lib/` 顶层）必红，只能靠补第二份副本凑绿，
+    // 而副本一旦陈旧，守卫扫的字节就不是被执行的字节 —— 假通过从运行期搬到守卫期。
+    const searchRoot = 'lib';
+    const guardedBasenames = <String>[
+      'schedule_contract.dart',
+      'schedule_engine.dart',
+    ];
+
     test('调度模块不得访问数据库或任何应用层代码', () {
-      for (final path in [
-        'lib/features/agent_scheduler/domain/schedule_contract.dart',
-        'lib/features/agent_scheduler/domain/schedule_engine.dart',
-      ]) {
-        // 只扫描代码：本模块的文档注释里本就会出现这些名字（用于说明"不得依赖"），
-        // 若连注释一起匹配，守卫会被自己绊倒。
-        final code = stripComments(File(path).readAsStringSync());
-        expect(code, isNot(contains('package:drift')), reason: path);
-        expect(code, isNot(contains('package:supabase')), reason: path);
-        expect(code, isNot(contains('task_repository')), reason: path);
-        expect(code, isNot(contains('app_database')), reason: path);
-        expect(code, isNot(contains('DateTime.now()')), reason: path);
+      for (final basename in guardedBasenames) {
+        final candidates = _findSourceCandidates(searchRoot, basename);
+
+        if (candidates.isEmpty) {
+          // 搜索根都不存在 = 环境无法提供被测源码：标 UNVERIFIABLE 并写清搜索根，
+          // 绝不静默折算成通过（报告口径只能是「N passed + 1 skipped」）。
+          if (!Directory(searchRoot).existsSync()) {
+            markTestSkipped(
+              'UNVERIFIABLE：搜索根 `$searchRoot/` 不存在'
+              '（当前工作目录 ${Directory.current.path}），无法定位 `$basename`；'
+              '本条不计入通过。',
+            );
+            return;
+          }
+          // 根在、文件不在 = 源码缺失，明确失败，不用 skip 掩盖。
+          fail('在 `$searchRoot/` 下递归查找 `$basename` 命中 0 个候选：被测源码缺失，守卫不空转通过。');
+        }
+
+        // 多候选：逐份核对。内容不一致直接失败，不允许任取其一（否则漏洞原样开回来）。
+        final normalized = <String, String>{
+          for (final path in candidates)
+            path: _normalizeNewlines(File(path).readAsStringSync()),
+        };
+        if (normalized.values.toSet().length > 1) {
+          final detail = normalized.entries
+              .map((e) => '  - ${e.key}：${utf8.encode(e.value).length} B（LF 归一后）')
+              .join('\n');
+          fail(
+            '`$basename` 在 `$searchRoot/` 下命中 ${candidates.length} 个候选且内容不一致：\n'
+            '$detail\n必须只保留一份被测源码；守卫拒绝在候选之间任取其一。',
+          );
+        }
+
+        for (final path in candidates) {
+          // 只扫描代码：本模块的文档注释里本就会出现这些名字（用于说明"不得依赖"），
+          // 若连注释一起匹配，守卫会被自己绊倒。
+          final code = stripComments(normalized[path]!);
+          expect(code, isNot(contains('package:drift')), reason: path);
+          expect(code, isNot(contains('package:supabase')), reason: path);
+          expect(code, isNot(contains('task_repository')), reason: path);
+          expect(code, isNot(contains('app_database')), reason: path);
+          expect(code, isNot(contains('DateTime.now()')), reason: path);
+        }
       }
     });
   });
```

---

## 三、规则与依据（逐条对应）

| 情形 | 行为 | 依据 |
|---|---|---|
| 命中 1 个 | 正常扫描 | — |
| 命中多个、内容一致（LF 归一后比较） | **逐份都扫**，不得任取其一 | M3 硬化① |
| 命中多个、内容不一致 | `fail()`，列出每个候选路径与 LF 归一字节数 | M3 硬化① + M0「不得复制第二份源码制造绿灯」 |
| 命中 0 个（`lib/` 存在） | `fail()`，写明搜索根与 basename | M0「必须明确 FAIL/UNVERIFIABLE，不能静默 skip」 |
| 搜索根 `lib/` 不存在 | `markTestSkipped`，写明搜索根、basename、当前工作目录，并注明「本条不计入通过」 | M3 硬化② |

**关于 skip 与 fail 的取舍（我给两位的说明，不是辩解）**：M0 令要求「不能通过静默 skip」，M3 硬化要求「skip 必须可见」。两者交集是「skip 只能出现在环境根本无法提供搜索根时，且必须自证」。因此我把「根在但文件不在」判为 `fail`（更严），只在「根都不存在」时 skip，并在消息里带 UNVERIFIABLE 与搜索根。

**可达性说明（重要，别把它当覆盖）**：后两行在能编译的 Dart 包里**不可达**——`package:` 导入本身就要求 `lib/<basename>` 存在。它们只作防御网，所以本项目**不存在**「守卫静默 skip 变绿」的路径；如实口径是 `58 passed + 0 skipped`。

---

## 四、两通道回归（修复后实测）

| 通道 | 命令 | 退出码 | 结果 | 日志 |
|---|---|---|---|---|
| 宿主 `flutter test` | `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy flutter test test/agent_scheduler_test.dart` | **0** | `00:00 +58: All tests passed!` | `docs/scheduler/reports/2026-11-05-host-after-guard-fix.log`（5,867 B / 60 行 / sha256 `b4024090a57adae664e97fdbff70b9e105b7b8d6dbc60a12e2fdd6b248efe0b3`） |
| 隔离 `dart test` | `cd /e/m2-verify && dart test` | **0** | `00:00 +58: All tests passed!` | `docs/scheduler/reports/2026-11-05-isolated-after-guard-fix.log`（7,699 B / 60 行 / sha256 `549c23ca8762074aeb9a617477924e530ee93b720b9770cb3bb1b8d4f28a6aab`） |

- Dart SDK 3.13.7（stable，windows_x64）。
- **两通道独立跑，不合并计分**；均为本机实测，**非 CI**。
- 隔离工程已**不再需要**同名副本：守卫按 basename 命中 `lib/features/agent_scheduler/domain/schedule_*.dart` 本身。

---

## 五、变异测试（证明守卫不空转）

在隔离工程临时放一份同名副本并在末尾加一行（模拟「陈旧副本」）：

```
00:00 +57: 模块边界 调度模块不得访问数据库或任何应用层代码
00:00 +57 -1: 模块边界 调度模块不得访问数据库或任何应用层代码 [E]
  `schedule_engine.dart` 在 `lib/` 下命中 2 个候选且内容不一致：
00:00 +57 -1: Some tests failed.
```

删除临时副本后恢复 `00:00 +58: All tests passed!`。变异只在 `/e/m2-verify` 临时目录，仓库源文件未改。

---

## 六、指纹（blob 与 sha256 分列，口径写明）

| 路径 | git blob SHA-1 | sha256（磁盘现值 CRLF） | sha256（LF 归一） |
|---|---|---|---|
| `lib/.../domain/schedule_contract.dart` | `f0e690bd749f05cb44023ef1f9b276574c8c488a`（未动） | `3867314180f53c7dca076cce906ebe53f4ec22d0c646f3ae4c6c0ac567dd4232`（23,762 B） | `cd8e65cc7296d07be932228fe0f88b0a274febf8d3f805d383d7f241069a67c5`（23,097 B / 665 行） |
| `lib/.../domain/schedule_engine.dart` | `1b06082708dfa86a1a896f57e8a275c711460f2f`（未动） | `1b0f6baaf6f5f811aa6679d13d280229030d08358399ba2d406185aa372193be`（28,053 B，磁盘即 LF） | 同左（824 行） |
| `test/agent_scheduler_test.dart` | `dd15a480e75c9d9ac9fed8eed22504f7f012976d`（新） | `798d6631a5aa8fafba80bd3439af5d61e89ecf95fe81ab11a18eecec11371de3`（87,216 B） | `bbc2f2447b841b620edbeab0c663c3d7f295fefd2c01cdd5ab10dc5a80a46662`（84,793 B / 2,423 行） |

旧 blob（M3 已复验版）：`1e50bc3463417eeb7488b6c819b43770ae42b916`。

---

## 七、未做与边界

- **代码修复已提交并推送**：commit `85867ecd4bbc4ffda945b2142b9a9de3f14e1d02`，父 `f929c0c19c75384aeb57527d6af8525bf68291fe`，分支 `feat/m2-availability-tri-state`，tree `f30d27aacf689acc3d0003517e43e261002f1630`；远端 `git ls-remote` 已核对 = 上述 SHA。本文与日志另以独立 docs-only commit 入库。
- 未动 `schedule_contract.dart` / `schedule_engine.dart` 一个字节。
- 未 rebase、未 force-push、未建 PR、未合并任何 PR。
- 没把这次修复换算成「19-C2 覆盖面变大」：58 条还是 58 条，只是守卫不再依赖布局。
