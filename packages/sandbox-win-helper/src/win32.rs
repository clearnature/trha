//! Win32 primitives (T4.4 Job Object, T4.5 path canonicalisation).
//!
//! Everything here is `#[cfg(windows)]`: it compiles in the cross-check
//! (`cargo check --target x86_64-pc-windows-gnu`) but has **not** run on a real
//! Windows host yet — T4.6's probe suite is the acceptance gate. Treat the
//! argument orders and flags below as reviewed-but-unverified until then.
//!
//! Restricted tokens (T4.2) deliberately stay out of this file: installing one
//! requires `CreateProcessAsUserW` with an explicit `STARTUPINFOW` and
//! inheritable stdio handles, i.e. a hand-written spawn path. The current
//! `Command`-based spawn cannot carry a token, which is exactly why
//! `enforcement` is reported as `Partial` for workspace-write today.

#![cfg(windows)]

use std::os::windows::ffi::OsStrExt;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFinalPathNameByHandleW, FILE_FLAG_BACKUP_SEMANTICS,
    FILE_NAME_NORMALIZED, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    OPEN_EXISTING,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, SetInformationJobObject,
    JobObjectExtendedLimitInformation, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_ACTIVE_PROCESS, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOB_OBJECT_LIMIT_PROCESS_MEMORY,
};
use windows_sys::Win32::System::Threading::{
    OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE,
};

fn wide(s: &str) -> Vec<u16> {
    std::ffi::OsStr::new(s).encode_wide().chain(Some(0)).collect()
}

/// Create a job that kills its whole tree when the last handle closes, plus
/// optional active-process and committed-memory caps.
pub fn create_job(active_process: Option<u32>, memory_bytes: Option<u64>) -> Result<HANDLE, String> {
    unsafe {
        let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if job.is_null() {
            return Err(format!(
                "CreateJobObjectW failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if let Some(n) = active_process {
            info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
            info.BasicLimitInformation.ActiveProcessLimit = n;
        }
        if let Some(bytes) = memory_bytes {
            info.ProcessMemoryLimit = bytes as usize;
            info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_PROCESS_MEMORY;
        }
        let ok = SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &info as *const _ as *const std::ffi::c_void,
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        );
        if ok == 0 {
            let err = std::io::Error::last_os_error();
            CloseHandle(job);
            return Err(format!("SetInformationJobObject failed: {err}"));
        }
        Ok(job)
    }
}

/// Put an already-running process (and, by inheritance, its future children)
/// into the job.
pub fn assign_to_job(job: HANDLE, pid: u32) -> Result<(), String> {
    unsafe {
        let process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid);
        if process.is_null() {
            return Err(format!(
                "OpenProcess({pid}) failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        let ok = AssignProcessToJobObject(job, process);
        let err = std::io::Error::last_os_error();
        CloseHandle(process);
        if ok == 0 {
            return Err(format!("AssignProcessToJobObject failed: {err}"));
        }
        Ok(())
    }
}

pub fn close(handle: HANDLE) {
    if !handle.is_null() {
        unsafe {
            CloseHandle(handle);
        }
    }
}

// ── T4.2: restricted token ────────────────────────────────────────────────

/// Create a restricted copy of the helper's own token.
///
/// `DISABLE_MAX_PRIVILEGE` removes every privilege except SeChangeNotifyPrivilege;
/// `WRITE_RESTRICTED` turns the token write-only-where-SIDs-allow.
///
/// * `restrict_to_user = false` → no restricting SIDs, so **no writes at all**.
///   That is exactly the read-only policy.
/// * `restrict_to_user = true` → the user's own SID is the restricting SID, so
///   writes succeed only where that SID has an allow ACE — i.e. the workspace
///   granted by `grant_directory_write`. This is workspace-write.
pub fn create_restricted_token(restrict_to_user: bool) -> Result<HANDLE, String> {
    use windows_sys::Win32::Security::{
        CreateRestrictedToken, GetTokenInformation, TokenUser, DISABLE_MAX_PRIVILEGE,
        SID_AND_ATTRIBUTES, TOKEN_DUPLICATE, TOKEN_QUERY, TOKEN_USER, WRITE_RESTRICTED,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    unsafe {
        let mut current: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY, &mut current) == 0 {
            return Err(format!(
                "OpenProcessToken failed: {}",
                std::io::Error::last_os_error()
            ));
        }

        // The SID lives inside this buffer: it must outlive the call below.
        let mut sid_buf: Vec<u8> = Vec::new();
        let mut restrict_sids: Vec<SID_AND_ATTRIBUTES> = Vec::new();
        if restrict_to_user {
            let mut len: u32 = 0;
            GetTokenInformation(current, TokenUser, std::ptr::null_mut(), 0, &mut len);
            if len == 0 {
                let err = std::io::Error::last_os_error();
                CloseHandle(current);
                return Err(format!("GetTokenInformation(TokenUser) size failed: {err}"));
            }
            sid_buf = vec![0u8; len as usize];
            let ok = GetTokenInformation(
                current,
                TokenUser,
                sid_buf.as_mut_ptr() as *mut std::ffi::c_void,
                len,
                &mut len,
            );
            if ok == 0 {
                let err = std::io::Error::last_os_error();
                CloseHandle(current);
                return Err(format!("GetTokenInformation(TokenUser) failed: {err}"));
            }
            let user = &*(sid_buf.as_ptr() as *const TOKEN_USER);
            restrict_sids.push(SID_AND_ATTRIBUTES {
                Sid: user.User.Sid,
                Attributes: 0,
            });
        }

        let mut restricted: HANDLE = std::ptr::null_mut();
        let ok = CreateRestrictedToken(
            current,
            DISABLE_MAX_PRIVILEGE | WRITE_RESTRICTED,
            0,
            std::ptr::null(),
            0,
            std::ptr::null(),
            restrict_sids.len() as u32,
            restrict_sids.as_ptr(),
            &mut restricted,
        );
        let err = std::io::Error::last_os_error();
        CloseHandle(current);
        if ok == 0 {
            return Err(format!("CreateRestrictedToken failed: {err}"));
        }
        Ok(restricted)
    }
}

// ── T4.3: workspace ACL ───────────────────────────────────────────────────

/// Append an allow ACE giving the current user read+write+delete on `path`.
///
/// This is the "grant" half of workspace-write: the restricted token's
/// restricting SID must have a matching ACE for writes to succeed. The
/// *protection* half (denying writes elsewhere) comes from `WRITE_RESTRICTED`
/// plus the fact that other directories carry no such ACE.
pub fn grant_directory_write(path: &str) -> Result<(), String> {
    use windows_sys::Win32::Security::Authorization::{
        SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W, GRANT_ACCESS,
        NO_MULTIPLE_TRUSTEE, SE_FILE_OBJECT, TRUSTEE_IS_SID, TRUSTEE_IS_USER, TRUSTEE_W,
    };
    use windows_sys::Win32::Security::{
        GetTokenInformation, TokenUser, ACL, CONTAINER_INHERIT_ACE, DACL_SECURITY_INFORMATION,
        OBJECT_INHERIT_ACE, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        DELETE, FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    // 1. current user SID
    let sid = unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(format!(
                "OpenProcessToken failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        let mut len: u32 = 0;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut len);
        let mut buf = vec![0u8; len.max(1) as usize];
        let ok = GetTokenInformation(
            token,
            TokenUser,
            buf.as_mut_ptr() as *mut std::ffi::c_void,
            len,
            &mut len,
        );
        let err = std::io::Error::last_os_error();
        CloseHandle(token);
        if ok == 0 {
            return Err(format!("GetTokenInformation(TokenUser) failed: {err}"));
        }
        let user = &*(buf.as_ptr() as *const TOKEN_USER);
        user.User.Sid
    };
    if sid.is_null() {
        return Err("token has no user SID".to_string());
    }

    // 2. one allow ACE for that SID
    let mut access: EXPLICIT_ACCESS_W = unsafe { std::mem::zeroed() };
    access.grfAccessPermissions = FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_GENERIC_EXECUTE | DELETE;
    access.grfAccessMode = GRANT_ACCESS;
    access.grfInheritance = CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE;
    access.Trustee = TRUSTEE_W {
        pMultipleTrustee: std::ptr::null_mut(),
        MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
        TrusteeForm: TRUSTEE_IS_SID,
        TrusteeType: TRUSTEE_IS_USER,
        ptstrName: sid as *mut u16,
    };

    // 3. merge into a new ACL and attach it
    unsafe {
        let mut new_acl: *mut ACL = std::ptr::null_mut();
        let rc = SetEntriesInAclW(1, &access, std::ptr::null_mut(), &mut new_acl);
        if rc != 0 {
            return Err(format!("SetEntriesInAclW failed: {rc}"));
        }
        let wide_path = wide(path);
        let set = SetNamedSecurityInfoW(
            wide_path.as_ptr() as *mut u16,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            new_acl,
            std::ptr::null_mut(),
        );
        if set != 0 {
            return Err(format!("SetNamedSecurityInfoW({path}) failed: {set}"));
        }
    }
    Ok(())
}

/// Canonical path for an existing file/directory via
/// `GetFinalPathNameByHandleW` — the only form that resolves 8.3 short names,
/// junctions/reparse points and `\\?\` spellings. Non-existent paths must be
/// handled by the caller with `path::normalize` plus a parent-directory check.
pub fn final_path(path: &str) -> Result<String, String> {
    let wide_path = wide(path);
    unsafe {
        let handle = CreateFileW(
            wide_path.as_ptr(),
            0, // query attributes only
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS, // required for directories
            std::ptr::null_mut(),
        );
        if handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
            return Err(format!(
                "CreateFileW({path}) failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        let mut buf = [0u16; 32_768];
        let len = GetFinalPathNameByHandleW(handle, buf.as_mut_ptr(), buf.len() as u32, FILE_NAME_NORMALIZED);
        CloseHandle(handle);
        if len == 0 {
            return Err(format!(
                "GetFinalPathNameByHandleW({path}) failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(String::from_utf16_lossy(&buf[..len as usize]))
    }
}

// ── T4.2/T4.3: spawn under the restricted token ──────────────────────────

/// A child started with the restricted token; the caller owns the pipes.
pub struct RestrictedChild {
    pub pid: u32,
    pub process: HANDLE,
    /// Parent-side write end of the child's stdin.
    pub stdin: HANDLE,
    /// Parent-side read ends.
    pub stdout: HANDLE,
    pub stderr: HANDLE,
    pub job: Option<HANDLE>,
}

impl RestrictedChild {
    /// Close every handle this struct owns (idempotent).
    pub fn close(&mut self) {
        for h in [self.stdin, self.stdout, self.stderr, self.process] {
            close(h);
        }
        self.stdin = std::ptr::null_mut();
        self.stdout = std::ptr::null_mut();
        self.stderr = std::ptr::null_mut();
        self.process = std::ptr::null_mut();
        if let Some(job) = self.job.take() {
            close(job);
        }
    }
}

/// Start `argv` under `token`, with stdout/stderr/stdin on inheritable pipes.
///
/// The child is created suspended, put into `job` (when given) *and only then*
/// resumed — so nothing can escape by forking before the job is assigned.
/// The token must come from `create_restricted_token`.
pub fn spawn_restricted(
    token: HANDLE,
    job: Option<HANDLE>,
    argv: &[String],
    cwd: &str,
    env: &[(String, String)],
) -> Result<RestrictedChild, String> {
    use windows_sys::Win32::Foundation::{SetHandleInformation, HANDLE_FLAG_INHERIT};
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::System::Pipes::CreatePipe;
    use windows_sys::Win32::System::Threading::{
        CreateProcessAsUserW, ResumeThread, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT,
        PROCESS_INFORMATION, STARTF_USESTDHANDLES, STARTUPINFOW,
    };

    if argv.is_empty() {
        return Err("empty argv".to_string());
    }

    let mut command_line = crate::winargs::build_command_line(argv);
    command_line.push('\0');
    let mut cmdline: Vec<u16> = command_line.encode_utf16().collect();
    let mut env_block = crate::winargs::build_env_block(env);
    let cwd_wide = wide(cwd);

    unsafe {
        let mut sa: SECURITY_ATTRIBUTES = std::mem::zeroed();
        sa.nLength = std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32;
        sa.bInheritHandle = 1;

        let mut handlers: [(HANDLE, HANDLE); 3] =
            [(std::ptr::null_mut(), std::ptr::null_mut()); 3];
        let mut created: Vec<HANDLE> = Vec::new();
        for slot in handlers.iter_mut() {
            if CreatePipe(&mut slot.0, &mut slot.1, &sa, 0) == 0 {
                for h in created {
                    CloseHandle(h);
                }
                return Err(format!(
                    "CreatePipe failed: {}",
                    std::io::Error::last_os_error()
                ));
            }
            created.push(slot.0);
            created.push(slot.1);
        }
        let [(stdin_r, stdin_w), (stdout_r, stdout_w), (stderr_r, stderr_w)] = handlers;

        // Only the child-side ends may cross the process boundary.
        for parent_end in [stdin_w, stdout_r, stderr_r] {
            SetHandleInformation(parent_end, HANDLE_FLAG_INHERIT, 0);
        }

        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = stdin_r;
        si.hStdOutput = stdout_w;
        si.hStdError = stderr_w;

        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        let ok = CreateProcessAsUserW(
            token,
            std::ptr::null(),                 // application name: argv[0] is in the command line
            cmdline.as_mut_ptr(),
            std::ptr::null(),                 // process attributes
            std::ptr::null(),                 // thread attributes
            1,                                // inherit handles (the three stdio ends)
            CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
            env_block.as_mut_ptr() as *const std::ffi::c_void,
            cwd_wide.as_ptr(),
            &si,
            &mut pi,
        );
        let err = std::io::Error::last_os_error();

        // The child owns these copies now, whether or not the spawn worked.
        for child_end in [stdin_r, stdout_w, stderr_w] {
            CloseHandle(child_end);
        }
        if ok == 0 {
            for h in [stdin_w, stdout_r, stderr_r] {
                CloseHandle(h);
            }
            return Err(format!("CreateProcessAsUserW failed: {err}"));
        }

        if let Some(job) = job {
            if let Err(e) = assign_handle_to_job(job, pi.hProcess) {
                let _ = terminate_process(pi.hProcess);
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
                for h in [stdin_w, stdout_r, stderr_r] {
                    CloseHandle(h);
                }
                return Err(e);
            }
        }

        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);

        Ok(RestrictedChild {
            pid: pi.dwProcessId,
            process: pi.hProcess,
            stdin: stdin_w,
            stdout: stdout_r,
            stderr: stderr_r,
            job,
        })
    }
}

#[cfg(windows)]
fn assign_handle_to_job(job: HANDLE, process: HANDLE) -> Result<(), String> {
    use windows_sys::Win32::System::JobObjects::AssignProcessToJobObject;
    let ok = unsafe { AssignProcessToJobObject(job, process) };
    if ok == 0 {
        return Err(format!(
            "AssignProcessToJobObject failed: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn terminate_process(process: HANDLE) {
    use windows_sys::Win32::System::Threading::TerminateProcess;
    unsafe {
        TerminateProcess(process, 126);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wide_is_nul_terminated() {
        let w = wide(r"C:\ws");
        assert_eq!(w.last(), Some(&0));
        assert_eq!(w.len(), r"C:\ws".len() + 1);
    }

    #[test]
    fn job_and_path_reject_nothing_at_type_level() {
        // Compile-time contract only: the real behaviour needs a Windows host
        // (T4.6). This test exists so the functions are linked, not dead code.
        let _ = create_job as fn(Option<u32>, Option<u64>) -> Result<HANDLE, String>;
        let _ = final_path as fn(&str) -> Result<String, String>;
    }
}
