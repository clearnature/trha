# trha

Microkernel agent harness in Haskell with TypeScript orchestration, multi-protocol API server, and Electron desktop app.

## Project Overview

**trha** is a multi-layer agent framework inspired by the Cordis plugin architecture. The core engine is written in Haskell (GHC, type-driven design with Free monad plugins) and exposes a multi-protocol API server (OpenAI / Anthropic / Responses-compatible). A TypeScript scheduler layer handles parallel sub-agent orchestration, and an Electron + React desktop app provides the UI.

### Architecture Layers

| Layer | Tech | Location |
|---|---|---|
| **Core** | Haskell, Free monad, STM | `src/Core/` |
| **LLM Adapters** | Haskell, http-client | `src/LLM/` |
| **API Server** | Haskell, Servant, Warp | `src/API/` |
| **Infrastructure** | Haskell (SQLite, HTTP, Sandbox) | `src/Infrastructure/` |
| **Orchestration Bridge** | Haskell ↔ TypeScript (HTTP) | `src/Orchestration/` |
| **CPU Backend** | Haskell (SIMD/BLAS/Inference) | `src/Infrastructure/CPU/` |
| **Scheduler** | TypeScript, Express, Zod, Winston | `packages/scheduler/` |
| **SDK** | Haskell | `packages/sdk/` |
| **Desktop App** | Electron + React | `packages/app/Desktop/` |
| **CLI App** | Haskell | `packages/app/CLI/` |

### Key Design Patterns

- **Free Monad Plugins**: `Core.Plugin.Free` uses `Control.Monad.Free` for composable, testable effect descriptions. Plugins register services, subscribe to events, and acquire resources via `Disposer` pattern.
- **LLMAdapter abstraction**: All LLM backends implement `LLMAdapter { llmChat, llmEmbed, llmModels }`. Current providers: DeepSeek (real HTTP), OpenAI, and a local CPU inference backend.
- **Multi-protocol API**: Single Servant server exposes OpenAI-compatible (`/v1/chat/completions`), Anthropic-compatible (`/v1/messages`), and Responses (`/v1/responses`) endpoints, both streaming and non-streaming.
- **Session/Agent FSM**: `Core.Session.Manager` manages session state; `Core.Agent.StateMachine` implements agent state transitions (Idle → Processing → Done/Error).

## Building and Running

### Haskell Core Engine

```bash
cabal build              # Build all libraries and executables
cabal test               # Run Hspec test suite
cabal run trha -- --help # Show CLI help
cabal run trha -- cli    # Run CLI REPL
cabal run trha -- tui    # Run TUI mode
```

GHC version: requires `base ^>=4.22` (GHC 9.12+). The cabal file defines 5 internal libraries (`trha-core`, `trha-llm`, `trha-api`, `trha-infra`, `trha-orchestration`) merged where needed to work around GHC internal-lib linking bugs.

### TypeScript Scheduler

```bash
cd packages/scheduler
npm install
npm run build   # tsc
npm test        # vitest
npm run lint    # eslint src
```

TypeScript config: ES2022 target, ESNext modules, strict mode. Test framework: Vitest.

### Desktop App (Electron + React)

```bash
cd packages/app/Desktop
npm install
npm run build
npm test
```

### Static Binary (Docker)

```bash
docker build -f Dockerfile.static -t trha .
```

Produces a single statically-linked binary from `scratch` image via Alpine + musl.

### API Server

The Servant server (`API.Server.startServer`) listens on a configurable port and serves all three protocol families. Configure via environment variables (see `.env.example`).

## Testing

- **Haskell**: `cabal test` runs `test/Spec.hs` (Hspec + QuickCheck). Tests cover Core plugin system, sessions, agent state machine, tool registry, event bus, cache engine, and LLM adapter creation.
- **TypeScript**: `cd packages/scheduler && npm test` runs Vitest. Test files in `packages/scheduler/test/`.
- **Smoke tests**: `benchmarks/` directory contains integration/smoke tests.

## Development Conventions

- **Language**: Haskell 2010 with GHC extensions (OverloadedStrings, DataKinds, TypeOperators, DeriveGeneric, ScopedTypeVariables). TypeScript with strict mode.
- **Module naming**: Follows the cabal internal library structure — e.g. `Core.Plugin.Types` lives under `src/Core/Plugin/Types.hs`.
- **Shared `src/` module ownership (read before touching `trha.cabal` or `src/`)**: All five internal libraries (`trha-core`, `trha-llm`, `trha-api`, `trha-infra`, `trha-orchestration`) declare `hs-source-dirs: src`, so GHC treats a file under `src/` as belonging to the package that imports it. Every module must therefore be owned by **exactly one** library:
  - listed in **two** libraries ⇒ two incompatible types of the same name (already happened once: `Infrastructure.CPU.GGUF` / `Dequant` were briefly in both `trha-llm` and `trha-api` — `visibility: public` exposes `other-modules` downstream; recorded in `docs/plans/desktop-provider-design.md`);
  - listed in **neither** ⇒ link failure `undefined reference to trha…-inplace_<MangledModule>_…` — reproduced 2026-09-13 by deleting `trha-api`'s `other-modules` (`cabal build all`: all three executables failed to link);
  - current ownership: `Core.Provider.Types` → **trha-api only**; `LLM.*` + `Infrastructure.CPU.*` → **trha-llm only**; `Infrastructure.{Storage,Network,Sandbox,Telemetry}.*` → **trha-infra only**; `Core.{Plugin,Session,Agent,Tools,Event,Cache}.*` → **trha-core only**; `Orchestration.*` → **trha-orchestration only**.
  Do **not** remove `other-modules` entries as "duplicates" — they are required by this layout. Do not re-organise `src/` per package without updating this table and `docs/architecture/architecture.md` (see `docs/plans/code-docs-reconciliation.md`).
- **No sed for code edits**: Use the `edit` tool for all code modifications (project convention).
- **Imports**: Qualified imports preferred for large modules (`Data.Text`, `Data.Map`, `Data.Vector`). Unqualified for small/focused imports.
- **Test naming**: Hspec `describe` blocks match module names (`Core.Plugin`, `LLM.Adapter`, etc.).
- **Formatting**: Standard Haskell formatting; no explicit formatter config found. TypeScript uses ESLint.
- **Secrets**: Never commit API keys. Use `.env` (gitignored) with values from `.env.example`. See `docs/reference/github-secrets-setup.md` and `docs/reference/security-cleanup-guide.md` for CI secret management.

## Environment Variables

Key variables from `.env.example`:

| Variable | Purpose |
|---|---|
| `DEEPSEEK_API_KEY` | DeepSeek API authentication |
| `OPENAI_API_KEY` | OpenAI API authentication |
| `SERVER_PORT` | API server port (default: 3000) |
| `DATABASE_URL` | SQLite database path |
| `CACHE_SIZE` / `CACHE_TTL` | In-memory cache configuration |
| `LOG_LEVEL` / `LOG_FORMAT` | Logging configuration |

## CI/CD

Three GitHub Actions workflows in `.github/workflows/`:
- `ci.yml` — Main CI pipeline
- `smoke-tests.yml` — Smoke/integration tests
- `static-build.yml` — Static binary build

## Documentation

`docs/` is organised by document lifecycle (reorganised 2026-09-13; see `docs/plans/code-docs-reconciliation.md` §5 for the classification rationale).

**Structure authority & project intent — `docs/architecture/`**
- `docs/architecture/architecture-intended-vs-actual.md` — **Project intent vs actual state**: spec base (Agda「律算合一」→ pyBitNet《架构宪法》→ this repo's CPU layer) → intended architecture → actual architecture (✅/⚠️/❌) → deviations D-1…D-9 → status tiers A–E. **Read this first**: the project intent (kernel as a *reasoning hub* with type-theoretic/causal constraints) had never been documented, which caused a serious misread.
- `docs/architecture/architecture.md` — System architecture overview. ⚠️ §6 package layout is out of date (see `docs/plans/code-docs-reconciliation.md` §6)
- `docs/architecture/presentation-layer.md` — Presentation layer (Desktop/Web/TUI) design
- `docs/architecture/event-matrix.md` — Event producer / consumer / persistence matrix
- `docs/architecture/agent-lifecycle-notes.md` — One step → rounds → tool execution
- `docs/architecture/dsh-capability-seams.md` — Capability seams (registration points)

**Protocol contracts — `docs/contracts/`**
- `docs/contracts/protocol-shell-kernel.md` — Shell ↔ Scheduler ↔ Kernel protocol ledger (Phase 3 baseline)
- `docs/contracts/desktop-port-contract.md` — UI ↔ backend `Port` contract (no direct `fetch` in components)
- `docs/contracts/desktop-host-contract.md` — Desktop ↔ Scheduler host contract (v1)

**Active plans — `docs/plans/`**
- `docs/plans/desktop-provider-design.md` — Provider system (P1–P8, A1–A5)
- `docs/plans/desktop-ui-execution-plan.md`, `desktop-ui-port-plan.md`, `desktop-ui-progress.md` — Desktop UI port
- `docs/plans/pybitnet-ternary-inference-blueprint.md` — CPU ternary inference (M1–M20)
- `docs/plans/plan-reconciliation.md` — Plan vs reality (feature scope)
- `docs/plans/code-docs-reconciliation.md` — Code vs docs (build / wiring / usage scope)

**Reference — `docs/reference/`**
- `docs/reference/source-code-analysis.md`, `reasonix-architecture-analysis.md`, `reasonix-cli-tui-architecture-analysis.md`, `cordis-plugin-notes.md`, `dsh-docs-alignment-plan.md`, `electron-desktop-plan.md`, `layer-integration-report.md`
- `docs/reference/github-secrets-setup.md`, `security-cleanup-guide.md` — CI / secrets operations

**Archive — `docs/archive/`** (completed or superseded plans)
- `docs/archive/implementation-plan-cli-tui.md`, `implementation-plan-phase2.md`, `plan-phase2-s2-s3-atomic.md`, `kernel-tool-execution-plan.md`
- `docs/archive/implementation-plan-shell-sharing.md`, `shell-sharing-design.md`, `reasonix-shell-sharing-analysis.md`, `execution-discipline-acceptance.md`
- `docs/archive/implementation-roadmap.md`, `code-migration-plan.md`, `pi-integration-plan.md`

Other component docs:
- `packages/scheduler/README.md` — Scheduler documentation
- `packages/app/Desktop/README.md` — Desktop app documentation
