// 通用设置面板（偏好设置 → 通用）——形态对齐 Reasonix GeneralSection：
//   区块一「桌面与语言」：语言（自动/中文/English，已接线 prefs.lang）、
//                         费用展示币种（预留）、会话体验-新会话默认权限（预留）
//   区块二「系统行为」：硬件加速、关闭窗口时、声音、底部信息栏样式、信息栏显示项（预留）
// 接线状态：语言 = done（prefs 持久化 + auto 跟随系统）；其余 = 预留（UI 呈现 + plannedInterface）。

import { FONT_SIZE_RANGE, type Lang } from '../state/prefs.js';
import { LANGS } from './i18n.js';
import { usePrefs } from './PrefsContext.js';

export interface GeneralSettingsPanelProps {
  t: (key: string) => string;
}

/** 预留设置项（reasonix 语义，未接线）：label + control 占位 + 说明。 */
function PlannedSetting({ label, control, hint }: { label: string; control: string; hint: string }) {
  return (
    <div className="setting-group">
      <label>{label}</label>
      <div className="planned-control" data-planned="1">{control}</div>
      <span className="param-hint">{hint}</span>
    </div>
  );
}

export function GeneralSettingsPanel({ t }: GeneralSettingsPanelProps) {
  const { prefs, setPrefs } = usePrefs();

  return (
    <div className="settings-pagebody">
      {/* 区块一：桌面与语言 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.general.desktopAndLanguage')}</h4>

        <div className="setting-group">
          <label htmlFor="pref-lang">{t('settings.general.language')}</label>
          <select
            id="pref-lang"
            value={prefs.lang}
            onChange={e => setPrefs({ lang: e.target.value as Lang })}
          >
            {LANGS.map(l => (
              <option key={l} value={l}>{t(`settings.general.lang.${l}`)}</option>
            ))}
          </select>
          <span className="param-hint">{t('settings.general.languageHint')}</span>
        </div>

        <PlannedSetting
          label={t('settings.general.currency')}
          control={t('settings.general.currencyControl')}
          hint={t('settings.general.currencyHint')}
        />

        <PlannedSetting
          label={t('settings.general.sessionPermission')}
          control={t('settings.general.sessionPermissionControl')}
          hint={t('settings.general.sessionPermissionHint')}
        />
      </section>

      {/* 区块二：系统行为 */}
      <section className="settings-block">
        <h4 className="settings-block-title">{t('settings.general.systemBehavior')}</h4>

        <PlannedSetting
          label={t('settings.general.hardwareAcceleration')}
          control={t('settings.general.hardwareAccelerationControl')}
          hint={t('settings.general.hardwareAccelerationHint')}
        />

        <PlannedSetting
          label={t('settings.general.closeBehavior')}
          control={t('settings.general.closeBehaviorControl')}
          hint={t('settings.general.closeBehaviorHint')}
        />

        <PlannedSetting
          label={t('settings.general.sound')}
          control={t('settings.general.soundControl')}
          hint={t('settings.general.soundHint')}
        />

        <div className="setting-group">
          <label htmlFor="pref-font">{t('settings.fontSize')}</label>
          <input
            id="pref-font"
            type="range"
            min={FONT_SIZE_RANGE.min}
            max={FONT_SIZE_RANGE.max}
            value={prefs.fontSize}
            onChange={e => setPrefs({ fontSize: Number(e.target.value) })}
          />
          <span className="pref-value">{prefs.fontSize}px</span>
        </div>
      </section>
    </div>
  );
}

export default GeneralSettingsPanel;