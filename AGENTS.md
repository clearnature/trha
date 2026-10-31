# AGENTS.md

Guidance for AI coding agents working in this repository.

**trha** — a microkernel agent harness: Haskell core engine (Free-monad plugins,
multi-protocol API server), TypeScript scheduler (parallel sub-agent
orchestration), Electron desktop app, and a Haskell CLI/TUI.

**Authority chain**: this file is the agent entry point only. The structural
authority is [`QWEN.md`](./QWEN.md) (§Architecture Layers / §Development
Conventions / §Documentation) and [`docs/architecture/architecture.md`](./docs/architecture/architecture.md).
If this file conflicts with them, they win.

## Build & Test

```bash
# Haskell (kernel + CLI; cabal resolves from the repo root)
cabal build all          # incremental; ~1s when nothing changed
cabal test trha-test     # kernel suite (Hspec)
cabal test trha-cli-test # CLI suite
cabal test all           # everything (slow, ~6.5 min — CI/pre-push)

# TypeScript scheduler (own npm project)
cd packages/scheduler && npm install
npx tsc --noEmit         # typecheck
npx vitest run           # full suite (see memory discipline below)
npx vitest run test/<file>.test.ts   # preferred during development

# Web / Desktop (own npm projects)
cd packages/app/Web      && npm install && npm run build
cd packages/app/Desktop  && npm install && npm run typecheck
```

## Test Memory Discipline (mandatory — OOM incident 2026-10-25)

The scheduler suite spawns **real child processes**: headless Chrome
(`browser-tools` tests), login bash shells (`terminal_open`), and scheduler
children. On a many-core machine vitest's default pool forks dozens of workers.

1. **Single instance**: never start a second vitest run while one may still be
   alive — check `pgrep -af vitest` first. After an *interrupted* run, its
   afterEach/afterAll cleanup never ran: orphaned Chrome/bash keep holding
   memory. Confirm death before restarting.
2. **Pool cap**: `packages/scheduler/vitest.config.ts` hard-caps
   `pool: 'forks', maxForks: 4`. Do not remove it.
3. **Scope**: during development run affected spec files only; a full run at
   most once per milestone.
4. **Orphan sweep** after any crash/interruption:
   `pkill -f "trha-browser-" ; pkill -f "bash -l"`.
5. **Boundary**: test artifacts go to `os.tmpdir()` or the workspace only.
   Write paths are guarded by `confineWritePath`; never write outside.

## Critical Conventions

- **Per-library source roots (2026-10-27) — read before touching `trha.cabal`
  or `src/`**: each library owns its own `hs-source-dirs` — `src/core` (trha-core),
  `src/llm` (trha-llm), `src/api` (trha-api), `src/infra` (trha-infra),
  `src/webgpu` (trha-webgpu), `src/gpu-infer` (trha-gpu-infer); `src/presentation`
  is **not** in any cabal component. A module belongs to exactly one library;
  other libraries import it through `build-depends`. Do **not** introduce a
  shared source root: it makes GHC compile one file per library and produces
  same-name-different-type duplicates (44 were removed on 2026-10-27; the
  symptom only appears at `cabal build all` link time, not in single-library
  builds). See [`QWEN.md`](./QWEN.md) §Development Conventions for the
  ownership table.
- **Platform shell contract** (scheduler): every shell spawn goes through
  `packages/scheduler/src/Server/shell.ts` — POSIX `bash -lc` (byte-stable
  contract), win32 `cmd.exe /d /s /c` + `windowsVerbatimArguments` +
  `NoDefaultCurrentDirectoryInExePath`. Do not hardcode `spawn('bash', …)`.
  The `bash` *tool name* is platform-independent; see
  `packages/scheduler/README.md`.
- **Reads unconfined, writes confined** (scheduler design): read tools may
  leave the workspace on purpose (`bash` already can); writes must go through
  `confineWritePath` (`Server/toolGuard.ts`).
- **Language**: Haskell 2010 + GHC extensions (OverloadedStrings, …);
  TypeScript strict mode, ESM (`*.js` import suffixes).
- **No sed for code edits** — use the edit tool so the security hooks can scan
  candidates.
- **Commits**: Conventional Commits with Chinese subjects
  (`feat(scheduler): …`). Git hooks live in `.githooks/`
  (`core.hooksPath`); a Mimosa security hook may block commits on static
  findings — triage them, never bypass the gate silently.
- **Push after commit**（2026-10-31 事故后立的规矩）：每个本地提交完成后必须
  立即 `git push`。判据是 `git rev-list --count origin/main..HEAD` 等于 0；
  不等于 0 就是在赌「这块盘不会出事」。
  > 事故：Windows 沙箱的约 900 行 Haskell 代码只在本地提交，远程 `main` 停在
  > `d3814c3`；trha 目录被删除后 `.git` 一并消失，`reflog` 只剩一条 `clone`，
  > 代码无法恢复，只能按设计重写。**未推送的提交等于没写。**
- **Secrets**: never commit API keys; `.env` is gitignored.

## Docs

`docs/` is organised by lifecycle: `architecture/` (structure facts),
`contracts/` (cross-shell protocols), `plans/` (active work — e.g.
`typescript-7-toolchain-migration.md`, `tui-port-plan.md`,
`windows-shell-port-plan.md`), `reference/` (analyses), `archive/` (do not
follow — superseded). Full index: [`docs/README.md`](./docs/README.md).

## Environment Variables

See [`QWEN.md`](./QWEN.md) §Environment Variables. Highlights:
`TRHA_TOKEN` (scheduler auth), `TRHA_PORT`/`TRHA_WORKSPACE`, `TRHA_PROXY`
(kernel outbound proxy; loopback is always direct), `TRHA_BROWSER`,
`TRHA_LSP_COMMAND`.
