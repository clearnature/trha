# @trha/cli —— TUI 的 npm 启动器

trha 的 TUI 是 Haskell 可执行文件（brick/vty），不是 JS 应用。这个包只做一件事：
**找到真正的 `trha` 二进制并原样透传参数与 stdio**，让 `pnpx` / `npx` 能一键启动它。

```
packages/app/CLI-npm/
├── package.json     bin: { "trha": "bin/trha.js" }
├── bin/trha.js      定位二进制 → spawnSync(stdio: 'inherit')
└── vendor/          可选：随包分发的 trha(.exe)
```

## 用法

```bash
# 仓库内（未发布）：传包目录，注意用绝对路径 —— pnpm 12 会把 `.` 解析成空的
# link: spec（ERR_PNPM_DLX_NO_BIN），相对目录同理不可靠。
pnpx "D:/work/github/trha/packages/app/CLI-npm" --help

# 之后正常进 TUI（需要交互终端）
pnpx "D:/work/github/trha/packages/app/CLI-npm"

# 非交互：行式 REPL
pnpx "D:/work/github/trha/packages/app/CLI-npm" cli
```

## 二进制查找顺序

1. `$TRHA_BIN` —— 显式指定（CI、多版本切换）
2. `<包>/vendor/trha[.exe]` —— 发布形态：把二进制放进 `vendor/`
3. `$TRHA_CABAL_BIN` —— 构建产物路径
4. `cabal list-bin trha` —— 仓库内开发形态（从本文件上溯找 `trha.cabal`）

都找不到时报错并给出三条修复建议，退出码 `127`。

## 为什么不做成"下载二进制"的 postinstall

trha 的内核/scheduler 与 TUI 版本强耦合，静默下载会让"装的到底是哪一版"不可追踪。
本地开发用 `cabal build trha` + 第 4 条查找；分发时把同版本的二进制放进 `vendor/`。

## 注意

- `stdio` 必须 `inherit`：TUI 直接驱动终端。stdin 不是终端时 `trha` 自己会报错并提示
  改用 `trha cli`，这一层不做判断、也不吞掉那个错误。
- 包目录不要 `npm install`：它没有依赖，装出来的 `node_modules` 只会污染仓库。
