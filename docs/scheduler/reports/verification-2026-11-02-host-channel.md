# M2 验证报告（2026-11-02）· 宿主 `flutter test` 通道解除阻塞

> 负责人：B（M2）　日期：2026-11-02
> 契约基准：`c9dda83195a9af4b9ca762d8556fdd0e8d43010a`（本轮无新 SHA，不跑增量 diff）
> 代码基准：`feat/m2-scheduler-basic` @ `73ad200`（**本轮零代码改动**）
> 纪律：隔离 Dart 与宿主 Flutter **两条通道分开报告**，不合并、不互相背书。

## 一、结论（一句话）

宿主 `flutter test` 长期失败的根因**不是** Windows 开发人员模式，也**不是** sqlite3 原生资产 502，
而是**本机环境变量 `http_proxy` 劫持了 `flutter` 工具与 `flutter_tester` 之间的 localhost WebSocket 握手**。
解除代理变量后，**同一条命令、同一份源码，宿主通道 38/38 全通过**；隔离 `dart test` 同样 38/38。

两条通道现在**都是绿的**，且都可复现（命令与输出见第三节）。

## 二、根因与历次失败原因对照

| 轮次 | 报错 | 真实原因 | 是否环境问题 |
|---|---|---|---|
| 早前一轮 | sqlite3 原生资产下载 502 | 走代理下载 GitHub Release 资产失败 | 环境 |
| `e63cdf4` 轮 | 无（曾 38/38 通过一次） | 当次代理进程未拦截 localhost，偶发通过 | 环境（间歇性） |
| `1acd187` / `73d6994` 轮 | `Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request` | `http_proxy` / `HTTP_PROXY` 指向本机代理端口，Dart 的 `HttpClient` 默认读取该变量，于是 `ws://127.0.0.1:<port>` 升级请求被发到代理而非 flutter_tester | 环境（**确定性**，不是间歇） |
| 本轮（`73ad200`） | 同上 | 同上，已定位 | 已解除 |

**关键区别**：`Invalid WebSocket upgrade request` 是**协商层**错误——TCP 连上了，但对面不是
flutter_tester 而是代理，所以 upgrade 失败。这与「开发人员模式未开」（那是构建/符号链接问题）
和「502」（那是网络下载问题）在日志形态上完全不同，三轮不该混为一谈。

定位依据：

```bash
env | grep -i proxy
# http_proxy=http://127.0.0.1:58512
# https_proxy=http://127.0.0.1:58512
# HTTP_PROXY=http://127.0.0.1:58512
# HTTPS_PROXY=http://127.0.0.1:58512
```

Dart 的 `HttpClient`（`flutter_tester` 的宿主侧连接用的就是它）**默认尊重 `http_proxy`**，
且不会自动把 `localhost`/`127.0.0.1` 排除在代理之外。代理进程收到 `GET /... Upgrade: websocket`
后按普通 HTTP 请求处理并返回非 101 响应 → `Invalid WebSocket upgrade request`。

## 三、两条通道的可复现命令与输出

### 3.1 隔离 Dart 通道（纯 Dart VM，不依赖 flutter_tester）

```bash
export PATH="/e/flutter/bin:$PATH"
cd /e/m2-verify            # 隔离工程：仅拷入两份 domain 源码 + 同一份测试文件
dart test
```

输出尾部：

```
00:00 +37: test\agent_scheduler_test.dart: 模块边界 调度模块不得访问数据库或任何应用层代码
00:00 +38: All tests passed!
```

退出码 `0`，**38/38**。

### 3.2 宿主 Flutter 通道（本轮解除阻塞）

```bash
export PATH="/e/flutter/bin:$PATH"
cd /e/Projects/check-d-lhy
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  flutter test test/agent_scheduler_test.dart
```

输出首尾：

```
00:00 +0: loading E:/Projects/check-d-lhy/test/agent_scheduler_test.dart
00:00 +0: generateSchedule 硬避让 任务必须绕开固定课程
...
00:00 +37: 模块边界 调度模块不得访问数据库或任何应用层代码
00:00 +38: All tests passed!
```

退出码 `0`，**38/38**。

若不想每次带 `env -u`，等价做法是保留代理但把本地地址排除：

```bash
export NO_PROXY="127.0.0.1,localhost,::1"
export no_proxy="$NO_PROXY"
flutter test test/agent_scheduler_test.dart
```

### 3.3 隔离工程与仓库的一致性前提

隔离工程里的两份源码与 `lib/features/agent_scheduler/domain/` **逐字节一致**（忽略行尾）。
测试文件的差异**只有 import 三行**（`package:m2_verify/...` + `package:test/test.dart`
对 `package:check_d/...` + `package:flutter_test/flutter_test.dart`），断言体完全相同：

```bash
diff <(tr -d '\r' < /e/m2-verify/test/agent_scheduler_test.dart) \
     <(tr -d '\r' < test/agent_scheduler_test.dart)
# 4,6c4,6  ← 仅第 4–6 行 import 不同，其余无差异
```

也就是说：**两条通道跑的是同一组 38 条断言**，结论可互相印证，但仍按纪律分开记录。

## 四、给 C 的 E0 → E1 升格材料

C 此前的口径是「B 的 38 条记 `B 自述、E0`，升 E1 需**可复现命令 + 输出**」。本轮即交付该材料：

| 升格要件 | 本轮提供 |
|---|---|
| 可复现命令 | 3.1 / 3.2 两段，逐字可粘贴 |
| 输出 | 两条通道各自的 `+38: All tests passed!` 与退出码 0 |
| 代码基准 | `73ad200`（`git rev-parse HEAD` 可直接核） |
| 用例数 | 38，与既有关联矩阵编号一致，无新增、无删减 |
| 环境前提 | 已写明必须排除 `http_proxy`；否则宿主通道复现的是环境错误，不是测试结论 |

**未升格的部分如实保留**：宿主通道通过**不等于**生产环境通过。生产原子写入、可信快照、
`base_version` 事务内核验、时区解析仍为 BLOCKED —— 这四项一条都没被这次 38/38 覆盖。

## 五、副作用与还原（每次跑宿主测试都要做）

`flutter test` 会改写 4 个平台生成文件，属工具链行为，**不得提交**：

```
macos/Flutter/GeneratedPluginRegistrant.swift
windows/flutter/generated_plugin_registrant.cc
windows/flutter/generated_plugin_registrant.h
windows/flutter/generated_plugins.cmake
```

本轮已还原：

```bash
git checkout -- macos/Flutter/GeneratedPluginRegistrant.swift \
  windows/flutter/generated_plugin_registrant.cc \
  windows/flutter/generated_plugin_registrant.h \
  windows/flutter/generated_plugins.cmake
git status --short     # 仅剩 .workbuddy/（本地工作区数据，未跟踪）
```

## 六、边界声明

- **零代码改动**：本轮没有改 `lib/`、没有改 `test/`、没有改契约本体。
- **未合并 PR**：PR #2 保持 Open，head `73ad200`。
- **未替他人判定**：R1/X1 的契约级验收仍归 C；本轮只解除自己的测试通道。
- **不改历史报告**：`revision-2026-10-31-*.md` 里对宿主通道的记录保持原样，本轮结论只写在本文件。
