// 内核权限规则引擎（scheduler 侧）：deny > ask > allow 三层，executeTool 前置判定。
// 规则格式（对齐 Reasonix Permissions）：ToolName、ToolName(glob)、Bash(command:* 或 glob)。
//   - ToolName          → 精确匹配工具名
//   - ToolName(glob)    → 工具名后跟参数 glob
//   - Bash(command:*)   → 命令前缀/通配
// 优先级：deny > ask > allow。无命中规则 → 默认 allow（沙箱已兜底文件边界）。

export interface PermissionRule {
  kind: 'deny' | 'ask' | 'allow';
  pattern: string;   // 原始规则串；pattern.matchFn(precomputed)
}

export type PermissionVerdict =
  | { action: 'allow' }
  | { action: 'deny'; reason: string }
  | { action: 'ask'; reason: string };

let rules: PermissionRule[] = [];

/** 查询当前规则集（测试/调试）。 */
export function getPermissionRules(): PermissionRule[] { return rules; }

/** 整体替换（前端持久化后同步；顺序无关，按优先级判）。 */
export function setPermissionRules(next: PermissionRule[]): void {
  rules = next.filter(r => r && typeof r.pattern === 'string' && ['deny', 'ask', 'allow'].includes(r.kind));
  recompile();
}

/** 解析 pattern → 匹配函数。种子：精确名 / glob / Bash(prefix:glob)。 */
function compilePattern(pattern: string): (name: string, args: Record<string, unknown>) => boolean {
  const p = pattern.trim();
  // Bash(command:*) —— 匹配工具名 bash 或任何 command 参数
  const bashMatch = /^Bash\(command:(.*)\)$/.exec(p);
  if (bashMatch) {
    const glob = bashMatch[1] ?? '';
    const re = new RegExp(globToRegex(glob), 'i');
    return (_name, args) => {
      const cmd = typeof args.command === 'string' ? args.command
        : typeof args.cmd === 'string' ? args.cmd
        : typeof args.full === 'string' ? args.full : '';
      return re.test(cmd);
    };
  }
  // ToolName(glob)
  const toolArgMatch = /^([A-Za-z0-9_]+)\((.*)\)$/.exec(p);
  if (toolArgMatch) {
    const tool = toolArgMatch[1];
    const glob = toolArgMatch[2] ?? '';
    const re = new RegExp(globToRegex(glob), 'i');
    return (name, args) => name === tool && argsMatch(re, args);
  }
  // ToolName 精确
  return name => name === p;
}

/** 简单 glob → regex（* 匹配任意串，? 单个字符）。 */
function globToRegex(glob: string): string {
  let re = '';
  for (const ch of glob) {
    if (ch === '*') re += '.*';
    else if (ch === '?') re += '.';
    else re += ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  return re;
}

/** 任意参数值命中 glob（字符串联）。 */
function argsMatch(re: RegExp, args: Record<string, unknown>): boolean {
  return Object.values(args).some(v => typeof v === 'string' && re.test(v));
}

export function isBashPattern(p: string): boolean { return /^Bash\(/.test(p.trim()); }

// 预编译缓存
interface Compiled { rule: PermissionRule; match: (name: string, args: Record<string, unknown>) => boolean; }
let compiled: Compiled[] = [];

function recompile(): void { compiled = rules.map(rule => ({ rule, match: compilePattern(rule.pattern) })); }

export function compileRules(): void { recompile(); }

/** 判定一次工具调用（优先级 deny > ask > allow）。 */
export function decidePermission(name: string, args: Record<string, unknown>): PermissionVerdict {
  if (compiled.length !== rules.length) recompile();
  if (compiled.length === 0) return { action: 'allow' };
  // 从高优先级扫：匹配的第一条按 kind 决定
  for (const kind of (['deny', 'ask', 'allow'] as const)) {
    for (const c of compiled) {
      if (c.rule.kind !== kind) continue;
      if (c.match(name, args)) {
        if (kind === 'deny') return { action: 'deny', reason: `denied by rule: ${c.rule.pattern}` };
        if (kind === 'ask') return { action: 'ask', reason: `requires confirmation: ${c.rule.pattern}` };
        return { action: 'allow' };
      }
    }
  }
  return { action: 'allow' };
}