//! NDJSON v1 frames — byte-compatible with `Infrastructure.Sandbox.Protocol`.
//!
//! The Haskell runner speaks these frames to the scheduler; the Windows helper
//! answers with the same shapes so `sandbox.ts` needs no platform branch.

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u8 = 1;
/// Matches the Haskell side's per-line limit (64 KiB).
pub const MAX_FRAME_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnvVar {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Frame {
    Hello {
        v: u8,
        scope: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        parent: Option<String>,
        policy: String,
        isolation: String,
    },
    Ready {
        v: u8,
        backend: String,
        enforcement: String,
        capabilities: serde_json::Value,
        pid: u32,
    },
    Exec {
        v: u8,
        id: String,
        argv: Vec<String>,
        cwd: String,
        #[serde(default)]
        env: Vec<EnvVar>,
        #[serde(skip_serializing_if = "Option::is_none")]
        stdin: Option<String>,
        #[serde(rename = "timeoutMs", skip_serializing_if = "Option::is_none")]
        timeout_ms: Option<u64>,
    },
    Stdin {
        v: u8,
        id: String,
        data: String,
    },
    Stdout {
        v: u8,
        id: String,
        data: String,
    },
    Stderr {
        v: u8,
        id: String,
        data: String,
    },
    Exit {
        v: u8,
        id: String,
        code: i32,
        #[serde(skip_serializing_if = "Option::is_none")]
        signal: Option<String>,
    },
    Deny {
        v: u8,
        id: String,
        kind: String,
        target: String,
    },
    Error {
        v: u8,
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
        code: String,
        message: String,
    },
    Shutdown {
        v: u8,
    },
}

impl Frame {
    pub fn version(&self) -> u8 {
        match self {
            Frame::Hello { v, .. }
            | Frame::Ready { v, .. }
            | Frame::Exec { v, .. }
            | Frame::Stdin { v, .. }
            | Frame::Stdout { v, .. }
            | Frame::Stderr { v, .. }
            | Frame::Exit { v, .. }
            | Frame::Deny { v, .. }
            | Frame::Error { v, .. }
            | Frame::Shutdown { v } => *v,
        }
    }
}

/// Serialise one frame plus the trailing newline that delimits NDJSON.
pub fn encode(frame: &Frame) -> String {
    let mut line = serde_json::to_string(frame).expect("frames always serialise");
    line.push('\n');
    line
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    TooLarge(usize),
    Malformed(String),
    VersionMismatch(u8),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecodeError::TooLarge(n) => {
                write!(f, "frame exceeds {MAX_FRAME_BYTES} bytes (got {n})")
            }
            DecodeError::Malformed(m) => write!(f, "malformed frame: {m}"),
            DecodeError::VersionMismatch(v) => {
                write!(f, "version mismatch: {v} (expected {PROTOCOL_VERSION})")
            }
        }
    }
}

pub fn decode(line: &str) -> Result<Frame, DecodeError> {
    if line.len() > MAX_FRAME_BYTES {
        return Err(DecodeError::TooLarge(line.len()));
    }
    let frame: Frame =
        serde_json::from_str(line).map_err(|e| DecodeError::Malformed(e.to_string()))?;
    if frame.version() != PROTOCOL_VERSION {
        return Err(DecodeError::VersionMismatch(frame.version()));
    }
    Ok(frame)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_round_trips_without_optional_parent() {
        let frame = Frame::Hello {
            v: PROTOCOL_VERSION,
            scope: "root".into(),
            parent: None,
            policy: "read-only".into(),
            isolation: "process".into(),
        };
        let text = encode(&frame);
        assert!(text.ends_with('\n'));
        assert!(!text.contains("parent"));
        assert_eq!(decode(text.trim_end()).unwrap(), frame);
    }

    #[test]
    fn exec_round_trips_camel_case_timeout() {
        let frame = Frame::Exec {
            v: PROTOCOL_VERSION,
            id: "c1".into(),
            argv: vec!["cmd.exe".into(), "/c".into(), "echo hi".into()],
            cwd: "C:\\ws".into(),
            env: vec![EnvVar {
                name: "PATH".into(),
                value: "C:\\bin".into(),
            }],
            stdin: None,
            timeout_ms: Some(5000),
        };
        let text = encode(&frame);
        assert!(
            text.contains("\"timeoutMs\":5000"),
            "wire name must match Haskell: {text}"
        );
        assert_eq!(decode(text.trim_end()).unwrap(), frame);
    }

    #[test]
    fn rejects_unknown_op() {
        let err = decode(r#"{"v":1,"op":"teleport"}"#).unwrap_err();
        assert!(matches!(err, DecodeError::Malformed(_)), "got {err:?}");
    }

    #[test]
    fn rejects_version_mismatch() {
        let err = decode(r#"{"v":2,"op":"shutdown"}"#).unwrap_err();
        assert_eq!(err, DecodeError::VersionMismatch(2));
    }
}
