# trha

Microkernel agent harness in Haskell with TypeScript orchestration, multi-protocol API server, and Electron desktop app.

## Project Overview

**trha** is a microkernel agent framework inspired by the Cordis plugin architecture. The core engine is written in Haskell (GHC, type-driven design) and exposes a multi-protocol API server (OpenAI / Anthropic / Responses-compatible). A TypeScript scheduler layer handles parallel sub-agent orchestration, and shell apps (brick TUI/CLI, Electron + React Desktop, Web) provide the UI. Product-wise the goal is a self-developed **agent IDE**; the four porting upstreams are qwen code, MiMo-Code, reasonix, and deepseek-harness (see `docs/reference/`).

### Architecture Layers

| Layer | Tech | Location |
|---|---|---|
| **Math foundation (L0)** | Haskell, external path dep `sov-math` | `../math/hs/sov-math` (sibling repo, relative path dep in `cabal.project`) |
| **Core** | Haskell, STM | `src/core/` (`Sov.*`, `Core.{Session,Agent,Tools,Event,Cache}.*`, `Kernel.Carrier`) |
| **LLM Adapters** | Haskell, http-client | `src/llm/LLM/` (DeepSeek, OpenAI) |
| **API Server** | Haskell, Servant, Warp | `src/api/API/` |
| **Infrastructure** | Haskell (SQLite, HTTP, Sandbox) | `src/infra/Infrastructure/` |
| **WebGPU Backend** | Haskell FFI → wgpu-native | `src/webgpu/Infrastructure/WebGPU/` |
| **Scheduler** | TypeScript, Express, Zod, Winston | `packages/scheduler/` |
| **SDK** | Haskell client face | `packages/sdk/` |
| **CLI/TUI App** | Haskell, brick + vty | `packages/app/CLI/` (entry: root `executable trha`) |
| **Desktop App** | Electron 44 + React | `packages/app/Desktop/` |
| **Web App** | Vite + React + zustand | `packages/app/Web/` |

Archived out of the build (do not resurrect without a ruling): `archive/inference-kernel/` (GPU/CPU inference model, 2026-10-28 — the kernel no longer depends on the inference model), `archive/haskell-plugin/` (`Core.Plugin.*`), `archive/orchestration/`, `archive/go-haskell-bridge/`, `archive/haskell-network/`, `archive/sdk-legacy/`, `archive/webgpu-legacy/`, `archive/cpu-backend-legacy/`.

### Key Design Patterns

- **Kernel/Shell responsibility split**: the kernel (Haskell) owns judgments and truth (session event log); the orchestration/shell layers (TS) own transactions and UI metadata. See `docs/plans/plan-reconciliation.md` (§架构原则) and `docs/contracts/session-truth.md`.
- **Session/Agent FSM**: `Core.Session.Manager` manages session state; `Core.Agent.StateMachine` implements agent state transitions. The kernel is an *abstract machine* (not an arithmetic machine) — 2026-10-26 user ruling, see `docs/architecture/architecture-intended-vs-actual.md`.
- **Kernel carrier**: `Kernel.Carrier` implements the C[A₄] function space + Plancherel inner product; the math itself lives in `sov-math` (zero-float, strongly typed). **Do not vendor or reimplement it** — one implementation with proofs, no "second implementation without an equivalence proof".
- **LLMAdapter abstraction**: all LLM backends implement `LLMAdapter { llmChat, llmEmbed, llmModels }`. Current providers: DeepSeek (real HTTP) and OpenAI.
- **Multi-protocol API**: single Servant server exposes OpenAI-compatible (`/v1/chat/completions`), Anthropic-compatible (`/v1/messages`), and Responses (`/v1/responses`) endpoints, streaming and non-streaming.
- **Kernel stub** (`trha-kernel-stub`, K6): deterministic two-round tool loop for end-to-end development without an API key.
- **Platform shell contract** (scheduler): every shell spawn goes through `packages/scheduler/src/Server/shell.ts` — POSIX `bash -lc`, win32 `cmd.exe /d /s /c` + `windowsVerbatimArguments` + `NoDefaultCurrentDirectoryInExePath`. Do not hardcode `spawn('bash', …)`. The `bash` *tool name* is platform-independent.
- **Reads unconfined, writes confined** (scheduler design): read tools may leave the workspace on purpose (`bash` already can); writes must go through `confineWritePath` (`Server/toolGuard.ts`).

## Building and Running

### Haskell (kernel + CLI + tests; cabal resolves from the repo root)

```bash
cabal build all          # root stanza + CLI + sdk + sov-math + 3rdparty
cabal test trha-test     # kernel suite (Hspec + QuickCheck), ~135s warm
cabal test trha-cli-test # CLI suite
cabal test all           # everything (~6.5 min — CI / occasional use only)
```

Notes:
- GHC requires `base ^>=4.22` (GHC 9.12+). The cabal file defines internal libraries (`trha-core`, `trha-llm`, `trha-api`, `trha-infra`, `trha-webgpu`), merged where needed to work around GHC internal-lib linking bugs.
- **Per-library source roots**: each internal library owns its own `hs-source-dirs` (see §Development Conventions). The `executable trha` is defined **only** in the root `trha.cabal` (sources in `packages/app/CLI`); `packages/app/CLI/trha-cli.cabal` deliberately defines **no** executable (only `trha-cli-test`) — two same-named executables would make `cabal run trha` pick ambiguously between builds.
- `sov-math` is a **relative path dependency** (`../math/hs/sov-math`); if that repo moves, only `cabal.project` changes.
- Build products go to the default `dist-newstyle/`. `builddir:` is not a valid `cabal.project` field — use `cabal build --builddir=...` on the command line instead.

### Running the app

```bash
trha                 # default: full-screen brick TUI (needs interactive terminal)
trha cli             # line REPL (pipe/script friendly)
trha serve           # kernel OpenAI-compatible API, default :19433
trha status          # pid & liveness of kernel / scheduler
trha stop            # stop kernel & scheduler (SIGTERM, --force for SIGKILL)
```

The scheduler listens on **:28433** (Bearer `TRHA_TOKEN`). TUI key semantics: `/quit` or Ctrl+Q exits the shell only; **stopping services** is Ctrl+Alt+Q (confirm; equivalent to `/stop confirm`). When stdin is not a TTY, TUI mode errors explicitly and points to `trha cli`.

`packages/app/CLI-npm` is an npm wrapper that locates the binary via `$TRHA_BIN` → `vendor/trha` → `$TRHA_CABAL_BIN` → `cabal list-bin trha` (see its README).

### TypeScript Scheduler

```bash
cd packages/scheduler
npm install
npm run build     # tsc
npm test          # vitest (watch); use npx vitest run for one-shot
npm run typecheck
npm run lint
npm run coverage  # used by the pre-push gate
```

Node >= 22.4; TypeScript 7 strict mode, ESM (`*.js` import suffixes); vitest 5.

### Web / Desktop apps

```bash
cd packages/app/Web      && npm install && npm run build   # vite; vitest run for tests
cd packages/app/Desktop  && npm install && npm run typecheck
```

### Services (user-level systemd / launchd)

```bash
make services-install|services-uninstall|services-start|services-stop|services-status|services-logs|services-dry-run
```

Never invoked by test suites or CI — tests spawn their own short-lived schedulers.

### Static Binary (Docker)

```bash
docker build -f Dockerfile.static -t trha .   # Alpine + musl → scratch, single binary
```

## Testing

- **Haskell suites**: `trha-test` (kernel; includes HTTP end-to-end assembly tests that start a real warp server — needs `-threaded`), `trha-cli-test`, `trha-sandbox-test` (platform-specific spec modules are excluded from the build on Windows, not skipped at runtime), `trha-webgpu-test` (real GPU; reports *pending* on GPU-less CI runners).
- **Live probe**: `test/DeepSeekCacheSpec.hs` calls api.deepseek.com when `DEEPSEEK_API_KEY` is set (burns tokens). Since commit 9981098 it reports *pending* (via `ctError` content) instead of failing when the account has insufficient balance. Provider errors surface in the `ctError` field, not `ctContent`.
- **Git hooks**: `.githooks/` via `core.hooksPath` (installed by `scripts/install-hooks.sh` on npm postinstall). `pre-push` runs: `cabal test trha-test`, scheduler coverage, web vitest, desktop coverage. A Mimosa security hook may block commits on static findings — triage them, never bypass the gate silently.

### 测试运行纪律（内存防护，2026-10-25 OOM 事故后确立）

The scheduler suite spawns **real child processes** (headless Chrome in browser-tools tests, login bash in `terminal_open`, scheduler children).

1. **单实例**：同一时刻只允许一个 vitest 进程。重跑前先 `pgrep -af vitest`；被中断的运行必须确认已死（中断时 afterEach/afterAll 清理不会执行，Chrome/bash 会变孤儿）。
2. **并发上限**：`packages/scheduler/vitest.config.ts` 已硬限 `pool: 'forks', maxForks: 4`——不要移除。
3. **范围收敛**：开发期只跑受影响的 spec（`npx vitest run test/<file>`）；全量运行每个里程碑最多一次。
4. **收尾兜底**：异常退出后 `pkill -f "trha-browser-" ; pkill -f "bash -l"` 再重跑。
5. **边界**：测试产物只落在 `os.tmpdir()` 或 workspace；写路径有 `confineWritePath` 兜底。

## Development Conventions

- **Language**: Haskell 2010 with GHC extensions (OverloadedStrings, DataKinds, TypeOperators, DeriveGeneric, ScopedTypeVariables). TypeScript strict mode, ES2022/ESNext modules.
- **Per-library source dirs (2026-10-27 拆分，2026-10-28 归档推理模型后的现状)**: each internal library owns its own `hs-source-dirs`; a module is visible to exactly one library and every other library imports it through `build-depends`:
  - `src/core/` → **trha-core**：`Sov.*`、`Core.{Session,Agent,Tools,Event,Cache}.*`、`Kernel.Carrier`；
  - `src/llm/` → **trha-llm**：`LLM.*`（`cbits/gf27_avx2.c`；OpenMP 仅在非 Windows/非 macOS 启用，Windows/macOS 走标量路径）；
  - `src/api/` → **trha-api**：`API.*` + `Core.Provider.Types`；
  - `src/infra/` → **trha-infra**：`Infrastructure.{Storage,Network,Sandbox,Telemetry}.*` + `Core.HTTPProxy`；
  - `src/webgpu/` → **trha-webgpu**：`Infrastructure.WebGPU.*`（`cbits/wgpu_callback_shim.c`）；
  - `src/presentation/` — **不在任何 cabal 组件内**（未接线）。

  **Why the split**: a shared `hs-source-dirs` makes GHC compile one file per library and produces same-name-different-type duplicates (44 were removed on 2026-10-27). The project's first criterion is strong typing — type uniqueness outranks build time. **Do not** put two libraries on the same `hs-source-dirs`, and do not add a module to two libraries; the symptom only appears at `cabal build all` link time, not in single-library builds. Ownership changes must update this table, `docs/architecture/architecture.md` and `docs/architecture/project-overview.md`.
- **3rdparty/**: `brick` (git submodule, PR branch state tracked), `commonmark` (fork of jgm/commonmark-hs, vendored as path deps — only `commonmark` + `commonmark-extensions`, no pandoc/cli), `wgpu-native` (libs + includes, referenced **only** from inside the repo), `llama-vulkan`, `llama-webgpu`, `corpus`, `fonts`.
- **Module naming / tests**: Hspec `describe` blocks match module names (`LLM.Adapter`, etc.). Test suite names: `trha-test`, `trha-cli-test`, `trha-sandbox-test`, `trha-webgpu-test`.
- **No sed for code edits**: use the `edit` tool for all code modifications (project convention; security hooks scan candidates).
- **Imports**: qualified imports preferred for large modules (`Data.Text`, `Data.Map`, `Data.Vector`). Unqualified for small/focused imports.
- **Formatting**: standard Haskell formatting; `.hlint.yaml` at root (`npm run lint:hs`). TypeScript uses oxlint (`npm run lint`).
- **Commits**: Conventional Commits with Chinese subjects (`feat(scheduler): …`).
- **Push after commit（2026-10-31 事故后立的规矩）**: every local commit must be pushed immediately. Criterion: `git rev-list --count origin/main..HEAD` == 0. Unpushed commits equal unwritten work (a lost sandbox cost ~900 lines of Haskell once).
- **Secrets**: never commit API keys. Use `.env` (gitignored) with values from `.env.example`. See `docs/reference/github-secrets-setup.md` and `docs/reference/security-cleanup-guide.md`.

## Environment Variables

Key variables (see `.env.example` and `packages/scheduler/README.md`):

| Variable | Purpose |
|---|---|
| `TRHA_TOKEN` | scheduler auth (Bearer), scheduler default port :28433 |
| `TRHA_PORT` / `TRHA_WORKSPACE` | scheduler port / workspace |
| `TRHA_PROXY` | kernel outbound proxy (loopback is always direct) |
| `TRHA_BROWSER` | browser used by browser tools |
| `TRHA_LSP_COMMAND` | LSP server command |
| `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` | DeepSeek API |
| `MIMO_API_KEY` / `MIMO_BASE_URL` / `MIMO_MODEL` | MiMo API |
| `OPENAI_API_KEY` / `OPENAI_BASE_URL` | OpenAI API |
| `SERVER_PORT` | legacy API server port from `.env.example` (kernel `trha serve` defaults to :19433) |
| `DATABASE_URL`, `CACHE_SIZE` / `CACHE_TTL`, `LOG_LEVEL` / `LOG_FORMAT` | infra configuration |

## CI/CD

Three GitHub Actions workflows in `.github/workflows/`:
- `ci.yml` — main CI pipeline
- `smoke-tests.yml` — smoke/integration tests
- `static-build.yml` — static binary build

Repo-root scripts also verify these locally: `npm run verify:ci` (workflow wiring), `npm run verify:docs` (doc links), `npm run lint` (oxlint).

## Documentation

`docs/` is organised by document lifecycle; **full index and reading order: `docs/README.md`** (browsing guide). Structural authority = this file (§Architecture Layers / §Development Conventions / §Documentation) + `docs/architecture/architecture.md`; `docs/README.md` says so explicitly and defers to QWEN.md on conflict.

**Structure authority & project intent — `docs/architecture/`**
- `project-overview.md` — one-page tech stack / build topology / per-plan completion ledger / not-done & not-verified lists / doc-drift list / reproducible check commands. Entry point for a whole-project view (a *view*, not an authority).
- `architecture-snapshot-2026-10-27.md` — measured current-state layered diagram, per-layer modules, one-turn data flow, problem index (S1–S3 / C1–C3 / D1–D4).
- `architecture-intended-vs-actual.md` — **project intent vs actual state** (spec chain: Agda「律算合一」→ pyBitNet《架构宪法》→ this repo), deviations D-1…D-9, status tiers. **Read this first** — the project intent had never been documented once and that caused a serious misread.
- `architecture.md` — system overview. ⚠️ §6 package layout is out of date.
- `presentation-layer.md` (code not wired), `event-matrix.md`, `agent-lifecycle-notes.md`, `dsh-capability-seams.md`.

**Protocol contracts — `docs/contracts/`**
- `protocol-shell-kernel.md` — shell ↔ scheduler (:28433, Bearer) ↔ kernel (:19433) endpoint/SSE/credential ledger.
- `session-truth.md` — **session truth contract (2026-10-27)**: A-class "model-visible history" = kernel event log; B-class UI metadata = scheduler `stateStore`; CLI `transcript.jsonl` is read-only replay.
- `desktop-port-contract.md` — UI ↔ backend `Port` contract (no direct `fetch` in components).
- `desktop-host-contract.md` — Desktop ↔ Scheduler host contract v1.

**Active plans — `docs/plans/`** (uncompleted items are *not* implemented; see `plan-reconciliation.md`)
- `compact-weights-plan.md` — compact weights (P-12 done; measured 2.5s/token, RSS 8.6GB via `trha-cpu-braintoken`).
- `sandbox-decisions.md` (ADR-001–007, frozen 2026-10-29), `sandbox-architecture.md` (design baseline, §5.7 interface freeze), `sandbox-delivery-plan.md` (M0–M5 + WBS 48 items), `sandbox-handoff.md` — **read the handoff doc before starting sandbox work**.
- `remote-access-bot-plan.md` — remote access / IM bot (chosen: IM long-connection, zero inbound ports; not implemented).
- `improvement-plan-2026-10-27.md` — improvement plan P-01..P-13 (incl. the per-library source split).
- `desktop-provider-design.md` (P1–P8/A1–A5 done; A6 CPU inference M1–M2 done, M3–M6 not started), `desktop-ui-execution-plan.md` / `desktop-ui-port-plan.md` / `desktop-ui-progress.md` (T1–T12; T5b/T12a open), `electron-44-upgrade.md`.
- `verification-criteria.md` — **what counts as evidence**: C1–C5 (algebra ↔ Agda, compile-time type invariants, cross-implementation equality, causal semantics, constraint ↔ external API). **Performance is not a criterion.**
- `file-completion-tracking.md`, `code-docs-reconciliation.md` (⚠️ §2 WebGPU claim stale — see `architecture/project-overview.md` §5), `pybitnet-ternary-inference-blueprint.md`, `webgpu-wiring-plan.md` (W1–W7/T1–T4 done, **not wired into production inference**), markdown-rendering plan (8cb9d51/a008158), `typescript-7-toolchain-migration.md`, `tui-port-plan.md`, `windows-shell-port-plan.md`.

**Reference — `docs/reference/`**: upstream porting sources and analyses (`trha-port-sources.md` memory table: hs `/data/work/functional-programming/hs`, MiMo-Code, qwen-code, deepseek-harness, DeepSeek-Reasonix + codex/gemini/ratatui/opencode), `microkernel-lineage.md`, `trha-architecture-review.md` (external, engineering-maintainability criterion — do not conflate with C1–C5), `trha-architecture-benchmark-review.md` (A1–A8), `cangjie-replacement-feasibility.md` + probes, `windows-dev-notes.md`, CI/secrets ops docs.

**Archive — `docs/archive/`**: completed or superseded plans — do not follow.

Component docs: `packages/scheduler/README.md`, `packages/app/Desktop/README.md`, `packages/app/CLI/README.md`, `packages/sdk/docs/sdk-api.md`, `3rdparty/README.md`.

**Maintenance conventions for docs/** (see `docs/README.md`): archive rather than delete; new docs go in a lifecycle subdirectory, never the `docs/` root; structure changes sync **this file's §Documentation** + `docs/README.md`; moving a doc requires grepping and fixing references; intent changes update `architecture-intended-vs-actual.md` first.
