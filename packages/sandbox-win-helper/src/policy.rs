//! Policy parsing and the pure translation into a launch plan.
//!
//! Everything here is platform-independent and unit-tested on Linux: the
//! Windows-specific enforcement (restricted token, ACL, Job Object) consumes a
//! `LaunchPlan` and never re-decides policy.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Policy {
    /// `WRITE_RESTRICTED` only limits writes, so read-only cannot be enforced
    /// by the token alone — the backend reports `partial`.
    ReadOnly,
    WorkspaceWrite,
}

impl Policy {
    pub fn parse(text: &str) -> Result<Policy, String> {
        match text {
            "read-only" => Ok(Policy::ReadOnly),
            "workspace-write" => Ok(Policy::WorkspaceWrite),
            "danger-full-access" => {
                Err("danger-full-access must not be rendered".to_string())
            }
            other => Err(format!("unsupported policy: {other}")),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Policy::ReadOnly => "read-only",
            Policy::WorkspaceWrite => "workspace-write",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Network {
    Off,
    /// bwrap-less Windows has no per-domain ACL yet; the list is carried for
    /// audit and for the future AppContainer capability mapping.
    Allow(Vec<String>),
    Proxy(String),
}

pub fn parse_network(text: &str) -> Result<Network, String> {
    if text == "off" || text.is_empty() {
        return Ok(Network::Off);
    }
    if let Some(rest) = text.strip_prefix("allow:") {
        let domains: Vec<String> = rest
            .split(',')
            .map(str::trim)
            .filter(|d| !d.is_empty())
            .map(str::to_string)
            .collect();
        return Ok(Network::Allow(domains));
    }
    if let Some(rest) = text.strip_prefix("proxy:") {
        return Ok(Network::Proxy(rest.trim().to_string()));
    }
    Err(format!("unsupported network spec: {text}"))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchPlan {
    pub argv: Vec<String>,
    pub cwd: String,
    pub policy: Policy,
    /// Directories the child may write to. Empty for read-only.
    pub writable_roots: Vec<String>,
    pub network: Network,
}

impl LaunchPlan {
    /// `enforcement` as reported in the `ready` frame.
    ///
    /// read-only now really denies writes: the child is spawned under a
    /// `WRITE_RESTRICTED` token with no restricting SIDs (T4.2). It still
    /// cannot stop reads, so it stays `Partial`.
    ///
    /// workspace-write has no token yet — a restricting SID plus a workspace
    /// ACE is unproven on a real host — so it is `Partial` too, and says so
    /// instead of pretending. T4.6's probes are the gate for raising either.
    pub fn enforcement(&self) -> &'static str {
        "Partial"
    }
}

/// Translate a scope's policy plus the exec request into Win32-shaped input.
pub fn plan(
    policy: Policy,
    workspace: &str,
    scratch: &str,
    argv: &[String],
) -> Result<LaunchPlan, String> {
    if argv.is_empty() {
        return Err("empty argv".to_string());
    }
    if workspace.trim().is_empty() {
        return Err("workspace must not be empty".to_string());
    }
    let writable_roots = match policy {
        Policy::ReadOnly => Vec::new(),
        Policy::WorkspaceWrite => vec![workspace.to_string(), scratch.to_string()],
    };
    Ok(LaunchPlan {
        argv: argv.to_vec(),
        cwd: workspace.to_string(),
        policy,
        writable_roots,
        network: Network::Off,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_two_renderable_policies() {
        assert_eq!(Policy::parse("read-only").unwrap(), Policy::ReadOnly);
        assert_eq!(
            Policy::parse("workspace-write").unwrap(),
            Policy::WorkspaceWrite
        );
        assert!(Policy::parse("danger-full-access").is_err());
        assert!(Policy::parse("nonsense").is_err());
    }

    #[test]
    fn parses_network_specs() {
        assert_eq!(parse_network("off").unwrap(), Network::Off);
        assert_eq!(
            parse_network("allow:a.com, b.com").unwrap(),
            Network::Allow(vec!["a.com".into(), "b.com".into()])
        );
        assert_eq!(
            parse_network("proxy:http://127.0.0.1:10808").unwrap(),
            Network::Proxy("http://127.0.0.1:10808".into())
        );
        assert!(parse_network("weird").is_err());
    }

    #[test]
    fn workspace_write_grants_workspace_and_scratch() {
        let p = plan(
            Policy::WorkspaceWrite,
            r"C:\ws",
            r"C:\scratch",
            &["cmd.exe".into()],
        )
        .unwrap();
        assert_eq!(p.writable_roots, vec![r"C:\ws", r"C:\scratch"]);
        // The token is not wired into spawn yet, so this must stay honest.
        assert_eq!(p.enforcement(), "Partial");
    }

    #[test]
    fn read_only_has_no_writable_roots_and_is_partial() {
        let p = plan(Policy::ReadOnly, r"C:\ws", r"C:\scratch", &["cmd.exe".into()]).unwrap();
        assert!(p.writable_roots.is_empty());
        assert_eq!(p.enforcement(), "Partial");
    }

    #[test]
    fn empty_argv_is_rejected() {
        assert!(plan(Policy::WorkspaceWrite, r"C:\ws", r"C:\s", &[]).is_err());
    }
}
