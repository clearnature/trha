// P0/P1 judgement tests for the scheduler-side sandbox seam.
// docs/plans/sandbox-architecture.md §6.1/§6.2: no unconfined fallback.

import { chmodSync, existsSync, readFileSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';
import {
  SandboxUnavailableError,
  defaultSandboxScope,
  policyCanonicalText,
  readSandboxConfig,
  sandboxEnabled,
  sandboxStatus,
  runExperiment,
  sandboxedInteractive,
  sandboxedSpawn,
  setSandboxConfigRuntime,
  setSandboxEnabledRuntime,
  writeSandboxConfig,
  type SandboxScope,
} from '../src/Server/sandbox.js';
import {
  PROTOCOL_VERSION,
  decodeFrame,
  encodeFrame,
  type ExecFrame,
} from '../src/Server/sandboxProtocol.js';

const scope: SandboxScope = {
  id: 'root/a',
  parent: 'root',
  policy: { kind: 'read-only', readonlyRoots: ['/ws'] },
  isolation: 'process',
  scratch: path.join(os.tmpdir(), 'trha-sandbox-test-scratch'),
};

const fixture = fileURLToPath(new URL('./fixtures/mock-sandbox-runner.mjs', import.meta.url));

describe('sandbox seam switch', () => {
  it('defaults to off (compatibility)', () => {
    expect(sandboxEnabled({})).toBe(false);
    expect(sandboxEnabled({ TRHA_SANDBOX: 'off' })).toBe(false);
    expect(sandboxEnabled({ TRHA_SANDBOX: 'false' })).toBe(false);
    expect(sandboxEnabled({ TRHA_SANDBOX: '0' })).toBe(false);
  });

  it('enables only on an explicit opt-in', () => {
    expect(sandboxEnabled({ TRHA_SANDBOX: 'on' })).toBe(true);
    expect(sandboxEnabled({ TRHA_SANDBOX: '1' })).toBe(true);
    expect(sandboxEnabled({ TRHA_SANDBOX: 'enforce' })).toBe(true);
  });

  it('reports no backend when off', async () => {
    const status = await sandboxStatus();
    expect(status.available).toBe(false);
    expect(status.enforcement).toBe('none');
  });
});

describe('sandboxedSpawn (off)', () => {
  it('refuses instead of running unconfined', async () => {
    await expect(
      sandboxedSpawn(scope, { argv: ['bash', '-c', 'true'], cwd: '/ws' }),
    ).rejects.toBeInstanceOf(SandboxUnavailableError);
  });
});

describe('sandboxedSpawn (on, mock runner)', () => {
  it('speaks NDJSON and returns the runner result', async () => {
    chmodSync(fixture, 0o755);
    const previousSandbox = process.env.TRHA_SANDBOX;
    const previousRunner = process.env.TRHA_SANDBOX_RUNNER;
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    try {
      const result = await sandboxedSpawn(scope, { argv: ['echo', 'x'], cwd: '/tmp' });
      expect(result.ok).toBe(true);
      expect(result.code).toBe(0);
      expect(result.stdout).toContain('mock-output');
      expect(result.enforcement).toBe('full');
    } finally {
      if (previousSandbox === undefined) delete process.env.TRHA_SANDBOX;
      else process.env.TRHA_SANDBOX = previousSandbox;
      if (previousRunner === undefined) delete process.env.TRHA_SANDBOX_RUNNER;
      else process.env.TRHA_SANDBOX_RUNNER = previousRunner;
    }
  });
});

/** Poll until the predicate holds (mock runner frames arrive asynchronously). */
async function waitFor(cond: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (cond()) return;
    await new Promise(r => setTimeout(r, 20));
  }
  throw new Error('timed out waiting for frames');
}

describe('sandboxedInteractive (on, mock runner)', () => {
  it('keeps a session open and routes stdin frames', async () => {
    chmodSync(fixture, 0o755);
    const previousSandbox = process.env.TRHA_SANDBOX;
    const previousRunner = process.env.TRHA_SANDBOX_RUNNER;
    const previousInteractive = process.env.MOCK_SANDBOX_INTERACTIVE;
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    process.env.MOCK_SANDBOX_INTERACTIVE = '1';
    try {
      const session = await sandboxedInteractive(scope, { argv: ['bash', '-l'], cwd: '/tmp' });
      let output = '';
      session.onData(chunk => { output += chunk; });
      const exited = new Promise<number>(resolve => session.onExit(resolve));

      session.write('hello\n');
      await waitFor(() => output.includes('echo:hello'));
      expect(output).toContain('echo:hello');

      session.write('exit\n');
      expect(await exited).toBe(0);
    } finally {
      if (previousSandbox === undefined) delete process.env.TRHA_SANDBOX;
      else process.env.TRHA_SANDBOX = previousSandbox;
      if (previousRunner === undefined) delete process.env.TRHA_SANDBOX_RUNNER;
      else process.env.TRHA_SANDBOX_RUNNER = previousRunner;
      if (previousInteractive === undefined) delete process.env.MOCK_SANDBOX_INTERACTIVE;
      else process.env.MOCK_SANDBOX_INTERACTIVE = previousInteractive;
    }
  });

  it('refuses instead of running unconfined when the seam is off', async () => {
    const previousSandbox = process.env.TRHA_SANDBOX;
    delete process.env.TRHA_SANDBOX;
    try {
      await expect(
        sandboxedInteractive(scope, { argv: ['bash', '-l'], cwd: '/tmp' }),
      ).rejects.toBeInstanceOf(SandboxUnavailableError);
    } finally {
      if (previousSandbox !== undefined) process.env.TRHA_SANDBOX = previousSandbox;
    }
  });
});

describe('sandboxStatus (on, mock runner)', () => {  it('asks the runner for the real backend', async () => {
    chmodSync(fixture, 0o755);
    const previousSandbox = process.env.TRHA_SANDBOX;
    const previousRunner = process.env.TRHA_SANDBOX_RUNNER;
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    try {
      const status = await sandboxStatus();
      expect(status.backend).toBe('linux-bwrap');
      expect(status.available).toBe(true);
      expect(status.enforcement).toBe('full');
    } finally {
      if (previousSandbox === undefined) delete process.env.TRHA_SANDBOX;
      else process.env.TRHA_SANDBOX = previousSandbox;
      if (previousRunner === undefined) delete process.env.TRHA_SANDBOX_RUNNER;
      else process.env.TRHA_SANDBOX_RUNNER = previousRunner;
    }
  });
});

describe('runExperiment (on, mock runner)', () => {
  it('runs the variant x seed matrix and writes repro.json', async () => {
    chmodSync(fixture, 0o755);
    const previousSandbox = process.env.TRHA_SANDBOX;
    const previousRunner = process.env.TRHA_SANDBOX_RUNNER;
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    const root = path.join(os.tmpdir(), `trha-exp-${Date.now()}`);
    try {
      const outcome = await runExperiment({
        id: 'b1',
        root,
        baseline: path.join(root, 'baseline'),
        variants: [{ id: 'a' }, { id: 'b' }],
        seeds: [1, 2],
        concurrency: 2,
      }, {
        makeRequest: task => ({ argv: ['echo', 'x'], cwd: task.work }),
        cacheState: 'cold',
        userId: 'probe-user',
        toolchain: { ghc: '9.14.1' },
      });
      expect(outcome.results).toHaveLength(4);
      expect(outcome.results.every(r => r.ok)).toBe(true);
      expect(outcome.results.map(r => `${r.variant}/${r.seed}`).sort())
        .toEqual(['a/1', 'a/2', 'b/1', 'b/2']);
      expect(existsSync(path.join(root, 'repro.json'))).toBe(true);
      // T2.8: the repro file carries the full canonical field set.
      const repro = JSON.parse(readFileSync(path.join(root, 'repro.json'), 'utf8'));
      expect(repro.batch).toBe('b1');
      expect(repro.cacheState).toBe('cold');
      expect(repro.userId).toBe('probe-user');
      expect(repro.toolchain).toEqual({ ghc: '9.14.1' });
      expect(repro.policyHash).toMatch(/^[0-9a-f]{32}$/);
      // (The exact digest is pinned in the cross-language differential test
      // below — this fixture uses a temp root, so its hash differs by design.)
      expect(repro.results).toHaveLength(4);
      expect(repro.results.every((r: { ok: boolean }) => r.ok)).toBe(true);
      // T2.2: work/ is reclaimed, out/ is kept.
      expect(existsSync(path.join(root, 'a', '1', 'out'))).toBe(true);
      expect(existsSync(path.join(root, 'a', '1', 'work'))).toBe(false);
    } finally {
      if (previousSandbox === undefined) delete process.env.TRHA_SANDBOX;
      else process.env.TRHA_SANDBOX = previousSandbox;
      if (previousRunner === undefined) delete process.env.TRHA_SANDBOX_RUNNER;
      else process.env.TRHA_SANDBOX_RUNNER = previousRunner;
      rmSync(root, { recursive: true, force: true });
    }
  });
});

// Cross-language differential with test/ExperimentSpec.hs: both suites pin
// the exact canonical text and its sha512 digest for the same fixture
// (root /ws/experiments/b1, baseline …/baseline). Either side's renderer
// drifting turns one of the two red.
describe('policyCanonicalText (cross-language differential)', () => {
  it('agrees byte for byte with the Haskell canonicalPolicyText', () => {
    expect(policyCanonicalText('/ws/experiments/b1', '/ws/experiments/b1/baseline')).toBe(
      'workspace-write|"/ws/experiments/b1"'
        + '|"/ws/experiments/b1/.batch-work"'
        + '|["/ws/experiments/b1/baseline"]'
        + '|off|0,0,600000|-|-',
    );
    expect(createHash('sha512')
      .update(policyCanonicalText('/ws/experiments/b1', '/ws/experiments/b1/baseline'))
      .digest('hex')
      .slice(0, 32)).toBe('e8b065d988e2ae560939865205581095');
  });
});

describe('writeSandboxConfig (on, mock runner)', () => {
  it('persists through the runner and flips the runtime switch', async () => {
    chmodSync(fixture, 0o755);
    const previousSandbox = process.env.TRHA_SANDBOX;
    const previousRunner = process.env.TRHA_SANDBOX_RUNNER;
    process.env.TRHA_SANDBOX = 'off';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    setSandboxEnabledRuntime(undefined);
    try {
      expect(sandboxEnabled()).toBe(false);
      const cfg = await writeSandboxConfig({ enabled: true, policy: 'read-only' });
      expect(cfg.enabled).toBe(true);
      expect(cfg.policy).toBe('read-only');
      expect(sandboxEnabled()).toBe(true);
    } finally {
      setSandboxEnabledRuntime(undefined);
      setSandboxConfigRuntime(undefined);
      if (previousSandbox === undefined) delete process.env.TRHA_SANDBOX;
      else process.env.TRHA_SANDBOX = previousSandbox;
      if (previousRunner === undefined) delete process.env.TRHA_SANDBOX_RUNNER;
      else process.env.TRHA_SANDBOX_RUNNER = previousRunner;
    }
  });
});

describe('defaultSandboxScope', () => {
  it('uses workspace-write and the cwd by default', () => {
    const s = defaultSandboxScope('/work', {});
    expect(s.policy.kind).toBe('workspace-write');
    if (s.policy.kind === 'workspace-write') expect(s.policy.root).toBe('/work');
    expect(s.scratch).toContain('.trha');
  });

  it('honours TRHA_SANDBOX_POLICY=read-only', () => {
    const s = defaultSandboxScope('/work', { TRHA_SANDBOX_POLICY: 'read-only' });
    expect(s.policy.kind).toBe('read-only');
  });
});

describe('defaultSandboxScope (cached config)', () => {
  it('uses the tuned policy and expands a home-relative scratch', () => {
    setSandboxConfigRuntime({
      enabled: true,
      policy: 'read-only',
      network: 'off',
      scratch: '~/scratch-x',
    });
    try {
      const s = defaultSandboxScope('/ws', {});
      expect(s.policy.kind).toBe('read-only');
      expect(s.scratch).toBe(path.join(os.homedir(), 'scratch-x'));
    } finally {
      setSandboxConfigRuntime(undefined);
    }
  });
});

describe('defaultSandboxScope (network)', () => {
  it('reads the network policy from the cached config', () => {
    setSandboxConfigRuntime({
      enabled: true,
      policy: 'workspace-write',
      network: 'allow:a.com,b.com',
      scratch: '/tmp/x',
    });
    try {
      const s = defaultSandboxScope('/ws', {});
      if (s.policy.kind === 'workspace-write') {
        expect(s.policy.network).toEqual({ kind: 'allow', domains: ['a.com', 'b.com'] });
      } else {
        throw new Error('expected workspace-write');
      }
    } finally {
      setSandboxConfigRuntime(undefined);
    }
  });
});


describe('config defaults and patches (mock runner)', () => {
  it('falls back to defaults when the CLI returns an empty object', async () => {
    chmodSync(fixture, 0o755);
    const prev = process.env.MOCK_SANDBOX_EMPTY;
    process.env.TRHA_SANDBOX = 'off';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    process.env.MOCK_SANDBOX_EMPTY = '1';
    try {
      const cfg = await readSandboxConfig();
      expect(cfg).toEqual({
        enabled: false,
        policy: 'workspace-write',
        network: 'off',
        scratch: '~/.trha/sandbox-scratch',
      });
    } finally {
      if (prev === undefined) delete process.env.MOCK_SANDBOX_EMPTY;
      else process.env.MOCK_SANDBOX_EMPTY = prev;
    }
  });

  it('passes network and scratch patches through', async () => {
    chmodSync(fixture, 0o755);
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    const cfg = await writeSandboxConfig({
      enabled: true,
      network: 'proxy:http://127.0.0.1:1',
      scratch: '/tmp/trha-scratch-x',
    });
    expect(cfg.network).toBe('proxy:http://127.0.0.1:1');
    expect(cfg.scratch).toBe('/tmp/trha-scratch-x');
  });
});

describe('sandboxedSpawn branches', () => {
  it('rejects danger-full-access without spawning', async () => {
    process.env.TRHA_SANDBOX = 'on';
    const danger: SandboxScope = {
      id: 'x',
      policy: { kind: 'danger-full-access' },
      isolation: 'process',
      scratch: '/tmp/trha-danger',
    };
    await expect(sandboxedSpawn(danger, { argv: ['true'], cwd: '/tmp' }))
      .rejects.toThrow(/danger-full-access/);
  });

  it('passes a read-only policy and the cwd to the runner', async () => {
    chmodSync(fixture, 0o755);
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    const ro: SandboxScope = {
      id: 'r',
      policy: { kind: 'read-only', readonlyRoots: ['/ws'] },
      isolation: 'process',
      scratch: '/tmp/trha-ro-scratch',
    };
    const r = await sandboxedSpawn(ro, { argv: ['echo', 'x'], cwd: '/tmp/trha-ro-cwd' });
    expect(r.stdout).toContain('--policy read-only');
    expect(r.stdout).toContain('--workspace /tmp/trha-ro-cwd');
  });


  it('rejects when the runner binary is missing', async () => {
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = '/nonexistent/trha-sandbox-runner';
    try {
      await expect(sandboxedSpawn(scope, { argv: ['true'], cwd: '/tmp' }))
        .rejects.toThrow(/ENOENT/);
    } finally {
      delete process.env.TRHA_SANDBOX_RUNNER;
    }
  });

  it('times out a hanging runner', async () => {
    chmodSync(fixture, 0o755);
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    process.env.MOCK_SANDBOX_HANG = '1';
    try {
      await expect(sandboxedSpawn(scope, { argv: ['sleep', '1'], cwd: '/tmp', timeoutMs: 200 }))
        .rejects.toThrow(/exceeded 200 ms/);
    } finally {
      delete process.env.MOCK_SANDBOX_HANG;
    }
  });
});

describe('defaultSandboxScope network edge cases', () => {
  it('parses proxy and invalid network specs', () => {
    setSandboxConfigRuntime({
      enabled: true, policy: 'workspace-write', network: 'proxy:http://p:1', scratch: '/tmp/x',
    });
    try {
      const s = defaultSandboxScope('/ws', {});
      if (s.policy.kind === 'workspace-write') {
        expect(s.policy.network).toEqual({ kind: 'proxy', url: 'http://p:1' });
      }
    } finally {
      setSandboxConfigRuntime(undefined);
    }
    setSandboxConfigRuntime({
      enabled: true, policy: 'workspace-write', network: 'garbage', scratch: '/tmp/x',
    });
    try {
      const s = defaultSandboxScope('/ws', {});
      if (s.policy.kind === 'workspace-write') {
        expect(s.policy.network).toEqual({ kind: 'off' });
      }
    } finally {
      setSandboxConfigRuntime(undefined);
    }
  });
});


describe('runner edge frames (mock runner)', () => {
  it('propagates an error frame', async () => {
    chmodSync(fixture, 0o755);
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    process.env.MOCK_SANDBOX_ERROR = '1';
    try {
      await expect(sandboxedSpawn(scope, { argv: ['true'], cwd: '/tmp' }))
        .rejects.toThrow(/boom/);
    } finally {
      delete process.env.MOCK_SANDBOX_ERROR;
    }
  });

  it('rejects when the runner exits without an exit frame', async () => {
    chmodSync(fixture, 0o755);
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    process.env.MOCK_SANDBOX_QUIT = '1';
    try {
      await expect(sandboxedSpawn(scope, { argv: ['true'], cwd: '/tmp' }))
        .rejects.toThrow(/without an exit frame/);
    } finally {
      delete process.env.MOCK_SANDBOX_QUIT;
    }
  });

  it('surfaces missing capabilities and notes from status', async () => {
    chmodSync(fixture, 0o755);
    process.env.TRHA_SANDBOX = 'on';
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    process.env.MOCK_SANDBOX_STATUS_EXTRA = '1';
    try {
      const st = await sandboxStatus();
      expect(st.missing).toEqual(['net']);
      expect(st.notes).toEqual(['extra note']);
    } finally {
      delete process.env.MOCK_SANDBOX_STATUS_EXTRA;
    }
  });
});


describe('coverage edges (mock runner)', () => {
  it('drops empty allow entries', () => {
    setSandboxConfigRuntime({
      enabled: true, policy: 'workspace-write', network: 'allow:a.com,,b.com', scratch: '/tmp/x',
    });
    try {
      const s = defaultSandboxScope('/ws', {});
      if (s.policy.kind === 'workspace-write') {
        expect(s.policy.network).toEqual({ kind: 'allow', domains: ['a.com', 'b.com'] });
      }
    } finally {
      setSandboxConfigRuntime(undefined);
    }
  });

  it('writes an explicit disable', async () => {
    chmodSync(fixture, 0o755);
    process.env.TRHA_SANDBOX_RUNNER = fixture;
    process.env.TRHA_SANDBOX = 'on';
    try {
      const cfg = await writeSandboxConfig({ enabled: false });
      expect(cfg.enabled).toBe(false);
      expect(sandboxEnabled()).toBe(false);
    } finally {
      setSandboxEnabledRuntime(undefined);
      setSandboxConfigRuntime(undefined);
    }
  });
});

describe('sandbox protocol v1', () => {
  it('round-trips an exec frame', () => {
    const frame: ExecFrame = {
      v: PROTOCOL_VERSION,
      op: 'exec',
      id: 'c1',
      argv: ['bash', '-lc', 'true'],
      cwd: '/ws',
    };
    expect(decodeFrame(encodeFrame(frame).trimEnd())).toEqual(frame);
  });

  it('rejects an unknown op', () => {
    expect(() => decodeFrame('{"v":1,"op":"teleport"}')).toThrow();
  });

  it('rejects a version mismatch', () => {
    expect(() => decodeFrame('{"v":99,"op":"shutdown"}')).toThrow(/version mismatch/);
  });
});
