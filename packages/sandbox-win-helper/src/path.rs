//! Windows path comparison rules (pure; unit-tested on every platform).
//!
//! Only string-prefix comparison is unsafe on Windows: 8.3 short names,
//! junction/reparse points, alternate data streams (`file:stream`), device
//! names and case-insensitivity all bypass it. The enforcing path is
//! `GetFinalPathNameByHandle` (see `win.rs`); these helpers cover the
//! string-level cases and are what tests can assert off-Windows.

/// Strip the `\\?\` verbatim prefix so comparisons see the same spelling.
pub fn strip_verbatim(path: &str) -> &str {
    path.strip_prefix(r"\\?\").unwrap_or(path)
}

/// Drop an alternate data stream suffix, keeping a drive prefix (`C:`).
pub fn strip_ads(path: &str) -> &str {
    match path.rfind(':') {
        Some(idx) if idx > 1 => &path[..idx],
        _ => path,
    }
}

/// Lower-case, backslash-separated, no trailing separator, no ADS/verbatim.
pub fn normalize(path: &str) -> String {
    let slashed = strip_verbatim(path).replace('/', "\\");
    let without_stream = strip_ads(&slashed).to_string();
    let trimmed = without_stream.trim_end_matches('\\');
    let lower = trimmed.to_lowercase();
    if lower.len() == 2 && lower.ends_with(':') {
        format!("{lower}\\")
    } else {
        lower
    }
}

/// Is `candidate` the root itself or below it?
pub fn is_within(root: &str, candidate: &str) -> bool {
    let r = normalize(root);
    let c = normalize(candidate);
    if c == r {
        return true;
    }
    let prefix = if r.ends_with('\\') { r } else { format!("{r}\\") };
    c.starts_with(&prefix)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_verbatim_and_trailing_separator() {
        assert_eq!(normalize(r"\\?\C:\Work\App\"), r"c:\work\app");
        assert_eq!(normalize(r"C:/Work/App"), r"c:\work\app");
    }

    #[test]
    fn drive_root_keeps_its_backslash() {
        assert_eq!(normalize(r"C:\"), r"c:\");
        assert_eq!(normalize("C:"), r"c:\");
    }

    #[test]
    fn strips_alternate_data_streams() {
        assert_eq!(normalize(r"C:\ws\a.txt:secret"), r"c:\ws\a.txt");
        // a drive colon is not a stream separator
        assert_eq!(normalize(r"C:\ws"), r"c:\ws");
    }

    #[test]
    fn containment_is_boundary_aware() {
        assert!(is_within(r"C:\ws", r"C:\ws\a"));
        assert!(is_within(r"C:\ws", r"C:\WS\A"));
        assert!(is_within(r"C:\ws", r"C:\ws"));
        assert!(!is_within(r"C:\ws", r"C:\wsx\a"));
        assert!(!is_within(r"C:\ws", r"C:\other"));
    }

    #[test]
    fn drive_root_contains_everything_on_that_drive() {
        assert!(is_within(r"C:\", r"C:\a\b"));
        assert!(!is_within(r"C:\", r"D:\a"));
    }
}
