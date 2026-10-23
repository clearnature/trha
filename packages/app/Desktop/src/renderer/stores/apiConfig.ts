// Renderer API client configuration.
//
// Two hosting modes:
//   * Electron shell (preload present): fetch the scheduler over
//     http://localhost:<port> with the session token from preload.
//   * /studio pages served same-origin by the scheduler: no base prefix,
//     no token header -- the loopback origin gate authorizes the request.
// The pure resolver is unit-testable without a window.

export interface ApiConfig {
  base: string;
  useToken: boolean;
}

export interface RuntimeHints {
  hasPreload: boolean;
  schedulerPort?: number | undefined;
  isStudioPath: boolean;
}

export function resolveApiConfig(hints: RuntimeHints): ApiConfig {
  if (hints.hasPreload && hints.schedulerPort) {
    return { base: `http://localhost:${hints.schedulerPort}`, useToken: true };
  }
  if (hints.isStudioPath) {
    // same-origin under /studio: the scheduler's loopback origin gate
    // authorizes these requests, so no base prefix and no token header
    return { base: '', useToken: false };
  }
  // plain browser against the default local port (same-origin only works
  // when the page itself is served by the scheduler; otherwise the API
  // will refuse -- explicit failure beats a silently wrong token)
  return { base: 'http://localhost:3456', useToken: false };
}
