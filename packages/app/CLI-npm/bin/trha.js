#!/usr/bin/env node
// trha TUI 的 npm 包装：定位真正的 Haskell 可执行文件，原样透传参数与 stdio。
//
// 查找顺序（先命中先用）：
//   1. $TRHA_BIN              —— 显式指定，CI/多版本切换用
//   2. <pkg>/vendor/trha[.exe] —— 随包分发的二进制（发布形态）
//   3. $TRHA_CABAL_BIN        —— 构建产物路径
//   4. `cabal list-bin trha`  —— 仓库内开发形态（从本文件上溯找 trha.cabal）
//
// stdio 必须 inherit：TUI 直接驱动终端，stdin 不是终端时 trha 自己会报错
// 并提示改用 `trha cli`，这一层不做判断，也不吞掉那个错误。

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const exeName = process.platform === 'win32' ? 'trha.exe' : 'trha';

function repoRoot() {
  let dir = here;
  for (let i = 0; i < 8; i += 1) {
    if (existsSync(path.join(dir, 'trha.cabal'))) return dir;
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  return null;
}

function cabalBin() {
  const root = repoRoot();
  if (!root) return null;
  const res = spawnSync('cabal', ['list-bin', 'trha'], {
    cwd: root,
    encoding: 'utf8',
    shell: process.platform === 'win32',
  });
  if (res.status !== 0) return null;
  const found = (res.stdout || '').trim();
  return found && existsSync(found) ? found : null;
}

function findBinary() {
  const candidates = [];
  if (process.env.TRHA_BIN) candidates.push(process.env.TRHA_BIN);
  candidates.push(path.join(here, '..', 'vendor', exeName));
  if (process.env.TRHA_CABAL_BIN) candidates.push(process.env.TRHA_CABAL_BIN);

  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate;
  }
  return cabalBin();
}

const bin = findBinary();
if (!bin) {
  console.error(
    [
      'trha: 找不到 trha 可执行文件。',
      '',
      '  仓库内开发：先构建  cabal build trha',
      '  已装二进制：设 TRHA_BIN=/path/to/trha（Windows 为 trha.exe）',
      '  随包分发：把二进制放到 <package>/vendor/trha[.exe]',
    ].join('\n'),
  );
  process.exit(127);
}

const result = spawnSync(bin, process.argv.slice(2), { stdio: 'inherit' });
if (result.error) {
  console.error(`trha: 启动失败 — ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
