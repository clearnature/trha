// Desktop-side studio version client (P4): reads /studio/versions from the
// scheduler -- the loopback origin-less read is allowed, so the shell can
// show the running kernel version and the update pin.
//
// The scheduler serves HTTPS with a self-signed loopback certificate, so the
// request goes through node:https with validation disabled for 127.0.0.1
// only (Node's global fetch has no per-request TLS option).

import { get } from 'node:https';

export interface StudioInfo {
  current: string;
  pinned: string | null;
}

export async function fetchStudioInfo(port: number): Promise<StudioInfo> {
  const body = await getJson(`https://127.0.0.1:${port}/studio/versions`) as
    { current?: unknown; pinned?: unknown };
  if (typeof body.current !== 'string') {
    throw new Error('studio versions: malformed response');
  }
  return {
    current: body.current,
    pinned: typeof body.pinned === 'string' ? body.pinned : null,
  };
}

function getJson(url: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const req = get(url, { rejectUnauthorized: false }, res => {
      if (res.statusCode !== 200) {
        res.resume();
        reject(new Error(`studio versions: HTTP ${res.statusCode}`));
        return;
      }
      let data = '';
      res.setEncoding('utf8');
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch (e) { reject(e as Error); }
      });
    });
    req.on('error', reject);
    req.setTimeout(5000, () => req.destroy(new Error('studio versions: timeout')));
  });
}
