// Phase 3 A1: local plugin directory loader.
//
// Scans a directory for ESM plugin modules (*.js / *.mjs) whose default
// export is a Plugin.  This gives function-carrying plugins a load path
// (startup registration) complementing the declarative HTTP registration.

import { readdir } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import type { Plugin } from './Plugin.js';

/** Load every plugin module found in `dir` (non-recursive). */
export async function loadPluginsFrom(dir: string): Promise<Plugin[]> {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = entries
    .filter(e => e.isFile() && (e.name.endsWith('.js') || e.name.endsWith('.mjs')))
    .sort((a, b) => a.name.localeCompare(b.name));

  const plugins: Plugin[] = [];
  for (const file of files) {
    const url = pathToFileURL(path.join(dir, file.name)).href;
    try {
      const mod = (await import(url)) as { default?: unknown };
      const p = mod.default;
      if (isPlugin(p)) {
        plugins.push(p);
      } else {
        console.warn(`plugin loader: ${file.name} has no Plugin default export; skipped`);
      }
    } catch (e) {
      console.warn(`plugin loader: failed to load ${file.name}:`, e);
    }
  }
  return plugins;
}

/** Load a single plugin module file (used by the directory watcher). */
export async function loadPluginFromFile(filePath: string): Promise<Plugin | null> {
  const url = pathToFileURL(filePath).href;
  try {
    const mod = (await import(url)) as { default?: unknown };
    return isPlugin(mod.default) ? mod.default : null;
  } catch (e) {
    console.warn(`plugin loader: failed to load ${filePath}:`, e);
    return null;
  }
}

function isPlugin(p: unknown): p is Plugin {
  if (typeof p !== 'object' || p === null) return false;
  const o = p as { name?: unknown; version?: unknown; description?: unknown };
  return typeof o.name === 'string'
    && typeof o.version === 'string'
    && typeof o.description === 'string';
}
