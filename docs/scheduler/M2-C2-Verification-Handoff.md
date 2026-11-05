# M2 · C2 引擎第三方复验交接包（给 M3）

> **用途**：M0 2026-11-05 09:43:21Z 裁定「追加 19-C2 引擎第三方实测」。本文提供 M3 复验所需的全部信息。
> **作者**：B（M2）刘恒瑜　**生成时间**：2026-11-05 17:48（+08）　**修订**：2026-11-05 18:40（+08，指纹口径 + 缺陷 B 修复）
> **⚠️ 历史件声明（2026-11-06 02:55 +08 补）**：本文对应 C2 复验坐标 `f929c0c1`（后经 `85867ec`/`73599a9`），
> 当时域测试为 58 条。此后引擎按 M0 P0/P1 修复包前进到 **69 条**（`9e27a7a`/`6ec72e6`），
> 当前坐标请看 `M2-Engine-Service-Interface.md` 与 `tools/m2-engine/deploy/PACKAGING.md`。
> 本文的 58 条断言与行号**只对该历史坐标成立**，不要拿它核当前代码。

> **本包不含任何业务代码改动承诺**：M2 分支只为「测试健壮性」改过 `test/agent_scheduler_test.dart`，两个被测源码 blob 未动（证据见 §2.1）。

---

## 一、要验证什么（19-C2 四条）

| # | 判据 | 期望行为 |
|---|---|---|
| a | `availability = null` | 按 `preferences` 的 `dayStartMinute` / `dayEndMinute` 逐日推导，正常排入 |
| b | `availability = []` | **不推导**；全部任务进 `unplanned_tasks`，`reason_code = NO_AVAILABILITY`，并产出 `NO_AVAILABILITY_WINDOW` 解释 |
| c | `availability` 非空 | **只使用显式窗口**，忽略 preferences 推导出的时段 |
| d | 序列化 | `Proposal.toJson()` 的键集合恰为 `{blocks, changes, unplanned_tasks, explanations}`，**不含 `availability`** |

对应两条用例：`T-6`（`test/agent_scheduler_test.dart` **L1120**）、`T-7`（**L1168**）。行号为修复版（`dd15a480…`）；修复前版本为 L1096 / L1144，内容未变、只整体下移 24 行。

---

## 二、代码坐标（完整 SHA，勿用短 SHA）

| 项 | 值 |
|---|---|
| 仓库（fork） | `https://github.com/973457137-lhy/check-d-lhy.git` |
| 分支 | `feat/m2-availability-tri-state` |
| **M3 实跑时的 head（历史坐标）** | `f929c0c19c75384aeb57527d6af8525bf68291fe` |
| **本次修复版** | `85867ecd4bbc4ffda945b2142b9a9de3f14e1d02`（父 `f929c0c1`，1 file / +76 −12，已推 fork；docs 修订见随后独立 commit） |
| 上游目标仓库 | `Dai-xx66/check-d`（本分支**未**向该仓推任何内容，也**未**开 PR） |

### 2.1 三个文件指纹（2026-11-05 修订：blob 与 sha256 分列，不再混用口径）

**修订原因（我自曝的缺陷 A）**：旧表只给 sha256、未标换行口径，而三个文件里 engine 是 LF、contract 与 test 是 CRLF，于是同一份代码在两台机器上算出两个值，被误读成「版本漂移」。M3 已实测确认成因只是行尾（工作树 autocrlf），内容逐位一致。

**从此固定给两个值**：

- **git blob SHA-1** —— `git hash-object <file>`，即写进索引/提交后的对象名，跨平台稳定、**不受 autocrlf 影响**；第三方优先核这个。
- **sha256** —— 分「磁盘现值（CRLF）」「LF 归一后」两栏，标清哪个是哪个。

#### 表 A：M3 已实跑通过的版本（`f929c0c1`，历史坐标）

| 路径（仓库内） | git blob SHA-1 | sha256（LF 归一） | 字节 / 行（LF 口径） |
|---|---|---|---|
| `lib/.../domain/schedule_contract.dart` | `f0e690bd749f05cb44023ef1f9b276574c8c488a` | `cd8e65cc7296d07be932228fe0f88b0a274febf8d3f805d383d7f241069a67c5` | 23,097 B / 665 |
| `lib/.../domain/schedule_engine.dart` | `1b06082708dfa86a1a896f57e8a275c711460f2f` | `1b0f6baaf6f5f811aa6679d13d280229030d08358399ba2d406185aa372193be` | 28,053 B / 824 |
| `test/agent_scheduler_test.dart` | `1e50bc3463417eeb7488b6c819b43770ae42b916` | `db9f3012eda4e5f5fd0ed1ed49756b05a39df6bdb4d28fa5f0a02b8f7ad99edc` | 81,740 B / 2,359 |

#### 表 B：本次修复后的版本（**已提交 `85867ecd` 并推 fork**；docs 修订见随后独立的 docs-only commit）

| 路径（仓库内） | git blob SHA-1 | sha256（磁盘现值 CRLF） | sha256（LF 归一） |
|---|---|---|---|
| `lib/.../domain/schedule_contract.dart` | `f0e690bd749f05cb44023ef1f9b276574c8c488a`（未动） | `3867314180f53c7dca076cce906ebe53f4ec22d0c646f3ae4c6c0ac567dd4232`（23,762 B） | `cd8e65cc7296d07be932228fe0f88b0a274febf8d3f805d383d7f241069a67c5`（23,097 B / 665 行） |
| `lib/.../domain/schedule_engine.dart` | `1b06082708dfa86a1a896f57e8a275c711460f2f`（未动） | `1b0f6baaf6f5f811aa6679d13d280229030d08358399ba2d406185aa372193be`（28,053 B，**本文件磁盘即 LF，两栏同值**） | 同左（824 行） |
| `test/agent_scheduler_test.dart` | `dd15a480e75c9d9ac9fed8eed22504f7f012976d` | `798d6631a5aa8fafba80bd3439af5d61e89ecf95fe81ab11a18eecec11371de3`（87,216 B） | `bbc2f2447b841b620edbeab0c663c3d7f295fefd2c01cdd5ab10dc5a80a46662`（84,793 B / 2,423 行） |

> 只有 `agent_scheduler_test.dart` 的 blob 变了（`1e50bc34…` → `dd15a480…`），两个被测源码的 blob **一字未动**——这就是「只改测试、不改业务逻辑」的字节级证据。

只要这三个文件的 blob 与上表一致，就等价于跑到了我报的那版代码；**不需要信任我的自报**。

### 2.2 缺陷 B 修复：模块边界守卫不再依赖仓库布局

旧用例用相对路径直接读 `lib/features/agent_scheduler/domain/*.dart`，隔离工程里必红，只能靠补第二份副本凑绿——而副本一旦陈旧，守卫扫的字节就不是被执行的字节，假通过从运行期搬到了守卫期（M3 指出并确认）。

现改为：在 `lib/` 下**按 basename 递归查找**被测源码。规则五条，逐条对应 M0 令与 M3 硬化：

| 情形 | 行为 | 依据 |
|---|---|---|
| 命中 1 个 | 正常扫描 | — |
| 命中多个、内容一致（LF 归一后比较） | **逐份都扫**，不得任取其一 | M3 硬化① |
| 命中多个、内容不一致 | `fail()`，列出每个候选路径与 LF 归一字节数 | M3 硬化① + M0「不得复制第二份源码制造绿灯」 |
| 命中 0 个（`lib/` 存在） | `fail()`，写明搜索根与 basename | M0「必须明确 FAIL/UNVERIFIABLE，不能静默 skip」 |
| 搜索根 `lib/` 不存在 | `markTestSkipped`，写明搜索根、basename、当前工作目录，并注明「本条不计入通过」 | M3 硬化② |

> 后两行在**能编译的 Dart 包里不可达**：`package:` 导入本身就要求 `lib/<basename>` 存在。这两个分支只是防御网，**不会**在本项目两条通道里静默吞掉任何失败；报告口径仍是 `58 passed + 0 skipped`。

**变异证据（证明守卫不空转）**：在隔离工程临时放一份同名副本、末尾加一行 → `+57 -1`，报错原文「`schedule_engine.dart` 在 `lib/` 下命中 2 个候选且内容不一致」；删掉临时副本后恢复 `58 passed`。变异只在临时目录，未改仓库源文件。

**副作用（净改进）**：路径 A 不再需要「补副本」这一步——隔离工程把源码放 `lib/` 顶层或 `lib/features/.../domain/` 都能被唯一的 basename 命中。

---

## 三、运行环境

| 项 | 要求 | 我实测的环境 |
|---|---|---|
| Flutter | ≥ 3.47（stable） | 3.47.9 stable |
| Dart SDK | ≥ 3.13 | 3.13.7 |
| 网络 | 首次 `pub get` 需访问 pub.dev；测试本身**不联网** | — |
| 数据库 / 模拟器 / 设备 | **都不需要** | — |

> 纯函数测试，不触碰 Flutter 引擎、不连库、不读系统时钟（时间基准全部来自 `ScheduleInput.now`）。

---

## 四、两条可执行路径（任选其一）

### 路径 A：最小 Dart 工程（推荐，轻量、无需 Flutter）

只需 Dart SDK，不需要 Flutter，也不需要本项目的 `pubspec`。

```bash
# 1) 取代码（只取这一条分支，不拉全历史）
git clone --depth 1 --branch feat/m2-availability-tri-state \
  https://github.com/973457137-lhy/check-d-lhy.git m2src

# 2) 建最小工程
mkdir -p m2verify/lib m2verify/test
cp m2src/lib/features/agent_scheduler/domain/schedule_contract.dart m2verify/lib/
cp m2src/lib/features/agent_scheduler/domain/schedule_engine.dart   m2verify/lib/

# 3) 改写 import（只改包名与测试框架，断言体一个字不动）
sed -e 's|package:check_d/features/agent_scheduler/domain/schedule_contract.dart|package:m2verify/schedule_contract.dart|' \
    -e 's|package:check_d/features/agent_scheduler/domain/schedule_engine.dart|package:m2verify/schedule_engine.dart|' \
    -e 's|package:flutter_test/flutter_test.dart|package:test/test.dart|' \
    m2src/test/agent_scheduler_test.dart > m2verify/test/agent_scheduler_test.dart

# 4) 依赖
cat > m2verify/pubspec.yaml <<'YAML'
name: m2verify
environment:
  sdk: ^3.13.0
dev_dependencies:
  test: ^1.25.0
YAML
cd m2verify && dart pub get

# 5) 跑
dart test test/agent_scheduler_test.dart
```

**预期输出（最后一行）**：

```
00:00 +58: All tests passed!
```

退出码 `0`，无 `skip`、无 `flaky`。

> ⚠️ **常见坑（2026-11-05 修复后已不再要求）**：旧版守卫用相对路径 `lib/features/agent_scheduler/domain/*.dart`，隔离工程必须补同名副本才能绿；现在按 basename 递归查找，**不要**再往 `lib/` 塞第二份同名源码——多份且内容不一致会直接 `fail`（这是设计意图）。

### 路径 B：完整仓库 + Flutter

```bash
git clone --depth 1 --branch feat/m2-availability-tri-state \
  https://github.com/973457137-lhy/check-d-lhy.git
cd check-d-lhy
flutter pub get

# 若本机设置了 http_proxy，必须先去掉：代理会劫持 flutter 与 flutter_tester
# 之间的 localhost WebSocket，报 Invalid WebSocket upgrade request
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  flutter test test/agent_scheduler_test.dart
```

**预期输出**：`00:00 +58: All tests passed!`，退出码 `0`。

> 路径 B 跑完，仓库里 4 个自动生成文件可能被改写（`macos/Flutter/GeneratedPluginRegistrant.swift`、`windows/flutter/generated_plugin_registrant.{cc,h}`、`windows/flutter/generated_plugins.cmake`）。**复验请用一次性 clone**，不要在你的工作区里跑，避免污染。

---

## 五、请你记录的内容（按 M0 要求）

1. 实际使用的 commit SHA（完整 40 位）；
2. 三个文件的 **blob SHA-1 + sha256（标 LF/CRLF 口径）**（与你取回的实际字节比对，报「一致 / 不一致」）；
3. 实际执行命令与**整体退出码**；
4. 逐项结果：19-C2 的 a/b/c/d 四条分别 PASS / FAIL / 未能验证；
5. 日志指纹（输出文件 sha256 或末若干行原文）；
6. 若无法安装依赖或复现：标 `BLOCKED` / `UNVERIFIABLE` 并附**实际错误原文**，**不得**把我的 58/58 改写成第三方实测。

---

## 六、M2 侧的边界承诺

- 复验期间 M2 **不改**被测业务源码，不改 `feat/m2-availability-tri-state` 的其他内容，不 rebase、不 force-push；
- 不新建 PR、不改 PR #2/#5 的 base、不合并任何 PR；
- 若你发现用例本身有问题（断言写错、覆盖不到判据），直接指出，我按你的证据改，不辩解。

---

## 七、证据等级说明

| 等级 | 含义 | 当前状态 |
|---|---|---|
| 作者本机双通道实测 | 我在本机跑 `dart test` + `flutter test`，各 58/58 | ✅ 已具备（非 CI；修复后重跑仍 58/58，见 §2.2） |
| **第三方本机实测** | **M3 按本文独立跑出 58/58，exit 0，Dart 3.13.7** | ✅ 已具备（2026-11-05 10:08:27Z，`f929c0c1` 版） |
| CI | GitHub Actions 跑出的结果 | ❌ 不存在（仓库未配置单测 workflow） |

这三级别不可互相替代，报告中请按实际等级写。
