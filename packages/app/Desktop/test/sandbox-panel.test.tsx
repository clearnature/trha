// @vitest-environment jsdom
import { describe, it, expect, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({
  status: {
    backend: 'linux-bwrap',
    enforcement: 'full',
    available: true,
    capabilities: {},
    notes: ['extra note'],
  } as Record<string, unknown>,
  scopes: [] as Array<Record<string, unknown>>,
  fail: false,
}));

vi.mock('../src/renderer/ui/SessionContext.js', () => ({
  useSessionStore: () => ({
    getState: () => ({
      port: {
        sandboxStatus: async () => {
          if (h.fail) throw new Error('down');
          return h.status;
        },
        sandboxScopes: async () => {
          if (h.fail) throw new Error('down');
          return h.scopes;
        },
        setWriteRoots: async (roots: string[]) => roots,
      },
    }),
  }),
}));

import { SandboxPanel } from '../src/renderer/ui/SandboxPanel.js';

const labels: Record<string, string> = {
  'settings.sandbox.backendTitle': 'SandBox backend',
  'settings.sandbox.backend': 'Backend',
  'settings.sandbox.enforcement': 'Enforcement',
  'settings.sandbox.available': 'SandBox',
  'settings.sandbox.scopes': 'Scopes',
  'settings.sandbox.yes': 'enabled',
  'settings.sandbox.no': 'disabled',
  'settings.sandbox.desc': 'desc',
};
const t = (key: string): string => labels[key] ?? key;

const reset = (): void => {
  h.fail = false;
  h.status = {
    backend: 'linux-bwrap',
    enforcement: 'full',
    available: true,
    capabilities: {},
    notes: ['extra note'],
  };
  h.scopes = [];
};

describe('SandboxPanel', () => {
  it('shows the backend, enforcement, switch and notes', async () => {
    reset();
    render(<SandboxPanel t={t} />);
    await waitFor(() => expect(screen.getByText('linux-bwrap')).toBeTruthy());
    expect(screen.getByText('full')).toBeTruthy();
    expect(screen.getByText('enabled')).toBeTruthy();
    expect(screen.getByText('extra note')).toBeTruthy();
  });

  it('summarises more than five scopes', async () => {
    reset();
    h.scopes = Array.from({ length: 7 }, (_, i) => ({
      id: `s${i}`,
      parent: null,
      depth: 0,
      policy: 'workspace-write',
      isolation: 'process',
      enabled: true,
      cwd: null,
    }));
    render(<SandboxPanel t={t} />);
    await waitFor(() => expect(screen.getByText(/…\+2/)).toBeTruthy());
    expect(screen.getByText(/s0 \(workspace-write\)/)).toBeTruthy();
  });

  it('shows disabled when the backend is unavailable', async () => {
    reset();
    h.status = { backend: 'none', enforcement: 'none', available: false, capabilities: {} };
    render(<SandboxPanel t={t} />);
    await waitFor(() => expect(screen.getByText('disabled')).toBeTruthy());
  });

  it('leaves the status blank when the port fails', async () => {
    reset();
    h.fail = true;
    render(<SandboxPanel t={t} />);
    await waitFor(() => expect(screen.getAllByText('—').length).toBeGreaterThan(0));
  });
});
