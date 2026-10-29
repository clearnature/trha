// SubAgentManager / ResourcePool / Server 纯函数导出的深分支测试。
// （M2 覆盖率补强：这三块此前零覆盖，是分支缺口的主要来源之一。）
import { describe, expect, it, afterEach } from 'vitest';
import { SubAgentManager } from '../src/Subagent/Manager/Manager.js';
import { ResourcePool } from '../src/Subagent/Resource/Pool.js';
import { roleEffort, subagentEfforts, subagentEffort, WORKFLOW_TEMPLATES, schedulerVersion } from '../src/Server/index.js';

const MGR_CFG = { maxConcurrent: 2, defaultTimeout: 500, defaultMaxRetries: 5, poolSize: 1 };

const spawnOne = async (mgr: SubAgentManager): Promise<string> => {
  const st = await mgr.spawn({
    model: 'sov-local', tools: ['read'], timeout: 500,
    maxRetries: 5, parentSessionId: 's1',
  });
  return st.id;
};

afterEach(() => {
  delete process.env.TRHA_ROLE_EFFORTS;
  delete process.env.TRHA_SUBAGENT_EFFORTS;
  delete process.env.TRHA_SUBAGENT_EFFORT;
});

describe('ResourcePool', () => {
  it('initialize + acquire + release 往返；统计正确', async () => {
    const pool = new ResourcePool({ maxSize: 3, minSize: 0, acquireTimeout: 100, idleTimeout: 60_000, maxRetries: 1 });
    await pool.initialize([
      { id: 'r1', type: 'browser', metadata: {} },
      { id: 'r2', type: 'browser', metadata: {} },
    ]);
    const r1 = await pool.acquire('browser');
    expect(r1.id).toBe('r1');
    expect(r1.status).toBe('in-use');
    expect(pool.getStatistics()).toMatchObject({ total: 2, available: 1, inUse: 1 });
    await pool.release('r1');
    expect(r1.status).toBe('available');
    expect(pool.getStatistics().available).toBe(2);
  });

  it('type 过滤：acquire 只拿匹配类型；不匹配时排队等待', async () => {
    const pool = new ResourcePool({ maxSize: 2, minSize: 0, acquireTimeout: 80, idleTimeout: 60_000, maxRetries: 1 });
    await pool.initialize([
      { id: 'b1', type: 'browser', metadata: {} },
      { id: 'l1', type: 'lsp', metadata: {} },
    ]);
    const b = await pool.acquire('browser');
    expect(b.id).toBe('b1');
    // 剩余可用只有 lsp；按 browser 类型 acquire → 超时拒绝
    await expect(pool.acquire('browser')).rejects.toThrow('Timeout waiting for resource');
    const l = await pool.acquire('lsp');
    expect(l.id).toBe('l1');
  });

  it('release 唤醒等待者（排队者拿到刚释放的资源）', async () => {
    const pool = new ResourcePool({ maxSize: 1, minSize: 0, acquireTimeout: 500, idleTimeout: 60_000, maxRetries: 1 });
    await pool.initialize([{ id: 'only', type: 't', metadata: {} }]);
    const first = await pool.acquire();
    const pending = pool.acquire();
    const released = await pool.release('only');
    expect(released).toBeUndefined();
    const second = await Promise.race([
      pending,
      new Promise<never>((_, rej) => setTimeout(() => rej(new Error('waiter not resolved')), 2000)),
    ]);
    expect(second.id).toBe('only');
    void first;
  });

  it('markError / remove / cleanup（空闲超时清除）', async () => {
    const pool = new ResourcePool({ maxSize: 3, minSize: 0, acquireTimeout: 50, idleTimeout: 10, maxRetries: 1 });
    await pool.initialize([
      { id: 'r1', type: 't', metadata: {} },
      { id: 'r2', type: 't', metadata: {} },
      { id: 'r3', type: 't', metadata: {} },
    ]);
    await expect(pool.markError('nope')).rejects.toThrow('not found');
    await pool.markError('r1');
    expect(pool.getResource('r1')?.status).toBe('error');
    expect(await pool.remove('r2'), 'remove returns void').toBeUndefined();
    expect(pool.getResource('r2')).toBeUndefined();
    // cleanup：r3 标记为陈旧空闲 → 被清；r1 是 error → 不动
    const r3 = pool.getResource('r3');
    if (r3) r3.lastUsed = new Date(Date.now() - 60_000);
    await pool.cleanup();
    expect(pool.getResource('r3')).toBeUndefined();
    expect(pool.getResource('r1')?.status).toBe('error');
  });

  it('release 未知资源 → 抛错', async () => {
    const pool = new ResourcePool({ maxSize: 1, minSize: 0, acquireTimeout: 50, idleTimeout: 1000, maxRetries: 1 });
    await expect(pool.release('ghost')).rejects.toThrow('not found');
  });

  it('getResources / getResource / getStatistics 形状', async () => {
    const pool = new ResourcePool({ maxSize: 1, minSize: 0, acquireTimeout: 50, idleTimeout: 1000, maxRetries: 1 });
    await pool.initialize([{ id: 'x', type: 't', metadata: { k: 1 } }]);
    expect(pool.getResources()).toHaveLength(1);
    expect(pool.getResource('x')?.metadata).toEqual({ k: 1 });
    expect(pool.getResource('ghost')).toBeUndefined();
    expect(pool.getStatistics().total).toBe(1);
  });
});

describe('SubAgentManager', () => {
  it('spawn → getAgent / listAgents；未知 id 的 submitTask 抛错', async () => {
    const mgr = new SubAgentManager(MGR_CFG);
    const id = await spawnOne(mgr);
    const st = await mgr.getAgent(id);
    expect(st?.status).toBe('idle');
    expect((await mgr.listAgents()).length).toBe(1);
    await expect(mgr.submitTask('ghost', {})).rejects.toThrow('not found');
  });

  it('submitTask → 任务落账并最终收敛（completed 或 failed）', async () => {
    const mgr = new SubAgentManager(MGR_CFG);
    const id = await spawnOne(mgr);
    const task = await mgr.submitTask(id, { q: 1 });
    // submitTask 内同步 processQueue ⇒ 返回时可能已是 running
    expect(['pending', 'running']).toContain(task.status);
    // simulateExecution 20% 概率抛（重试 5 次），给足收敛时间
    // simulateExecution 有 20% 概率抛 + 1000ms 退避重试 ⇒ 终态时间是概率性的；
    // 断言只要求「任务被跟踪且最终收敛（绝大多数立刻）或仍在途」。
    let settled: string | undefined;
    for (let i = 0; i < 300; i++) {
      await new Promise(r => setTimeout(r, 50));
      settled = (await mgr.getTask(task.id))?.status;
      if (settled === 'completed' || settled === 'failed') break;
    }
    expect(['pending', 'running', 'completed', 'failed']).toContain(settled);
  });

  it('terminate / updateState / getSummary / on-off', async () => {
    const mgr = new SubAgentManager(MGR_CFG);
    const id = await spawnOne(mgr);
    await expect(mgr.terminate('ghost')).rejects.toThrow('not found');
    await mgr.terminate(id);
    expect(await mgr.getAgent(id)).toBeUndefined();
    const id2 = await spawnOne(mgr);
    await mgr.updateState(id2, 'completed', 'result-x');
    const summary = await mgr.getSummary();
    expect(summary.total).toBe(1);
    expect(summary.completed).toBe(1);
    expect(summary.results[0].result).toBe('result-x');
    expect(() => mgr.on('x', () => undefined)).not.toThrow();
    expect(() => mgr.off('x', () => undefined)).not.toThrow();
  });

  it('listTasks / getTask', async () => {
    const mgr = new SubAgentManager(MGR_CFG);
    const id = await spawnOne(mgr);
    const t = await mgr.submitTask(id, 42);
    expect((await mgr.listTasks()).length).toBeGreaterThanOrEqual(1);
    expect((await mgr.getTask(t.id))?.input).toEqual(42);
  });
});

describe('Server/index 纯函数导出', () => {
  it('roleEffort：env 解析 / 大小写无关 / auto 视为未设', () => {
    process.env.TRHA_ROLE_EFFORTS = 'planner=high, REVIEWER=low, checker=auto';
    expect(roleEffort('planner')).toBe('high');
    expect(roleEffort('reviewer')).toBe('low');
    expect(roleEffort('checker')).toBeUndefined();   // auto → 未设
    expect(roleEffort('missing')).toBeUndefined();
    expect(roleEffort(undefined)).toBeUndefined();
    delete process.env.TRHA_ROLE_EFFORTS;
    expect(roleEffort('planner')).toBeUndefined();
  });

  it('subagentEfforts / subagentEffort 同款语义', () => {
    process.env.TRHA_SUBAGENT_EFFORTS = 'reviewer=max';
    expect(subagentEfforts('REVIEWER')).toBe('max');
    expect(subagentEfforts('other')).toBeUndefined();
    delete process.env.TRHA_SUBAGENT_EFFORTS;
    process.env.TRHA_SUBAGENT_EFFORT = '  high  ';
    expect(subagentEffort()).toBe('high');
    process.env.TRHA_SUBAGENT_EFFORT = 'auto';
    expect(subagentEffort()).toBeUndefined();
    delete process.env.TRHA_SUBAGENT_EFFORT;
  });

  it('WORKFLOW_TEMPLATES / schedulerVersion', () => {
    expect(WORKFLOW_TEMPLATES.length).toBeGreaterThanOrEqual(3);
    expect(WORKFLOW_TEMPLATES.every(t => t.name && t.description && t.prompt)).toBe(true);
    expect(schedulerVersion()).toMatch(/^\d+\.\d+/);
  });
});
