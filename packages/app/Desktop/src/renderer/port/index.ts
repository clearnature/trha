/// <reference types="vite/client" />
// Port assembly: pick the implementation for the runtime.
//   * mock: tests/development without a backend (vitest MODE=test default)
//   * real: SchedulerPort over the configured API runtime (must be set by
//     bootstrap -- setApiRuntime); falling back to mock with a warning when
//     no runtime was configured is an explicit developer affordance.

import type { Port } from './port.js';
import { MockPort } from './mock.js';
import { SchedulerPort } from './http.js';
import { getApiRuntime } from './runtime.js';

export function createPort(opts: { mock?: boolean } = {}): Port {
  if (opts.mock === true || (opts.mock !== false && import.meta.env?.MODE === 'test')) {
    return new MockPort();
  }
  const runtime = getApiRuntime();
  if (!runtime) {
    console.warn('[port] no API runtime configured; using mock port');
    return new MockPort();
  }
  return new SchedulerPort(runtime.cfg, runtime.token);
}

export { MockPort, SchedulerPort };
export type { Port };
export { setApiRuntime, getApiRuntime, clearApiRuntime } from './runtime.js';
