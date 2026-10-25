# TypeScript 7 工具链迁移备忘录

> 状态（**2026-10-25 建档**）：**工具链迁移已完成、全仓 audit 清零、兼容性矩阵全绿**。
> typescript-eslint 的 TS 7.1 适配仍在官方 WIP（PR #12803, draft）——本仓**不自研适配层**，等官方合入后整体升级。
> 本文档同时记录「为什么不做兼容 shim」的证据链与「何时做什么」的触发条件。

## 1. 现状快照

| 层 | 版本 / 状态 |
| --- | --- |
| 全局 `tsc`（pnpm 12.15.0 管理） | `typescript@7.1.0-beta`（2026-10-25 从 7.0.2 升级；`pnpm add -g typescript@beta`） |
| 各包 devDependencies | `typescript ^7.0.2`（npm `latest`，scheduler / Desktop / benchmarks 各自锁定） |
| vitest 链 | 1.6.1（EOL，含 critical）→ **5.0.5** 全仓迁移完成（scheduler/Desktop/Web/benchmarks） |
| vite | 5.4 → **7.3.7**（Web + Desktop），`@vitejs/plugin-react ^5.1.4`（6.x peer 要 vite 8） |
| electron | 44.2.0 → **44.9.3**（审计清零；二进制下载见下 §5 待办） |
| `@types/node` | 20 → **24**（vitest 5 peer 要求；运行时 Node 26） |
| Desktop 的 eslint 链 | **已移除**（`eslint` + `@typescript-eslint/*` + lint 脚本）——原本就没接线（无 ESLint 配置文件，脚本必报 no configuration），且 TS 7 下永不可用（见 §3） |

**TS 7 的形态**（`typescript@7.x` 即 Go 原生编译器）：bin 仍叫 `tsc`（`lib/tsc.js` 是启动器，经平台包 `@typescript/typescript-linux-x64` 调原生二进制）；**不再提供 `lib/typescript.js` 编译器 JS API**——这是全部兼容性问题的根源。新的程序化 API 在 7.1 才以 preview 形态出现（`typescript/sync`、`/ast`、`/fs` 等子路径），且架构变为「本地 server + RPC 协议 + snapshot + 显式 dispose」，不是旧 API 的回归。PoC 实测：beta 里 `Client` 运行时只暴露原始 RPC（`apiRequest`/`batchRequests`/`close`），类型化方法尚未装配。

## 2. 兼容性矩阵（2026-10-25，全绿）

| 测试项 | 结果 |
| --- | --- |
| 全局 7.1.0-beta × scheduler/Desktop(两份 tsconfig)/Web `--noEmit` | ✅ 全部 exit 0 |
| Desktop main 真实 emit（临时 outDir） | ✅ js/d.ts/map 齐全 |
| 7.1 收紧的分布条件类型检查 | ✅ 未打中本仓任何类型代码 |
| tsrs（全局工具） | ✅ 自带 7.1.0-dev 编译器，不受全局换版影响 |
| vitest 全量四包 | ✅ 252 + 170(+7 skip) + 82 + 3 |
| 全仓 5 处 `npm audit`（官方 advisory 库） | ✅ 零 advisory（本次修复：qs/proxy-addr/body-parser/follow-redirects/express 升级、死依赖 zod/uuid/eslint 链移除、electron 44.9.3、overrides 压掉 shell-quote critical 等） |

## 3. typescript-eslint 源码检查（`/data/training/cli/typescript-eslint`，main @ `1166ba20e`）

- **main 硬拒 TS 7.0**：`eaf457631` 检测到 `typescript@7.0` 直接抛错，指引 TS 6 API side-by-side；三个包 peer 全锁 `>=4.8.4 <6.1.0`。仓库自身 typecheck 已跑 tsgo（`1849b530c`）——用新编译器、不用新 API。
- **依赖面**：`typescript-estree` 31 处 `import 'typescript'`；`ts.Node`(95)/`ts.SyntaxKind`(67)/`ts.SourceFile`(31)/`ts.Token`(25)…（大头是类型引用，运行时需完整解析器能力）。
- **官方移植 = PR #12803**（draft，2026-10-16 更新，+5616/−477，125 文件）：`projectService: { EXPERIMENTAL_backend: 'native' }`，四个适配器把经典 `ts.*` 表面盖在新 API 上：
  - `nativeNodeAdapter`：SyntaxKind/NodeFlags **重新编号**、属性改名、token 遍历；
  - `nativeTypeAdapter`：`Type/Symbol/Signature` 包装且保持稳定对象身份（新 API 是 lazy 方法 `type.getSymbol()`，旧的是平铺属性 `type.symbol`）；
  - `nativeCheckerAdapter` / `nativeProgramAdapter`：checker/program 门面。
  - **AST 实质分歧清单**（PR 内文档化）：`questionToken`/`exclamationToken` → `postfixToken`；`EndOfFileToken` → `EndOfFile`；`escapedText` 移除；JSX `</` 单 token 化；`Namespace`/`GlobalAugmentation` flags 移除等。
  - 性能：文件多时 native 比 classic 慢至 ~1.5×——官方明说等 7.1 的批量 API 补齐后改善。
- **维护者口径**（issue #10940）：bradzacher——「没有 API 我们无法集成，只能等」；Goldberg——TS 团队（andrewbranch）按其需求补 API，「7.1 支持越来越稳」。

## 4. 迁移决策（本仓纪律）

1. **不自研兼容 shim。** 官方 5.6k 行适配器还在随 beta 协议演化；自研 = 复刻一个移动目标，且本仓没有需要移植的消费方（全仓运行时 `import 'typescript'` 为零，lint 需求由根目录 oxlint（Rust，不依赖 TS API）覆盖）。
2. **编译器钉 latest stable（7.x 线内自然升级）**。本仓代码与编译器版本天然解耦：不做「在 6.x API 下维持兼容」的胶水，也不提前吃 beta——7.1 stable 一发布，各包 `typescript ^7.0.2 → ^7.1` 即完成迁移（bin 不变，typecheck/build 脚本无感）。
3. **全局（pnpm -g）与项目（-D）分层**：全局是「手边的 CLI」，项目内版本由锁文件钉死，脚本解析永远先命中 `node_modules/.bin/tsc`——全局升 beta 不影响各包构建。
4. **lint 依赖与编译器解耦**：需要重新接 lint 时，优先 oxlint；typescript-eslint 等 `EXPERIMENTAL_backend: 'native'` 转正后再接。

## 5. 触发条件与届时操作

| 触发 | 动作 |
| --- | --- |
| PR #12803 合入 main（发布版） | 评估在本仓接回 typescript-eslint（若需要类型感知 lint） |
| `typescript@7.1` stable 发布 | 各包 `pnpm/npm` 升 `typescript ^7.1`，跑 §2 矩阵回归；重点看分布条件类型新检查与 lib.es2026 变化 |
| 7.1 批量 API 落地（官方性能声明兑现） | 复测 tseslint native 后端性能再决定是否接入 |
| 立即待办 | Desktop `npm install`（allowScripts 已批准 electron@44.9.3）落地二进制；本档与 electron-44-upgrade.md 的遗留项一起提交 |

## 6. 时间预期（2026-10-25 查证，均为官方口径的推算，非承诺）

- **TS 7.1**：7.1 Beta 公告（约 2026-10-22）明示「修 bug → 约 1 个月后 RC → 不久后 stable」，即 **RC ≈ 2026-11 底、stable ≈ 2026-12 初**。npm dist-tags 已有 `beta: 7.1.0-beta`。
- **typescript-eslint（PR #12803）**：2026-08-31 开出、10-16 仍在更新（draft）。维护者 bradzacher 给出的剩余路径：收尾几条前置 PR（#12922→#12923、#12936→#12934）→ 最后一轮性能调查 → 标记 ready for review。**没有给日期**；前置依赖是 7.1 的批量 API，故现实链路是「7.1 stable（≈12 月）前后合入」，且官方明示**首发 IPC 版本性能不会优于 TS 6**（ESLint 侧缺批量查询 API，#11677）。
- **本仓动作锚点不变**：7.1 stable 发布即升 `typescript ^7.1`（与 tseslint 无关、当天可完成）；lint 链路等 #12803 转正合入后再接。

## 7. 参考

- 官方：[TS 7.0 发布公告](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/) · [TS 7.1 Beta](https://devblogs.microsoft.com/typescript/announcing-typescript-7-1-beta)（新模块化 API、content mappers、`--target es2026`）
- typescript-eslint：[issue #10940（TS 7 适配跟踪）](https://github.com/typescript-eslint/typescript-eslint/issues/10940) · [PR #12803（native backend）](https://github.com/typescript-eslint/typescript-eslint/pull/12803)
- 本地源码：`/data/training/cli/typescript-eslint`（main @ `1166ba20e`；TS7 检测 `eaf457631`，tsgo typecheck `1849b530c`）
- 相关既有文档：[`electron-44-upgrade.md`](./electron-44-upgrade.md)（Desktop 工具链升级先例与本轮待办的关联）
