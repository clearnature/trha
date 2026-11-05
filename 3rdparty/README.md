# 3rdparty —— 外部代码与数据

本目录混放三类东西，**性质完全不同**，删除前务必看清：

| 类别 | 含义 | 删除后果 |
|---|---|---|
| **构建依赖** | cabal 直接引用（`extra-lib-dirs` / `include-dirs`） | **构建失败** |
| **运行时数据** | 代码按路径读取 | **功能缺失**（不报错但少东西） |
| **参考源码 / 语料** | 只在 `docs/` 里被提及，不参与构建与运行 | 无影响，仅失去对照材料 |

## 目录清单

| 目录 | 类别 | 引用位置 | 首次提交 |
|---|---|---|---|
| `wgpu-native/` | **构建依赖** | `trha.cabal` 的 `include-dirs`、`extra-lib-dirs-static`（Windows/Linux 各一份） | `68b932a` 2026-09-13 |
| `fonts/` | **运行时数据** | `packages/app/CLI/Core/Fonts.hs:31`（`./3rdparty/fonts`，含 `NotoSansYi-Regular.ttf`） | `00ba4cc` 2026-10-27 |
| `corpus/` | **参考语料** | 无代码引用（本目录自带 `README.md` 说明） | `00ba4cc` 2026-10-27 |
| `brick-3.0/` | **参考源码** | `docs/plans/ide-information-architecture.md:225` | `9e4b7c3` 2026-10-25 |
| `llama-webgpu/` | **参考源码** | `docs/plans/webgpu-wiring-plan.md`（WGSL 写法对照，41 个 shader） | `68b932a` 2026-09-13 |
| `llama-vulkan/` | **参考源码** | `docs/architecture/project-overview.md:97` | `1697316` 2026-09-13 |

## 几处容易误判的地方

**`wgpu-native` 不是参考代码。** 它被 `trha.cabal` 以路径方式链接：

```haskell
include-dirs:          3rdparty/wgpu-native/include
extra-lib-dirs-static: 3rdparty/wgpu-native/lib        # Linux
extra-lib-dirs-static: 3rdparty/wgpu-native/lib/windows  # Windows
```

没有它 `trha-webgpu` 链接不过。

**`brick-3.0` 不在构建里。** CLI 用的是 Hackage 的 `brick >= 3.0`（`trha.cabal:412`），
`dist-newstyle/cache/plan.json` 记录其来源为 `repo-tar` + `hackage.haskell.org`。
这里的源码只用于查 API（trha 用到 `customMain` / `appFor` / `appStartEvent` 等 3.x 接口）。

**`fonts` 是运行时查找，不是编译期依赖。** `Core/Fonts.hs` 优先取 `./3rdparty/fonts`，
找不到才退回系统字体——所以删掉不会编译失败，只会让彝文字形丢失。

**`corpus` 目前零引用。** 84K 的彝文语料，来自 `/data/trit/pyBitNet`（MIT），
用途写在 `corpus/README.md`：为未来的彝文分词/词元映射留档，不参与渲染。

## 维护约定

- 新增目录时，请在上表补一行并写明「类别」与「引用位置」。
- 参考类目录若长期不再使用，可移入 `archive/`；构建依赖与运行时数据不要动。
- `hlint` 已豁免本目录（vendored 代码不参与风格检查）。
