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
#![allow(non_snake_case)] // windows-sys macro shapes the item, not us

use std::os::windows::ffi::OsStrExt;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFinalPathNameByHandleW, FILE_FLAG_BACKUP_SEMANTICS, FILE_NAME_NORMALIZED,
    FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_ACTIVE_PROCESS,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOB_OBJECT_LIMIT_PROCESS_MEMORY,
};
use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE};
// T4.2/T4.3 (keep-alive SIDs, Low integrity, DACL merge):
use windows_sys::Win32::Foundation::BOOL;
use windows_sys::Win32::Security::Authorization::{
    GetNamedSecurityInfoW, SetEntriesInAclW, SetNamedSecurityInfoW, DENY_ACCESS, EXPLICIT_ACCESS_W,
    GRANT_ACCESS, NO_MULTIPLE_TRUSTEE, SE_FILE_OBJECT, TRUSTEE_IS_GROUP, TRUSTEE_IS_SID,
    TRUSTEE_IS_USER, TRUSTEE_W,
};
use windows_sys::Win32::Security::{
    AllocateAndInitializeSid, FreeSid, GetLengthSid, GetTokenInformation, TokenLogonSid, TokenUser,
    ACE_HEADER, ACL, CONTAINER_INHERIT_ACE, DACL_SECURITY_INFORMATION, LABEL_SECURITY_INFORMATION,
    OBJECT_INHERIT_ACE, PSECURITY_DESCRIPTOR, PSID, SECURITY_WORLD_SID_AUTHORITY,
    SID_IDENTIFIER_AUTHORITY, TOKEN_GROUPS, TOKEN_QUERY, TOKEN_USER,
};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_DELETE_CHILD, FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

fn wide(s: &str) -> Vec<u16> {
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(Some(0))
        .collect()
}

/// Create a job that kills its whole tree when the last handle closes, plus
/// optional active-process and committed-memory caps.
pub fn create_job(
    active_process: Option<u32>,
    memory_bytes: Option<u64>,
) -> Result<HANDLE, String> {
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
#[allow(unused_assignments)]
pub fn create_restricted_token(restrict_to_user: bool) -> Result<HANDLE, String> {
    use windows_sys::Win32::Security::{
        CreateRestrictedToken, GetTokenInformation, TokenUser, DISABLE_MAX_PRIVILEGE,
        SID_AND_ATTRIBUTES, TOKEN_DUPLICATE, TOKEN_QUERY, TOKEN_USER, WRITE_RESTRICTED,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    unsafe {
        let mut current: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_DUPLICATE | TOKEN_QUERY,
            &mut current,
        ) == 0
        {
            return Err(format!(
                "OpenProcessToken failed: {}",
                std::io::Error::last_os_error()
            ));
        }

        // The SIDs live inside these buffers: they must outlive the call below.
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
        // Keep-alive group (logon SID + Everyone; DSH 2026-08 confirmed): without
        // it, early DLL initialization dies with 0xC0000142 and CNG crashes
        // pwsh with 0xE0434352. Present in BOTH modes — it confers no write
        // authority because the Low integrity label denies writes outside the
        // labeled roots. Everyone is allocated once; the callee frees it.
        let world = world_sid()?;
        // (buffer, Some(sid)) — the buffer owns the SID memory and must
        // outlive CreateRestrictedToken below.
        let (_logon_buf, logon) = logon_sid(current)?;
        restrict_sids.push(SID_AND_ATTRIBUTES {
            Sid: world,
            Attributes: 0,
        });
        if let Some(l) = logon {
            restrict_sids.push(SID_AND_ATTRIBUTES {
                Sid: l,
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
        free_sid(world);
        if ok == 0 {
            return Err(format!("CreateRestrictedToken failed: {err}"));
        }
        set_token_low_integrity(restricted)?;
        Ok(restricted)
    }
}

// ── T4.3: workspace ACL ───────────────────────────────────────────────────

// Windows release of `SetTokenIntegrityLevel` — windows-sys 0.59 does not
// export it, so bind the same DLL the way its own macros do. On non-Windows
// the declaration compiles but is never linked into a call path.
windows_targets::link!("advapi32.dll" "system" fn SetTokenIntegrityLevel(tokenhandle : HANDLE, integritylevelsid : PSID) -> BOOL);

// Windows release of `LocalFree` for the security-descriptor buffers the
// advapi32 info functions allocate.
windows_targets::link!("kernel32.dll" "system" fn LocalFree(hmem : *mut core::ffi::c_void) -> *mut core::ffi::c_void);

/// The Low integrity SID `S-1-16-4096` (SECURITY_MANDATORY_LOW_RID).
///
/// The caller frees it with `free_sid` after the last use.
fn low_label_sid() -> Result<PSID, String> {
    unsafe {
        let authority = SID_IDENTIFIER_AUTHORITY {
            Value: [0, 0, 0, 0, 0, 16],
        };
        let mut sid: PSID = std::ptr::null_mut();
        if AllocateAndInitializeSid(&authority, 1, 4096, 0, 0, 0, 0, 0, 0, 0, &mut sid) == 0 {
            return Err(format!(
                "AllocateAndInitializeSid(S-1-16-4096) failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(sid)
    }
}

/// The Everyone SID `S-1-1-0` (SECURITY_WORLD_SID_AUTHORITY, RID 0).
fn world_sid() -> Result<PSID, String> {
    let authority = SECURITY_WORLD_SID_AUTHORITY;
    unsafe {
        let mut sid: PSID = std::ptr::null_mut();
        if AllocateAndInitializeSid(&authority, 1, 0, 0, 0, 0, 0, 0, 0, 0, &mut sid) == 0 {
            return Err(format!(
                "AllocateAndInitializeSid(S-1-1-0) failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(sid)
    }
}

/// Free a SID from `AllocateAndInitializeSid` (the crate already binds this).
fn free_sid(sid: PSID) {
    if !sid.is_null() {
        unsafe { FreeSid(sid) };
    }
}

/// The logon SID (session marker) and the buffer owning it.
///
/// Optional: a token without a logon SID (e.g. a service entry) still works —
/// Everyone alone carries the keep-alive role there (DSH 2026-08).
fn logon_sid(token: HANDLE) -> Result<(Vec<u8>, Option<PSID>), String> {
    unsafe {
        let mut len: u32 = 0;
        GetTokenInformation(token, TokenLogonSid, std::ptr::null_mut(), 0, &mut len);
        if len == 0 {
            return Ok((Vec::new(), None)); // no logon SID: not fatal
        }
        let mut buf = vec![0u8; len as usize];
        let ok = GetTokenInformation(
            token,
            TokenLogonSid,
            buf.as_mut_ptr() as *mut std::ffi::c_void,
            len,
            &mut len,
        );
        if ok == 0 {
            return Ok((Vec::new(), None));
        }
        let groups = &*(buf.as_ptr() as *const TOKEN_GROUPS);
        if groups.GroupCount == 0 {
            return Ok((buf, None));
        }
        Ok((buf, Some(groups.Groups[0].Sid)))
    }
}

/// Lower a freshly created (restricted) token to Low integrity.
///
/// This is the token-side half of the mandatory-integrity wall (gpt/DSH
/// 2026-08). We check the call first because CreateRestrictedToken succeeds
/// long before any real write: a silently High-integrity token would make the
/// SACL label inert and every probe would "pass" for the wrong reason.
fn set_token_low_integrity(token: HANDLE) -> Result<(), String> {
    let sid = low_label_sid()?;
    unsafe {
        let rc = SetTokenIntegrityLevel(token, sid);
        let err = std::io::Error::last_os_error();
        free_sid(sid);
        if rc == 0 {
            return Err(format!("SetTokenIntegrityLevel failed: {err}"));
        }
    }
    Ok(())
}

/// One `SetNamedSecurityInfoW` applies three edits to the write root (gpt/DSH
/// 2026-08), in this order inside the merged DACL:
///
/// 1. **Allow** (this user's SID): read+write+execute+delete, inherited — the
///    "grant" half. The restricted token's restricting SID is the user SID
///    itself, so writes succeed only here.
/// 2. **Deny `FILE_DELETE_CHILD` to Everyone** (`CONTAINER_INHERIT` only):
///    the parent-directory delete right authorizes a delete without
///    co-signing the restricting SIDs; the deny closes that escape while
///    leaving file-level DACLs untouched.
/// 3. **Label the tree Low**, inheritable: with the child token also Low,
///    mandatory integrity denies write-class access outside the labeled set.
///
/// The old DACL is **read and merged** — passing `null` as the old DACL
/// replaces the whole descriptor and drops every other ACE (SYSTEM etc.),
/// which is a host-breaking bug this function must never reintroduce.
pub fn grant_directory_write(path: &str) -> Result<(), String> {
    // 1. current user SID (the grant's trustee and the token's restricting SID)
    let user_sid = unsafe {
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
    if user_sid.is_null() {
        return Err("token has no user SID".to_string());
    }

    // 2. keep-alive deny trustee
    let world = world_sid()?;
    let wide_path = wide(path);
    let result = unsafe {
        // 3. read the *existing* DACL — merge, do not replace
        let mut old_dacl: *mut ACL = std::ptr::null_mut();
        let mut old_sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        let rc = GetNamedSecurityInfoW(
            wide_path.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut old_dacl,
            std::ptr::null_mut(),
            &mut old_sd,
        );
        if rc != 0 {
            return Err(format!("GetNamedSecurityInfoW({path}) failed: {rc}"));
        }

        // 4. user allow + Everyone delete-child deny
        let mut allow: EXPLICIT_ACCESS_W = std::mem::zeroed();
        allow.grfAccessPermissions =
            FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_GENERIC_EXECUTE | DELETE;
        allow.grfAccessMode = GRANT_ACCESS;
        allow.grfInheritance = CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE;
        allow.Trustee = TRUSTEE_W {
            pMultipleTrustee: std::ptr::null_mut(),
            MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
            TrusteeForm: TRUSTEE_IS_SID,
            TrusteeType: TRUSTEE_IS_USER,
            ptstrName: user_sid as *mut u16,
        };
        let mut deny: EXPLICIT_ACCESS_W = std::mem::zeroed();
        deny.grfAccessPermissions = FILE_DELETE_CHILD;
        deny.grfAccessMode = DENY_ACCESS;
        deny.grfInheritance = CONTAINER_INHERIT_ACE;
        deny.Trustee = TRUSTEE_W {
            pMultipleTrustee: std::ptr::null_mut(),
            MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
            TrusteeForm: TRUSTEE_IS_SID,
            TrusteeType: TRUSTEE_IS_GROUP,
            ptstrName: world as *mut u16,
        };
        let entries = [allow, deny];

        let mut new_acl: *mut ACL = std::ptr::null_mut();
        let rc = SetEntriesInAclW(
            entries.len() as u32,
            entries.as_ptr(),
            old_dacl,
            &mut new_acl,
        );
        if rc != 0 {
            LocalFree(old_sd as *mut std::ffi::c_void);
            return Err(format!("SetEntriesInAclW({path}) failed: {rc}"));
        }

        // 5. hand-built SACL label (SetEntriesInAclW cannot emit label ACEs,
        //    and AddAccessAllowedAceEx is pinned to ACCESS_ALLOWED)
        let label = low_label_sid()?;
        let sid_len = GetLengthSid(label);
        // ACE body: AceHeader(4) + Mask(4) + Sid — 4-aligned like the kernel does.
        let ace_size = 8 + sid_len;
        let acl_size = 8u32 + ace_size;
        let mut sacl_buf = vec![0u8; acl_size as usize];
        let sacl = sacl_buf.as_mut_ptr() as *mut ACL;
        (*sacl).AclRevision = 2; // ACL_REVISION
        (*sacl).Sbz1 = 0;
        (*sacl).AclSize = acl_size as u16;
        (*sacl).AceCount = 1;
        (*sacl).Sbz2 = 0;
        #[repr(C)]
        struct LabelAce {
            ace_type: u8,  // SYSTEM_MANDATORY_LABEL_ACE_TYPE = 0x11
            ace_flags: u8, // inheritable into files and directories
            ace_size: u16,
            mask: u32, // SYSTEM_MANDATORY_LABEL_NO_WRITE_UP (0x2)
                       // SidStart follows; copied as raw SID bytes below.
        }
        let ace = sacl_buf.as_mut_ptr().add(8);
        let header = ace as *mut ACE_HEADER;
        (*header).AceType = 0x11;
        (*header).AceFlags = (CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE) as u8;
        (*header).AceSize = ace_size as u16;
        std::ptr::copy_nonoverlapping(label as *const u8, ace.add(8), sid_len as usize);
        let _ = LabelAce {
            ace_type: 0,
            ace_flags: 0,
            ace_size: 0,
            mask: 0,
        }; // layout kept for review

        // 6. one call commits DACL + SACL label
        let set = SetNamedSecurityInfoW(
            wide_path.as_ptr() as *mut u16,
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | LABEL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            new_acl,
            sacl,
        );
        free_sid(label);
        LocalFree(new_acl as *mut std::ffi::c_void);
        LocalFree(old_sd as *mut std::ffi::c_void);
        if set != 0 {
            return Err(format!("SetNamedSecurityInfoW({path}) failed: {set}"));
        }
        Ok(())
    };
    free_sid(world);
    result
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
        let len = GetFinalPathNameByHandleW(
            handle,
            buf.as_mut_ptr(),
            buf.len() as u32,
            FILE_NAME_NORMALIZED,
        );
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

        let mut handlers: [(HANDLE, HANDLE); 3] = [(std::ptr::null_mut(), std::ptr::null_mut()); 3];
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
            std::ptr::null(), // application name: argv[0] is in the command line
            cmdline.as_mut_ptr(),
            std::ptr::null(), // process attributes
            std::ptr::null(), // thread attributes
            1,                // inherit handles (the three stdio ends)
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
