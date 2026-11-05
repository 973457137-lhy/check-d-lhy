# M2 · C2 引擎第三方复验交接包（给 M3）

> **用途**：M0 2026-11-05 09:43:21Z 裁定「追加 19-C2 引擎第三方实测」。本文提供 M3 复验所需的全部信息。
> **作者**：B（M2）刘恒瑜　**生成时间**：2026-11-05 17:48（+08）
> **本包不含任何代码改动承诺**：M2 分支保持原样，不为测试改动代码。

---

## 一、要验证什么（19-C2 四条）

| # | 判据 | 期望行为 |
|---|---|---|
| a | `availability = null` | 按 `preferences` 的 `dayStartMinute` / `dayEndMinute` 逐日推导，正常排入 |
| b | `availability = []` | **不推导**；全部任务进 `unplanned_tasks`，`reason_code = NO_AVAILABILITY`，并产出 `NO_AVAILABILITY_WINDOW` 解释 |
| c | `availability` 非空 | **只使用显式窗口**，忽略 preferences 推导出的时段 |
| d | 序列化 | `Proposal.toJson()` 的键集合恰为 `{blocks, changes, unplanned_tasks, explanations}`，**不含 `availability`** |

对应两条用例：`T-6`（`test/agent_scheduler_test.dart` **L1096**）、`T-7`（**L1144**）。

---

## 二、代码坐标（完整 SHA，勿用短 SHA）

| 项 | 值 |
|---|---|
| 仓库（fork） | `https://github.com/973457137-lhy/check-d-lhy.git` |
| 分支 | `feat/m2-availability-tri-state` |
| **完整 head SHA** | `4919546a865050d8536a091dc8208ad1842df160` |
| 远端同步 | 已确认 `refs/heads/feat/m2-availability-tri-state` = 上述 SHA |
| 上游目标仓库 | `Dai-xx66/check-d`（本分支**未**向该仓推任何内容，也**未**开 PR） |

### 2.1 三个文件指纹（取回后请先核字节）

| 路径（仓库内） | 字节 | 行 | sha256 |
|---|---|---|---|
| `lib/features/agent_scheduler/domain/schedule_contract.dart` | 23,762 | 665 | `3867314180f53c7dca076cce906ebe53f4ec22d0c646f3ae4c6c0ac567dd4232` |
| `lib/features/agent_scheduler/domain/schedule_engine.dart` | 28,053 | 824 | `1b0f6baaf6f5f811aa6679d13d280229030d08358399ba2d406185aa372193be` |
| `test/agent_scheduler_test.dart` | 84,099 | 2,359 | `0788c2bc51d1e4a93b284d05861d2d687f4ceed77a80c1999eac422093f37480` |

只要这三个文件的 sha256 与上表一致，就等价于跑到了我报的那版代码；**不需要信任我的自报**。

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

> ⚠️ **常见坑**：不要把两份 domain 文件再复制到 `lib/` 顶层之外的同名位置。`package:m2verify/xxx.dart` 只认 `lib/xxx.dart` 这一个位置；多留一份旧副本会导致「改完代码仍跑旧逻辑」的假通过。

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
2. 三个文件的 sha256（与你取回的实际字节比对，报「一致 / 不一致」）；
3. 实际执行命令与**整体退出码**；
4. 逐项结果：19-C2 的 a/b/c/d 四条分别 PASS / FAIL / 未能验证；
5. 日志指纹（输出文件 sha256 或末若干行原文）；
6. 若无法安装依赖或复现：标 `BLOCKED` / `UNVERIFIABLE` 并附**实际错误原文**，**不得**把我的 58/58 改写成第三方实测。

---

## 六、M2 侧的边界承诺

- 复验期间 M2 **不改** `feat/m2-availability-tri-state` 的任何提交，不 rebase、不 force-push；
- 不新建 PR、不改 PR #2/#5 的 base、不合并任何 PR；
- 若你发现用例本身有问题（断言写错、覆盖不到判据），直接指出，我按你的证据改，不辩解。

---

## 七、证据等级说明

| 等级 | 含义 | 当前状态 |
|---|---|---|
| 作者本机双通道实测 | 我在本机跑 `dart test` + `flutter test`，各 58/58 | ✅ 已具备（非 CI） |
| **第三方本机实测** | **你按本文独立跑出 58/58** | ⬜ 待你执行 |
| CI | GitHub Actions 跑出的结果 | ❌ 不存在（仓库未配置单测 workflow） |

这三级别不可互相替代，报告中请按实际等级写。
