import { describe, it, expect } from 'vitest';
import { LANGS, messages, t } from '../src/renderer/ui/i18n.js';

describe('i18n', () => {
  it('covers every key in all locales (no gaps)', () => {
    const zhKeys = Object.keys(messages.zh).sort();
    for (const lang of LANGS) {
      expect(Object.keys(messages[lang]).sort(), `locale ${lang}`).toEqual(zhKeys);
    }
  });

  it('interpolates {var} placeholders', () => {
    expect(t('en', 'list.messages', { count: 3 })).toBe('3 messages');
    expect(t('zh', 'settings.currentMode', { mode: 'minimal' })).toBe('当前模式：minimal');
  });

  it('translates per language', () => {
    expect(t('en', 'composer.send')).toBe('Send');
    expect(t('zh', 'composer.send')).toBe('发送');
  });

  it('falls back to zh for an unknown locale', () => {
    expect(t('fr' as never, 'composer.send')).toBe('发送');
  });
});
