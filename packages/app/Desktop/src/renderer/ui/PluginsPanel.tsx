// 插件面板（能力扩展 → 插件）——形态对齐 Reasonix Plugins 页：
//   标题行：已安装插件 · N 启用 · 共 N · 0 异常 + 刷新插件 + 安装插件
//   插件卡片：名称/发行方/兼容性徽标/版本 + 能力标签（skills/agents/commands/hooks/MCP）
// 接线状态：trha 无插件系统 —— 列表为预留（port.plugins()），操作按钮预留标注。

export interface PluginsPanelProps {
  t: (key: string) => string;
}

export interface PluginInfo {
  name: string;
  publisher: string;
  compatibility: 'full' | 'partial';
  version: string;
  skills: number;
  agents: number;
  commands: number;
  hooks: number;
  mcp: number;
  enabled: boolean;
}

// 预留数据源：const installed = await port.plugins()（Port 接口待加）。
// trha 无插件数据 ⇒ 空态（诚实）；示例结构见 PluginInfo。
export function PluginsPanel({ t }: PluginsPanelProps) {
  const plugins: PluginInfo[] = [];   // trha 尚无插件数据
  const enabled = plugins.filter(p => p.enabled).length;
  const erroring = 0;

  return (
    <div className="settings-pagebody">
      {/* 标题行 */}
      <div className="plugins-header">
        <h3 className="plugins-title">{t('settings.plugins.title')}</h3>
        <div className="plugins-stats">
          <span>{enabled} {t('settings.plugins.enabled')}</span>
          <span>· {t('settings.plugins.total', { n: String(plugins.length) })}</span>
          <span>· {erroring} {t('settings.plugins.erroring')}</span>
        </div>
        <div className="plugins-actions">
          <button type="button" className="btn" disabled title={t('settings.plugins.refreshPlanned')}>
            {t('settings.plugins.refresh')}
          </button>
          <button type="button" className="btn btn--primary" disabled title={t('settings.plugins.installPlanned')}>
            {t('settings.plugins.install')}
          </button>
        </div>
      </div>

      {/* 列表 */}
      {plugins.length === 0 ? (
        <div className="mcp-empty">
          <p>{t('settings.plugins.empty')}</p>
          <code>{t('settings.plugins.planned')}</code>
        </div>
      ) : (
        <div className="plugins-list">
          {plugins.map(p => (
            <div key={p.name} className="plugin-card">
              <div className="plugin-head">
                <span className="plugin-name">{p.name}</span>
                <span className="plugin-publisher">{p.publisher}</span>
                <span className={`plugin-compat plugin-compat--${p.compatibility}`}>
                  {p.compatibility === 'full' ? t('settings.plugins.compatFull') : t('settings.plugins.compatPartial')}
                </span>
                <span className="plugin-version">{p.version}</span>
              </div>
              <div className="plugin-caps">
                <span>{p.skills} {t('settings.plugins.skills')}</span>
                <span>{p.agents} {t('settings.plugins.agents')}</span>
                <span>{p.commands} {t('settings.plugins.commands')}</span>
                <span>{p.hooks} {t('settings.plugins.hooks')}</span>
                <span>{p.mcp} {t('settings.plugins.mcp')}</span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export default PluginsPanel;