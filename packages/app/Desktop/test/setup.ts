// Node 22+ ships a global `localStorage` getter that is `undefined` unless the
// process was started with --localstorage-file.  In jsdom tests that getter sits
// in front of jsdom's own implementation, so `localStorage.clear()` throws
// "Cannot read properties of undefined".  Install an in-memory Storage whenever
// the global is missing; when a real one exists (browser/jsdom) leave it alone.
class MemoryStorage implements Storage {
  private store = new Map<string, string>();

  get length(): number {
    return this.store.size;
  }

  clear(): void {
    this.store.clear();
  }

  getItem(key: string): string | null {
    return this.store.has(key) ? this.store.get(key)! : null;
  }

  key(index: number): string | null {
    return [...this.store.keys()][index] ?? null;
  }

  removeItem(key: string): void {
    this.store.delete(key);
  }

  setItem(key: string, value: string): void {
    this.store.set(key, String(value));
  }
}

function currentStorage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

if (!currentStorage()) {
  Object.defineProperty(globalThis, 'localStorage', {
    value: new MemoryStorage(),
    configurable: true,
    writable: true,
  });
}
