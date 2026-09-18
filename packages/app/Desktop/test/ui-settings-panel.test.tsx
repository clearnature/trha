// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { SettingsPanel } from '../src/renderer/ui/SettingsPanel.js';
import { PrefsProvider } from '../src/renderer/ui/PrefsContext.js';
import { SessionProvider, type SessionStore } from '../src/renderer/ui/SessionContext.js';
import { makeSessionStore } from '../src/renderer/state/sessionStore.js';
import { DEFAULT_PREFS, type Prefs, type PrefsBackend } from '../src/renderer/state/prefs.js';
import { MockPort } from '../src/renderer/port/mock.js';

let store: SessionStore;
let saved: Prefs;
const backend: PrefsBackend = {
  load: async () => ({ ...DEFAULT_PREFS }),
  save: async p => { saved = p; },
};

const mount = () => render(
  <PrefsProvider backend={backend} initial={{ ...DEFAULT_PREFS }}>
    <SessionProvider store={store}>
      <SettingsPanel onClose={() => {}} />
    </SessionProvider>
  </PrefsProvider>,
);

beforeEach(async () => {
  saved = { ...DEFAULT_PREFS };
  store = makeSessionStore(new MockPort());
  await store.getState().loadCatalog();
  await store.getState().loadVersion();
});

describe('SettingsPanel', () => {
  it('renders local prefs and the read-only kernel surface', () => {
    mount();
    // ✅ 2026-09-19 更新：设置中心分层级后，默认视图为 general（语言/主题/字号），
    // 版本等内核信息移入「关于」tab；此处断言 general 内容 + 8 组导航存在。
    // ✅ 2026-09-19：通用页现为「桌面与语言」区块（语言/费用币种/会话权限）+
    // 「系统行为」区块；主题/字号已移入「外观」tab。
    expect(screen.getByLabelText('界面语言')).toBeTruthy();
    expect(screen.getByText('桌面与语言')).toBeTruthy();   // 区块一
    expect(screen.getByText('系统行为')).toBeTruthy();     // 区块二
    // 导航分组（对齐 Reasonix 8 组）
    expect(screen.getByText('偏好设置')).toBeTruthy();
    expect(screen.getAllByText('模型').length).toBeGreaterThan(0);
    expect(screen.getByText('模型偏好')).toBeTruthy();
    expect(screen.getByText('集成与连接')).toBeTruthy();
  });

  it('persists a theme change through the injected backend（外观 tab）', async () => {
    mount();
    await userEvent.click(screen.getByText('外观'));   // 导航到外观 tab
    await userEvent.selectOptions(screen.getByLabelText('明暗模式'), 'dark');
    await waitFor(() => expect(saved.theme).toBe('dark'));
  });

  it('persists a font-size change（外观 tab）', async () => {
    mount();
    await userEvent.click(screen.getByText('外观'));
    await userEvent.selectOptions(screen.getByLabelText('界面字号'), 'small');
    await waitFor(() => expect(saved.fontSize).toBe(12));
  });

  it('switches language and re-renders labels（通用页）', async () => {
    mount();
    await userEvent.selectOptions(screen.getByLabelText('界面语言'), 'en');
    await waitFor(() => expect(screen.getByText('Settings')).toBeTruthy());
    expect(screen.getByText('Desktop & Language')).toBeTruthy();
  });
});
