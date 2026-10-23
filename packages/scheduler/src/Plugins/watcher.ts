// Plugin directory hot reload (cordis reversible-effects reload model).
//
// Polls a plugin directory and reconciles the PluginManager against what is
// on disk: newly added files are registered, removed files are unregistered,
// changed files are reloaded (unregister + register).  The plan builder is a
// pure function (`computePlan`) so the reconciliation logic is unit-testable;
// the polling loop is a thin shell over it.

import { readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import type { PluginManager } from './Plugin.js';
import { loadPluginFromFile } from './loader.js';

export interface FileState {
  /** Plugin name currently loaded from this file, when known. */
  pluginName?: string | undefined;
  /** mtime (ms) of the file when it was last loaded. */
  mtimeMs: number;
}

export interface ReconcilePlan {
  added: string[];    // file paths to register
  removed: string[];  // plugin names to unregister
  changed: string[];  // file paths to reload (unregister + register)
}

/**
 * Diff the previously-known files against what is on disk now.
 * `known`: file path -> state captured after the last load.
 * `seen`:  file path -> { mtimeMs } just read from disk (pluginName empty).
 */
export function computePlan(
  known: Map<string, FileState>,
  seen: Map<string, FileState>,
): ReconcilePlan {
  const added: string[] = [];
  const removed: string[] = [];
  const changed: string[] = [];

  for (const file of seen.keys()) {
    const prev = known.get(file);
    if (!prev) {
      added.push(file);
    } else if (prev.mtimeMs !== (seen.get(file)?.mtimeMs ?? 0)) {
      changed.push(file);
    }
  }
  for (const file of known.keys()) {
    if (!seen.has(file)) {
      const name = known.get(file)?.pluginName;
      if (name) {
        removed.push(name);
      }
    }
  }
  return { added, removed, changed };
}

/**
 * Apply a plan against a manager: removals first, then adds/reloads.
 * Returns the plugin names loaded per file (for the caller's known-state).
 */
export async function applyPlan(
  manager: PluginManager,
  plan: ReconcilePlan,
  dir: string,
): Promise<Map<string, string>> {
  for (const name of plan.removed) {
    if (manager.getPlugin(name)) {
      await manager.unregister(name);
    }
  }
  const loaded = new Map<string, string>();
  for (const file of [...plan.changed, ...plan.added]) {
    const plugin = await loadPluginFromFile(path.join(dir, file));
    if (plugin) {
      if (manager.getPlugin(plugin.name)) {
        await manager.unregister(plugin.name);
      }
      await manager.register(plugin);
      loaded.set(file, plugin.name);
    }
  }
  return loaded;
}

/** Capture the on-disk plugin files of `dir` (name -> mtime). */
export async function scanDir(dir: string): Promise<Map<string, FileState>> {
  const out = new Map<string, FileState>();
  let entries;
  try {
    entries = await readdir(dir);
  } catch {
    return out;
  }
  for (const name of entries.filter(n => n.endsWith('.js') || n.endsWith('.mjs'))) {
    const full = path.join(dir, name);
    try {
      const st = await stat(full);
      if (st.isFile()) {
        out.set(name, { mtimeMs: st.mtimeMs });
      }
    } catch {
      // file vanished mid-scan; ignore
    }
  }
  return out;
}

/**
 * Start a polling watcher.  Returns a stop function.
 * `intervalMs` defaults to 1500 ms; `onError` receives load errors.
 */
export function startPluginWatcher(
  dir: string,
  manager: PluginManager,
  options: { intervalMs?: number; onError?: (e: unknown) => void } = {},
): () => void {
  const intervalMs = options.intervalMs ?? 1500;
  const onError = options.onError ?? ((e: unknown) => console.error('plugin watcher:', e));

  const known = new Map<string, FileState>();
  let stopped = false;

  void reconcileOnce(known).catch(onError);

  const timer = setInterval(() => {
    if (stopped) return;
    reconcileOnce(known).catch(onError);
  }, intervalMs);

  return () => {
    stopped = true;
    clearInterval(timer);
  };

  async function reconcileOnce(state: Map<string, FileState>): Promise<void> {
    const seen = await scanDir(dir);
    const plan = computePlan(state, seen);
    const loaded = await applyPlan(manager, plan, dir);
    // refresh known state with the mtimes we saw and the names we loaded;
    // keep the previous plugin name when a file is unchanged this round
    for (const [file, st] of seen) {
      state.set(file, {
        mtimeMs: st.mtimeMs,
        pluginName: loaded.get(file) ?? state.get(file)?.pluginName,
      });
    }
    for (const file of state.keys()) {
      if (!seen.has(file)) {
        state.delete(file);
      }
    }
  }
}
