// permissionRules：deny > ask > allow 三层规则引擎的穷举测试。
// 纯逻辑、零外部依赖：精确名 / ToolName(glob) / Bash(command:*) / 优先级 / 非法规则过滤。
import { afterEach, describe, expect, it } from 'vitest';

import {
  getPermissionRules,
  setPermissionRules,
  decidePermission,
  isBashPattern,
  compileRules,
  type PermissionRule,
} from '../src/Permission/permissionRules.js';

const rule = (kind: PermissionRule['kind'], pattern: string): PermissionRule => ({ kind, pattern });

afterEach(() => {
  setPermissionRules([]);   // 每条用例后清场，避免规则泄漏进其他套件
});

describe('permissionRules — 三层规则引擎', () => {
  it('空规则集 → 默认 allow（沙箱已兜底文件边界）', () => {
    setPermissionRules([]);
    expect(decidePermission('bash', { command: 'rm -rf /' })).toEqual({ action: 'allow' });
  });

  it('精确工具名：deny 命中给出规则原文', () => {
    setPermissionRules([rule('deny', 'bash')]);
    expect(decidePermission('bash', { command: 'x' })).toEqual({
      action: 'deny', reason: 'denied by rule: bash',
    });
    expect(decidePermission('read_file', {}).action).toBe('allow');
  });

  it('ToolName(glob)：参数值命中 glob（ask）', () => {
    setPermissionRules([rule('ask', 'write_file(*.ts)')]);
    expect(decidePermission('write_file', { path: 'src/a.ts' })).toEqual({
      action: 'ask', reason: 'requires confirmation: write_file(*.ts)',
    });
    expect(decidePermission('write_file', { path: 'src/a.md' })).toEqual({ action: 'allow' });
  });

  it('Bash(command:*)：命令前缀通配（name 是 bash 或 args 里有 command/cmd/full）', () => {
    setPermissionRules([rule('deny', 'Bash(command:rm *)')]);
    expect(decidePermission('bash', { command: 'rm -rf /tmp/x' })).toEqual({
      action: 'deny', reason: 'denied by rule: Bash(command:rm *)',
    });
    expect(decidePermission('shell', { cmd: 'rm x' })).toEqual({
      action: 'deny', reason: 'denied by rule: Bash(command:rm *)',
    });
    expect(decidePermission('bash', { command: 'ls -la' })).toEqual({ action: 'allow' });
  });

  it('优先级：deny > ask > allow（三条同时命中时 deny 赢）', () => {
    setPermissionRules([
      rule('allow', 'Bash(command:git *)'),
      rule('ask', 'Bash(command:git *)'),
      rule('deny', 'Bash(command:git *)'),
    ]);
    expect(decidePermission('bash', { command: 'git push' }).action).toBe('deny');
  });

  it('ask 在无 deny 时命中；allow 在无 deny/ask 时命中', () => {
    setPermissionRules([rule('allow', 'Bash(command:git *)'), rule('ask', 'Bash(command:git *)')]);
    expect(decidePermission('bash', { command: 'git push' }).action).toBe('ask');
    setPermissionRules([rule('allow', 'bash')]);
    expect(decidePermission('bash', {}).action).toBe('allow');
  });

  it('非法规则被过滤（pattern 非串 / kind 不合法）', () => {
    setPermissionRules([
      rule('deny', 'bash'),
      { kind: 'bogus', pattern: 'x' } as unknown as PermissionRule,
      { kind: 'deny', pattern: 42 } as unknown as PermissionRule,
    ]);
    expect(getPermissionRules()).toHaveLength(1);
    expect(decidePermission('bash', {})).toEqual({ action: 'deny', reason: 'denied by rule: bash' });
  });

  it('compileRules：手动改完内部规则后重编译生效（测试/调试口径）', () => {
    setPermissionRules([]);
    // setPermissionRules 已重编译；compileRules 是幂等再编译
    expect(() => compileRules()).not.toThrow();
    expect(decidePermission('anything', {})).toEqual({ action: 'allow' });
  });

  it('isBashPattern：大小写敏感的 Bash( 前缀', () => {
    expect(isBashPattern('Bash(command:rm *)')).toBe(true);
    expect(isBashPattern(' bash(command:x)')).toBe(false);  // 前导空格后是小写 b
    expect(isBashPattern('bash')).toBe(false);
  });

  it('glob 的 ? 单字符与特殊字符转义', () => {
    setPermissionRules([rule('deny', 'read_file(??.txt)')]);
    expect(decidePermission('read_file', { path: 'ab.txt' }).action).toBe('deny');
    expect(decidePermission('read_file', { path: 'x.txt' }).action).toBe('allow');
    // 特殊字符（如 .）被转义：不把 aXb 当 a.b
    setPermissionRules([rule('deny', 'read_file(a.b)')]);
    expect(decidePermission('read_file', { path: 'axb' })).toEqual({ action: 'allow' });
  });
});
