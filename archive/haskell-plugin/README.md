# Haskell 插件层（已归档，2026-10-27）

原 `src/Core/Plugin/{Types,Free}.hs`（Free monad + `Dynamic` + `Disposer`）与
`test/PluginSpec.hs`。

归档理由（用户裁定，见 `docs/plans/improvement-plan-2026-10-27.md` P-05）：

- 生产代码零引用（仅测试引用）；
- 真正的扩展面在 scheduler 的 Cordis 式 `ctx`（service/inject/waterfall/bail）与 MCP/LSP；
- 保留在 `archive/` 仅作设计参考，不再参与构建。

设计背景见 `docs/architecture/architecture.md` §3.1 与 `docs/reference/microkernel-lineage.md`。
