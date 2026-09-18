// 预留功能面板（capability/未接线 tab 的 UI 呈现）。
// 诚实标注「规划中」+ plannedInterface 说明，不冒充已接线。

export interface ScaffoldPanelProps {
  tabId: string;
  titleKey: string;
  descriptionKey: string;
  plannedInterface: string | undefined;
  statusKey: string;
  t: (key: string) => string;
}

export function ScaffoldPanel({ titleKey, descriptionKey, plannedInterface, statusKey, t }: ScaffoldPanelProps) {
  return (
    <div className="settings-pagebody">
      <div className="settings-page-title">
        <h3>{t(titleKey)}</h3>
        <span className="settings-scaffold-badge">{t(statusKey)}</span>
      </div>
      <p className="settings-page-desc">{t(descriptionKey)}</p>
      {plannedInterface && (
        <div className="settings-planned-interface">
          <h4>{t('settings.scaffold.interface')}</h4>
          <code>{plannedInterface}</code>
        </div>
      )}
    </div>
  );
}

export default ScaffoldPanel;