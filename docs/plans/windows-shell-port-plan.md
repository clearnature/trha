# Windows Shell 支持移植计划

> 事实输入（2026-10-25 源码直读）：DeepSeek-Reasonix 的 Windows 兼容层（Go）与 deepseek-harness 的 shell 包家族（TS），对照 trha scheduler 的 6 处执行路径。
> 执行方式：subagent-driven-development 或 executing-plans。步骤用 `- [ ]` 语法。
> 范围声明：M0 在本计划内完整 TDD 展开（可直接执行）；M1/M2 为里程碑契约，启动时按本仓惯例另行细化——跨子系统拆独立计划，非占位符。

**目标：** trha scheduler 的 shell 执行路径在 Windows 上可用——平台 shell 探测与选择层收拢全部硬编码 `bash`，cmd.exe/PowerShell 引号与环境语义对齐参考实现。
**架构：** 新增 `src/Server/shell.ts` 纯模块（平台 → shell 调用规约），六处执行路径全部经它取 shell；POSIX 行为**逐字节不变**（现有 252 个测试就是回归护栏）。工具命名保持 `bash` 作为平台无关的"shell 工具"身份（与 Reasonix/harness 的孪生工具思路不同——trha 用单工具多后端，避免权限规则与目录分裂）；独立 `pwsh` 工具补 `powershell.exe` 回退。
**技术栈：** TypeScript + node:child_process（现状不变）；无新依赖。

---

## 差距清单（对照参考实现，2026-10-25 核准）

| # | trha 现状 | 参考实现 | Windows 后果 |
| --- | --- | --- | --- |
| G1 | `standardTools.ts:141` `startJob`：硬编码 `spawn('bash', ['-lc', …])` | harness `tool-bash`/`tool-pwsh` 孪生 | ❌ 后台作业直接失败 |
| G2 | `extraTools.ts:61` `sh()` helper：硬编码 `spawn('bash', ['-lc', …])`（worktree 等使用） | 同上 | ❌ 失败 |
| G3 | `extraTools.ts:153` `terminal_open`：硬编码 `spawn('bash', ['-l'])` + PS1 清除 | harness persistent 变体 | ❌ 失败 |
| G4 | `standardTools.ts:393-408` `run_code`：bash/sh runner 白名单 `cmd:'bash'` | harness pwsh twin | ❌ bash/sh 代码失败 |
| G5 | `extraTools.ts:312` `pwsh` 工具：只认 `pwsh`（PS7）；Windows 自带的 **Windows PowerShell 5 是 `powershell.exe`** | Reasonix `command_normalize.go:354` 识别 4 种名字 | ⚠️ 只装 PS5 的机器失败 |
| G6 | `index.ts:859` `runShell = promisify(exec)` | — | ✅ **无需改**：Node `exec` 在 win32 自动用 `cmd.exe /d /s /c`（写入契约注释即可） |
| G7 | 无 cmd.exe 引号/环境语义 | Reasonix `windows_compat.go:54-112`：`/d /s /c` 引号编码（`CommandLineToArgvW` ≠ cmd.exe 解析）、`NoDefaultCurrentDirectoryInExePath`（`runner.go:85-105`） | ❌ 含引号/特殊字符的命令静默出错 |

## 里程碑总览与验收标准

| 里程碑 | 内容 | 验收标准 |
| --- | --- | --- |
| **M0 shell 抽象层** | `src/Server/shell.ts` + 六处路径收拢（G1-G5） | POSIX 行为逐字节不变（scheduler 252 测试全绿）；注入 `win32` 后单测断言 `cmd.exe /d /s /c` 规约 |
| **M1 Windows 语义** | G7 引号编码移植、`run_code` 平台 runner、pwsh/PS5 回退链 | 引号单测（注入平台，无需真 Windows）；CI 加 windows-latest 跑 scheduler vitest |
| **M2 语义对齐与文档** | 工具命名契约文档化、`terminal_open` PowerShell 的 PS1 处理、平台矩阵 README、Windows 手工验证清单 | 文档 + 手工验证记录入库（对齐 electron-44-upgrade.md 的做法） |

---

## M0：shell 抽象层（本计划内完整展开）

**文件：** 创建 `packages/scheduler/src/Server/shell.ts` · 修改 `src/Server/standardTools.ts:141,399` · `src/Server/extraTools.ts:61,153,312` · 测试 `packages/scheduler/test/shell.test.ts`（新建）

- [x] **任务 1：纯模块 `shell.ts`（失败测试先行）**

  - [x] 步骤 1.1：写失败测试 `test/shell.test.ts`（纯函数，注入平台，无需真 Windows）：

    ```ts
    import { describe, it, expect } from 'vitest';
    import { resolveShell, interactiveShell, powerShellCandidates, shellRunner } from '../src/Server/shell.js';

    describe('resolveShell', () => {
      it('preserves the POSIX contract byte-for-byte', () => {
        expect(resolveShell('make test', 'linux')).toEqual({ cmd: 'bash', args: ['-lc', 'make test'] });
      });
      it('routes to cmd.exe /d /s /c on win32', () => {
        expect(resolveShell('dir', 'win32')).toEqual({ cmd: 'cmd.exe', args: ['/d', '/s', '/c', 'dir'] });
      });
      it('keeps the interactive shells per platform', () => {
        expect(interactiveShell('linux')).toEqual({ cmd: 'bash', args: ['-l'] });
        expect(interactiveShell('win32')).toEqual({ cmd: 'powershell.exe', args: ['-NoLogo'] });
      });
      it('prefers pwsh with a PS5 fallback only on win32', () => {
        expect(powerShellCandidates('win32')).toEqual(['pwsh', 'powershell.exe']);
        expect(powerShellCandidates('linux')).toEqual(['pwsh']);
      });
      it('maps run_code shell runners per platform', () => {
        expect(shellRunner('bash', 'linux')).toEqual({ ok: true, cmd: 'bash' });
        expect(shellRunner('sh', 'win32').ok).toBe(false);
      });
    });
    ```

  - [x] 步骤 1.2：`npx vitest run test/shell.test.ts` → FAIL（模块不存在）。

  - [x] 步骤 1.3：最小实现 `src/Server/shell.ts`：

    ```ts
    // Platform shell resolution for every spawn site. POSIX keeps the exact
    // `bash -lc` contract (252 tests are the regression guard); win32 uses
    // cmd.exe /d /s /c — the same form Node's exec picks and Reasonix's
    // windows_compat.go encodes for.
    export type ShellSpec = { cmd: string; args: string[] };

    export function resolveShell(command: string, platform: NodeJS.Platform = process.platform): ShellSpec {
      if (platform === 'win32') return { cmd: 'cmd.exe', args: ['/d', '/s', '/c', command] };
      return { cmd: 'bash', args: ['-lc', command] };
    }

    export function interactiveShell(platform: NodeJS.Platform = process.platform): ShellSpec {
      if (platform === 'win32') return { cmd: 'powershell.exe', args: ['-NoLogo'] };
      return { cmd: 'bash', args: ['-l'] };
    }

    export function powerShellCandidates(platform: NodeJS.Platform = process.platform): string[] {
      return platform === 'win32' ? ['pwsh', 'powershell.exe'] : ['pwsh'];
    }

    export type RunnerSpec = { ok: boolean; cmd: string };
    export function shellRunner(language: string, platform: NodeJS.Platform = process.platform): RunnerSpec {
      if (language !== 'bash' && language !== 'sh') return { ok: true, cmd: language };
      if (platform === 'win32') return { ok: false, cmd: '' };
      return { ok: true, cmd: 'bash' };
    }
    ```

  - [x] 步骤 1.4：`npx vitest run test/shell.test.ts` → PASS → `git commit -m "feat(scheduler): platform shell resolution module"`。

- [x] **任务 2：收拢 G1/G2（行为保持，POSIX 不变）**

  - [x] 步骤 2.1：`standardTools.ts:141` `startJob` 改 `const sh = resolveShell(command); spawn(sh.cmd, sh.args, { cwd: host.workspace })`。

  - [x] 步骤 2.2：`extraTools.ts:61` `sh()` helper 同样改经 `resolveShell`。

  - [x] 步骤 2.3：`npx vitest run`（全量 252）→ 全绿（POSIX 路径未变）→ `git commit -m "refactor(scheduler): route job/worktree spawns through shell.ts"`。

- [x] **任务 3：收拢 G3/G5/G4**

  - [x] 步骤 3.1：`terminal_open` 改 `const ish = interactiveShell(); spawn(ish.cmd, ish.args, { cwd: host.cwd(), env: platform==='win32' ? process.env : {...process.env, PS1: ''}, … })`。

  - [x] 步骤 3.2：`pwsh` 工具改候选链：`for (const exe of powerShellCandidates()) { try spawn…; ENOENT → 下一候选 }`，全失败时报 `ERROR: neither pwsh nor powershell.exe is installed`（保持 127 友好消息惯例）。

  - [x] 步骤 3.3：`run_code`：`bash/sh` 语言项改走 `shellRunner(language)`，`ok:false` 时返回 `ERROR: bash is not available on this platform (use pwsh)`（不静默换语言——对齐模型可知性）。

  - [x] 步骤 3.4：`npx vitest run` 全绿；新增 3 个注入平台的行为测试（win32 下 pwsh 候选回退用 spawn mock）→ `git commit -m "feat(scheduler): platform-aware terminal/pwsh/run_code paths"`。

## M1：Windows 语义（启动时细化，契约如下）

- [x] **cmd.exe 引号编码**：~~`encodeForCmd(argv)`~~ **范围裁定**：Reasonix 的 argv-form 编码服务于其 `.cmd` hook 体系；trha 没有 `.cmd` argv-form 路径（无 hooks 系统），唯一 cmd.exe 表面是 shell-form `/c` 字符串。故实现为 `resolveShell` 的 **verbatim 外层引号包装**（`/d /s /c "command"` + `windowsVerbatimArguments`，等价 Reasonix `windowsCmdCommandLine`，`windows_compat.go:107-113`），注入平台单测（`test/shell.test.ts` 13 例）。
- [x] **环境语义**：`hardenedEnv` —— win32 注入 `NoDefaultCurrentDirectoryInExePath=1`（Reasonix `runner.go:85-105`），接入全部 5 个 spawn 点（startJob/sh/run_code/pwsh/terminal_open）。
- [x] **CI 矩阵**：`ci.yml` 新增 `scheduler-windows`（windows-latest，全量 scheduler vitest）——纯函数用例注入平台，POSIX 集成用例依赖 runner 自带 Git Bash；若真机出现红项按 M2 处理。

## M2：语义对齐与文档（启动时细化，契约如下）

- [x] 契约文档：`bash` 工具名 = 平台无关 shell 工具身份（权限规则键不变），实际 shell 由 `shell.ts` 决定——平台矩阵已写入 `packages/scheduler/README.md`。
- [x] `terminal_open` PowerShell 分支：PS1 仅 POSIX 清除（`hardenedEnv` + 条件 env，M1 已实现）。
- Windows 手工验证清单入库（对齐 `electron-44-upgrade.md` §3.2 风格）：真机跑 bash 工具/cmd.exe 语义/pwsh 回退/后台作业，记录回执。

## 自检记录

- 覆盖度：G1-G7 逐项有落点——G1-G5→M0，G7→M1，G6→M0 文档注释（无需代码）；语义错位与验证→M2。
- 占位符：无 TODO；M1/M2 为显式另行细化声明。
- 类型一致：`ShellSpec`/`RunnerSpec`/`powerShellCandidates` 在任务 1 定义，任务 2/3 引用同名。
