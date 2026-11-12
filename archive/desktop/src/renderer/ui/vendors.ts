// vendors.ts — one account, however many doors it answers on.
//
// Same idea as the reference implementation's ui/vendors.ts: the display name
// of an account is derived from its host, so nobody has to invent one, and two
// entries at the same host read as one service reached two ways.

/** The host of a base URL, lower-cased; falls back to the trimmed string. */
export function hostOf(baseUrl: string): string {
  try {
    return new URL(baseUrl).hostname.toLowerCase();
  } catch {
    return baseUrl.trim().toLowerCase();
  }
}

/** The name a person would use: "api.deepseek.com" is "deepseek". */
export function vendorLabel(host: string): string {
  const bare = host.replace(/^(www|api|open|gateway)\./, '');
  const first = bare.split('.')[0];
  return first || host;
}

/** The config name we prefill for a new source. */
export function derivedName(host: string): string {
  return vendorLabel(host).replace(/[^a-zA-Z0-9._-]/g, '-') || 'custom';
}

export function nameFrom(baseUrl: string): string {
  try {
    return derivedName(new URL(baseUrl).hostname.toLowerCase());
  } catch {
    return 'custom';
  }
}

/** Make a name unique among the ones already taken (adds -2, -3 …). */
export function uniqueName(base: string, taken: string[]): string {
  if (!taken.includes(base)) return base;
  for (let i = 2; i < 100; i++) {
    const candidate = `${base}-${i}`;
    if (!taken.includes(candidate)) return candidate;
  }
  return base;
}
