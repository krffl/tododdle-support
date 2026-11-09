import type { SupportStorage } from './types';

/** Storage that lives only as long as the page or app process. The default. */
export function memoryStorage(): SupportStorage {
  const values = new Map<string, string>();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => {
      values.set(key, value);
    },
    removeItem: (key) => {
      values.delete(key);
    },
  };
}

export async function readJson<T>(
  storage: SupportStorage,
  key: string,
  guard: (value: unknown) => value is T,
): Promise<T | null> {
  let raw: string | null;
  try {
    raw = await storage.getItem(key);
  } catch {
    return null;
  }
  if (raw === null) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    return guard(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

export async function writeJson(storage: SupportStorage, key: string, value: unknown): Promise<void> {
  try {
    await storage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage is a cache. A full or blocked store must not break reporting.
  }
}
