// Platform shell resolution (see src/Server/shell.ts).
//
// POSIX keeps the exact `bash -lc` contract — the 252 existing scheduler tests
// are the regression guard. win32 routes to `cmd.exe /d /s /c`, the same form
// Node's exec picks and DeepSeek-Reasonix's windows_compat.go encodes for.
// Everything is pure: the platform is injected, so no real Windows is needed.

import { describe, it, expect } from 'vitest';
import { resolveShell, interactiveShell, powerShellCandidates, shellRunner, hardenedEnv } from '../src/Server/shell.js';

describe('resolveShell', () => {
  it('preserves the POSIX contract byte-for-byte', () => {
    expect(resolveShell('make test', 'linux')).toEqual({ cmd: 'bash', args: ['-lc', 'make test'] });
    expect(resolveShell('make test', 'darwin')).toEqual({ cmd: 'bash', args: ['-lc', 'make test'] });
  });

  it('routes to cmd.exe /d /s /c on win32', () => {
    expect(resolveShell('dir', 'win32')).toEqual({
      cmd: 'cmd.exe',
      args: ['/d', '/s', '/c', '"dir"'],
      options: { windowsVerbatimArguments: true },
    });
  });

  it('wraps the win32 command in outer quotes for /s to strip (cmd.exe owns the rest)', () => {
    const spec = resolveShell('echo "a & b"', 'win32');
    expect(spec.args[3]).toBe('"echo "a & b""');
    expect(spec.options?.windowsVerbatimArguments).toBe(true);
  });

  it('uses the live platform when not injected', () => {
    const live = resolveShell('echo hi');
    expect(live.cmd.length).toBeGreaterThan(0);
    expect(live.args).toContain('echo hi');
  });
});

describe('interactiveShell', () => {
  it('keeps the POSIX login shell', () => {
    expect(interactiveShell('linux')).toEqual({ cmd: 'bash', args: ['-l'] });
  });

  it('uses Windows PowerShell on win32 (PS1 has no meaning there)', () => {
    expect(interactiveShell('win32')).toEqual({ cmd: 'powershell.exe', args: ['-NoLogo'] });
  });
});

describe('powerShellCandidates', () => {
  it('prefers pwsh with a PS5 fallback only on win32', () => {
    expect(powerShellCandidates('win32')).toEqual(['pwsh', 'powershell.exe']);
    expect(powerShellCandidates('linux')).toEqual(['pwsh']);
    expect(powerShellCandidates('darwin')).toEqual(['pwsh']);
  });
});

describe('shellRunner', () => {
  it('passes non-shell languages through unchanged', () => {
    expect(shellRunner('python', 'linux')).toEqual({ ok: true, cmd: 'python3' });
    expect(shellRunner('python', 'win32')).toEqual({ ok: true, cmd: 'python3' });
    expect(shellRunner('lean', 'win32')).toEqual({ ok: true, cmd: 'lean' });
  });

  it('keeps bash/sh on POSIX', () => {
    expect(shellRunner('bash', 'linux')).toEqual({ ok: true, cmd: 'bash' });
    expect(shellRunner('sh', 'darwin')).toEqual({ ok: true, cmd: 'bash' });
  });

  it('refuses bash/sh on win32 instead of silently failing at spawn', () => {
    expect(shellRunner('bash', 'win32')).toEqual({ ok: false, cmd: '' });
    expect(shellRunner('sh', 'win32')).toEqual({ ok: false, cmd: '' });
  });
});

describe('hardenedEnv', () => {
  it('sets NoDefaultCurrentDirectoryInExePath on win32 (Reasonix runner.go:85 rule)', () => {
    const env = hardenedEnv('win32', { PATH: 'C:\\Windows' });
    expect(env.NoDefaultCurrentDirectoryInExePath).toBe('1');
    expect(env.PATH).toBe('C:\\Windows');
  });

  it('returns the base env untouched on POSIX', () => {
    const base = { PATH: '/usr/bin' };
    expect(hardenedEnv('linux', base)).toBe(base);
  });

  it('defaults the base to process.env', () => {
    const env = hardenedEnv('win32');
    expect(env.NoDefaultCurrentDirectoryInExePath).toBe('1');
  });
});
