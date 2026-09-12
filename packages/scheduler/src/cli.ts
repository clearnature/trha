// Standalone scheduler launcher (spawned by the Electron host and by
// desktop shells).  All configuration arrives through the environment so
// the launcher itself stays argument-free and host-contract friendly:
//   TRHA_PORT / TRHA_HOST / TRHA_TOKEN
//   TRHA_LLM_HOST / TRHA_LLM_PORT     (kernel/endpoint to talk to)
//   TRHA_STATE_DIR                    (session persistence)
//   TRHA_LEASE_STDIN=1                (stdin is a lease -- exit on close)
// stdout carries the versioned JSON handshake from startServer.

import { startServer } from './Server/index.js';

const port = Number(process.env.TRHA_PORT ?? 3456);
const host = process.env.TRHA_HOST ?? '127.0.0.1';
const token = process.env.TRHA_TOKEN ?? 'dev-token';
const llmHost = process.env.TRHA_LLM_HOST ?? 'localhost';
const llmPort = Number(process.env.TRHA_LLM_PORT ?? 8080);

void startServer({
  port,
  host,
  token,
  haskellHost: llmHost,
  haskellPort: llmPort,
  stateDir: process.env.TRHA_STATE_DIR || undefined,
  pluginsDir: process.env.TRHA_PLUGINS_DIR || undefined,
}).catch((e) => {
  console.error('scheduler startup failed:', e);
  process.exit(1);
});
