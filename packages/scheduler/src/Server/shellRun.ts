/**
 * One-shot shell execution with the sandbox seam applied.
 *
 * Extracted from `index.ts` so the `bash` tool can move onto the registry while
 * the core chain keeps working during the transition — both sides import the
 * same implementation rather than owning copies.
 */
import { exec as execCb } from 'node:child_process';
import { promisify } from 'node:util';
import { execShell } from './shell.js';
import { defaultSandboxScope, sandboxEnabled, sandboxedSpawn } from './sandbox.js';

const execAsync = promisify(execCb);

/** One shell command's budget. */
export const SHELL_TIMEOUT_MS = 120_000;
/** Capture ceiling before exec starts dropping output. */
export const SHELL_MAX_BUFFER = 4 * 1024 * 1024;

export interface ShellResult {
  code: number;
  stdout: string;
  stderr: string;
  /** Extra explanation for the model; empty when nothing needs saying. */
  note: string;
}

/**
 * Run one command.
 *
 * Compatibility default (`TRHA_SANDBOX=off`): the unconfined path is unchanged.
 * When the seam is enabled execution goes through the runner and a failure is
 * returned as a failed tool call — never a silent fallback.
 */
export async function runShell(cmd: string, opts: { cwd: string }): Promise<ShellResult> {
  const shell = execShell();
  if (sandboxEnabled()) {
    try {
      const result = await sandboxedSpawn(defaultSandboxScope(opts.cwd), {
        argv: [shell ?? 'bash', '-c', cmd],
        cwd: opts.cwd,
        timeoutMs: SHELL_TIMEOUT_MS,
      });
      return {
        code: result.code ?? 1,
        stdout: result.stdout,
        stderr: result.stderr,
        note: result.ok ? '' : (result.stderr ? '' : 'sandbox denied the command'),
      };
    } catch (e) {
      return {
        code: 1,
        stdout: '',
        stderr: (e as Error).message,
        note: 'sandbox unavailable',
      };
    }
  }
  try {
    const { stdout, stderr } = await execAsync(cmd, {
      cwd: opts.cwd,
      timeout: SHELL_TIMEOUT_MS,
      maxBuffer: SHELL_MAX_BUFFER,
      ...(shell ? { shell } : {}),
    });
    return { code: 0, stdout, stderr, note: '' };
  } catch (e) {
    const err = e as {
      code?: number | string; stdout?: string; stderr?: string;
      message: string; killed?: boolean;
    };
    const code = typeof err.code === 'number' ? err.code : (err.killed ? 124 : 1);
    const stdout = err.stdout ?? '';
    const stderr = err.stderr ?? '';
    // A kill is a timeout (exec's own message would just repeat the command);
    // otherwise exec's "Command failed: …" only adds noise once the command
    // produced output, so keep it for the empty case (ENOENT / bad cwd).
    const note = err.killed
      ? `timed out after ${SHELL_TIMEOUT_MS / 1000} s`
      : (stdout || stderr ? '' : err.message);
    return { code, stdout, stderr, note };
  }
}
