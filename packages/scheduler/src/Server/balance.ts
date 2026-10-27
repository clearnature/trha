// Provider account balance (Reasonix's status-line "余额").
//
// Reads the first in-use OpenAI-compatible provider from ~/.trha/providers.json
// (the same file the kernel uses) and asks its balance endpoint.  DeepSeek's
// `/user/balance` is the only one wired today; other providers answer 404 and
// that surfaces as "balance unavailable", never as a crash.

import { readFile } from 'node:fs/promises';
import path from 'node:path';

export interface Balance {
  currency: string;
  total: number;
}

interface ProviderRow {
  name?: string;
  baseUrl?: string;
  kind?: string;
  inUse?: boolean;
  keyEnv?: string;
}

/** Fetch the in-use provider's account balance. Throws when unavailable. */
export async function fetchBalance(home = process.env.HOME ?? ''): Promise<Balance> {
  const trha = path.join(home, '.trha');
  const raw = JSON.parse(await readFile(path.join(trha, 'providers.json'), 'utf8')) as {
    providers?: ProviderRow[];
  };
  const providers = raw.providers ?? [];
  const base = providers.find(p => p.kind === 'openai' && p.inUse)
    ?? providers.find(p => p.kind === 'openai')
    ?? providers.find(p => p.inUse)
    ?? providers[0];
  if (!base?.baseUrl) throw new Error('no provider configured');

  let key = base.keyEnv ? (process.env[base.keyEnv] ?? '') : '';
  if (!key) {
    try {
      const keys = JSON.parse(await readFile(path.join(trha, 'provider-keys.json'), 'utf8')) as {
        keys?: Record<string, string>;
      };
      key = (base.name ? keys.keys?.[base.name] : undefined) ?? '';
    } catch { /* no keys file */ }
  }
  if (!key) throw new Error(`no API key for ${base.name ?? 'provider'}`);

  const url = `${base.baseUrl.replace(/\/$/, '')}/user/balance`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${key}` } });
  if (!res.ok) throw new Error(`balance HTTP ${res.status}`);
  const data = (await res.json()) as {
    balance_infos?: Array<{ currency?: string; total_balance?: string }>;
  };
  const info = data.balance_infos?.[0];
  if (!info) throw new Error('no balance_infos in the response');
  return { currency: info.currency ?? 'CNY', total: Number(info.total_balance ?? 0) };
}
