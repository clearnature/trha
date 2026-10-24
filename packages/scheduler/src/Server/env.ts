// Environment parsing, in one place.
//
// `Number(process.env.X ?? '')` is 0, so "unset" used to mean "zero" — which
// silently disabled subagents and the schedule driver in every deployment that
// did not set the variable. Unset, empty, non-numeric and out-of-range all mean
// "use the default" here.

export interface EnvIntOptions {
  /** Allow 0 as a real value (0 often means "off"). */
  allowZero?: boolean;
  /** Reject values below this (default 0). */
  min?: number;
}

export function envInt(name: string, fallback: number, opts: EnvIntOptions = {}): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const n = Number(raw);
  const min = opts.min ?? 0;
  if (!Number.isFinite(n) || n < min) return fallback;
  if (!opts.allowZero && n === 0) return fallback;
  return n;
}

/** Like 'envInt' but 0 (or unset) means Infinity — "no cap". */
export function envCap(name: string): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return Number.POSITIVE_INFINITY;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) return Number.POSITIVE_INFINITY;
  return n;
}
