// Platform shell resolution for every spawn site.
//
// POSIX keeps the exact `bash -lc` contract — the existing scheduler tests are
// the regression guard. win32 uses `cmd.exe /d /s /c`, the same form Node's
// `exec` picks and DeepSeek-Reasonix's windows_compat.go encodes for. All
// functions are pure: the platform is injected, so behaviour is testable
// without a real Windows machine.

export type ShellSpec = {
  cmd: string;
  args: string[];
  /** win32-only spawn options: verbatim argv so cmd.exe owns the quoting. */
  options?: { windowsVerbatimArguments?: boolean };
};

/** The shell invocation for one command line on one platform. */
export function resolveShell(command: string, platform: NodeJS.Platform = process.platform): ShellSpec {
  if (platform === 'win32') {
    // /d skips AutoRun; /s makes cmd.exe strip only the outer quotes of the /c
    // string, so the command's own quotes and operators are parsed by cmd.exe —
    // never by CommandLineToArgvW. windowsVerbatimArguments keeps Node from
    // re-escaping the quotes (the cross-spawn rule; Reasonix windows_compat.go
    // reaches the same command line by hand in Go).
    return {
      cmd: 'cmd.exe',
      args: ['/d', '/s', '/c', `"${command}"`],
      options: { windowsVerbatimArguments: true },
    };
  }
  return { cmd: 'bash', args: ['-lc', command] };
}

/** The interactive persistent shell (terminal_open). PowerShell has no PS1. */
export function interactiveShell(platform: NodeJS.Platform = process.platform): ShellSpec {
  if (platform === 'win32') return { cmd: 'powershell.exe', args: ['-NoLogo'] };
  return { cmd: 'bash', args: ['-l'] };
}

/** PowerShell executables in preference order (PS5 is Windows-only). */
export function powerShellCandidates(platform: NodeJS.Platform = process.platform): string[] {
  return platform === 'win32' ? ['pwsh', 'powershell.exe'] : ['pwsh'];
}

export type RunnerSpec = { ok: boolean; cmd: string };

/** run_code shell runner for a language; bash/sh are POSIX-only. */
export function shellRunner(language: string, platform: NodeJS.Platform = process.platform): RunnerSpec {
  if (language !== 'bash' && language !== 'sh') {
    // non-shell languages share one table on every platform
    const table: Record<string, string> = { python: 'python3', python3: 'python3', javascript: 'node', js: 'node', node: 'node', lean: 'lean' };
    const cmd = table[language];
    return cmd ? { ok: true, cmd } : { ok: false, cmd: '' };
  }
  if (platform === 'win32') return { ok: false, cmd: '' };
  return { ok: true, cmd: 'bash' };
}

/**
 * Spawn env hardened against cwd command hijacking: on win32 a bare command
 * name (`python`) would otherwise resolve against the current directory first,
 * so a workspace shipping a `python.exe` would execute it
 * (DeepSeek-Reasonix runner.go:85-105). Harmless no-op on POSIX.
 */
export function hardenedEnv(
  platform: NodeJS.Platform = process.platform,
  base: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  if (platform !== 'win32') return base;
  return { ...base, NoDefaultCurrentDirectoryInExePath: '1' };
}
