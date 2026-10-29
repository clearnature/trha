#!/usr/bin/env node
// Minimal NDJSON runner used by the scheduler tests. Mirrors the real
// `trha sandbox runner` handshake/exec/exit frames.

import { createInterface } from 'node:readline';

// `trha sandbox config [--enabled on|off ...] --json`.
if (process.argv[2] === 'sandbox' && process.argv[3] === 'config') {
  if (process.env.MOCK_SANDBOX_EMPTY === '1') {
    process.stdout.write('{}');
    process.exit(0);
  }
  const val = (k) => {
    const i = process.argv.indexOf(k);
    return i >= 0 ? process.argv[i + 1] : undefined;
  };
  process.stdout.write(JSON.stringify({
    enabled: val('--enabled') === 'on',
    policy: val('--policy') ?? 'read-only',
    network: val('--network') ?? 'off',
    scratch: val('--scratch') ?? '/tmp/trha-scratch',
  }));
  process.exit(0);
}

// `trha sandbox status --json` shape (the scheduler shells out to this).
if (process.argv[2] === 'sandbox' && process.argv[3] === 'status') {
  if (process.env.MOCK_SANDBOX_STATUS_EXTRA === '1') {
    process.stdout.write(JSON.stringify({
      backend: 'linux-bwrap', platform: 'linux', enforcement: 'full',
      available: true, capabilities: {}, missing: ['net'], notes: ['extra note'],
    }));
    process.exit(0);
  }
  process.stdout.write(JSON.stringify({
    backend: 'linux-bwrap',
    platform: 'linux',
    enforcement: 'full',
    available: true,
  }));
  process.exit(0);
}

const rl = createInterface({ input: process.stdin });

rl.on('line', (line) => {
  if (!line.trim()) return;
  const frame = JSON.parse(line);
  if (frame.op === 'hello') {
    process.stdout.write(JSON.stringify({
      v: 1,
      op: 'ready',
      backend: 'linux-bwrap',
      enforcement: 'full',
      capabilities: {},
      pid: 0,
    }) + '\n');
    return;
  }
  if (frame.op === 'exec') {
    if (process.env.MOCK_SANDBOX_HANG === '1') return;
    if (process.env.MOCK_SANDBOX_ERROR === '1') {
      process.stdout.write(JSON.stringify({
        v: 1, op: 'error', id: frame.id, kind: 'runner', message: 'boom',
      }) + '\n');
      return;
    }
    if (process.env.MOCK_SANDBOX_QUIT === '1') process.exit(0);
    const args = process.argv.slice(2).join(' ');
    process.stdout.write(JSON.stringify({
      v: 1, op: 'stdout', id: frame.id, data: `mock-output\nargs:${args}\n`,
    }) + '\n');
    process.stdout.write(JSON.stringify({
      v: 1, op: 'exit', id: frame.id, code: 0,
    }) + '\n');
    return;
  }
  if (frame.op === 'shutdown') {
    rl.close();
    process.exitCode = 0;
  }
});
