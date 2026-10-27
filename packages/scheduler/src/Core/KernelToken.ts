// Shared kernel token.
//
// The kernel binds to 127.0.0.1 and requires `Authorization: Bearer <token>`
// on every route except /health.  **Every kernel launch rotates the token**:
// it mints 32 random bytes and publishes them atomically to
// `~/.trha/kernel-token` (0600).
//
// The scheduler re-reads the file per request and retries once on 401
// (Core/HTTP.ts, Bridge/Haskell.ts, forwardToKernel), so a kernel restart
// needs no scheduler restart — that is the whole handshake.
//
// If the file is absent (an older kernel that does not check), no header is
// sent.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

/** `~/.trha/kernel-token` — the kernel's loopback credential. */
export function kernelTokenPath(): string {
  return path.join(homedir(), '.trha', 'kernel-token');
}

/** `TRHA_KERNEL_TOKEN` wins; otherwise the shared file; otherwise null. */
export function resolveKernelToken(): string | null {
  const override = process.env.TRHA_KERNEL_TOKEN?.trim();
  if (override) return override;
  try {
    const stored = readFileSync(kernelTokenPath(), 'utf8').trim();
    return stored || null;
  } catch {
    return null;
  }
}
