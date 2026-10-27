// RunPid.ts：runtime.json 注册表 + scheduler.pid 认领的全分支覆盖。
// HOME 重定向到临时目录（os.homedir() 在 POSIX 每次调用都读 $HOME），
// 不污染真实 ~/.trha。
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import * as RP from '../src/Core/RunPid.js';

let home = '';
let oldHome: string | undefined;

const ENTRY = { host: '127.0.0.1', port: 3000, pid: process.pid, token: 'tok' };

beforeEach(async () => {
  oldHome = process.env.HOME;
  home = await mkdtemp(path.join(tmpdir(), 'runpid-'));
  process.env.HOME = home;
  await mkdir(path.join(home, '.trha', 'run'), { recursive: true });
});

afterEach(async () => {
  process.env.HOME = oldHome;
  await rm(home, { recursive: true, force: true });
});

const runtimeFile = (): string => path.join(home, '.trha', 'runtime.json');

async function writeRuntime(json: unknown): Promise<void> {
  await writeFile(runtimeFile(), JSON.stringify(json));
}

describe('RunPid — runtime.json 注册表', () => {
  it('读缺失文件 → undefined', () => {
    expect(RP.readRuntimeSection('kernel')).toBeUndefined();
  });

  it('write 后 read 往返；kernel 与 scheduler 两节互不干扰', () => {
    RP.writeRuntimeSection('kernel', ENTRY);
    RP.writeRuntimeSection('scheduler', { ...ENTRY, port: 3100, token: 't2' });
    expect(RP.readRuntimeSection('kernel')?.port).toBe(3000);
    expect(RP.readRuntimeSection('scheduler')?.port).toBe(3100);
  });

  it('二次写入是覆盖，不是追加第二份', async () => {
    RP.writeRuntimeSection('kernel', ENTRY);
    RP.writeRuntimeSection('kernel', { ...ENTRY, port: 3200 });
    expect(RP.readRuntimeSection('kernel')?.port).toBe(3200);
    const raw = JSON.parse((await readFile(runtimeFile(), 'utf8')).toString());
    expect(Object.keys(raw).filter(k => k === 'kernel')).toHaveLength(1);
  });

  it('坏 JSON → undefined（不抛）', async () => {
    await writeFile(runtimeFile(), '{not json');
    expect(RP.readRuntimeSection('scheduler')).toBeUndefined();
  });

  it('字段类型不符 → undefined（host 缺失 / port 是字符串 / token 是数字）', async () => {
    await writeRuntime({ scheduler: { port: 1, pid: 2, token: 'x' } });
    expect(RP.readRuntimeSection('scheduler')).toBeUndefined();
    await writeRuntime({ scheduler: { host: 'h', port: '1', pid: 2, token: 'x' } });
    expect(RP.readRuntimeSection('scheduler')).toBeUndefined();
    await writeRuntime({ scheduler: { host: 'h', port: 1, pid: 2, token: 9 } });
    expect(RP.readRuntimeSection('scheduler')).toBeUndefined();
  });

  it('非对象节 → undefined', async () => {
    await writeRuntime({ scheduler: 42 });
    expect(RP.readRuntimeSection('scheduler')).toBeUndefined();
  });

  it('removeRuntimeSection：自己的 pid 才删；别人的留着', async () => {
    RP.writeRuntimeSection('kernel', ENTRY);
    RP.writeRuntimeSection('scheduler', ENTRY);
    RP.removeRuntimeSection('scheduler'); // pid = process.pid → 删
    expect(RP.readRuntimeSection('scheduler')).toBeUndefined();
    expect(RP.readRuntimeSection('kernel')).toBeDefined();

    RP.writeRuntimeSection('scheduler', { ...ENTRY, pid: 123456 });
    RP.removeRuntimeSection('scheduler'); // 别人的 pid → 不动
    expect(RP.readRuntimeSection('scheduler')).toBeDefined();
  });

  it('removeRuntimeSection 对坏文件静默', async () => {
    await writeFile(runtimeFile(), 'nope');
    expect(() => RP.removeRuntimeSection('kernel')).not.toThrow();
  });
});

describe('RunPid — scheduler.pid 认领', () => {
  it('干净目录 → 认领成功，pid 文件写的是当前进程', async () => {
    expect(RP.claimSchedulerPid()).toBe(true);
    const pid = (await readFile(RP.pidPath('scheduler'), 'utf8')).toString();
    expect(Number(pid)).toBe(process.pid);
  });

  it('pid 文件里是死 pid → 视为陈旧，覆盖认领', () => {
    RP.claimSchedulerPid();
    // 99999999 超出常见 pid_max ⇒ kill(pid,0) 必失败 ⇒ 不是活的调度器
    writeFile(RP.pidPath('scheduler'), '99999999').then(() => undefined);
    expect(RP.claimSchedulerPid()).toBe(true);
  });

  it('schedulerTokenFile 与 pid 文件同目录同名家族', () => {
    expect(RP.schedulerTokenFile()).toContain(path.join('.trha', 'run', 'scheduler.token'));
    expect(RP.pidPath('scheduler')).toContain(path.join('.trha', 'run', 'scheduler.pid'));
  });
});
