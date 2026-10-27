// Scheduler host-lease handshake parsing (Electron host architecture):
// stdout of the child carries exactly one line of versioned JSON first:
//   {"v":1,"name":"trha-scheduler","port":28433}
// Unknown versions or names cause the host to refuse to start the child.

export interface Handshake {
  v: number;
  name: string;
  port: number;
}

/** Parse one handshake line; `null` for anything that is not a valid handshake. */
export function parseHandshake(line: string): Handshake | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith('{')) {
    return null;
  }
  try {
    const raw = JSON.parse(trimmed) as Partial<Handshake>;
    if (typeof raw.v !== 'number' || typeof raw.name !== 'string' || typeof raw.port !== 'number') {
      return null;
    }
    return { v: raw.v, name: raw.name, port: raw.port };
  } catch {
    return null;
  }
}

/** The host supports exactly v1 of the trha scheduler contract. */
export function isSupported(h: Handshake): boolean {
  return h.v === 1 && h.name === 'trha-scheduler';
}
