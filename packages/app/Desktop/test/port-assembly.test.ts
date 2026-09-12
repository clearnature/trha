import { describe, expect, it } from 'vitest';
import { clearApiRuntime, createPort, getApiRuntime, setApiRuntime } from '../src/renderer/port/index.js';
import { MockPort } from '../src/renderer/port/mock.js';
import { SchedulerPort } from '../src/renderer/port/http.js';

describe('port assembly', () => {
  beforeEach(() => clearApiRuntime());
  it('returns the mock under test mode or explicit mock', async () => {
    expect(createPort({ mock: true })).toBeInstanceOf(MockPort);
  });

  it('returns the scheduler port once a runtime is configured', async () => {
    setApiRuntime({ base: 'http://localhost:3456', useToken: true }, 't');
    const p = createPort({ mock: false });
    expect(p).toBeInstanceOf(SchedulerPort);
    expect(getApiRuntime()?.cfg.base).toBe('http://localhost:3456');
  });

  it('falls back to mock with a warning when no runtime is set', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    try {
      expect(createPort({ mock: false })).toBeInstanceOf(MockPort);
      expect(warn).toHaveBeenCalledOnce();
    } finally {
      warn.mockRestore();
    }
  });
});
