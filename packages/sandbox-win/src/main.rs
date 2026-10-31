//! trha-sandbox-win — Windows 沙箱 helper（P4）
//!
//! 与 scheduler 之间走 NDJSON v1 协议（`docs/plans/sandbox-architecture.md` §5.7.3）：
//! 每行一个 JSON 对象、≤ 1 MiB；stdin 只读，stdout 只写协议帧，日志一律走 stderr
//! （避免污染协议流）。
//!
//! # T4.1 范围
//!
//! 骨架 + 握手：`hello` → `ready`。能力表全部 `false`、`enforcement=partial`，
//! 并在 `capabilities.reason` 说明原因（协议要求 partial 必须带原因）。
//!
//! 后续阶段每落地一项原语，就把对应 capability 翻成 `true`：
//! - T4.2 受限令牌 → `restrictedToken`
//! - T4.3 ACL 授权 → `acl`
//! - T4.4 Job Object → `jobObject`
//! - T4.8 AppContainer → `appContainer`

use serde::Serialize;
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

/// 协议版本，与 Haskell 侧 `Infrastructure.Sandbox.Protocol.protocolVersion` 对齐。
const PROTOCOL_VERSION: u64 = 1;

/// 单帧上限，与 `Protocol.maxFrameBytes` 对齐。
const MAX_FRAME_BYTES: usize = 1024 * 1024;

/// 后端标识，与 `Backend.Windows.backendIdWindows` 对齐。
const BACKEND_ID: &str = "windows-restricted-token";

/// 能力协商表。T4.1 全部 `false`；每实现一项就把对应位翻 `true`。
#[derive(Serialize)]
struct Capabilities {
    #[serde(rename = "restrictedToken")]
    restricted_token: bool,
    acl: bool,
    #[serde(rename = "jobObject")]
    job_object: bool,
    #[serde(rename = "appContainer")]
    app_container: bool,
    /// `enforcement=partial` 的原因（协议要求）。
    reason: &'static str,
}

fn capabilities() -> Capabilities {
    Capabilities {
        restricted_token: false,
        acl: false,
        job_object: false,
        app_container: false,
        reason: "T4.1 skeleton: no isolation primitive implemented yet",
    }
}

/// 写一帧并立即 flush（宿主按行读取，不能攒批）。
fn send(out: &mut impl Write, frame: Value) {
    if let Ok(line) = serde_json::to_string(&frame) {
        let _ = writeln!(out, "{line}");
        let _ = out.flush();
    }
}

fn error_frame(id: Option<&Value>, code: &str, message: String) -> Value {
    json!({
        "v": PROTOCOL_VERSION,
        "op": "error",
        "id": id,
        "code": code,
        "message": message,
    })
}

fn main() {
    let stdin = io::stdin();
    let mut out = io::stdout();
    let mut handshaken = false;

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                send(&mut out, error_frame(None, "io_error", e.to_string()));
                break;
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        if line.len() > MAX_FRAME_BYTES {
            send(
                &mut out,
                error_frame(None, "frame_too_large", format!("{} bytes", line.len())),
            );
            continue;
        }

        let frame: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                send(&mut out, error_frame(None, "malformed_frame", e.to_string()));
                continue;
            }
        };

        let version = frame.get("v").and_then(Value::as_u64).unwrap_or(0);
        if version != PROTOCOL_VERSION {
            send(
                &mut out,
                error_frame(
                    frame.get("id"),
                    "version_mismatch",
                    format!("got v{version}, want v{PROTOCOL_VERSION}"),
                ),
            );
            continue;
        }

        let op = frame.get("op").and_then(Value::as_str).unwrap_or("");
        match op {
            "hello" => {
                handshaken = true;
                send(
                    &mut out,
                    json!({
                        "v": PROTOCOL_VERSION,
                        "op": "ready",
                        "backend": BACKEND_ID,
                        "enforcement": "partial",
                        "capabilities": capabilities(),
                        "pid": std::process::id(),
                    }),
                );
            }
            "shutdown" => break,
            other if !handshaken => {
                // 未握手不执行任何命令（协议硬约束）。
                send(
                    &mut out,
                    error_frame(
                        frame.get("id"),
                        "no_handshake",
                        format!("op '{other}' before hello"),
                    ),
                );
            }
            other => {
                send(
                    &mut out,
                    error_frame(
                        frame.get("id"),
                        "not_implemented",
                        format!("op '{other}' not implemented in T4.1 skeleton"),
                    ),
                );
            }
        }
    }
}
