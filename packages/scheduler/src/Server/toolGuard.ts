// Defensive guards for host tools (deepseek-harness defensive-patterns):
//   * write paths must resolve inside the workspace even through symlinks
//     ("unlink link-shaped paths" / never hand untrusted output predictable
//     escape paths);
//   * tool outputs are length-capped before being handed back to the model.

import { mkdir, realpath } from 'node:fs/promises';
import path from 'node:path';

export const MAX_TOOL_OUTPUT = 64 * 1024; // 64 KiB

/**
 * Resolve a requested write target so that its real (symlink-free) parent
 * directory lives under `root`.  Creates the parent when missing and
 * returns the canonical target path, or `null` when the path escapes.
 */
export async function confineWritePath(root: string, target: string): Promise<string | null> {
  const absRoot = path.resolve(root) + path.sep;
  const resolved = path.resolve(target);
  if (!(resolved + '').startsWith(absRoot)) {
    return null;
  }
  try {
    const parent = path.dirname(resolved);
    await mkdir(parent, { recursive: true });
    const realParent = await realpath(parent);
    if (!(realParent + path.sep).startsWith(absRoot)) {
      return null; // a symlinked parent escapes the workspace
    }
    return path.join(realParent, path.basename(resolved));
  } catch {
    return null;
  }
}

/** Cap tool output at MAX_TOOL_OUTPUT and mark the truncation. */
export function limitOutput(text: string): string {
  if (text.length <= MAX_TOOL_OUTPUT) {
    return text;
  }
  return text.slice(0, MAX_TOOL_OUTPUT) + '\n…[truncated]';
}
