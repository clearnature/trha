#!/usr/bin/env node
// Minimal NDJSON runner used by the scheduler tests. Mirrors the real
// `trha sandbox runner` handshake/exec/exit frames.

import { createInterface } from 'node:readline';

// `trha sandbox config [--enabled on|off ...] --json`.
if (process.argv[2] === 'sandbox' && process.argv[3] === 'config') {
  const at = process.argv.indexOf('--enabled');
  const enabled = at >= 0 && process.argv[at + 1] === 'on';
  process.stdout.write(JSON.stringify({
    enabled,
    policy: 'read-only',
    network: 'off',
    scratch: '/tmp/trha-scratch',
  }));
  process.exit(0);
}

// `trha sandbox status --json` shape (the scheduler shells out to this).
if (process.argv[2] === 'sandbox' && process.argv[3] === 'status') {
  process.stdout.write(JSON.stringify({
    backend: 'linux-bwrap',
    platform: 'linux',
    enforcement: 'full',
    available: true,
    capabilities: {},
    notes: [],
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
    process.stdout.write(JSON.stringify({
      v: 1, op: 'stdout', id: frame.id, data: 'mock-output\n',
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
