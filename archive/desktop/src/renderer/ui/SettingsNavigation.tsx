// 设置中心导航：左栏「8 组 × tab」两级导航（对齐 Reasonix SettingsNavigation）。
// status 徽标：done=实心 / partial=半 / scaffold=「规划中」提示（不冒充已接线）。

import { SETTINGS_GROUPS } from '../state/settingsTypes.js';

export interface SettingsNavigationProps {
  activeTab: string;
  onSelect: (tab: string) => void;
  t: (key: string) => string;
}

function StatusBadge({ status, t }: { status: 'done' | 'partial' | 'scaffold'; t: (key: string) => string }) {
  if (status === 'done') return <span className="settings-navtab-status settings-navtab-status--done" aria-label={t('settings.status.done')} />;
  if (status === 'partial') return <span className="settings-navtab-status settings-navtab-status--partial" title={t('settings.status.partial')} aria-label={t('settings.status.partial')}>●</span>;
  return <span className="settings-navtab-status settings-navtab-status--scaffold" title={t('settings.status.scaffold')}>◌</span>;
}

export function SettingsNavigation({ activeTab, onSelect, t }: SettingsNavigationProps) {
  return (
    <nav className="settings-nav" aria-label={t('settings.title')}>
      {SETTINGS_GROUPS.map(group => (
        <section className="settings-navgroup" key={group.id}>
          <div className="settings-navgroup-label">{t(group.labelKey)}</div>
          <ul className="settings-navtabs">
            {group.tabs.map(tab => {
              const active = tab.id === activeTab;
              return (
                <li key={tab.id}>
                  <button
                    type="button"
                    className={`settings-navtab ${active ? 'active' : ''}`}
                    aria-current={active ? 'page' : undefined}
                    onClick={() => onSelect(tab.id)}
                    title={tab.plannedInterface}
                  >
                    <span className="settings-navtab-label">{t(tab.labelKey)}</span>
                    <StatusBadge status={tab.status} t={t} />
                  </button>
                </li>
              );
            })}
          </ul>
        </section>
      ))}
    </nav>
  );
}

export default SettingsNavigation;