// i18n pairing contract: every user-visible key must exist in both languages.
//
// `MessageKey` is derived from `messages.zh`, and `t()` casts dynamic keys, so
// a missing English entry degrades to showing the raw key at runtime instead
// of failing to compile. This test makes that a build-time failure.
import { describe, it, expect } from 'vitest';
import { messages, LANGS } from '../src/renderer/ui/i18n.js';

describe('i18n pairing', () => {
  const zh = messages.zh as Record<string, string>;
  const en = messages.en as Record<string, string>;
  const zhKeys = Object.keys(zh);
  const enKeys = Object.keys(en);

  it('defines exactly the same keys in zh and en', () => {
    const missingInEn = zhKeys.filter(k => !(k in en));
    const missingInZh = enKeys.filter(k => !(k in zh));
    expect({ missingInEn, missingInZh }).toEqual({ missingInEn: [], missingInZh: [] });
  });

  it('has no empty translations', () => {
    const empty = [
      ...zhKeys.filter(k => zh[k]!.trim() === '').map(k => `zh:${k}`),
      ...enKeys.filter(k => en[k]!.trim() === '').map(k => `en:${k}`),
    ];
    expect(empty).toEqual([]);
  });

  it('exposes a table for every concrete language in LANGS', () => {
    const tables = messages as Record<string, unknown>;
    const missing = LANGS.filter(lang => lang !== 'auto' && !(lang in tables));
    expect(missing).toEqual([]);
  });
});
