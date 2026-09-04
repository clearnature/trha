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
- **No sed for code edits**: Use the `edit` tool for all code modifications (project convention).
- **Imports**: Qualified imports preferred for large modules (`Data.Text`, `Data.Map`, `Data.Vector`). Unqualified for small/focused imports.
- **Test naming**: Hspec `describe` blocks match module names (`Core.Plugin`, `LLM.Adapter`, etc.).
- **Formatting**: Standard Haskell formatting; no explicit formatter config found. TypeScript uses ESLint.
- **Secrets**: Never commit API keys. Use `.env` (gitignored) with values from `.env.example`. See `docs/github-secrets-setup.md` and `docs/security-cleanup-guide.md` for CI secret management.

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

- `docs/architecture.md` — System architecture overview
- `docs/github-secrets-setup.md` — CI secret configuration
- `docs/security-cleanup-guide.md` — Sensitive data cleanup
- `docs/pi-integration-plan.md` — Pi parallel sub-agent integration
- `docs/shell-sharing-design.md` — Shell sharing design
- `packages/scheduler/README.md` — Scheduler documentation
- `packages/app/Desktop/README.md` — Desktop app documentation
