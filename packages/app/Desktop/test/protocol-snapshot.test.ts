// Protocol shape snapshot: starts the real scheduler (same handshake/token/
// stdin-lease contract the Electron shell uses), drives the endpoints the
// desktop port layer consumes, and compares the *shape* of every response
// (field names + types) with test/fixtures/protocol-shape.json.
//
// Values are deliberately not compared — ids, timestamps and model lists
// change legitimately. A changed field name or type is a protocol break.
//
// Regenerate after an intentional protocol change:
//   UPDATE_SNAPSHOTS=1 npx vitest run test/protocol-snapshot.test.ts
import { describe, it, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { collectProtocol } from '../scripts/e2e-desktop.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const desktopRoot = path.resolve(here, '..');
const repoRoot = path.resolve(desktopRoot, '../../..');
const schedulerEntry = path.join(repoRoot, 'packages/scheduler/dist/cli.js');
const hasScheduler = fs.existsSync(schedulerEntry);
const fixturePath = path.join(here, 'fixtures', 'protocol-shape.json');

type Shape = string | Shape[] | { [key: string]: Shape };

function shape(value: unknown): Shape {
  if (Array.isArray(value)) {
    return value.length > 0 ? [shape(value[0])] : [];
  }
  if (value !== null && typeof value === 'object') {
    const out: { [key: string]: Shape } = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = shape((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return typeof value;
}

describe('desktop protocol shape', () => {
  it.runIf(hasScheduler)(
    'matches the recorded fixture',
    async () => {
      const snap = await collectProtocol({ port: 3481 });
      const shaped = {
        handshake: shape(snap.handshake),
        health: shape(snap.health),
        modes: shape(snap.modes),
        models: shape(snap.models),
        session: shape(snap.session),
        sessions: shape(snap.sessions),
        messages: shape(snap.messages),
        http: snap.http,
        exitCode: snap.exitCode,
      };

      if (process.env.UPDATE_SNAPSHOTS === '1') {
        fs.mkdirSync(path.dirname(fixturePath), { recursive: true });
        fs.writeFileSync(fixturePath, `${JSON.stringify(shaped, null, 2)}\n`);
      }

      const expected = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
      expect(shaped).toEqual(expected);
    },
    60000,
  );

  it.runIf(!hasScheduler)('is skipped until the scheduler is built', () => {
    expect(true).toBe(true);
  });
});
