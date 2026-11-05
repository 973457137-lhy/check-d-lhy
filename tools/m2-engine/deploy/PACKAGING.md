# 引擎最小部署包（给 M1 的容器，实测环境：Linux x86_64 + /opt/flutter）

> 依据 M1 2026-11-05 17:24:14Z 的 `/diag` 实测：容器内 `dart`/`flutter` 已装、可 spawn 第二进程、
> 可 bind 127.0.0.1、`/workspace` 可写、`pub.dev` 通。
> 结论：**不需要 Docker，也不需要 `pub get`**——引擎已改为相对导入，纯 `dart run` 即可。

## 一、要拷哪些文件（保持相对布局）

```
<workspace>/
├── tools/m2-engine/
│   ├── bin/serve.dart
│   ├── bin/smoke.dart                # 可选，自检用
│   ├── lib/contract_json.dart
│   ├── lib/handler.dart
│   ├── lib/validate.dart
│   └── fixtures/*.json               # 可选，演示/自检用
└── lib/features/agent_scheduler/domain/
    ├── schedule_contract.dart
    └── schedule_engine.dart
```

**布局不能变**：`tools/m2-engine/lib/*.dart` 用 `../../../lib/features/agent_scheduler/domain/...`
的相对导入引用域文件。把这两个域文件放到别处会直接编译失败——这是有意的，避免出现第二份源码。

## 二、启动

```bash
cd <workspace>
/opt/flutter/bin/dart run tools/m2-engine/bin/serve.dart
# 默认 127.0.0.1:8787；可用环境变量覆盖：
#   M2_ENGINE_PORT=8787  M2_ENGINE_HOST=127.0.0.1
```

- **没有第三方依赖**，不跑 `pub get`；
- 冷启动首次编译约 **10–20 秒**（本机实测），建议启动后轮询 `/health` 再放流量；
- 监听回环即可，公网只暴露你的 `tool_server`。

健康检查：

```bash
curl -fsS http://127.0.0.1:8787/health
# {"ok":true,"service":"m2-engine","version":"1.0.0","contract_basis":"39f7f965",...}
```

## 三、`app.py` 里拉起（示例）

```python
import json, os, subprocess, time, urllib.request

ENGINE_PORT = 8787
_proc = None

def start_engine(workspace="/workspace"):
    global _proc
    env = dict(os.environ, M2_ENGINE_HOST="127.0.0.1", M2_ENGINE_PORT=str(ENGINE_PORT))
    _proc = subprocess.Popen(
        ["/opt/flutter/bin/dart", "run", "tools/m2-engine/bin/serve.dart"],
        cwd=workspace, env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
    )
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{ENGINE_PORT}/health", timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(1)
    return False
```

**失败处理（与 M1 提案一致，我同意）**：引擎起不来或 `/health` 不通时，`generate_schedule` 必须返回
`DEPENDENCY_UNAVAILABLE`，**不得回落成 mock 静默成功**。宁可报错，不假成功。

## 四、容器重启的现实约束（M1 已观测：10–25 分钟一次）

- 引擎是**无状态纯函数服务**，重启后无需恢复任何数据；但 `app.py` 需要重新 spawn 一次。
- 若平台只接受「一条启动命令」，把 spawn 放在 `app.py` 的 lifespan/startup 钩子里即可（上面示例）。
- 演示数据复位与引擎无关：引擎不写库、不留状态，`/admin/reset` 只影响你的 tool_server。

## 五、这个包**不**包含什么（别误读）

- 不含审批、落库、readback、五键信封——全部属 `tool_server` 层；
- 不含鉴权：它只监听回环，公网入口仍是你的服务；
- 不含 `proposal_id` / `snapshot_ref` / `input_digest` / `generated_at` / `expires_at` / `status`：
  方案 A 下这些由服务端补。

## 六、自检（可选，但建议在容器里跑一次）

```bash
/opt/flutter/bin/dart run tools/m2-engine/bin/smoke.dart
# 末行 SMOKE OK，退出码 0；当前 50 项断言（内部会自己起临时端口跑真实 HTTP）
```

它证明的是：端点、编解码、+08:00 墙钟、三态、非法输入拒绝、确定性都在当前环境成立。

## 七、这个包已经按「干净拷贝」实测过（2026-11-06 01:55 +08）

不是「应该能跑」，是真跑过：把上面 10 个文件（共 **136 KB**）拷到一个**没有 pubspec、
没有 .dart_tool、没有 git** 的空目录 `/e/m2-pack`，然后：

```bash
cd /e/m2-pack
dart run tools/m2-engine/bin/smoke.dart
# 通过 50 项，失败 0 项 / SMOKE OK / exit 0

M2_ENGINE_PORT=8899 dart run tools/m2-engine/bin/serve.dart
curl -s http://127.0.0.1:8899/health
# {"ok":true,"service":"m2-engine","version":"1.0.0","contract_basis":"39f7f965",...}
curl -s -X POST http://127.0.0.1:8899/generate_schedule \
  -H 'content-type: application/json' -d @tools/m2-engine/fixtures/normal.json
# {"ok":true,"proposal":{"blocks":[{"block_id":"blk-t_eng",...}]...}}
```

冷启动（含首次编译）约 **15 秒**；期间 `/health` 不通是正常的，按第三节的轮询即可。

