# SDK 遗留部分（已归档，2026-10-27）

原 `packages/sdk` 中与内核重复的模块：

- `Core/Server.hs`、`Core/Handlers.hs` —— 一个 servant HTTP server，与 `src-api/API/Server.hs` 重复；
- `Types/Config.hs` —— 配置读写，与 `packages/app/CLI/Config/Settings.hs` 的职责重叠；
- `Server/Main.hs` —— 上述 server 的可执行入口。

保留并**并入主线**的部分（`packages/sdk`，已在根 `cabal.project`）：

- `Core/Types.hs`、`Core/Client.hs`、`Core/HTTP.hs`
- `Client/{Session,Agent,Tool,Model}.hs`
- `Utils/{Logger,Retry}.hs` + `test/Spec.hs`

依据：P-02（用户裁定「进行拆分，合并归档，并入主线」），见
`docs/plans/improvement-plan-2026-10-27.md`。
