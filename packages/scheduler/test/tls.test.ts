// Scheduler TLS: HTTPS by default, self-signed loopback certificate generated
// on demand, explicit TRHA_TLS_CERT/KEY wins, TRHA_TLS=0 keeps plain HTTP.

import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ensureSelfSignedCert, resolveTls, tlsEnabled } from '../src/Server/tls.js';

function opensslAvailable(): boolean {
  try {
    execFileSync('openssl', ['version'], { stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
}

const hasOpenssl = opensslAvailable();

describe('tlsEnabled', () => {
  const saved = process.env.TRHA_TLS;
  afterEach(() => {
    if (saved === undefined) delete process.env.TRHA_TLS;
    else process.env.TRHA_TLS = saved;
  });

  it('is on by default', () => {
    delete process.env.TRHA_TLS;
    expect(tlsEnabled()).toBe(true);
  });

  it('can be turned off explicitly', () => {
    for (const v of ['0', 'false', 'off']) {
      process.env.TRHA_TLS = v;
      expect(tlsEnabled()).toBe(false);
    }
  });
});

describe.skipIf(!hasOpenssl)('ensureSelfSignedCert', () => {
  let dir: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'trha-tls-'));
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it('generates a reusable certificate pair', async () => {
    const first = ensureSelfSignedCert(dir);
    const cert = await readFile(first.certFile, 'utf8');
    const key = await readFile(first.keyFile, 'utf8');
    expect(cert).toContain('BEGIN CERTIFICATE');
    expect(key).toContain('BEGIN PRIVATE KEY');
    // second call reuses the same files
    const second = ensureSelfSignedCert(dir);
    expect(second).toEqual(first);
  });

  it('resolveTls returns material when enabled', async () => {
    const savedDir = process.env.TRHA_TLS_DIR;
    const savedCert = process.env.TRHA_TLS_CERT;
    const savedKey = process.env.TRHA_TLS_KEY;
    process.env.TRHA_TLS_DIR = dir;
    delete process.env.TRHA_TLS_CERT;
    delete process.env.TRHA_TLS_KEY;
    try {
      const tls = resolveTls();
      expect(tls?.cert.toString()).toContain('BEGIN CERTIFICATE');
      expect(tls?.key.toString()).toContain('PRIVATE KEY');
    } finally {
      if (savedDir === undefined) delete process.env.TRHA_TLS_DIR;
      else process.env.TRHA_TLS_DIR = savedDir;
      if (savedCert === undefined) delete process.env.TRHA_TLS_CERT;
      else process.env.TRHA_TLS_CERT = savedCert;
      if (savedKey === undefined) delete process.env.TRHA_TLS_KEY;
      else process.env.TRHA_TLS_KEY = savedKey;
    }
  });
});
