//! Command-line and environment encoding for `CreateProcessAsUserW`.
//!
//! Pure functions, unit-tested on every platform: the Win32 spawn path is the
//! only consumer, but the quoting rules are exactly where a sandbox helper can
//! silently hand the wrong argv to the child (e.g. splitting an argument that
//! contains a space), so they are tested without a Windows host.

/// Quote one argument the way `CommandLineToArgvW` parses it.
///
/// Rules (as implemented by the C runtime / `CommandLineToArgvW`):
/// * no whitespace and no quote → emit as-is;
/// * a run of N backslashes followed by `"` becomes 2N+1 backslashes plus `"`;
/// * a run of N backslashes at the end of a quoted argument becomes 2N.
pub fn quote_arg(arg: &str) -> String {
    let needs_quotes = arg.is_empty()
        || arg
            .chars()
            .any(|c| c.is_whitespace() || c == '"' || c == '\t');
    if !needs_quotes {
        return arg.to_string();
    }
    let mut out = String::with_capacity(arg.len() + 2);
    out.push('"');
    let mut backslashes = 0usize;
    for ch in arg.chars() {
        match ch {
            '\\' => backslashes += 1,
            '"' => {
                out.push_str(&"\\".repeat(backslashes * 2 + 1));
                out.push('"');
                backslashes = 0;
            }
            _ => {
                out.push_str(&"\\".repeat(backslashes));
                backslashes = 0;
                out.push(ch);
            }
        }
    }
    out.push_str(&"\\".repeat(backslashes * 2));
    out.push('"');
    out
}

/// Join argv into the single command line `CreateProcessAsUserW` expects.
pub fn build_command_line(argv: &[String]) -> String {
    argv.iter()
        .map(|a| quote_arg(a))
        .collect::<Vec<_>>()
        .join(" ")
}

/// UTF-16 environment block: `K=V\0K=V\0\0`, sorted by name (Win32 requires
/// the sort for `CREATE_UNICODE_ENVIRONMENT` blocks).
pub fn build_env_block(env: &[(String, String)]) -> Vec<u16> {
    let mut pairs: Vec<&(String, String)> = env.iter().collect();
    pairs.sort_by(|a, b| a.0.to_lowercase().cmp(&b.0.to_lowercase()));
    if pairs.is_empty() {
        // An empty block still needs the double NUL terminator.
        return vec![0, 0];
    }
    let mut block: Vec<u16> = Vec::new();
    for (key, value) in pairs {
        for unit in format!("{key}={value}").encode_utf16() {
            block.push(unit);
        }
        block.push(0);
    }
    block.push(0);
    block
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_arguments_stay_unquoted() {
        assert_eq!(quote_arg("cmd.exe"), "cmd.exe");
        assert_eq!(quote_arg("/c"), "/c");
        assert_eq!(quote_arg(r"C:\ws"), r"C:\ws");
    }

    #[test]
    fn spaces_force_quotes() {
        assert_eq!(quote_arg("echo hi"), r#""echo hi""#);
        assert_eq!(quote_arg(""), r#""""#);
    }

    #[test]
    fn embedded_quotes_are_escaped() {
        assert_eq!(quote_arg("say \"hi\""), "\"say \\\"hi\\\"\"");
    }

    #[test]
    fn trailing_backslashes_are_doubled_inside_quotes() {
        // `a b\` → "a b\\"
        assert_eq!(quote_arg("a b\\"), "\"a b\\\\\"");
        // one backslash directly before a quote → 2N+1 backslashes
        assert_eq!(quote_arg("a\\\""), "\"a\\\\\\\"\"");
    }

    #[test]
    fn command_line_joins_with_single_spaces() {
        let argv = vec!["cmd.exe".to_string(), "/c".into(), "echo hi".into()];
        assert_eq!(build_command_line(&argv), "cmd.exe /c \"echo hi\"");
    }

    #[test]
    fn env_block_is_nul_separated_sorted_and_double_terminated() {
        let env = vec![
            ("PATH".to_string(), r"C:\bin".to_string()),
            ("HOME".to_string(), r"C:\home".to_string()),
        ];
        let block = build_env_block(&env);
        let text = String::from_utf16(&block).unwrap();
        assert_eq!(text, "HOME=C:\\home\0PATH=C:\\bin\0\0");
        assert_eq!(block.last(), Some(&0));
        assert_eq!(block[block.len() - 2], 0);
    }

    #[test]
    fn empty_env_is_just_the_double_nul() {
        assert_eq!(build_env_block(&[]), vec![0u16, 0u16]);
    }
}
