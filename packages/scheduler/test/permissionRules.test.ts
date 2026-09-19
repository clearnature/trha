import { describe, it, expect, beforeEach } from 'vitest';
import { setPermissionRules, decidePermission, getPermissionRules, PermissionRule } from '../src/Permission/permissionRules.js';

describe('permissionRules', () => {
  beforeEach(() => setPermissionRules([]));

  const deny: PermissionRule = { kind: 'deny', pattern: 'write_file(tmp/*)' };
  const allow: PermissionRule = { kind: 'allow', pattern: 'read_file' };

  it('无规则 → 默认 allow', () => {
    expect(decidePermission('read_file', { path: '/tmp/x' }).action).toBe('allow');
  });

  it('deny 匹配 Block 阻断', () => {
    setPermissionRules([deny]);
    expect(decidePermission('write_file', { path: '/tmp/sensitive' }).action).toBe('deny');
    // 不匹配则不阻断
    expect(decidePermission('write_file', { path: '/data/other' }).action).toBe('allow');
  });

  it('allow 精确名放行', () => {
    setPermissionRules([allow]);
    expect(decidePermission('read_file', { path: '/tmp/x' }).action).toBe('allow');
  });

  it('优先级 deny > ask > allow', () => {
    setPermissionRules([
      { kind: 'allow', pattern: 'write_file(*)' },
      { kind: 'deny', pattern: 'write_file(tmp/*)' },
      { kind: 'ask', pattern: 'write_file' },
    ]);
    const v = decidePermission('write_file', { path: '/tmp/a' });
    expect(v.action).toBe('deny');  // deny 优先于 ask/allow
  });

  it('ask 返回确认请求', () => {
    setPermissionRules([{ kind: 'ask', pattern: 'write_file' }]);
    const v = decidePermission('write_file', { path: '/tmp/a' });
    expect(v.action).toBe('ask');
  });

  it('Bash(command:*) 前缀匹配', () => {
    setPermissionRules([{ kind: 'deny', pattern: 'Bash(command:rm -rf *)' }]);
    const v = decidePermission('bash', { command: 'rm -rf /home' });
    expect(v.action).toBe('deny');
    expect(decidePermission('bash', { command: 'ls' }).action).toBe('allow');
  });
});
