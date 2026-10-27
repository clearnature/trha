// TLS material for the scheduler.
//
// HTTPS is the default (the shell, Desktop and the browser all talk to the
// same origin).  Certificates come from, in order:
//
//   1. TRHA_TLS_CERT + TRHA_TLS_KEY (explicit paths);
//   2. a self-signed pair under ~/.trha/tls/ (generated once with openssl,
//      SAN = 127.0.0.1, localhost).
//
// TRHA_TLS=0 (or false/off) keeps the old plain-HTTP behaviour.

import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

export interface TlsMaterial {
  cert: Buffer;
  key: Buffer;
}

/** `~/.trha/tls` (TRHA_TLS_DIR overrides, mostly for tests). */
export function tlsDir(): string {
  const override = process.env.TRHA_TLS_DIR?.trim();
  return override || path.join(homedir(), '.trha', 'tls');
}

/** Whether TLS is enabled; only an explicit 0/false/off turns it off. */
export function tlsEnabled(): boolean {
  const v = (process.env.TRHA_TLS ?? '').trim().toLowerCase();
  return !(v === '0' || v === 'false' || v === 'off');
}

/**
 * Ensure a self-signed certificate exists and return its paths.
 *
 * Generated once, then reused.  The key is 0600; the directory 0700.
 */
export function ensureSelfSignedCert(
  dir = tlsDir(),
): { certFile: string; keyFile: string } {
  const certFile = path.join(dir, 'cert.pem');
  const keyFile = path.join(dir, 'key.pem');
  if (existsSync(certFile) && existsSync(keyFile)) return { certFile, keyFile };
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
    '-keyout', keyFile, '-out', certFile,
    '-subj', '/CN=127.0.0.1',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
  ], { stdio: 'pipe' });
  chmodSync(keyFile, 0o600);
  chmodSync(certFile, 0o644);
  return { certFile, keyFile };
}

/** Resolve TLS material, or null when TLS is disabled. */
export function resolveTls(): TlsMaterial | null {
  if (!tlsEnabled()) return null;
  const certEnv = process.env.TRHA_TLS_CERT?.trim();
  const keyEnv = process.env.TRHA_TLS_KEY?.trim();
  const files = certEnv && keyEnv
    ? { certFile: certEnv, keyFile: keyEnv }
    : ensureSelfSignedCert();
  return { cert: readFileSync(files.certFile), key: readFileSync(files.keyFile) };
}
