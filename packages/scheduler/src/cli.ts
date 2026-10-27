// Standalone scheduler launcher (spawned by the Electron host and by
// desktop shells).  All configuration arrives through the environment so
// the launcher itself stays argument-free and host-contract friendly:
//   TRHA_PORT / TRHA_HOST / TRHA_TOKEN
//   TRHA_LLM_HOST / TRHA_LLM_PORT     (kernel/endpoint to talk to)
//   TRHA_STATE_DIR                    (session persistence; default
//                                      ~/.trha/scheduler-state)
//   TRHA_LEASE_STDIN=1                (stdin is a lease -- exit on close)
// stdout carries the versioned JSON handshake from startServer.

import { startServer } from './Server/index.js';
import { defaultStateDir } from './Server/stateStore.js';
import { claimSchedulerIdentity, writeRuntimeSection } from './Core/RunPid.js';

const port = Number(process.env.TRHA_PORT ?? 28433);
const host = process.env.TRHA_HOST ?? '127.0.0.1';
const token = process.env.TRHA_TOKEN ?? 'dev-token';
// Kernel default is 19433 (packages/app/CLI: `trha serve --kernel-port`), chosen
// to stay clear of 28433 (scheduler) and ports commonly used by other tools.
const llmHost = process.env.TRHA_LLM_HOST ?? '127.0.0.1';
const llmPort = Number(process.env.TRHA_LLM_PORT ?? 19433);

if (!claimSchedulerIdentity(token)) {
  console.error(
    'another scheduler is already running (~/.trha/run/scheduler.pid); stop it first: trha stop scheduler',
  );
  process.exit(1);
}
// Publish the live endpoint for shells (`~/.trha/runtime.json`).
writeRuntimeSection('scheduler', { host, port, pid: process.pid, token });

void startServer({
  port,
  host,
  token,
  haskellHost: llmHost,
  haskellPort: llmPort,
  stateDir: defaultStateDir(),
  pluginsDir: process.env.TRHA_PLUGINS_DIR || undefined,
}).catch((e) => {
  console.error('scheduler startup failed:', e);
  process.exit(1);
});
