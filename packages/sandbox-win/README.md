# trha-sandbox-win

Windows 沙箱 helper（P4）。与 scheduler 之间走 **NDJSON v1** 协议，每行一个 JSON
对象、≤ 1 MiB；stdin 只读，stdout 只写协议帧，日志走 stderr。

协议定义以 Haskell 侧为准：`src/infra/Infrastructure/Sandbox/Protocol.hs`
（对应 `docs/plans/sandbox-architecture.md` §5.7.3）。

## 当前进度（T4.1）

骨架 + 握手。`hello` → `ready`，能力表全部 `false`、`enforcement=partial`
（并在 `capabilities.reason` 说明原因）。

| 阶段 | 内容 | 能力位 |
|---|---|---|
| **T4.1** | 骨架 + 握手 | 全部 `false` |
| T4.2 | `CreateRestrictedToken` + `WRITE_RESTRICTED` + restricting SIDs | `restrictedToken` |
| T4.3 | workspace ACE + deny 父目录删除 + Low integrity | `acl` |
| T4.4 | Job Object（进程数 / 内存 / `KILL_ON_JOB_CLOSE`） | `jobObject` |
| T4.5 | 路径规范化（`GetFinalPathNameByHandle`：junction / ADS / 8.3） | — |
| T4.6 | 探针套件（§6.3 Windows 版） | — |
| T4.7 | 签名 / 分发 | — |
| T4.8 | 可选：AppContainer / MXC（`Strong`） | `appContainer` |

## 构建

```bash
cd packages/sandbox-win
cargo build --release
# 产物：target/release/trha-sandbox-win.exe
```

crates.io 在国内直连会 403，`$CARGO_HOME/config.toml` 需配置 sparse 镜像
（如 `sparse+https://rsproxy.cn/index/`）。

## 手动验证（T4.1 验收）

```bash
printf '{"v":1,"op":"hello","scope":"s1","policy":"workspace-write","isolation":"process"}\n{"v":1,"op":"shutdown"}\n' \
  | ./target/release/trha-sandbox-win.exe
```

期望输出一行 `ready`：

```json
{"v":1,"op":"ready","backend":"windows-restricted-token","enforcement":"partial","capabilities":{"restrictedToken":false,"acl":false,"jobObject":false,"appContainer":false,"reason":"T4.1 skeleton: no isolation primitive implemented yet"},"pid":12345}
```

## 错误帧

| code | 触发条件 |
|---|---|
| `frame_too_large` | 单行 > 1 MiB（与 `Protocol.maxFrameBytes` 对齐） |
| `malformed_frame` | 非法 JSON |
| `version_mismatch` | `v != 1` |
| `no_handshake` | 未 `hello` 就发 `exec` 等 |
| `not_implemented` | 已握手但该 op 尚未实现（T4.1 的全部 exec 类） |
| `io_error` | stdin 读失败 |

## 与 Haskell 侧的对接

`Backend.Windows.backendIdWindows = BackendId "windows-restricted-token"`
必须与本文 `BACKEND_ID` 一致；`ready.backend` 回传该字符串，Haskell 侧据此
选择 `BackendCapabilities`。能力位与 `Capability` 枚举的映射在 T4.2 接入时确定。
