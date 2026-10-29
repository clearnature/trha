//! Platform layer: Win32 on Windows, an explicit error everywhere else.
//!
//! The helper is a *skeleton* at T4.1: it speaks the protocol, reports
//! `enforcement` honestly, and spawns the child. T4.2–T4.5 replace the plain
//! `Command` spawn with restricted token + ACL + Job Object.

use crate::policy::LaunchPlan;
use crate::protocol::{self, Frame, PROTOCOL_VERSION};
use std::io::Write;

pub(crate) fn emit<W: Write>(out: &mut W, frame: &Frame) {
    let _ = out.write_all(protocol::encode(frame).as_bytes());
    let _ = out.flush();
}

/// Run one launch plan, streaming stdout/stderr frames for `id`, then `exit`.
pub fn launch<W: Write>(plan: &LaunchPlan, id: &str, out: &mut W) -> i32 {
    match imp::run(plan, id, out) {
        Ok(code) => {
            emit(
                out,
                &Frame::Exit {
                    v: PROTOCOL_VERSION,
                    id: id.to_string(),
                    code,
                    signal: None,
                },
            );
            code
        }
        Err(message) => {
            emit(
                out,
                &Frame::Error {
                    v: PROTOCOL_VERSION,
                    id: Some(id.to_string()),
                    code: "backend".into(),
                    message,
                },
            );
            emit(
                out,
                &Frame::Exit {
                    v: PROTOCOL_VERSION,
                    id: id.to_string(),
                    code: 126,
                    signal: None,
                },
            );
            126
        }
    }
}

/// One-shot mode: run the command with stdio inherited and return its exit
/// code. The Haskell runner uses this shape (`-- argv`) so its drain can turn
/// the helper's stdout/stderr into protocol frames — no nested protocol.
pub fn run_once(cfg: &crate::Config, argv: &[String]) -> i32 {
    match crate::policy::plan(cfg.policy, &cfg.workspace, &cfg.scratch, argv) {
        Ok(launch) => imp::run_inherit(&launch),
        Err(message) => {
            eprintln!("{message}");
            126
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::LaunchPlan;
    use std::io::Write;

    pub fn run<W: Write>(_plan: &LaunchPlan, _id: &str, _out: &mut W) -> Result<i32, String> {
        Err("windows backend requires Windows; the helper builds everywhere but only \
             enforces on win32"
            .to_string())
    }

    pub fn run_inherit(_plan: &LaunchPlan) -> i32 {
        eprintln!(
            "windows backend requires Windows; one-shot mode is not available on this platform"
        );
        126
    }
}

#[cfg(windows)]
mod imp {
    use super::{emit, Frame, LaunchPlan, PROTOCOL_VERSION};
    use crate::policy::Network;
    use std::io::{BufRead, BufReader, Write};
    use std::process::{Command, Stdio};

    pub fn run_inherit(plan: &LaunchPlan) -> i32 {
        let mut cmd = Command::new(&plan.argv[0]);
        cmd.args(&plan.argv[1..])
            .current_dir(&plan.cwd)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
        if let Network::Proxy(url) = &plan.network {
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
                cmd.env(key, url);
            }
        }
        // TODO(T4.2/T4.3): restricted token + workspace ACL. A Job Object is
        // installed so a crashed agent cannot leave orphans behind.
        let job = crate::win32::create_job(None, None).ok();
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("spawn failed: {e}");
                if let Some(j) = job {
                    crate::win32::close(j);
                }
                return 126;
            }
        };
        if let Some(j) = job {
            if let Err(e) = crate::win32::assign_to_job(j, child.id()) {
                eprintln!("job assignment failed (continuing without it): {e}");
            }
        }
        let code = match child.wait() {
            Ok(status) => status.code().unwrap_or(1),
            Err(e) => {
                eprintln!("wait failed: {e}");
                126
            }
        };
        if let Some(j) = job {
            crate::win32::close(j);
        }
        code
    }

    pub fn run<W: Write>(plan: &LaunchPlan, id: &str, out: &mut W) -> Result<i32, String> {
        let mut cmd = Command::new(&plan.argv[0]);
        cmd.args(&plan.argv[1..])
            .current_dir(&plan.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        // Proxy mode is best-effort on Windows too (ADR-009): set the usual
        // variables, do not pretend it is an ACL.
        if let Network::Proxy(url) = &plan.network {
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
                cmd.env(key, url);
            }
        }

        // TODO(T4.2–T4.5): CreateRestrictedToken + SetEntriesInAcl + Job Object
        // (`JOB_OBJECT_LIMIT_ACTIVE_PROCESS` / `PROCESS_MEMORY` /
        // `KILL_ON_JOB_CLOSE`). Until then the child runs with the helper's
        // own token, which is exactly why `enforcement` stays Partial.
        let mut child = cmd.spawn().map_err(|e| format!("spawn failed: {e}"))?;

        let stdout = child.stdout.take().ok_or("child has no stdout")?;
        let stderr = child.stderr.take().ok_or("child has no stderr")?;
        let id_out = id.to_string();
        let reader_out = std::thread::spawn(move || {
            let mut sink = std::io::stdout();
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                emit(
                    &mut sink,
                    &Frame::Stdout {
                        v: PROTOCOL_VERSION,
                        id: id_out.clone(),
                        data: line + "\n",
                    },
                );
            }
        });
        let id_err = id.to_string();
        let reader_err = std::thread::spawn(move || {
            let mut sink = std::io::stdout();
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                emit(
                    &mut sink,
                    &Frame::Stderr {
                        v: PROTOCOL_VERSION,
                        id: id_err.clone(),
                        data: line + "\n",
                    },
                );
            }
        });
        let _ = reader_out.join();
        let _ = reader_err.join();

        let status = child.wait().map_err(|e| format!("wait failed: {e}"))?;
        Ok(status.code().unwrap_or(1))
    }
}
