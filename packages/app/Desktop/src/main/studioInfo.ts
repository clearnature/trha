// Desktop-side studio version client (P4): reads /studio/versions from the
// scheduler -- the loopback origin-less read is allowed, so the shell can
// show the running kernel version and the update pin.

export interface StudioInfo {
  current: string;
  pinned: string | null;
}

export async function fetchStudioInfo(port: number): Promise<StudioInfo> {
  const res = await fetch(`http://127.0.0.1:${port}/studio/versions`);
  if (!res.ok) {
    throw new Error(`studio versions: HTTP ${res.status}`);
  }
  const body = (await res.json()) as { current?: unknown; pinned?: unknown };
  if (typeof body.current !== 'string') {
    throw new Error('studio versions: malformed response');
  }
  return {
    current: body.current,
    pinned: typeof body.pinned === 'string' ? body.pinned : null,
  };
}
