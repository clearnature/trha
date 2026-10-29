//! `trha-sandbox-win`: the Windows sandbox helper.
//!
//! Speaks the same NDJSON v1 protocol as `trha sandbox runner`, so the
//! scheduler's `sandbox.ts` needs no platform branch: it spawns this binary
//! (or the Haskell runner) and talks frames to it.
//!
//! T4.1 scope: argument parsing, handshake, `exec` dispatch and honest
//! `enforcement` reporting. The Win32 enforcement (restricted token, ACL, Job
//! Object) lands in T4.2–T4.5.

mod path;
mod policy;
mod protocol;
#[cfg(windows)]
mod win32;
mod win;

use std::io::{BufRead, Write};

use policy::{parse_network, plan, Network, Policy};
use protocol::{Frame, PROTOCOL_VERSION};

pub struct Config {
    pub workspace: String,
    pub scratch: String,
    pub policy: Policy,
    pub network: Network,
}

fn parse_args(args: &[String]) -> Result<(Config, Option<Vec<String>>), String> {
    let mut workspace: Option<String> = None;
    let mut scratch: Option<String> = None;
    let mut policy: Option<String> = None;
    let mut network: Option<String> = None;
    let mut command: Option<Vec<String>> = None;

    let mut i = 0;
    while i < args.len() {
        let flag = args[i].as_str();
        // One-shot mode: everything after `--` is the command to run. This is
        // how the Haskell runner drives the helper (its drain turns the
        // helper's stdout/stderr into protocol frames).
        if flag == "--" {
            let rest = args[i + 1..].to_vec();
            if rest.is_empty() {
                return Err("-- must be followed by a command".to_string());
            }
            command = Some(rest);
            break;
        }
        let value = args
            .get(i + 1)
            .ok_or_else(|| format!("{flag} needs a value"))?
            .clone();
        match flag {
            "--workspace" => workspace = Some(value),
            "--scratch" => scratch = Some(value),
            "--policy" => policy = Some(value),
            "--network" => network = Some(value),
            other => return Err(format!("unknown argument: {other}")),
        }
        i += 2;
    }

    let cfg = Config {
        workspace: workspace.ok_or("--workspace is required")?,
        scratch: scratch.ok_or("--scratch is required")?,
        policy: Policy::parse(&policy.ok_or("--policy is required")?)?,
        network: parse_network(network.as_deref().unwrap_or("off"))?,
    };
    Ok((cfg, command))
}

/// Both policies report `Partial`: the restricted token (T4.2) is created but
/// not yet carried into spawn, so writes are unconstrained today.
fn enforcement_for(_policy: Policy) -> &'static str {
    "Partial"
}

/// Serve frames until `shutdown` or EOF. Returns the process exit code.
fn serve<R: BufRead, W: Write>(cfg: &Config, input: R, mut out: W) -> i32 {
    for line in input.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        let frame = match protocol::decode(&line) {
            Ok(f) => f,
            Err(e) => {
                win::emit(
                    &mut out,
                    &Frame::Error {
                        v: PROTOCOL_VERSION,
                        id: None,
                        code: "protocol".into(),
                        message: e.to_string(),
                    },
                );
                return 2;
            }
        };
        match frame {
            Frame::Hello { .. } => win::emit(
                &mut out,
                &Frame::Ready {
                    v: PROTOCOL_VERSION,
                    backend: "windows-restricted-token".into(),
                    enforcement: enforcement_for(cfg.policy).into(),
                    capabilities: serde_json::Value::Array(Vec::new()),
                    pid: std::process::id(),
                },
            ),
            Frame::Exec { id, argv, .. } => match plan(cfg.policy, &cfg.workspace, &cfg.scratch, &argv)
            {
                Ok(launch) => {
                    win::launch(&launch, &id, &mut out);
                }
                Err(message) => {
                    win::emit(
                        &mut out,
                        &Frame::Error {
                            v: PROTOCOL_VERSION,
                            id: Some(id.clone()),
                            code: "policy".into(),
                            message,
                        },
                    );
                    win::emit(
                        &mut out,
                        &Frame::Exit {
                            v: PROTOCOL_VERSION,
                            id,
                            code: 126,
                            signal: None,
                        },
                    );
                }
            },
            Frame::Shutdown { .. } => return 0,
            _ => {}
        }
    }
    0
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (cfg, command) = match parse_args(&args) {
        Ok(parsed) => parsed,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    if let Some(argv) = command {
        std::process::exit(win::run_once(&cfg, &argv));
    }
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let code = serve(&cfg, stdin.lock(), stdout.lock());
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        Config {
            workspace: r"C:\ws".into(),
            scratch: r"C:\scratch".into(),
            policy: Policy::WorkspaceWrite,
            network: Network::Off,
        }
    }

    fn run(input: &str) -> String {
        let mut out = Vec::new();
        let code = serve(&cfg(), input.as_bytes(), &mut out);
        let text = String::from_utf8(out).unwrap();
        assert_eq!(code, 0, "serve returned {code}: {text}");
        text
    }

    #[test]
    fn answers_hello_with_ready() {
        let text = run("{\"v\":1,\"op\":\"hello\",\"scope\":\"s\",\"policy\":\"workspace-write\",\"isolation\":\"process\"}\n");
        assert!(text.contains("\"op\":\"ready\""), "{text}");
        assert!(text.contains("windows-restricted-token"), "{text}");
    }

    #[test]
    fn read_only_reports_partial() {
        let mut c = cfg();
        c.policy = Policy::ReadOnly;
        let mut out = Vec::new();
        let _ = serve(
            &c,
            "{\"v\":1,\"op\":\"hello\",\"scope\":\"s\",\"policy\":\"read-only\",\"isolation\":\"process\"}\n".as_bytes(),
            &mut out,
        );
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\"enforcement\":\"Partial\""), "{text}");
    }

    #[test]
    fn rejects_malformed_frames_with_an_error_frame() {
        let mut out = Vec::new();
        let code = serve(&cfg(), "not json\n".as_bytes(), &mut out);
        assert_eq!(code, 2);
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\"op\":\"error\""), "{text}");
    }

    #[test]
    fn shutdown_stops_the_loop() {
        let text = run("{\"v\":1,\"op\":\"shutdown\"}\n");
        assert!(text.is_empty(), "shutdown must not emit frames: {text}");
    }

    #[test]
    fn exec_on_a_non_windows_build_fails_closed() {
        if cfg!(windows) {
            return;
        }
        let text = run("{\"v\":1,\"op\":\"exec\",\"id\":\"c1\",\"argv\":[\"cmd.exe\"],\"cwd\":\"C:\\\\ws\"}\n");
        assert!(text.contains("\"op\":\"error\""), "{text}");
        assert!(text.contains("\"code\":126"), "{text}");
    }

    #[test]
    fn parses_required_flags() {
        let args: Vec<String> = ["--workspace", r"C:\ws", "--scratch", r"C:\s", "--policy", "read-only", "--network", "off"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let (parsed, command) = parse_args(&args).unwrap();
        assert_eq!(parsed.policy, Policy::ReadOnly);
        assert!(command.is_none(), "no `--` means NDJSON mode");
        assert!(parse_args(&args[..2]).is_err(), "missing scratch must fail");
    }

    #[test]
    fn one_shot_mode_takes_everything_after_double_dash() {
        let args: Vec<String> = [
            "--workspace", r"C:\ws", "--scratch", r"C:\s", "--policy", "workspace-write",
            "--", "cmd.exe", "/c", "echo hi",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let (_, command) = parse_args(&args).unwrap();
        assert_eq!(command.unwrap(), vec!["cmd.exe", "/c", "echo hi"]);
    }
}
